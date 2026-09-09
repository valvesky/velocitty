#define STBTT_STATIC
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#include <string.h>

enum { ZT_STB_INFO_CAP = 256 };

_Static_assert(sizeof(stbtt_fontinfo) <= ZT_STB_INFO_CAP, "stbtt_fontinfo grew");

int zt_stb_init(void *storage, const unsigned char *data, int len) {
    stbtt_fontinfo *info;
    int offset;
    (void)len;
    if (storage == NULL || data == NULL) return 0;
    memset(storage, 0, sizeof(stbtt_fontinfo));
    info = (stbtt_fontinfo *)storage;
    offset = stbtt_GetFontOffsetForIndex(data, 0);
    if (offset < 0) return 0;
    return stbtt_InitFont(info, data, offset);
}

void zt_stb_vmetrics(const void *storage, int *ascent, int *descent, int *line_gap, int *upem) {
    const stbtt_fontinfo *info = (const stbtt_fontinfo *)storage;
    stbtt_GetFontVMetrics(info, ascent, descent, line_gap);
    *upem = ((int)info->data[info->head + 18] << 8) | (int)info->data[info->head + 19];
}

int zt_stb_num_glyphs(const void *storage) {
    const stbtt_fontinfo *info = (const stbtt_fontinfo *)storage;
    return info->numGlyphs;
}

int zt_stb_find_glyph(const void *storage, int codepoint) {
    const stbtt_fontinfo *info = (const stbtt_fontinfo *)storage;
    return stbtt_FindGlyphIndex(info, codepoint);
}

int zt_stb_advance(const void *storage, int glyph) {
    const stbtt_fontinfo *info = (const stbtt_fontinfo *)storage;
    int adv = 0;
    int lsb = 0;
    stbtt_GetGlyphHMetrics(info, glyph, &adv, &lsb);
    return adv;
}

float zt_stb_scale(const void *storage, float size_px) {
    const stbtt_fontinfo *info = (const stbtt_fontinfo *)storage;
    return stbtt_ScaleForMappingEmToPixels(info, size_px);
}

void zt_stb_glyph_box(const void *storage, int glyph, float size_px, int *x0, int *y0, int *x1, int *y1) {
    const stbtt_fontinfo *info = (const stbtt_fontinfo *)storage;
    const float scale = stbtt_ScaleForMappingEmToPixels(info, size_px);
    stbtt_GetGlyphBitmapBox(info, glyph, scale, scale, x0, y0, x1, y1);
}

void zt_stb_make_glyph(const void *storage, int glyph, float size_px, unsigned char *out, int w, int h) {
    const stbtt_fontinfo *info = (const stbtt_fontinfo *)storage;
    const float scale = stbtt_ScaleForMappingEmToPixels(info, size_px);
    stbtt_MakeGlyphBitmap(info, out, w, h, w, scale, scale, glyph);
}
