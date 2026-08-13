/* Template board profile — copy to boards/custom.h and fill in.
 *
 * Then run `idf.py menuconfig` → "glint board" → "Custom board", and build.
 * board.h supplies a default for everything not defined here and reports
 * anything missing by name at compile time, so start minimal and let the
 * compiler tell you what else this board needs.
 *
 * Nothing on the host side changes: the panel's size and capabilities reach
 * both hosts through the HELLO handshake.
 */
#pragma once

/* ------------------------------------------------------------- panel -- */

/* Native size in pixels, as the panel is wired — not as you intend to view it.
 * Rotation is the host's business (`--portrait` / `-landscape`). */
#define BOARD_LCD_H_RES 320
#define BOARD_LCD_V_RES 480

/* Start conservatively; SPI panels are usually specified to 40-80 MHz, and a
 * bus that is too fast shows as tearing or noise rather than a clean failure.
 * This is the ceiling on frame rate for a full-screen change. */
#define BOARD_LCD_PCLK_HZ (40 * 1000 * 1000)

/* 0: one data line plus a DC pin (ST7796 and most SPI panels).
 * 1: four data lines with commands carried in-band (CO5300 and other QSPI
 *    AMOLEDs). A QSPI profile defines D0..D3 and no DC pin. */
#define BOARD_LCD_QSPI 0

/* Placeholders. Replace every one with your board's actual pin; these are low
 * numbers only so this file compiles unedited on any ESP32 target. */
#define BOARD_PIN_LCD_SCLK GPIO_NUM_12
#define BOARD_PIN_LCD_CS   GPIO_NUM_10
#define BOARD_PIN_LCD_RST  GPIO_NUM_9 /* GPIO_NUM_NC if the panel has no reset */

#if !BOARD_LCD_QSPI
#define BOARD_PIN_LCD_MOSI GPIO_NUM_11
#define BOARD_PIN_LCD_DC   GPIO_NUM_13
#else
#define BOARD_PIN_LCD_D0 GPIO_NUM_4
#define BOARD_PIN_LCD_D1 GPIO_NUM_5
#define BOARD_PIN_LCD_D2 GPIO_NUM_6
#define BOARD_PIN_LCD_D3 GPIO_NUM_7
#endif

/* Optional, all default to 0. Get these wrong and the picture is mirrored,
 * colour-swapped or offset — visible immediately with `glint bars`. */
/* #define BOARD_LCD_SPI_MODE 3 */
/* #define BOARD_LCD_MIRROR_X 1 */
/* #define BOARD_LCD_MIRROR_Y 1 */
/* #define BOARD_LCD_INVERT   1 */
/* #define BOARD_LCD_GAP_X    6 */  /* column offset, if the panel is inset */
/* #define BOARD_LCD_GAP_Y    0 */

/* --------------------------------------------------------- backlight -- */

/* Exactly one of these: a GPIO (on/off), the same GPIO driven by LEDC (PWM),
 * or a panel brightness register (AMOLED, which has no backlight at all). */
#define BOARD_PIN_LCD_BL GPIO_NUM_14
/* #define BOARD_BL_USE_LEDC  1 */
/* #define BOARD_BL_USE_PANEL 1 */

/* ------------------------------------------------------------- touch -- */

/* Leave both at 0 for a display-only board; the handshake then reports no
 * touch points and hosts will not wait for taps. Adding a third controller
 * means a driver, a flag here, and one branch in touch.c. */
/* #define BOARD_HAS_FT6336  1 */
/* #define BOARD_HAS_CST9217 1 */

/* Needed by touch and by an AXP2101 PMU. */
/* #define BOARD_PIN_I2C_SDA GPIO_NUM_7 */
/* #define BOARD_PIN_I2C_SCL GPIO_NUM_8 */
/* #define BOARD_PIN_TP_RST  GPIO_NUM_15 */  /* GPIO_NUM_NC if unwired */
/* #define BOARD_PIN_TP_INT  GPIO_NUM_16 */

/* --------------------------------------------------------------- misc -- */

/* Set if an AXP2101 PMU must bring up the panel's rails before it will light. */
/* #define BOARD_HAS_AXP2101 1 */

/* Clear if the data port cannot present a serial device, which makes
 * `glint bootloader` useless on this board. See NOTES.md. */
/* #define BOARD_CAN_SERIAL_BOOT 0 */
