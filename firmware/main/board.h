/* Board pin maps. Primary target: the ESP32-P4-WIFI6-Touch-LCD-3.5 (pins
 * proven by the carplay/mapcast firmware for the same unit). The Waveshare
 * ESP32-S3-Touch-LCD-3.5 variant is kept for reference/backup — pins from its
 * factory demo. Both: ST7796 SPI, 320x480 portrait, BGR + colour-invert. */
#pragma once

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "sdkconfig.h"

#define BOARD_LCD_H_RES 320
#define BOARD_LCD_V_RES 480

#define BOARD_LCD_SPI_HOST SPI2_HOST
#define BOARD_LCD_PCLK_HZ  (80 * 1000 * 1000)

#if CONFIG_IDF_TARGET_ESP32P4

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

/* FT6336 on the shared ESP_I2C bus (schematic: TP_SDA/TP_SCL/TP_RST/TP_INT) */
#define BOARD_PIN_I2C_SDA GPIO_NUM_7
#define BOARD_PIN_I2C_SCL GPIO_NUM_8
#define BOARD_PIN_TP_RST  GPIO_NUM_29
#define BOARD_PIN_TP_INT  GPIO_NUM_50

#elif CONFIG_IDF_TARGET_ESP32S3

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

#define BOARD_PIN_I2C_SDA GPIO_NUM_8
#define BOARD_PIN_I2C_SCL GPIO_NUM_7
#define BOARD_PIN_TP_RST  GPIO_NUM_NC
#define BOARD_PIN_TP_INT  GPIO_NUM_NC

#else
#error "unsupported target — add a board pin map"
#endif

/* Largest single tile payload we accept: one full-width 64px strip. */
#define BOARD_MAX_TILE_LEN (BOARD_LCD_H_RES * 64 * 2)
