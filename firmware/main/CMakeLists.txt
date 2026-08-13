set(srcs "main.c" "lcd.c" "usb_vendor.c" "rle.c" "stream.c")

# Every board with a touch controller: the driver differs, touch.c does not.
if(CONFIG_GLINT_BOARD_P4_LCD35 OR CONFIG_GLINT_BOARD_S3_LCD35
   OR CONFIG_GLINT_BOARD_S3_AMOLED175)
    list(APPEND srcs "touch.c")
endif()

if(CONFIG_GLINT_ENABLE_WIFI)
    list(APPEND srcs "net.c")
endif()

if(CONFIG_IDF_TARGET_ESP32S3)
    list(APPEND srcs "power.cpp")
endif()

idf_component_register(SRCS ${srcs}
                       INCLUDE_DIRS "." "../../protocol")
