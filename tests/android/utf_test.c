/* Allocation-free production codec regressions: host C, no ECL/JNI/ART. */
#include "starintel_utf.h"
#include <stdio.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main(void)
{
    static const unsigned char malformed[][5] = {
        {0x80}, {0xc0,0x80}, {0xc1,0xbf}, {0xc2}, {0xc2,0x41},
        {0xe0,0x80,0x80}, {0xed,0xa0,0x80}, {0xed,0xbf,0xbf},
        {0xe2,0x82}, {0xf0,0x80,0x80,0x80}, {0xf4,0x90,0x80,0x80},
        {0xf5,0x80,0x80,0x80}, {0xff}, {0xf0,0x9f,0x99},
        {0xf0,0x9f,0x41,0x82}
    };
    static const size_t lengths[] = {1,2,2,1,2,3,3,3,2,4,4,4,1,3,4};
    static const uint16_t unpaired[][2] = {{0xd800}, {0xdc00}, {0xdbff,0x41}, {0xd800,0xd800}};
    static const size_t utf16_lengths[] = {1,1,2,2};
    uint32_t scalar;
    size_t i;
    /* Exhaustive scalar round trips including NUL, boundaries and non-BMP.
     * This also proves UTF-16/UTF-8 widths without relying on string strlen. */
    for (scalar = 0; scalar <= 0x10ffffu; scalar++) {
        char encoded[4];
        uint16_t units[2];
        uint32_t decoded = 0xffffffffu;
        size_t cursor = 0, bytes = starintel_utf8_encode(scalar, encoded);
        size_t count = starintel_utf16_encode(scalar, units);
        if (scalar >= 0xd800u && scalar <= 0xdfffu) {
            CHECK(!bytes && !count);
            continue;
        }
        CHECK(bytes >= 1 && bytes <= 4);
        CHECK(starintel_utf8_next(encoded, bytes, &cursor, &decoded));
        CHECK(decoded == scalar && cursor == bytes);
        cursor = 0;
        CHECK(starintel_utf16_next(units, count, &cursor, &decoded));
        CHECK(decoded == scalar && cursor == count);
    }
    for (i = 0; i < sizeof lengths / sizeof lengths[0]; i++) {
        size_t cursor = 0, count;
        uint32_t cp = 42;
        CHECK(!starintel_utf8_next((const char *)malformed[i], lengths[i], &cursor, &cp));
        CHECK(cursor == 0 && cp == 42);
        CHECK(!starintel_utf8_count((const char *)malformed[i], lengths[i], &count));
    }
    for (i = 0; i < sizeof utf16_lengths / sizeof utf16_lengths[0]; i++) {
        size_t cursor = 0;
        uint32_t cp = 42;
        CHECK(!starintel_utf16_next(unpaired[i], utf16_lengths[i], &cursor, &cp));
        CHECK(cursor == 0 && cp == 42);
    }
    CHECK(!starintel_utf8_width(0x110000u));
    CHECK(!starintel_utf8_width(0xffffffffu));
    printf("%u/%u Unicode scalar codec checks passed (host C only)\n", checks - failures, checks);
    return failures != 0;
}
