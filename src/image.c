// Image decoding (PNG, JPEG, GIF first frame) via the vendored wuffs release.
#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__STATIC_FUNCTIONS
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_CONFIG__MODULE__PNG
#define WUFFS_CONFIG__MODULE__JPEG
#define WUFFS_CONFIG__MODULE__LZW
#define WUFFS_CONFIG__MODULE__GIF
#include "wuffs-v0.4.c"

#include <stdlib.h>
#include <string.h>

#define ZT_IMAGE_MAX_DIMENSION 4096

static wuffs_base__image_decoder *zt_image_decoder(const unsigned char *d, size_t n, int *gif) {
    *gif = 0;
    wuffs_base__image_decoder *dec = NULL;
    if (n >= 8 && memcmp(d, "\x89PNG\r\n\x1a\n", 8) == 0) {
        dec = wuffs_png__decoder__alloc_as__wuffs_base__image_decoder();
    } else if (n >= 3 && d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) {
        dec = wuffs_jpeg__decoder__alloc_as__wuffs_base__image_decoder();
    } else if (n >= 6 && (memcmp(d, "GIF87a", 6) == 0 || memcmp(d, "GIF89a", 6) == 0)) {
        dec = wuffs_gif__decoder__alloc_as__wuffs_base__image_decoder();
        *gif = 1;
        // Report the logical-screen background so uncovered canvas pixels
        // get it, as stb_image did for the first frame.
        if (dec) wuffs_base__image_decoder__set_quirk(dec, WUFFS_GIF__QUIRK_HONOR_BACKGROUND_COLOR, 1);
    }
    // Like stb_image, do not reject images over CRC/Adler-32 mismatches
    // (also skips the checksum work). JPEG has no such quirk; its error
    // status for the unknown key is deliberately ignored.
    if (dec) wuffs_base__image_decoder__set_quirk(dec, WUFFS_BASE__QUIRK_IGNORE_CHECKSUM, 1);
    return dec;
}

// Fills the canvas with a premultiplied ARGB color as non-premultiplied RGBA.
static void zt_fill_rgba(unsigned char *pixels, size_t count, wuffs_base__color_u32_argb_premul argb) {
    uint32_t a = argb >> 24;
    if (a == 0) return; // Already zeroed (transparent).
    unsigned char px[4];
    px[0] = (unsigned char)(((argb >> 16) & 0xFF) * 255 / a);
    px[1] = (unsigned char)(((argb >> 8) & 0xFF) * 255 / a);
    px[2] = (unsigned char)((argb & 0xFF) * 255 / a);
    px[3] = (unsigned char)a;
    for (size_t i = 0; i < count; i++) memcpy(pixels + i * 4, px, 4);
}

static uint32_t zt_be32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static void zt_put_be32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v >> 24);
    p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8);
    p[3] = (unsigned char)v;
}

static int zt_is_cgbi(const unsigned char *d, size_t n) {
    return n >= 16 && memcmp(d, "\x89PNG\r\n\x1a\n", 8) == 0 && memcmp(d + 12, "CgBI", 4) == 0;
}

// Apple's CgBI PNG variant (iOS-optimized): a CgBI chunk before IHDR, IDAT
// holding raw DEFLATE without the zlib wrapper, and BGR(A) pixels with
// premultiplied alpha. Rewrites it as a standard PNG: chunks before the
// first IDAT are kept, every IDAT is merged into one zlib-wrapped IDAT.
// Checksums are written as zero; the decoder runs with checksums ignored.
// Sets `*alpha` when the image has an alpha channel to unpremultiply.
static unsigned char *zt_cgbi_to_png(const unsigned char *d, size_t n, size_t *out_n, int *alpha) {
    unsigned char *out = malloc(n + 64);
    if (out == NULL) return NULL;
    memcpy(out, d, 8);
    size_t o = 8, pos = 8, idat_len_at = 0;
    int in_idat = 0, done_idat = 0;
    *alpha = 0;
    while (pos + 12 <= n) {
        uint32_t len = zt_be32(d + pos);
        const unsigned char *type = d + pos + 4;
        if (len > n - pos - 12) break; // Truncated: decode what arrived.
        const unsigned char *body = d + pos + 8;
        pos += 12 + (size_t)len;
        if (memcmp(type, "IEND", 4) == 0) break;
        if (memcmp(type, "CgBI", 4) == 0) continue;
        if (memcmp(type, "IDAT", 4) == 0) {
            if (done_idat) continue;
            if (!in_idat) {
                in_idat = 1;
                idat_len_at = o;
                memcpy(out + o + 4, "IDAT", 4);
                out[o + 8] = 0x78; // zlib header: deflate, 32K window, no dictionary.
                out[o + 9] = 0x01;
                o += 10;
            }
            memcpy(out + o, body, len);
            o += len;
            continue;
        }
        if (in_idat) {
            done_idat = 1; // Chunks after the image data are not needed.
            continue;
        }
        if (memcmp(type, "IHDR", 4) == 0 && len >= 10) *alpha = body[9] == 6;
        memcpy(out + o, d + pos - 12 - len, 12 + (size_t)len);
        o += 12 + (size_t)len;
    }
    if (!in_idat) {
        free(out);
        return NULL;
    }
    // Adler-32 and chunk CRC (zero: ignored), then the IDAT length.
    memset(out + o, 0, 8);
    o += 8;
    zt_put_be32(out + idat_len_at, (uint32_t)(o - idat_len_at - 12));
    memcpy(out + o, "\0\0\0\0IEND\xae\x42\x60\x82", 12);
    o += 12;
    *out_n = o;
    return out;
}

// BGRA premultiplied (as decoded from a rewritten CgBI PNG) to RGBA.
static void zt_cgbi_fix(unsigned char *p, size_t count, int alpha) {
    for (size_t i = 0; i < count; i++, p += 4) {
        unsigned char t = p[0];
        p[0] = p[2];
        p[2] = t;
        unsigned a = p[3];
        if (!alpha || a == 255 || a == 0) continue;
        for (int c = 0; c < 3; c++) {
            unsigned v = (p[c] * 255u + a / 2) / a;
            p[c] = (unsigned char)(v > 255 ? 255 : v);
        }
    }
}

// Dimensions from the header alone. `closed` says `data` is the whole file;
// otherwise it is a prefix. Returns 1 with *w/*h set, 0 for an invalid or
// unsupported image, -1 when a longer prefix is needed.
int zt_image_info(const unsigned char *data, size_t n, int closed, int *w, int *h) {
    if (data == NULL || w == NULL || h == NULL) return 0;
    if (zt_is_cgbi(data, n)) {
        // IHDR follows the 4-byte CgBI chunk.
        if (n < 48) return closed ? 0 : -1;
        if (memcmp(data + 28, "IHDR", 4) != 0) return 0;
        uint32_t iw = zt_be32(data + 32), ih = zt_be32(data + 36);
        if (iw == 0 || ih == 0 || iw > ZT_IMAGE_MAX_DIMENSION || ih > ZT_IMAGE_MAX_DIMENSION) return 0;
        *w = (int)iw;
        *h = (int)ih;
        return 1;
    }
    int gif = 0;
    wuffs_base__image_decoder *dec = zt_image_decoder(data, n, &gif);
    if (dec == NULL) return (!closed && n < 8) ? -1 : 0;
    wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)data, n, closed != 0);
    wuffs_base__image_config ic;
    wuffs_base__status st = wuffs_base__image_decoder__decode_image_config(dec, &ic, &src);
    free(dec);
    if (st.repr == wuffs_base__suspension__short_read) return closed ? 0 : -1;
    if (st.repr) return 0;
    uint32_t iw = wuffs_base__pixel_config__width(&ic.pixcfg);
    uint32_t ih = wuffs_base__pixel_config__height(&ic.pixcfg);
    if (iw == 0 || ih == 0 || iw > ZT_IMAGE_MAX_DIMENSION || ih > ZT_IMAGE_MAX_DIMENSION) return 0;
    *w = (int)iw;
    *h = (int)ih;
    return 1;
}

static int zt_decode(const unsigned char *data, size_t n, int *w, int *h, unsigned char **out) {
    int gif = 0;
    wuffs_base__image_decoder *dec = zt_image_decoder(data, n, &gif);
    if (dec == NULL) return 0;

    int ok = 0;
    unsigned char *pixels = NULL;
    unsigned char *work = NULL;
    wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader((uint8_t *)data, n, true);
    wuffs_base__image_config ic;
    if (wuffs_base__image_decoder__decode_image_config(dec, &ic, &src).repr) goto done;

    uint32_t iw = wuffs_base__pixel_config__width(&ic.pixcfg);
    uint32_t ih = wuffs_base__pixel_config__height(&ic.pixcfg);
    if (iw == 0 || ih == 0 || iw > ZT_IMAGE_MAX_DIMENSION || ih > ZT_IMAGE_MAX_DIMENSION) goto done;
    wuffs_base__pixel_config__set(&ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
                                  WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, iw, ih);

    size_t size = (size_t)iw * ih * 4;
    pixels = calloc(size, 1);
    if (pixels == NULL) goto done;
    uint64_t wl = wuffs_base__image_decoder__workbuf_len(dec).max_incl;
    if (wl > SIZE_MAX) goto done;
    if (wl != 0) {
        work = malloc((size_t)wl);
        if (work == NULL) goto done;
    }

    if (gif) {
        // A GIF frame may cover only part of the canvas; the rest shows the
        // background (transparent when the background index is).
        wuffs_base__frame_config fc;
        if (wuffs_base__image_decoder__decode_frame_config(dec, &fc, &src).repr) goto done;
        zt_fill_rgba(pixels, (size_t)iw * ih, wuffs_base__frame_config__background_color(&fc));
    }

    wuffs_base__pixel_buffer pb;
    if (wuffs_base__pixel_buffer__set_from_slice(&pb, &ic.pixcfg, wuffs_base__make_slice_u8(pixels, size)).repr) goto done;
    if (wuffs_base__image_decoder__decode_frame(dec, &pb, &src, WUFFS_BASE__PIXEL_BLEND__SRC,
                                                wuffs_base__make_slice_u8(work, (size_t)wl), NULL).repr) goto done;

    *w = (int)iw;
    *h = (int)ih;
    *out = pixels;
    pixels = NULL;
    ok = 1;
done:
    free(work);
    free(pixels);
    free(dec);
    return ok;
}

// Decodes the first frame as non-premultiplied RGBA8. Returns 1 on success;
// `*out` is malloc'd and released with zt_image_free.
int zt_image_load_rgba(const unsigned char *data, int len, int *w, int *h, unsigned char **out) {
    if (data == NULL || len <= 0 || w == NULL || h == NULL || out == NULL) return 0;
    *out = NULL;
    size_t n = (size_t)len;
    if (zt_is_cgbi(data, n)) {
        int alpha = 0;
        size_t pn = 0;
        unsigned char *png = zt_cgbi_to_png(data, n, &pn, &alpha);
        if (png == NULL) return 0;
        int ok = zt_decode(png, pn, w, h, out);
        free(png);
        if (ok) zt_cgbi_fix(*out, (size_t)*w * (size_t)*h, alpha);
        return ok;
    }
    int ok = zt_decode(data, n, w, h, out);
    if (!ok && n >= 4 && data[0] == 0xFF && data[1] == 0xD8 &&
        !(data[n - 2] == 0xFF && data[n - 1] == 0xD9)) {
        // JPEG without its EOI marker (truncated or sloppy encoders), which
        // stb_image accepted: end the stream explicitly and retry.
        unsigned char *fixed = malloc(n + 2);
        if (fixed == NULL) return 0;
        memcpy(fixed, data, n);
        fixed[n] = 0xFF;
        fixed[n + 1] = 0xD9;
        ok = zt_decode(fixed, n + 2, w, h, out);
        free(fixed);
    }
    return ok;
}

void zt_image_free(unsigned char *p) {
    free(p);
}
