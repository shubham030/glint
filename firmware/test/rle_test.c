/* Host-side test for the firmware RLE decoder — it must accept exactly what
 * the Swift encoder produces (host/Sources/GlintCore/RLE.swift) and reject
 * anything malformed. Build and run with firmware/test/run.sh; no ESP-IDF and
 * no hardware required.
 */
#include "../main/rle.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check(int cond, const char *what)
{
    if (!cond) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

/* Mirrors the encoder's wire format: bit15 clear = RUN, set = LITERAL. */
static size_t put_run(uint8_t *p, uint16_t count, uint16_t value)
{
    p[0] = count & 0xFF;
    p[1] = count >> 8;
    p[2] = value & 0xFF;
    p[3] = value >> 8;
    return 4;
}

static size_t put_literal(uint8_t *p, const uint16_t *px, uint16_t count)
{
    const uint16_t word = count | 0x8000u;
    p[0] = word & 0xFF;
    p[1] = word >> 8;
    size_t n = 2;
    for (uint16_t i = 0; i < count; i++) {
        p[n++] = px[i] & 0xFF;
        p[n++] = px[i] >> 8;
    }
    return n;
}

static void test_single_run(void)
{
    uint8_t src[4];
    const size_t len = put_run(src, 1000, 0x1234);
    uint16_t dst[1000];

    check(rle_decode(src, len, dst, 1000) == 1000, "run decodes fully");
    for (int i = 0; i < 1000; i++) {
        if (dst[i] != 0x1234) {
            check(0, "run pixel value");
            break;
        }
    }
}

static void test_literal(void)
{
    const uint16_t px[5] = {1, 2, 3, 4, 5};
    uint8_t src[32];
    const size_t len = put_literal(src, px, 5);
    uint16_t dst[5] = {0};

    check(rle_decode(src, len, dst, 5) == 5, "literal decodes fully");
    check(memcmp(dst, px, sizeof(px)) == 0, "literal pixel values");
}

static void test_mixed(void)
{
    const uint16_t lit[3] = {0xAAAA, 0xBBBB, 0xCCCC};
    uint8_t src[64];
    size_t n = 0;
    n += put_run(src + n, 4, 0x0001);
    n += put_literal(src + n, lit, 3);
    n += put_run(src + n, 2, 0xFFFF);

    uint16_t dst[9] = {0};
    check(rle_decode(src, n, dst, 9) == 9, "mixed stream length");
    const uint16_t want[9] = {1, 1, 1, 1, 0xAAAA, 0xBBBB, 0xCCCC, 0xFFFF,
                              0xFFFF};
    check(memcmp(dst, want, sizeof(want)) == 0, "mixed stream contents");
}

static void test_rejects_malformed(void)
{
    uint16_t dst[16] = {0};

    uint8_t zero_count[4] = {0x00, 0x00, 0x00, 0x00};
    check(rle_decode(zero_count, 4, dst, 16) == -1, "zero count rejected");

    /* Claims 1000 pixels into a 16-pixel tile. */
    uint8_t overflow[4];
    put_run(overflow, 1000, 0x1234);
    check(rle_decode(overflow, 4, dst, 16) == -1, "overflow rejected");

    /* Decodes to fewer pixels than the tile needs. */
    uint8_t short_stream[4];
    put_run(short_stream, 8, 0x1234);
    check(rle_decode(short_stream, 4, dst, 16) == -1, "underflow rejected");

    /* Literal header promising more data than the buffer holds. */
    uint8_t truncated[6] = {0x03, 0x80, 0x11, 0x22, 0x33, 0x44};
    check(rle_decode(truncated, 6, dst, 3) == -1, "truncated literal rejected");

    /* A trailing odd byte must not be read as a count word. */
    uint8_t odd[5];
    put_run(odd, 4, 0x0007);
    odd[4] = 0x99;
    check(rle_decode(odd, 5, dst, 4) == 4, "trailing odd byte ignored");
}

static void test_full_tile_of_one_colour(void)
{
    static uint16_t dst[64 * 64];
    uint8_t src[8];
    size_t n = put_run(src, 3000, 0x2104);
    n += put_run(src + n, 64 * 64 - 3000, 0x2104);

    check(rle_decode(src, n, dst, 64 * 64) == 64 * 64,
          "consecutive runs cover a whole tile");
    check(dst[0] == 0x2104 && dst[64 * 64 - 1] == 0x2104, "tile edges filled");
}

/* The encoder splits anything longer than the 15-bit count field, so the
 * decoder must accept a maximum-length run followed by a remainder. */
static void test_maximum_length_run(void)
{
    static uint16_t dst[40000];
    uint8_t src[8];
    size_t n = put_run(src, 0x7FFF, 0xABCD);
    n += put_run(src + n, 40000 - 0x7FFF, 0xABCD);

    check(rle_decode(src, n, dst, 40000) == 40000, "0x7FFF run accepted");
    check(dst[0x7FFF] == 0xABCD, "remainder run continues the value");
}

/* Bytes produced by the real Swift encoder (GlintCore/RLE.swift) for a mixed
 * 4096-pixel tile: 100x black, 3 literals, 7x red, 2x green, then 3984x blue.
 * This is the cross-implementation contract — if either side's format drifts,
 * this test fails instead of the panel smearing. */
static void test_swift_encoder_fixture(void)
{
    static const uint8_t fixture[] = {
        0x64, 0x00, 0x00, 0x00, 0x03, 0x80, 0x11, 0x11, 0x22, 0x22, 0x33, 0x33,
        0x07, 0x00, 0x00, 0xF8, 0x02, 0x80, 0xE0, 0x07, 0xE0, 0x07, 0x90, 0x0F,
        0x1F, 0x00,
    };
    static uint16_t dst[4096];

    check(rle_decode(fixture, sizeof(fixture), dst, 4096) == 4096,
          "Swift fixture decodes to a full tile");
    check(dst[0] == 0x0000, "fixture pixel 0");
    check(dst[99] == 0x0000, "fixture pixel 99");
    check(dst[100] == 0x1111, "fixture pixel 100");
    check(dst[102] == 0x3333, "fixture pixel 102");
    check(dst[103] == 0xF800, "fixture pixel 103");
    check(dst[109] == 0xF800, "fixture pixel 109");
    check(dst[110] == 0x07E0, "fixture pixel 110");
    check(dst[111] == 0x07E0, "fixture pixel 111");
    check(dst[112] == 0x001F, "fixture pixel 112");
    check(dst[4095] == 0x001F, "fixture pixel 4095");
    check(sizeof(fixture) == 26, "encoder compressed 8KB to 26 bytes");
}

int main(void)
{
    test_swift_encoder_fixture();
    test_single_run();
    test_literal();
    test_mixed();
    test_rejects_malformed();
    test_full_tile_of_one_colour();
    test_maximum_length_run();

    if (failures == 0) {
        printf("rle_test: all checks passed\n");
        return 0;
    }
    printf("rle_test: %d failure(s)\n", failures);
    return 1;
}
