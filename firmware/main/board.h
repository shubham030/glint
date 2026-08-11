/* Board pin maps, selected by the Kconfig choice in Kconfig.projbuild.
 *
 * The host learns geometry from the HELLO handshake, so adding a panel here is
 * a firmware-only change — nothing on the Mac or Linux side needs to know.
 *
 * BOARD_LCD_QSPI picks the panel-IO shape: 0 = one data line + a DC pin
 * (ST7796), 1 = four data lines and commands carried in-band (CO5300). */
#pragma once

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "sdkconfig.h"

#define BOARD_LCD_SPI_HOST SPI2_HOST

#if CONFIG_GLINT_BOARD_P4_LCD35

/* ESP32-P4-WIFI6-Touch-LCD-3.5 — pins proven by carplay/mapcast on this unit. */
#define BOARD_LCD_H_RES    320
#define BOARD_LCD_V_RES    480
#define BOARD_LCD_QSPI     0
#define BOARD_LCD_PCLK_HZ  (80 * 1000 * 1000)
#define BOARD_PIN_LCD_MOSI GPIO_NUM_20
#define BOARD_PIN_LCD_SCLK GPIO_NUM_21
#define BOARD_PIN_LCD_CS   GPIO_NUM_23
#define BOARD_PIN_LCD_DC   GPIO_NUM_26
#define BOARD_PIN_LCD_RST  GPIO_NUM_27
#define BOARD_PIN_LCD_BL   GPIO_NUM_28
#define BOARD_LCD_SPI_MODE 3
#define BOARD_HAS_AXP2101  0
#define BOARD_BL_USE_LEDC  0 /* plain GPIO, exactly as mapcast proved */
#define BOARD_LCD_MIRROR_X 1 /* panel scans mirrored; mapcast sets this too */
#define BOARD_LCD_MIRROR_Y 0
#define BOARD_LCD_INVERT   1

/* FT6336 on the shared ESP_I2C bus (schematic: TP_SDA/TP_SCL/TP_RST/TP_INT) */
#define BOARD_HAS_FT6336  1
#define BOARD_PIN_I2C_SDA GPIO_NUM_7
#define BOARD_PIN_I2C_SCL GPIO_NUM_8
#define BOARD_PIN_TP_RST  GPIO_NUM_29
#define BOARD_PIN_TP_INT  GPIO_NUM_50

#elif CONFIG_GLINT_BOARD_S3_LCD35

/* Waveshare ESP32-S3-Touch-LCD-3.5 — pins from its factory demo. */
#define BOARD_LCD_H_RES    320
#define BOARD_LCD_V_RES    480
#define BOARD_LCD_QSPI     0
#define BOARD_LCD_PCLK_HZ  (80 * 1000 * 1000)
#define BOARD_PIN_LCD_MOSI GPIO_NUM_1
#define BOARD_PIN_LCD_SCLK GPIO_NUM_5
#define BOARD_PIN_LCD_CS   GPIO_NUM_NC /* tied active on-board */
#define BOARD_PIN_LCD_DC   GPIO_NUM_3
#define BOARD_PIN_LCD_RST  GPIO_NUM_NC /* no GPIO reset; PMU-powered */
#define BOARD_PIN_LCD_BL   GPIO_NUM_6
#define BOARD_LCD_SPI_MODE 0
#define BOARD_HAS_AXP2101  1
#define BOARD_BL_USE_LEDC  1
#define BOARD_LCD_MIRROR_X 0 /* factory demo runs unmirrored */
#define BOARD_LCD_MIRROR_Y 0
#define BOARD_LCD_INVERT   1

#define BOARD_HAS_FT6336  1
#define BOARD_PIN_I2C_SDA GPIO_NUM_8
#define BOARD_PIN_I2C_SCL GPIO_NUM_7
#define BOARD_PIN_TP_RST  GPIO_NUM_NC
#define BOARD_PIN_TP_INT  GPIO_NUM_NC

#elif CONFIG_GLINT_BOARD_S3_AMOLED175

/* Waveshare ESP32-S3-Touch-AMOLED-1.75 — CO5300 over QSPI, square 466x466.
 * Pin map and the quirks below (column offset, no TE line, brightness by panel
 * command rather than a backlight pin) come from the rivo firmware, which runs
 * this exact board. AMOLED has no backlight: CMD_BACKLIGHT maps to the panel's
 * own brightness register. */
#define BOARD_LCD_H_RES     466
#define BOARD_LCD_V_RES     466
#define BOARD_LCD_QSPI      1
#define BOARD_LCD_PCLK_HZ   (40 * 1000 * 1000)
#define BOARD_PIN_LCD_SCLK  GPIO_NUM_38
#define BOARD_PIN_LCD_D0    GPIO_NUM_4
#define BOARD_PIN_LCD_D1    GPIO_NUM_5
#define BOARD_PIN_LCD_D2    GPIO_NUM_6
#define BOARD_PIN_LCD_D3    GPIO_NUM_7
#define BOARD_PIN_LCD_CS    GPIO_NUM_12
#define BOARD_PIN_LCD_RST   GPIO_NUM_39
#define BOARD_LCD_SPI_MODE  0
#define BOARD_LCD_GAP_X     6 /* CO5300 column offset on this board */
#define BOARD_LCD_GAP_Y     0
#define BOARD_HAS_AXP2101   0 /* present at 0x34, but the panel needs no rail work */
#define BOARD_BL_USE_LEDC   0
#define BOARD_BL_USE_PANEL  1
#define BOARD_LCD_MIRROR_X  0
#define BOARD_LCD_MIRROR_Y  0
#define BOARD_LCD_INVERT    0 /* CO5300 drives RGB order directly */

/* CST9217 touch — not wired up yet; rivo has a patched multi-touch driver. */
#define BOARD_HAS_FT6336  0
#define BOARD_PIN_I2C_SDA GPIO_NUM_15
#define BOARD_PIN_I2C_SCL GPIO_NUM_14
#define BOARD_PIN_TP_RST  GPIO_NUM_40
#define BOARD_PIN_TP_INT  GPIO_NUM_11

#else
#error "no glint board selected — see main/Kconfig.projbuild"
#endif

#ifndef BOARD_BL_USE_PANEL
#define BOARD_BL_USE_PANEL 0
#endif

/* Largest single tile payload we accept: one full-width 64px strip. */
#define BOARD_MAX_TILE_LEN (BOARD_LCD_H_RES * 64 * 2)
