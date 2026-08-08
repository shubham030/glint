#include "rle.h"

#define LITERAL_FLAG 0x8000u
#define COUNT_MASK   0x7FFFu

static inline uint16_t rd16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

int rle_decode(const uint8_t *src, size_t src_len, uint16_t *dst,
               size_t dst_px)
{
    size_t si = 0;
    size_t di = 0;

    while (si + 1 < src_len) {
        const uint16_t word = rd16(src + si);
        si += 2;
        const size_t count = word & COUNT_MASK;
        if (count == 0) {
            return -1;
        }

        if (word & LITERAL_FLAG) {
            if (si + count * 2 > src_len || di + count > dst_px) {
                return -1;
            }
            for (size_t k = 0; k < count; k++) {
                dst[di++] = rd16(src + si);
                si += 2;
            }
        } else {
            if (si + 2 > src_len || di + count > dst_px) {
                return -1;
            }
            const uint16_t v = rd16(src + si);
            si += 2;
            for (size_t k = 0; k < count; k++) {
                dst[di++] = v;
            }
        }
    }

    return (di == dst_px) ? (int)di : -1;
}
