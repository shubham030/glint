/* Board selection and the contract every board profile must satisfy.
 *
 * A board is one file in boards/, chosen by the Kconfig option in
 * Kconfig.projbuild. Nothing else in the firmware refers to a specific board,
 * and the hosts never do: geometry travels in the HELLO handshake, so a new
 * panel is a firmware-only change.
 *
 * To add a board, copy boards/template.h to boards/custom.h, fill it in, and
 * pick "Custom board" in menuconfig. The checks at the bottom of this file
 * report anything the profile forgot, by name, at compile time.
 */
#pragma once

#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "sdkconfig.h"

#define BOARD_LCD_SPI_HOST SPI2_HOST

#if CONFIG_GLINT_BOARD_P4_LCD35
#include "boards/p4_lcd35.h"
#elif CONFIG_GLINT_BOARD_S3_AMOLED175
#include "boards/s3_amoled175.h"
#elif CONFIG_GLINT_BOARD_CUSTOM
#include "boards/custom.h"
#else
#error "no glint board selected — run menuconfig, or see main/boards/template.h"
#endif

/* ---------------------------------------------------------- optional -- */
/* Defaults for everything a profile may leave out, so a minimal profile is
 * short: an SPI panel with a GPIO backlight and no touch needs about a dozen
 * lines. */

#ifndef BOARD_LCD_QSPI
#define BOARD_LCD_QSPI 0 /* 1 = four data lines, commands in-band (CO5300) */
#endif
#ifndef BOARD_LCD_SPI_MODE
#define BOARD_LCD_SPI_MODE 0
#endif
#ifndef BOARD_LCD_MIRROR_X
#define BOARD_LCD_MIRROR_X 0
#endif
#ifndef BOARD_LCD_MIRROR_Y
#define BOARD_LCD_MIRROR_Y 0
#endif
#ifndef BOARD_LCD_INVERT
#define BOARD_LCD_INVERT 0
#endif
#ifndef BOARD_HAS_AXP2101
#define BOARD_HAS_AXP2101 0 /* AXP2101 PMU brings up the panel rails */
#endif
#ifndef BOARD_BL_USE_LEDC
#define BOARD_BL_USE_LEDC 0 /* PWM backlight rather than on/off GPIO */
#endif
#ifndef BOARD_BL_USE_PANEL
#define BOARD_BL_USE_PANEL 0 /* brightness is a panel register (AMOLED) */
#endif
#ifndef BOARD_HAS_FT6336
#define BOARD_HAS_FT6336 0
#endif
#ifndef BOARD_HAS_CST9217
#define BOARD_HAS_CST9217 0
#endif
#ifndef BOARD_CAN_SERIAL_BOOT
/* Whether the data port can present USB-Serial-JTAG on request. False on a
 * board whose data port is wired to a high-speed PHY; see NOTES.md. */
#define BOARD_CAN_SERIAL_BOOT 1
#endif

/* ---------------------------------------------------------- required -- */

#if !defined(BOARD_LCD_H_RES) || !defined(BOARD_LCD_V_RES)
#error "board profile must define BOARD_LCD_H_RES and BOARD_LCD_V_RES"
#endif
#if !defined(BOARD_LCD_PCLK_HZ)
#error "board profile must define BOARD_LCD_PCLK_HZ (panel clock)"
#endif
#if !defined(BOARD_PIN_LCD_SCLK) || !defined(BOARD_PIN_LCD_CS)
#error "board profile must define BOARD_PIN_LCD_SCLK and BOARD_PIN_LCD_CS"
#endif
#if !defined(BOARD_PIN_LCD_RST)
#error "board profile must define BOARD_PIN_LCD_RST (GPIO_NUM_NC if none)"
#endif

#if BOARD_LCD_QSPI
#if !defined(BOARD_PIN_LCD_D0) || !defined(BOARD_PIN_LCD_D1) \
    || !defined(BOARD_PIN_LCD_D2) || !defined(BOARD_PIN_LCD_D3)
#error "a QSPI profile must define BOARD_PIN_LCD_D0..D3"
#endif
#else
#if !defined(BOARD_PIN_LCD_MOSI) || !defined(BOARD_PIN_LCD_DC)
#error "an SPI profile must define BOARD_PIN_LCD_MOSI and BOARD_PIN_LCD_DC"
#endif
#endif

#if !BOARD_BL_USE_PANEL && !defined(BOARD_PIN_LCD_BL)
#error "define BOARD_PIN_LCD_BL, or BOARD_BL_USE_PANEL for a panel-register backlight"
#endif

#if (BOARD_HAS_FT6336 || BOARD_HAS_CST9217 || BOARD_HAS_AXP2101) \
    && (!defined(BOARD_PIN_I2C_SDA) || !defined(BOARD_PIN_I2C_SCL))
#error "touch or PMU needs BOARD_PIN_I2C_SDA and BOARD_PIN_I2C_SCL"
#endif

#if (BOARD_HAS_FT6336 || BOARD_HAS_CST9217) \
    && (!defined(BOARD_PIN_TP_RST) || !defined(BOARD_PIN_TP_INT))
#error "a touch profile must define BOARD_PIN_TP_RST and BOARD_PIN_TP_INT (GPIO_NUM_NC if none)"
#endif

#if BOARD_HAS_FT6336 && BOARD_HAS_CST9217
#error "pick one touch controller"
#endif

/* ----------------------------------------------------------- derived -- */

/* One flag for "this board can report touch at all", so the task, the handshake
 * and the build all key off the same thing. */
#define BOARD_HAS_TOUCH (BOARD_HAS_FT6336 || BOARD_HAS_CST9217)

#if BOARD_HAS_FT6336
#define BOARD_TOUCH_NAME "FT6336"
#elif BOARD_HAS_CST9217
#define BOARD_TOUCH_NAME "CST9217"
#else
#define BOARD_TOUCH_NAME "no touch"
#endif

/* Largest single tile payload the firmware accepts: one full-width 64px
 * strip. */
#define BOARD_MAX_TILE_LEN (BOARD_LCD_H_RES * 64 * 2)
