/* Private, allocation-free Unicode scalar codec shared by JSON, JNI and ECL.
 * Standard UTF-8 (RFC 3629), never JNI modified UTF-8 or replacement decoding.
 * All lengths exclude terminators. U+0000 is a scalar; callers decide whether
 * their transport admits it. No normalization is performed.
 */
#ifndef STARINTEL_UTF_H
#define STARINTEL_UTF_H

#include <stddef.h>
#include <stdint.h>

static inline size_t starintel_utf8_width(uint32_t cp)
{
    if (cp > 0x10ffffu || (cp >= 0xd800u && cp <= 0xdfffu)) return 0;
    return cp < 0x80u ? 1 : cp < 0x800u ? 2 : cp < 0x10000u ? 3 : 4;
}

static inline size_t starintel_utf8_encode(uint32_t cp, char *out)
{
    size_t n = starintel_utf8_width(cp);
    if (n == 1) out[0] = (char)cp;
    else if (n > 1) {
        size_t i;
        for (i = n - 1; i > 0; i--) {
            out[i] = (char)(0x80u | (cp & 0x3fu));
            cp >>= 6;
        }
        out[0] = (char)((n == 2 ? 0xc0u : n == 3 ? 0xe0u : 0xf0u) | cp);
    }
    return n;
}

/* On failure, neither the cursor nor output scalar changes. */
static inline int starintel_utf8_next(const char *data, size_t len,
                                      size_t *cursor, uint32_t *scalar)
{
    size_t p = *cursor, n, i;
    uint32_t cp, minimum;
    unsigned char lead;
    if (p >= len) return 0;
    lead = (unsigned char)data[p];
    if (lead < 0x80u) { n = 1; cp = lead; minimum = 0; }
    else if (lead >= 0xc2u && lead <= 0xdfu) { n = 2; cp = lead & 0x1fu; minimum = 0x80u; }
    else if (lead >= 0xe0u && lead <= 0xefu) { n = 3; cp = lead & 0x0fu; minimum = 0x800u; }
    else if (lead >= 0xf0u && lead <= 0xf4u) { n = 4; cp = lead & 7u; minimum = 0x10000u; }
    else return 0;
    if (n > len - p) return 0;
    for (i = 1; i < n; i++) {
        unsigned char ch = (unsigned char)data[p + i];
        if ((ch & 0xc0u) != 0x80u) return 0;
        cp = (cp << 6) | (ch & 0x3fu);
    }
    if (cp < minimum || !starintel_utf8_width(cp)) return 0;
    *cursor = p + n;
    *scalar = cp;
    return 1;
}

static inline int starintel_utf8_count(const char *data, size_t len, size_t *count)
{
    size_t p = 0, n = 0;
    uint32_t cp;
    while (p < len) {
        if (!starintel_utf8_next(data, len, &p, &cp)) return 0;
        n++;
    }
    *count = n;
    return 1;
}

static inline int starintel_utf16_next(const uint16_t *data, size_t len,
                                       size_t *cursor, uint32_t *scalar)
{
    size_t p = *cursor;
    uint32_t cp;
    if (p >= len) return 0;
    cp = data[p++];
    if (cp >= 0xd800u && cp <= 0xdbffu) {
        uint32_t low;
        if (p >= len) return 0;
        low = data[p++];
        if (low < 0xdc00u || low > 0xdfffu) return 0;
        cp = 0x10000u + ((cp - 0xd800u) << 10) + (low - 0xdc00u);
    } else if (cp >= 0xdc00u && cp <= 0xdfffu) return 0;
    *cursor = p;
    *scalar = cp;
    return 1;
}

static inline size_t starintel_utf16_encode(uint32_t cp, uint16_t *out)
{
    if (!starintel_utf8_width(cp)) return 0;
    if (cp < 0x10000u) { out[0] = (uint16_t)cp; return 1; }
    cp -= 0x10000u;
    out[0] = (uint16_t)(0xd800u | (cp >> 10));
    out[1] = (uint16_t)(0xdc00u | (cp & 0x3ffu));
    return 2;
}

/* ABI 1 accepts valid NUL-terminated strings. Scan only to its byte bound. */
static inline size_t starintel_bounded_strlen(const char *s, size_t limit)
{
    size_t n = 0;
    while (n < limit && s[n]) n++;
    return n;
}
#endif
