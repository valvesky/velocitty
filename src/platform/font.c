/* Native font discovery only; glyph rasterization stays in Velocitty. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Apple Color Emoji carries several sbix strikes and exceeds 64 MiB. Keep
 * native discovery bounded without excluding the system's emoji fallback. */
#ifdef __APPLE__
#define FONT_LIMIT (512u * 1024u * 1024u)
#else
#define FONT_LIMIT (64u * 1024u * 1024u)
#endif

static uint32_t be32(const unsigned char *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

/* Find which member of a TrueType collection owns the given sfnt header and
 * table directory (bytes starting at the member's offset table). Portable so
 * it is unit-testable off Windows. Returns 1 and sets *index on a unique-first
 * match, 0 otherwise. All reads are bounds-checked. */
int
velocitty_ttc_member(const unsigned char *ttc, size_t ttc_len, const unsigned char *dir, size_t dir_len, unsigned *index)
{
    uint32_t count;
    if (!ttc || !dir || !index || dir_len < 12 || ttc_len < 12 || memcmp(ttc, "ttcf", 4) != 0) return 0;
    count = be32(ttc + 8);
    if (count > (ttc_len - 12) / 4) return 0;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t off = be32(ttc + 12 + (size_t)i * 4);
        if (off > ttc_len || dir_len > ttc_len - off) continue;
        if (memcmp(ttc + off, dir, dir_len) == 0) { *index = i; return 1; }
    }
    return 0;
}

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define TAG_TTCF 0x66637474u /* 'ttcf' as GDI's little-endian DWORD tag */

static int CALLBACK
enum_family(const LOGFONTW *lf, const TEXTMETRICW *tm, DWORD type, LPARAM param)
{
    (void)lf; (void)tm; (void)type;
    *(int *)param = 1;
    return 0;
}

/* GetTextFaceW may return a localized family name (e.g. 微软雅黑 on Chinese
 * Windows) that differs from the requested English one. Enumeration lists
 * only installed families (never substitutes), and accepts either name, so
 * any hit means the requested family exists and CreateFontW selected it. */
static int
face_matches(HDC dc, const WCHAR *name, const WCHAR *actual)
{
    LOGFONTW lf;
    int found = 0;
    if (lstrcmpiW(name, actual) == 0) return 1;
    memset(&lf, 0, sizeof lf);
    lf.lfCharSet = DEFAULT_CHARSET;
    lstrcpynW(lf.lfFaceName, name, LF_FACESIZE);
    EnumFontFamiliesExW(dc, &lf, enum_family, (LPARAM)&found, 0);
    return found;
}

unsigned char *
velocitty_font_load(const char *family, int bold, int italic, int exact, size_t *len, unsigned *index)
{
    WCHAR name[LF_FACESIZE], actual[LF_FACESIZE];
    HDC dc;
    HFONT font;
    HGDIOBJ old;
    DWORD n, ttc;
    unsigned char *data = NULL;
    if (!family || !len || !index) return NULL;
    *index = 0;
    if (!exact && strcmp(family, "monospace") == 0) family = "Consolas";
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, family, -1, name, LF_FACESIZE)) return NULL;
    dc = CreateCompatibleDC(NULL);
    if (!dc) return NULL;
    font = CreateFontW(16, 0, 0, 0, bold ? FW_BOLD : FW_NORMAL, italic, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_TT_ONLY_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
        FIXED_PITCH | FF_MODERN, name);
    if (!font) { DeleteDC(dc); return NULL; }
    old = SelectObject(dc, font);
    if (exact && (!GetTextFaceW(dc, LF_FACESIZE, actual) || !face_matches(dc, name, actual))) goto done;
    ttc = GetFontData(dc, TAG_TTCF, 0, NULL, 0);
    if (ttc != GDI_ERROR && ttc) {
        /* Face lives in a collection: GetFontData(0) would return the member's
         * offset table with offsets relative to the whole file, so load the
         * whole collection and locate the selected member by its directory. */
        unsigned char head[12], *dir;
        DWORD tables, dir_len;
        if (ttc > FONT_LIMIT || ttc < 12) goto done;
        if (GetFontData(dc, 0, 0, head, 12) != 12) goto done;
        tables = (DWORD)head[4] << 8 | head[5];
        dir_len = 12 + 16 * tables;
        dir = malloc(dir_len);
        if (!dir) goto done;
        data = malloc(ttc);
        if (data && GetFontData(dc, 0, 0, dir, dir_len) == dir_len && GetFontData(dc, TAG_TTCF, 0, data, ttc) == ttc
            && velocitty_ttc_member(data, ttc, dir, dir_len, index)) {
            *len = ttc;
        } else {
            free(data); data = NULL; *index = 0;
        }
        free(dir);
        goto done;
    }
    n = GetFontData(dc, 0, 0, NULL, 0);
    if (n == GDI_ERROR || !n || n > FONT_LIMIT) goto done;
    data = malloc(n);
    if (data && GetFontData(dc, 0, 0, data, n) != n) { free(data); data = NULL; }
    if (data) *len = n;
done:
    SelectObject(dc, old);
    DeleteObject(font);
    DeleteDC(dc);
    return data;
}
#elif defined(__APPLE__)
#include <CoreText/CoreText.h>

static void put16(unsigned char *p, uint16_t v) { p[0] = v >> 8; p[1] = v; }
static void put32(unsigned char *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

unsigned char *
velocitty_font_load(const char *family, int bold, int italic, int exact, size_t *len, unsigned *index)
{
    CFStringRef name, actual;
    CTFontRef font, styled;
    CFArrayRef tags;
    CFDataRef tables[256] = {0};
    uint32_t table_tags[256];
    size_t n = 0, total, offset, count = 0;
    unsigned char *data = NULL;
    int cff = 0;
    if (!family || !len || !index) return NULL;
    *index = 0;
    name = CFStringCreateWithCString(NULL, family, kCFStringEncodingUTF8);
    if (!name) return NULL;
    font = !exact && strcmp(family, "monospace") == 0
        ? CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, 16, NULL)
        : CTFontCreateWithName(name, 16, NULL);
    if (!font) { CFRelease(name); return NULL; }
    actual = CTFontCopyFamilyName(font);
    if (exact && (!actual || CFStringCompare(name, actual, kCFCompareCaseInsensitive) != kCFCompareEqualTo)) {
        if (actual) CFRelease(actual);
        CFRelease(name); CFRelease(font); return NULL;
    }
    if (actual) CFRelease(actual);
    CFRelease(name);
    CTFontSymbolicTraits traits = (bold ? kCTFontBoldTrait : 0) | (italic ? kCTFontItalicTrait : 0);
    styled = traits ? CTFontCreateCopyWithSymbolicTraits(font, 16, NULL, traits, kCTFontBoldTrait | kCTFontItalicTrait) : NULL;
    if (styled) { CFRelease(font); font = styled; }
    tags = CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions);
    if (!tags) { CFRelease(font); return NULL; }
    n = (size_t)CFArrayGetCount(tags);
    if (n > 256) goto done;
    total = 12 + 16 * n;
    for (size_t i = 0; i < n; i++) {
        uint32_t tag = (uint32_t)(uintptr_t)CFArrayGetValueAtIndex(tags, (CFIndex)i);
        CFDataRef table = CTFontCopyTable(font, tag, kCTFontTableOptionNoOptions);
        if (!table) continue;
        size_t bytes = (size_t)CFDataGetLength(table);
        if (bytes > FONT_LIMIT || total > FONT_LIMIT - ((bytes + 3) & ~(size_t)3)) { CFRelease(table); goto done; }
        total += (bytes + 3) & ~(size_t)3;
        tables[count] = table; table_tags[count++] = tag;
        if (tag == 0x43464620) cff = 1; /* CFF */
    }
    if (!count) goto done;
    data = calloc(1, total);
    if (!data) goto done;
    put32(data, cff ? 0x4f54544f : 0x00010000);
    put16(data + 4, (uint16_t)count);
    uint16_t power = 1, selector = 0;
    while ((size_t)power * 2 <= count) { power *= 2; selector++; }
    put16(data + 6, power * 16); put16(data + 8, selector);
    put16(data + 10, (uint16_t)(count * 16 - power * 16));
    offset = 12 + 16 * count;
    for (size_t i = 0; i < count; i++) {
        size_t bytes = (size_t)CFDataGetLength(tables[i]);
        unsigned char *entry = data + 12 + 16 * i;
        put32(entry, table_tags[i]); put32(entry + 8, (uint32_t)offset); put32(entry + 12, (uint32_t)bytes);
        memcpy(data + offset, CFDataGetBytePtr(tables[i]), bytes);
        offset += (bytes + 3) & ~(size_t)3;
    }
    *len = offset;
done:
    for (size_t i = 0; i < count; i++) CFRelease(tables[i]);
    CFRelease(tags); CFRelease(font);
    return data;
}
#else
unsigned char *
velocitty_font_load(const char *family, int bold, int italic, int exact, size_t *len, unsigned *index)
{
    (void)family; (void)bold; (void)italic; (void)exact; (void)len;
    if (index) *index = 0;
    return NULL;
}
#endif

void velocitty_font_free(void *data) { free(data); }
