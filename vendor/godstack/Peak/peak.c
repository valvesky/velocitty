#include "peak.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(PEAK_WIN32)
#include <malloc.h>
#endif

#if defined(PEAK_WIN32) || defined(PEAK_WEB) || defined(PEAK_MACOS) || defined(PEAK_LINUX)
#define PEAK_Q 64

typedef struct {
    unsigned h, n;
    PeakEvent e[PEAK_Q];
} PeakQ;

static int
peak_q_motion(PeakEvent ev)
{
    return ev.type == PEAK_EVENT_POINTER && ev.pointer.state == PEAK_POINTER_MOVED;
}

static void
peak_q_push(PeakQ *q, PeakEvent ev)
{
    if (!q)
        return;
    /* Motion floods must not eat a button release. A dropped release leaves
     * a drag running, so a later click changes the selection. */
    if (q->n == PEAK_Q) {
        if (peak_q_motion(ev))
            return;
        q->h = (q->h + 1) % PEAK_Q;
        q->n--;
    }
    q->e[(q->h + q->n++) % PEAK_Q] = ev;
}

static int
peak_q_pop(PeakQ *q, PeakEvent *ev)
{
    if (!q || !q->n)
        return 0;
    *ev = q->e[q->h];
    q->h = (q->h + 1) % PEAK_Q;
    q->n--;
    return 1;
}
static void
peak_q_text(PeakQ *q, const char *utf8, size_t n)
{
    while (n) {
        PeakEvent ev = {0};
        size_t chunk = n < sizeof ev.text.bytes ? n : sizeof ev.text.bytes;
        if (chunk < n) while (chunk && ((unsigned char)utf8[chunk] & 0xc0) == 0x80) chunk--;
        if (!chunk) return;
        ev.type = PEAK_EVENT_TEXT;
        ev.text.n = chunk;
        memcpy(ev.text.bytes, utf8, chunk);
        peak_q_push(q, ev);
        utf8 += chunk; n -= chunk;
    }
}

#endif

#define PEAK_CLIP_MAX (1024u * 1024u)

static struct {
    char *own[2];
    size_t own_n[2];
    char *paste;
    size_t paste_n;
    int paste_ready;
    int synthetic;
    PeakClip paste_which;
} peak_clip;

static struct {
    char *text;
    size_t text_n;
    int text_ready;
    char *drop;
    size_t drop_n;
    int drop_ready;
} peak_xfer;

static int
peak_clip_own_store(PeakClip which, const char *utf8, size_t n)
{
    char *p;

    if ((unsigned)which > 1)
        return 0;
    if (n && !utf8)
        return 0;
    p = realloc(peak_clip.own[which], n ? n : 1);
    if (!p)
        return 0;
    if (n)
        memcpy(p, utf8, n);
    peak_clip.own[which] = p;
    peak_clip.own_n[which] = n;
    return 1;
}

static int
peak_clip_own_get(PeakClip which, const char **p, size_t *n)
{
    if ((unsigned)which > 1 || !p || !n)
        return 0;
    *p = peak_clip.own[which] ? peak_clip.own[which] : "";
    *n = peak_clip.own_n[which];
    return 1;
}

static void
peak_clip_paste_store(PeakClip which, const char *utf8, size_t n)
{
    char *p;

    if (n > PEAK_CLIP_MAX)
        n = PEAK_CLIP_MAX;
    if (n && !utf8)
        n = 0;
    p = realloc(peak_clip.paste, n ? n : 1);
    if (!p) {
        peak_clip.paste_ready = 0;
        return;
    }
    if (n)
        memcpy(p, utf8, n);
    peak_clip.paste = p;
    peak_clip.paste_n = n;
    peak_clip.paste_which = which;
    peak_clip.paste_ready = 1;
}

static void
peak_text_store(const char *utf8, size_t n)
{
    char *p;

    if (n > PEAK_CLIP_MAX)
        n = PEAK_CLIP_MAX;
    if (n && !utf8)
        n = 0;
    p = realloc(peak_xfer.text, n ? n : 1);
    if (!p) {
        peak_xfer.text_ready = 0;
        return;
    }
    if (n)
        memcpy(p, utf8, n);
    peak_xfer.text = p;
    peak_xfer.text_n = n;
    peak_xfer.text_ready = 1;
}

static void
peak_drop_store(const char *utf8, size_t n)
{
    char *p;

    if (n > PEAK_CLIP_MAX)
        n = PEAK_CLIP_MAX;
    if (n && !utf8)
        n = 0;
    p = realloc(peak_xfer.drop, n ? n : 1);
    if (!p) {
        peak_xfer.drop_ready = 0;
        return;
    }
    if (n)
        memcpy(p, utf8, n);
    peak_xfer.drop = p;
    peak_xfer.drop_n = n;
    peak_xfer.drop_ready = 1;
}

#if defined(PEAK_WIN32)
#include "p_win32.c"
#elif defined(PEAK_LINUX)
#include "p_linux.c"
#elif defined(PEAK_MACOS)
#include "p_macos.c"
#elif defined(PEAK_WEB)
#include "p_emscripten.c"
#endif

#include "p_log.c"

static uint32_t *
peak_window_sync(PeakWindow *win, size_t *width, size_t *height)
{
    size_t w = 0, h = 0;
    win->buffer = peak_platform_window_buffer(&win->internal, &w, &h);
    win->width = (uint32_t)w;
    win->height = (uint32_t)h;
    win->bufsize = win->width * win->height;
    if (width) *width = w;
    if (height) *height = h;
    return win->buffer;
}

int
peak_init(void)
{
    return peak_platform_init();
}

void
peak_quit(void)
{
    peak_audio_stop();
    peak_platform_quit();
}

PeakWindow
peak_window_open(const char *name, uint32_t width, uint32_t height, uint32_t flags)
{
    PeakWindow win = {0};
    if (!name || !name[0]) name = "Peak";
    if (!width) width = 800;
    if (!height) height = 600;
    win.internal = peak_platform_window_open(name, width, height, flags);
    if (!peak_window_sync(&win, NULL, NULL)) return win;
    win.running = 1;
    return win;
}

void
peak_window_close(PeakWindow *win)
{
    win->running = 0;
    peak_platform_window_close(&win->internal);
    win->buffer = NULL;
    win->width = 0;
    win->height = 0;
    win->bufsize = 0;
}

int
peak_window_epoll(PeakWindow *win, PeakEvent *ev)
{
    int got;
    if (peak_clip.synthetic) {
        memset(ev, 0, sizeof *ev);
        peak_clip.synthetic = 0;
        ev->type = PEAK_EVENT_CLIP;
        ev->clip.which = peak_clip.paste_which;
        ev->clip.n = peak_clip.paste_n;
        return 1;
    }
    got = peak_platform_epoll(&win->internal, ev);
    if (got && ev->type == PEAK_EVENT_TEXT)
        peak_text_store(ev->text.bytes, ev->text.n);
    if (got && ev->type == PEAK_EVENT_WINDOW_RESIZE)
        peak_window_sync(win, NULL, NULL);
    return got;
}

int
peak_window_fd(PeakWindow *win)
{
    if (!win)
        return -1;
    return peak_platform_fd(&win->internal);
}

int
peak_window_pending(PeakWindow *win)
{
    if (!win)
        return 0;
    return peak_clip.synthetic ? 1 : peak_platform_pending(&win->internal);
}

uint32_t *
peak_window_backbuffer(PeakWindow *win, size_t *width, size_t *height)
{
    return peak_window_sync(win, width, height);
}

void
peak_window_clear(PeakWindow *win, float r, float g, float b, float a)
{
    uint32_t c, i;
    if (!win || !win->buffer) return;
#if defined(PEAK_WEB)
    /* ImageData RGBA bytes = LE 0xAABBGGRR */
    c =  (uint32_t)(r * 255.f)
      | ((uint32_t)(g * 255.f) << 8)
      | ((uint32_t)(b * 255.f) << 16)
      | ((uint32_t)(a * 255.f) << 24);
#else
    c = ((uint32_t)(a * 255.f) << 24)
      | ((uint32_t)(r * 255.f) << 16)
      | ((uint32_t)(g * 255.f) << 8)
      |  (uint32_t)(b * 255.f);
#endif
    for (i = 0; i < win->bufsize; i++)
        win->buffer[i] = c;
}

void
peak_window_present(PeakWindow *win)
{
    if (win) peak_platform_window_present(&win->internal);
}

void
peak_window_present_rect(PeakWindow *win, uint32_t y, uint32_t h)
{
    if (!win) return;
#if defined(PEAK_LINUX) || defined(PEAK_WIN32)
    peak_platform_window_present_rect(&win->internal, y, h);
#else
    (void)y;
    (void)h;
    peak_platform_window_present(&win->internal);
#endif
}

void
peak_window_set_title(PeakWindow *win, const char *name)
{
    if (!win || !name)
        return;
    peak_platform_window_set_title(&win->internal, name);
}

void
peak_window_set_text_input_rect(PeakWindow *win, int x, int y, int w, int h)
{
    if (!win)
        return;
#if defined(PEAK_MACOS) || defined(PEAK_WIN32)
    peak_platform_window_set_text_input_rect(&win->internal, x, y, w, h);
#else
    (void)x;
    (void)y;
    (void)w;
    (void)h;
#endif
}

void
peak_window_set_class(PeakWindow *win, const char *name)
{
    if (!win || !name || !name[0])
        return;
    peak_platform_window_set_class(&win->internal, name);
}

void
peak_window_set_opacity(PeakWindow *win, uint8_t alpha)
{
    if (!win)
        return;
    peak_platform_window_set_opacity(&win->internal, alpha);
}

void
peak_window_set_size(PeakWindow *win, uint32_t width, uint32_t height)
{
    if (!win || !width || !height)
        return;
    peak_platform_window_set_size(&win->internal, width, height);
    peak_window_sync(win, NULL, NULL);
}

void
peak_window_fullscreen(PeakWindow *win, int on)
{
    if (!win)
        return;
    peak_platform_window_fullscreen(&win->internal, on);
}

void
peak_window_cursor(PeakWindow *win, int on)
{
    if (!win)
        return;
    peak_platform_window_cursor(&win->internal, on);
}

void
peak_window_cursor_shape(PeakWindow *win, int shape)
{
    if (!win)
        return;
    peak_platform_window_cursor_shape(&win->internal, shape);
}

void
peak_window_pointer_relative(PeakWindow *win, int on)
{
    if (!win)
        return;
    peak_platform_window_pointer_relative(&win->internal, on);
}

float
peak_window_scale(PeakWindow *win)
{
    if (!win)
        return 1.f;
    return peak_platform_window_scale(&win->internal);
}

unsigned
peak_window_refresh_rate(PeakWindow *win)
{
#if defined(PEAK_MACOS)
    return win ? peak_platform_window_refresh_rate(&win->internal) : 0;
#else
    (void)win;
    return 0;
#endif
}

#ifdef PEAK_WEB
#include <emscripten.h>
static void
peak_internal_web_step(void *arg)
{
    PeakWindow *win = arg;
    if (!win->tick(win, win->userdata) || !win->running) {
        win->running = 0;
        emscripten_cancel_main_loop();
    }
}
#endif

void
peak_window_run(PeakWindow *win, int (*peak_tick)(PeakWindow *win, void *userdata), void *userdata)
{
    assert(win && "peak_window_run needs a window");
    assert(peak_tick && "peak_window_run needs tick callback");
    win->tick = peak_tick;
    win->userdata = userdata;
    win->running = 1;
#ifdef PEAK_WEB
    emscripten_set_main_loop_arg(peak_internal_web_step, win, 0, 1);
#else
    while (win->running && win->tick(win, win->userdata));
#endif
}

int
peak_audio_start(uint32_t channels, uint32_t rate, void (*fill)(int16_t *out, size_t frames, void *userdata), void *userdata)
{
    if (!fill || !channels || !rate)
        return 0;
    peak_audio_stop();
    return peak_platform_audio_start(channels, rate, fill, userdata);
}

void
peak_audio_stop(void)
{
    peak_platform_audio_stop();
}

uint64_t
peak_get_time(void)
{
    return peak_platform_get_time();
}

void
peak_sleep_ns(int64_t ns)
{
    peak_platform_sleep_ns(ns);
}

int
peak_file_exists(const char *path)
{
    FILE *f;
    if (!path) return 0;
    f = fopen(path, "rb");
    if (!f) return 0;
    fclose(f);
    return 1;
}

void *
peak_file_alloc(const char *path, unsigned long *buf_size)
{
    FILE *f;
    long n;
    void *p;
    if (!path) return NULL;
    f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    n = ftell(f);
    if (n < 0) { fclose(f); return NULL; }
    rewind(f);
    p = malloc((size_t)n + (n == 0));
    if (!p) { fclose(f); return NULL; }
    if (n && fread(p, 1, (size_t)n, f) != (size_t)n) {
        free(p);
        fclose(f);
        return NULL;
    }
    fclose(f);
    if (buf_size) *buf_size = (unsigned long)n;
    return p;
}

int
peak_file_write(const char *path, const void *buf, size_t n)
{
    FILE *f;

    if (!path || (n && !buf))
        return 0;
    f = fopen(path, "wb");
    if (!f)
        return 0;
    if (n && fwrite(buf, 1, n, f) != n) {
        fclose(f);
        return 0;
    }
    fclose(f);
    return 1;
}

const char **
peak_vulkan_get_extensions(uint32_t *count)
{
    return peak_platform_vulkan_get_extensions(count);
}

int
peak_vulkan_create_surface(PeakWindow *win, void *instance, const void *allocator, void *out_surface)
{
    if (!win || !instance || !out_surface) return 0;
    return peak_platform_vulkan_create_surface(&win->internal, instance, allocator, out_surface);
}

int
peak_clip_set(PeakWindow *win, PeakClip which, const char *utf8, size_t n)
{
    if (which != PEAK_CLIP_CLIPBOARD && which != PEAK_CLIP_PRIMARY)
        return 0;
    if (n && !utf8)
        return 0;
    if (n > PEAK_CLIP_MAX)
        n = PEAK_CLIP_MAX;
    if (!peak_clip_own_store(which, utf8, n))
        return 0;
#if defined(PEAK_WIN32) || defined(PEAK_MACOS) || defined(PEAK_WEB)
    /* PRIMARY is terminal-local on platforms with a single system clipboard. */
    if (which == PEAK_CLIP_PRIMARY) return 1;
#endif
    if (!win)
        return 1;
    return peak_platform_clip_set(&win->internal, which, utf8, n);
}

int
peak_clip_request(PeakWindow *win, PeakClip which)
{
    const char *p;
    size_t n;

    if (which != PEAK_CLIP_CLIPBOARD && which != PEAK_CLIP_PRIMARY)
        return 0;
    if (!win
#if defined(PEAK_WIN32) || defined(PEAK_MACOS)
        || which == PEAK_CLIP_PRIMARY
#endif
    ) {
        if (!peak_clip_own_get(which, &p, &n))
            return 0;
        peak_clip_paste_store(which, p, n);
        if (win) peak_clip.synthetic = 1;
        return 1;
    }
    return peak_platform_clip_request(&win->internal, which);
}

int
peak_clip_take(PeakWindow *win, char *dst, size_t cap, size_t *n)
{
    size_t c;

    (void)win;
    if (!peak_clip.paste_ready)
        return 0;
    peak_clip.paste_ready = 0;
    c = peak_clip.paste_n;
    if (c > cap)
        c = cap;
    if (dst && c)
        memcpy(dst, peak_clip.paste, c);
    if (n)
        *n = c;
    return 1;
}

int
peak_text_take(PeakWindow *win, char *dst, size_t cap, size_t *n)
{
    size_t c;

    (void)win;
    if (!peak_xfer.text_ready)
        return 0;
    peak_xfer.text_ready = 0;
    c = peak_xfer.text_n;
    if (c > cap)
        c = cap;
    if (dst && c)
        memcpy(dst, peak_xfer.text, c);
    if (n)
        *n = c;
    return 1;
}

int
peak_drop_drag(PeakWindow *win, const char *utf8, size_t n)
{
    if (!win || (n && !utf8))
        return 0;
    if (n > PEAK_CLIP_MAX)
        n = PEAK_CLIP_MAX;
    return peak_platform_drop_drag(&win->internal, utf8, n);
}

int
peak_drop_take(PeakWindow *win, char *dst, size_t cap, size_t *n)
{
    size_t c;

    (void)win;
    if (!peak_xfer.drop_ready)
        return 0;
    peak_xfer.drop_ready = 0;
    c = peak_xfer.drop_n;
    if (c > cap)
        c = cap;
    if (dst && c)
        memcpy(dst, peak_xfer.drop, c);
    if (n)
        *n = c;
    return 1;
}
