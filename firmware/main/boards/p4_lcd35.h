/* ESP32-P4-WIFI6-Touch-LCD-3.5 — ST7796 over SPI, 320x480.
 *
 * A board profile: pin map and panel quirks for one piece of hardware. Nothing
 * outside this file knows the board — see board.h for the contract a profile
 * must satisfy, and boards/template.h to add your own.
 */
#pragma once

/* ESP32-P4-WIFI6-Touch-LCD-3.5. These pins are what this firmware drives;
 * verify against your own board's schematic before trusting them. */
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
#define BOARD_BL_USE_LEDC  0 /* plain GPIO: this board has no dimming */
#define BOARD_LCD_MIRROR_X 1 /* the panel scans mirrored */
#define BOARD_LCD_MIRROR_Y 0
#define BOARD_LCD_INVERT   1

/* FT6336 on the shared ESP_I2C bus (schematic: TP_SDA/TP_SCL/TP_RST/TP_INT) */
#define BOARD_HAS_FT6336  1
/* The OTG Type-C is wired to the UTMI (high-speed) PHY, and USB-Serial-JTAG
 * needs the internal FS PHY, so no serial device can appear on the data port.
 * This board is flashed over its separate UART Type-C (CH343) instead. */
#define BOARD_CAN_SERIAL_BOOT 0
#define BOARD_PIN_I2C_SDA GPIO_NUM_7
#define BOARD_PIN_I2C_SCL GPIO_NUM_8
#define BOARD_PIN_TP_RST  GPIO_NUM_29
#define BOARD_PIN_TP_INT  GPIO_NUM_50
