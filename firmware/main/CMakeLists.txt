# No REQUIRES on purpose: `main` auto-depends on every component in the build,
# including managed ones (esp_tinyusb) and the vendored drivers.
set(srcs "main.c" "lcd.c" "usb_vendor.c" "touch.c")

if(CONFIG_IDF_TARGET_ESP32S3)
    # AXP2101 PMU exists only on the S3-Touch-LCD-3.5 board
    list(APPEND srcs "power.cpp")
endif()

idf_component_register(SRCS ${srcs}
                       INCLUDE_DIRS ".")
