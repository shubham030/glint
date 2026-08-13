/* Waveshare ESP32-S3-Touch-AMOLED-1.75 — CO5300 over QSPI, 466x466.
 *
 * A board profile: pin map and panel quirks for one piece of hardware. Nothing
 * outside this file knows the board — see board.h for the contract a profile
 * must satisfy, and boards/template.h to add your own.
 */
#pragma once

/* Waveshare ESP32-S3-Touch-AMOLED-1.75 — CO5300 over QSPI, square 466x466.
 * Pin map and the quirks below (column offset, no TE line, brightness by panel
 * command rather than a backlight pin) follow the vendor's reference design,
 * which runs
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

#define BOARD_HAS_FT6336    0
#define BOARD_HAS_CST9217   1
#define BOARD_CAN_SERIAL_BOOT 1
#define BOARD_PIN_I2C_SDA GPIO_NUM_15
#define BOARD_PIN_I2C_SCL GPIO_NUM_14
#define BOARD_PIN_TP_RST  GPIO_NUM_40
#define BOARD_PIN_TP_INT  GPIO_NUM_11
