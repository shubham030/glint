set(srcs "main.c" "lcd.c" "usb_vendor.c" "rle.c" "stream.c")

# Always built: touch.c guards its own body on BOARD_HAS_TOUCH, which only the
# selected board profile knows.
list(APPEND srcs "touch.c" "ft6336.c")

if(CONFIG_GLINT_ENABLE_WIFI)
    list(APPEND srcs "net.c")
endif()

if(CONFIG_IDF_TARGET_ESP32S3)
    list(APPEND srcs "power.cpp")
endif()

idf_component_register(SRCS ${srcs}
                       INCLUDE_DIRS "." "../../protocol")
