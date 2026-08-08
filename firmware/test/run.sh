#!/bin/sh
# Compiles the firmware's pure-C logic with the host compiler and runs it.
# No ESP-IDF, no board.
set -e
cd "$(dirname "$0")"
cc -std=c11 -Wall -Wextra -Werror -O2 -o /tmp/glint_rle_test \
    rle_test.c ../main/rle.c
/tmp/glint_rle_test
