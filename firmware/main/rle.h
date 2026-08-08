#pragma once

#include <stddef.h>
#include <stdint.h>

/* Decodes an RGB565_RLE stream (fmt 1 — see protocol/protocol.h and the Swift
 * encoder in host/Sources/GlintCore/RLE.swift). Writes exactly `dst_px` pixels
 * or fails: a stream that decodes to the wrong length is corrupt, and painting
 * it would smear the panel.
 *
 * Returns the pixel count written, or -1 on malformed input. */
int rle_decode(const uint8_t *src, size_t src_len, uint16_t *dst,
               size_t dst_px);
