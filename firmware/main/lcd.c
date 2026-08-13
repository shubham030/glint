#include "lcd.h"

#include "board.h"

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_check.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_vendor.h"

#if BOARD_LCD_QSPI
#include "esp_lcd_co5300.h"
#else
#include "esp_lcd_st7796.h"
#endif

#if BOARD_BL_USE_LEDC
#include "driver/ledc.h"
#endif

static const char *TAG = "lcd";

static esp_lcd_panel_handle_t s_panel;
static uint8_t s_bl_level = 200;

#if BOARD_BL_USE_LEDC

#define BL_LEDC_TIMER    LEDC_TIMER_1
#define BL_LEDC_MODE     LEDC_LOW_SPEED_MODE
#define BL_LEDC_CHANNEL  LEDC_CHANNEL_0
#define BL_LEDC_DUTY_RES LEDC_TIMER_10_BIT
#define BL_LEDC_FREQ_HZ  5000

static esp_err_t backlight_init(void)
{
    const ledc_timer_config_t timer_cfg = {
        .speed_mode = BL_LEDC_MODE,
        .timer_num = BL_LEDC_TIMER,
        .duty_resolution = BL_LEDC_DUTY_RES,
        .freq_hz = BL_LEDC_FREQ_HZ,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ESP_RETURN_ON_ERROR(ledc_timer_config(&timer_cfg), TAG, "ledc timer");

    const ledc_channel_config_t ch_cfg = {
        .speed_mode = BL_LEDC_MODE,
        .channel = BL_LEDC_CHANNEL,
        .timer_sel = BL_LEDC_TIMER,
        .intr_type = LEDC_INTR_DISABLE,
        .gpio_num = BOARD_PIN_LCD_BL,
        .duty = 0,
        .hpoint = 0,
    };
    return ledc_channel_config(&ch_cfg);
}

static void backlight_set(uint8_t level)
{
    const uint32_t duty = ((uint32_t)level * 1023u) / 255u;
    ledc_set_duty(BL_LEDC_MODE, BL_LEDC_CHANNEL, duty);
    ledc_update_duty(BL_LEDC_MODE, BL_LEDC_CHANNEL);
}

#elif BOARD_BL_USE_PANEL

/* AMOLED: no backlight exists — each pixel emits — so brightness is a panel
 * register. Set after init, since the panel handle must exist first. */
static esp_err_t backlight_init(void)
{
    return ESP_OK;
}

static void backlight_set(uint8_t level)
{
    if (s_panel != NULL) {
        /* The protocol carries 0..255; this panel wants a percentage and
         * rejects anything above 100. */
        esp_lcd_panel_co5300_set_brightness(s_panel,
                                            ((int)level * 100) / 255);
    }
}

#else /* plain GPIO backlight, as on the P4 board */

static esp_err_t backlight_init(void)
{
    const gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << BOARD_PIN_LCD_BL,
        .mode = GPIO_MODE_OUTPUT,
    };
    return gpio_config(&cfg);
}

static void backlight_set(uint8_t level)
{
    gpio_set_level(BOARD_PIN_LCD_BL, level > 0);
}

#endif

esp_err_t lcd_init(void)
{
    ESP_RETURN_ON_ERROR(backlight_init(), TAG, "backlight");

#if BOARD_LCD_QSPI
    /* Four data lines and no DC pin: the CO5300 carries the command in-band,
     * which is why lcd_cmd_bits is 32 rather than 8. */
    const spi_bus_config_t bus_cfg = {
        .sclk_io_num = BOARD_PIN_LCD_SCLK,
        .data0_io_num = BOARD_PIN_LCD_D0,
        .data1_io_num = BOARD_PIN_LCD_D1,
        .data2_io_num = BOARD_PIN_LCD_D2,
        .data3_io_num = BOARD_PIN_LCD_D3,
        .max_transfer_sz = BOARD_MAX_TILE_LEN + 64,
    };
#else
    const spi_bus_config_t bus_cfg = {
        .sclk_io_num = BOARD_PIN_LCD_SCLK,
        .mosi_io_num = BOARD_PIN_LCD_MOSI,
        .miso_io_num = -1,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = BOARD_MAX_TILE_LEN + 64,
    };
#endif
    ESP_RETURN_ON_ERROR(
        spi_bus_initialize(BOARD_LCD_SPI_HOST, &bus_cfg, SPI_DMA_CH_AUTO), TAG,
        "spi bus");

    const esp_lcd_panel_io_spi_config_t io_cfg = {
        .cs_gpio_num = BOARD_PIN_LCD_CS,
#if BOARD_LCD_QSPI
        .dc_gpio_num = -1,
        .lcd_cmd_bits = 32,
        .flags.quad_mode = true,
#else
        .dc_gpio_num = BOARD_PIN_LCD_DC,
        .lcd_cmd_bits = 8,
#endif
        .spi_mode = BOARD_LCD_SPI_MODE,
        .pclk_hz = BOARD_LCD_PCLK_HZ,
        .trans_queue_depth = 10,
        .lcd_param_bits = 8,
    };
    esp_lcd_panel_io_handle_t io = NULL;
    ESP_RETURN_ON_ERROR(
        esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)BOARD_LCD_SPI_HOST,
                                 &io_cfg, &io),
        TAG, "panel io");

#if BOARD_LCD_QSPI
    /* QSPI panels carry commands in-band rather than on a DC line. A board
     * whose panel needs a non-default init table can pass one here through
     * the driver's vendor_config. */
    const co5300_vendor_config_t vendor_cfg = {
        .flags.use_qspi_interface = 1,
    };
#endif
    const esp_lcd_panel_dev_config_t panel_cfg = {
        .reset_gpio_num = BOARD_PIN_LCD_RST,
#if BOARD_LCD_QSPI
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
#else
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_BGR,
#endif
        .bits_per_pixel = 16,
#if BOARD_LCD_QSPI
        .vendor_config = (void *)&vendor_cfg,
#endif
    };

#if BOARD_LCD_QSPI
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_co5300(io, &panel_cfg, &s_panel), TAG,
                        "co5300");
#else
    ESP_RETURN_ON_ERROR(esp_lcd_new_panel_st7796(io, &panel_cfg, &s_panel), TAG,
                        "st7796");
#endif
    ESP_RETURN_ON_ERROR(esp_lcd_panel_reset(s_panel), TAG, "reset");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_init(s_panel), TAG, "init");
#if BOARD_LCD_INVERT
    ESP_RETURN_ON_ERROR(esp_lcd_panel_invert_color(s_panel, true), TAG,
                        "invert");
#endif
#ifdef BOARD_LCD_GAP_X
    ESP_RETURN_ON_ERROR(
        esp_lcd_panel_set_gap(s_panel, BOARD_LCD_GAP_X, BOARD_LCD_GAP_Y), TAG,
        "gap");
#endif
    ESP_RETURN_ON_ERROR(
        esp_lcd_panel_mirror(s_panel, BOARD_LCD_MIRROR_X, BOARD_LCD_MIRROR_Y),
        TAG, "mirror");
    ESP_RETURN_ON_ERROR(esp_lcd_panel_disp_on_off(s_panel, true), TAG,
                        "disp on");
    backlight_set(s_bl_level); /* AMOLED needs the panel handle to exist */
    return ESP_OK;
}

esp_lcd_panel_handle_t lcd_panel(void)
{
    return s_panel;
}

void lcd_backlight(uint8_t level)
{
    s_bl_level = level;
    backlight_set(level);
}

void lcd_sleep(bool sleep)
{
    if (s_panel != NULL) {
        esp_lcd_panel_disp_on_off(s_panel, !sleep);
    }
    backlight_set(sleep ? 0 : s_bl_level);
}
