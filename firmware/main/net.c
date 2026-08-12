#include "net.h"

#include <errno.h>
#include <string.h>

#include "esp_check.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "mdns.h"
#include "nvs_flash.h"
#include "stream.h"
#include "usb_vendor.h"

static const char *TAG = "net";

#define AP_PASSWORD  "glintglint" /* WPA2 needs >= 8 characters */
#define AP_CHANNEL   1
#define AP_MAX_CONN  2
#define READ_TIMEOUT_MS 200

/* The accepted client, shared with net_send_event. -1 when nobody is on. */
static volatile int s_client = -1;
static SemaphoreHandle_t s_tx_lock;
static QueueHandle_t s_tile_queue;

/* ------------------------------------------------------------ transport -- */

static int net_read(void *ctx, void *buf, size_t max)
{
    const int fd = (int)(intptr_t)ctx;
    if (max == 0) {
        return 0;
    }
    const int got = recv(fd, buf, max, 0);
    if (got > 0) {
        return got;
    }
    if (got == 0) {
        return -1; /* orderly close */
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        return 0; /* idle: the parser will ask again */
    }
    ESP_LOGW(TAG, "recv failed: %d", errno);
    return -1;
}

static bool send_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    size_t sent = 0;
    while (sent < len) {
        const int n = send(fd, p + sent, len - sent, 0);
        if (n > 0) {
            sent += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK ||
                      errno == EINTR)) {
            vTaskDelay(pdMS_TO_TICKS(2));
            continue;
        }
        return false;
    }
    return true;
}

static bool net_write(void *ctx, const void *buf, size_t len)
{
    const int fd = (int)(intptr_t)ctx;
    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    const bool ok = send_all(fd, buf, len);
    xSemaphoreGive(s_tx_lock);
    return ok;
}

bool net_send_event(const glint_evt_t *evt)
{
    const int fd = s_client;
    if (fd < 0) {
        return false;
    }
    return net_write((void *)(intptr_t)fd, evt, sizeof(*evt));
}

/* ---------------------------------------------------------------- wifi -- */

static esp_err_t common_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_RETURN_ON_ERROR(err, TAG, "nvs");

    ESP_RETURN_ON_ERROR(esp_netif_init(), TAG, "netif");
    ESP_RETURN_ON_ERROR(esp_event_loop_create_default(), TAG, "event loop");
    return ESP_OK;
}

/* Advertised so the host never needs to be told a DHCP address: the panel is
 * reachable as glint.local. */
static void advertise(void)
{
    if (mdns_init() != ESP_OK) {
        ESP_LOGW(TAG, "mDNS unavailable — connect by IP");
        return;
    }
    mdns_hostname_set("glint");
    mdns_instance_name_set("glint panel");
    mdns_service_add(NULL, "_glint", "_tcp", GLINT_NET_PORT, NULL, 0);
    ESP_LOGI(TAG, "advertising glint.local:%d", GLINT_NET_PORT);
}

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id,
                          void *data)
{
    (void)arg;
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        ESP_LOGW(TAG, "wifi dropped — reconnecting");
        esp_wifi_connect();
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        const ip_event_got_ip_t *e = data;
        ESP_LOGI(TAG, "joined %s — panel at " IPSTR ":%d (glint.local)",
                 CONFIG_GLINT_WIFI_SSID, IP2STR(&e->ip_info.ip),
                 GLINT_NET_PORT);
        advertise();
    }
}

static esp_err_t sta_start(void)
{
    esp_netif_create_default_wifi_sta();
    const wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "wifi init");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                            on_wifi_event, NULL, NULL),
        TAG, "wifi events");
    ESP_RETURN_ON_ERROR(
        esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                            on_wifi_event, NULL, NULL),
        TAG, "ip events");

    wifi_config_t sta = {0};
    strlcpy((char *)sta.sta.ssid, CONFIG_GLINT_WIFI_SSID, sizeof(sta.sta.ssid));
    strlcpy((char *)sta.sta.password, CONFIG_GLINT_WIFI_PASSWORD,
            sizeof(sta.sta.password));
    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_STA), TAG, "mode");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_STA, &sta), TAG, "sta cfg");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start");
    /* Frames are big and latency matters more than battery here. */
    esp_wifi_set_ps(WIFI_PS_NONE);
    ESP_LOGI(TAG, "joining \"%s\"…", CONFIG_GLINT_WIFI_SSID);
    return ESP_OK;
}

static esp_err_t softap_start(void)
{
    esp_netif_create_default_wifi_ap();

    const wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_RETURN_ON_ERROR(esp_wifi_init(&cfg), TAG, "wifi init");

    /* Name the AP after the MAC so two panels never collide. */
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_SOFTAP);
    wifi_config_t ap = {0};
    snprintf((char *)ap.ap.ssid, sizeof(ap.ap.ssid), "glint-%02X%02X", mac[4],
             mac[5]);
    ap.ap.ssid_len = strlen((char *)ap.ap.ssid);
    strlcpy((char *)ap.ap.password, AP_PASSWORD, sizeof(ap.ap.password));
    ap.ap.channel = AP_CHANNEL;
    ap.ap.max_connection = AP_MAX_CONN;
    ap.ap.authmode = WIFI_AUTH_WPA2_PSK;

    ESP_RETURN_ON_ERROR(esp_wifi_set_mode(WIFI_MODE_AP), TAG, "mode");
    ESP_RETURN_ON_ERROR(esp_wifi_set_config(WIFI_IF_AP, &ap), TAG, "ap cfg");
    ESP_RETURN_ON_ERROR(esp_wifi_start(), TAG, "wifi start");
    /* Frames are big and latency matters more than range. */
    esp_wifi_set_ps(WIFI_PS_NONE);

    ESP_LOGI(TAG, "SoftAP \"%s\" up (pass %s) — panel at 192.168.4.1:%d",
             (char *)ap.ap.ssid, AP_PASSWORD, GLINT_NET_PORT);
    advertise();
    return ESP_OK;
}

static esp_err_t wifi_start(void)
{
    ESP_RETURN_ON_ERROR(common_init(), TAG, "common");
    /* Runtime rather than compile-time: Kconfig cannot express "this string is
     * non-empty", and both paths are small enough to always build. */
    if (strlen(CONFIG_GLINT_WIFI_SSID) > 0) {
        return sta_start();
    }
    ESP_LOGI(TAG, "no SSID configured — self-hosting an AP");
    return softap_start();
}

/* --------------------------------------------------------------- serve -- */

static void serve_client(int fd)
{
    /* A short receive timeout keeps the parser responsive without spinning. */
    const struct timeval tv = {
        .tv_sec = 0,
        .tv_usec = READ_TIMEOUT_MS * 1000,
    };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    const int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    /* A new client cannot inherit a half-received tile from the last one. */
    glint_stream_reset();
    s_client = fd;

    const glint_stream_io_t io = {
        .read = net_read,
        .write = net_write,
        .ctx = (void *)(intptr_t)fd,
        .name = "tcp",
    };
    glint_stream_run(&io, s_tile_queue, glint_stats());

    s_client = -1;
    close(fd);
}

static void accept_task(void *arg)
{
    (void)arg;

    for (;;) {
        const int listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (listener < 0) {
            ESP_LOGE(TAG, "socket: %d", errno);
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }
        const int one = 1;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

        struct sockaddr_in addr = {
            .sin_family = AF_INET,
            .sin_port = htons(GLINT_NET_PORT),
            .sin_addr.s_addr = htonl(INADDR_ANY),
        };
        if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
            listen(listener, 1) != 0) {
            ESP_LOGE(TAG, "bind/listen: %d", errno);
            close(listener);
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }
        ESP_LOGI(TAG, "listening on :%d", GLINT_NET_PORT);

        for (;;) {
            struct sockaddr_in peer;
            socklen_t peer_len = sizeof(peer);
            const int fd = accept(listener, (struct sockaddr *)&peer,
                                  &peer_len);
            if (fd < 0) {
                ESP_LOGW(TAG, "accept: %d", errno);
                break;
            }
            ESP_LOGI(TAG, "client %s connected", inet_ntoa(peer.sin_addr));
            serve_client(fd);
            ESP_LOGI(TAG, "client gone");
        }
        close(listener);
    }
}

esp_err_t net_init(QueueHandle_t tile_queue)
{
    s_tile_queue = tile_queue;
    s_tx_lock = xSemaphoreCreateMutex();
    ESP_RETURN_ON_FALSE(s_tx_lock != NULL, ESP_ERR_NO_MEM, TAG, "tx lock");

    ESP_RETURN_ON_ERROR(wifi_start(), TAG, "wifi");

    ESP_RETURN_ON_FALSE(
        xTaskCreatePinnedToCore(accept_task, "glint_net", 5120, NULL, 8, NULL, 0)
            == pdPASS,
        ESP_ERR_NO_MEM, TAG, "accept task");
    return ESP_OK;
}
