#define _POSIX_C_SOURCE 200809L
#include <stdlib.h>
#include <stddef.h>
static int fail_calloc;
static void *review_calloc(size_t n, size_t size);
#define calloc review_calloc
#define PEAK_NO_GAMEPAD
#include "../vendor/godstack/Peak/peak.c"
#undef calloc
#include <assert.h>

static struct peak_linux_win test_window;
static XEvent queued;
static int has_event;
static unsigned char prop_bytes[32];
static size_t prop_n;
static Atom prop_type;
static int prop_fmt = 8;
static unsigned long prop_after;
static int ime_filter;
static Status ime_status = XLookupChars;
static void *review_calloc(size_t n, size_t size) { return fail_calloc ? NULL : calloc(n, size); }
static Bool check_event(Display *d, XEvent *out, Bool (*predicate)(Display *, XEvent *, XPointer), XPointer arg) {
    if (!has_event || !predicate(d, &queued, arg)) return False;
    *out = queued; has_event = 0; return True;
}
static int single_pending(Display *d) { (void)d; return has_event; }
static void single_putback(Display *d, XEvent *ev) { (void)d; assert(!has_event); queued = *ev; has_event = 1; }
static int flush(Display *d) { (void)d; return 0; }
static int xfree(void *p) { free(p); return 0; }
static int delete_property(Display *d, Window w, Atom a) { (void)d; (void)w; (void)a; return 0; }
static int lookup(XKeyEvent *ev, char *buf, int cap, KeySym *ks, XComposeStatus *cs) {
    (void)cap; (void)cs;
    switch (ev->keycode) {
    case 1: *ks = XK_eacute; buf[0] = (char)0xe9; return 1;
    case 2: *ks = XK_KP_Enter; buf[0] = '\r'; return 1;
    case 3: *ks = XK_KP_Left; return 0;
    case 6: *ks = XK_KP_Right; return 0;
    case 7: *ks = XK_KP_Up; return 0;
    case 8: *ks = XK_KP_Down; return 0;
    case 9: *ks = XK_bracketleft; buf[0] = 27; return 1;
    case 10: *ks = XK_a; buf[0] = 'a'; return 1;
    case 11: *ks = XK_Delete; buf[0] = 127; return 1;
    default: *ks = XK_a; buf[0] = 'a'; return 1;
    }
}
static int ime_length;
static int ime_unicode;
static Bool filter_event(XEvent *ev, Window w) { (void)ev; (void)w; return ime_filter; }
static int lookup_utf8(XIC ic, XKeyPressedEvent *ev, char *buf, int cap, KeySym *ks, Status *status) {
    (void)ic; *ks = NoSymbol;
    if (ev->keycode == 9) { *ks = XK_bracketleft; *status = XLookupKeySym; return 0; }
    if (ev->keycode == 10) { *ks = XK_a; *status = XLookupBoth; buf[0] = 'a'; return 1; }
    if (ev->keycode == 11) { *ks = XK_Delete; *status = XLookupBoth; buf[0] = 127; return 1; }
    if (cap < ime_length) { *status = XBufferOverflow; return ime_length; }
    memset(buf, 'z', ime_length);
    if (ime_unicode && ime_length == 2) { buf[0] = (char)0xc3; buf[1] = (char)0xa9; }
    *ks = XK_e; *status = ime_status; return ime_length;
}
static XImage *image_failure(Display *d, Visual *v, unsigned int depth, int format, int offset, char *data, unsigned int w, unsigned int h, int pad, int stride) {
    (void)d; (void)v; (void)depth; (void)format; (void)offset; (void)data;
    (void)w; (void)h; (void)pad; (void)stride; return NULL;
}
static int get_property(Display *d, Window w, Atom a, long off, long len, Bool del, Atom req,
    Atom *type, int *fmt, unsigned long *n, unsigned long *after, unsigned char **out) {
    (void)d; (void)w; (void)a; (void)off; (void)len; (void)del; (void)req;
    *type = prop_type; *fmt = prop_fmt; *n = prop_n; *after = prop_after;
    *out = malloc(prop_n + 1);
    memcpy(*out, prop_bytes, prop_n); (*out)[prop_n] = 0;
    return Success;
}
static int destroy_image(XImage *image) { free(image); return 1; }
void review_setup(PeakWindow *win, int scenario) {
    memset(&test_window, 0, sizeof test_window);
    memset(win, 0, sizeof *win);
    win->internal.w = &test_window;
    test_window.window = 123;
    peak_linux.windows = &test_window;
    test_window.width = test_window.height = 2;
    peak_linux_kind = PEAK_LINUX_X11;
    peak_linux.im = NULL;
    peak_linux.display = (Display *)1;
    peak_linux.wm_delete_window = 100;
    peak_linux.clip_clipboard = 101;
    peak_linux.clip_utf8 = 102;
    peak_linux.clip_prop = 103;
    peak_linux.xdnd_selection = 104;
    peak_linux.uri_list = 106;
    peak_clip_incr_type = None;
    peak_clip_req_on = peak_clip_incr_on = 0;
    prop_fmt = 8; prop_after = 0; ime_filter = 0; ime_status = XLookupChars;
    peak_x11.XCheckIfEvent = check_event;
    peak_x11.XPending = single_pending;
    peak_x11.XPutBackEvent = single_putback;
    peak_x11.XLookupString = lookup;
    peak_x11.XFlush = flush;
    peak_x11.XFree = xfree;
    peak_x11.XDeleteProperty = delete_property;
    peak_x11.XGetWindowProperty = get_property;
    memset(&queued, 0, sizeof queued);
    queued.xany.window = test_window.window;
    if (scenario == 4 || scenario == 5) {
        queued.xbutton.type = ButtonPress;
        queued.xbutton.button = scenario == 4 ? 8 : 6;
        queued.xbutton.x = queued.xbutton.y = 1;
    } else {
        queued.xkey.type = KeyPress;
        queued.xkey.keycode = (unsigned int)scenario;
    }
    has_event = 1;
}

int review_clipboard(void) {
    PeakWindow win; PeakEvent ev; char text[16]; size_t n;
    review_setup(&win, 0); has_event = 0;
    prop_type = XA_STRING; prop_bytes[0] = 0xe9; prop_n = 1;
    assert(peak_linux_clip_take_prop(test_window.window, peak_linux.clip_prop, PEAK_CLIP_CLIPBOARD, &ev));
    assert(peak_clip_take(&win, text, sizeof text, &n));
    assert(n == 2 && (unsigned char)text[0] == 0xc3 && (unsigned char)text[1] == 0xa9);
    peak_clip_incr_on = 1; peak_clip_incr_which = PEAK_CLIP_CLIPBOARD;
    queued.xproperty.type = PropertyNotify; queued.xproperty.window = test_window.window;
    queued.xproperty.atom = peak_linux.clip_prop; queued.xproperty.state = PropertyNewValue;
    has_event = 1;
    assert(!peak_window_epoll(&win, &ev));
    prop_n = 0; has_event = 1;
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_CLIP);
    assert(peak_clip_take(&win, text, sizeof text, &n));
    assert(n == 2 && (unsigned char)text[0] == 0xc3 && (unsigned char)text[1] == 0xa9);
    peak_clip_incr_on = 1; prop_n = 1; has_event = 1;
    assert(!peak_window_epoll(&win, &ev));
    prop_type = peak_linux.clip_utf8; has_event = 1;
    assert(!peak_window_epoll(&win, &ev));
    assert(!peak_clip_incr_on && !peak_clip_incr);
    return 1;
}
static void resize_case(int write_after) {
    PeakWindow win; PeakEvent ev;
    review_setup(&win, 0);
    test_window.buffer = calloc(4, sizeof(uint32_t));
    test_window.ximage = calloc(1, sizeof(XImage));
    test_window.ximage->data = (char *)test_window.buffer;
    test_window.ximage->f.destroy_image = destroy_image;
    uint32_t *borrowed = peak_window_backbuffer(&win, NULL, NULL);
    assert(borrowed);
    queued.xconfigure.type = ConfigureNotify;
    queued.xconfigure.width = queued.xconfigure.height = 4;
    fail_calloc = 1;
    assert(!peak_window_epoll(&win, &ev));
    fail_calloc = 0;
    assert(test_window.buffer == borrowed && win.buffer == borrowed);
    assert(test_window.width == 2 && test_window.height == 2);
    XImage *original_image = test_window.ximage;
    _XPrivDisplay fake_display = calloc(1, sizeof *fake_display);
    assert(fake_display);
    peak_linux.display = (Display *)fake_display;
    test_window.visual = (Visual *)1; test_window.depth = 24;
    peak_x11.XCreateImage = image_failure;
    has_event = 1;
    assert(!peak_window_epoll(&win, &ev));
    assert(test_window.buffer == borrowed && win.buffer == borrowed);
    assert(test_window.ximage == original_image);
    assert(test_window.width == 2 && test_window.height == 2);
    free(fake_display); peak_linux.display = (Display *)1;
    if (write_after) borrowed[0] = 42;
    test_window.ximage->data = NULL; XDestroyImage(test_window.ximage); free(test_window.buffer);
}
static void ime_case(void) {
    PeakWindow win; PeakEvent ev;
    review_setup(&win, 0);
    test_window.ic = (XIC)1;
    peak_linux.im = (XIM)1;
    peak_x11.XFilterEvent = filter_event;
    peak_x11.Xutf8LookupString = lookup_utf8;
    queued.xkey.keycode = 0; ime_length = 100;
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_KEY_DOWN);
    assert(peak_window_pending(&win));
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.n == 64);
    assert(peak_window_pending(&win));
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.n == 36);
    assert(!peak_window_pending(&win));
    queued.xkey.keycode = 1; queued.xkey.state = Mod1Mask | ControlMask;
    ime_length = 2; ime_unicode = 1; ime_status = XLookupBoth; has_event = 1;
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_KEY_DOWN);
    assert(ev.key.key == PEAK_KEY_UNKNOWN && ev.key.code == 0 && ev.key.mod == 0);
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.n == 2);
    assert((unsigned char)ev.text.bytes[0] == 0xc3 && (unsigned char)ev.text.bytes[1] == 0xa9);
    ime_status = XLookupChars; ime_unicode = 0; ime_length = 2; has_event = 1;
    assert(peak_window_epoll(&win, &ev) && ev.key.code == 0 && ev.key.mod == 0);
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.n == 2);
    queued.xkey.keycode = 1; queued.xkey.type = KeyPress; has_event = 1;
    ime_filter = 1; assert(!peak_window_epoll(&win, &ev));
    ime_filter = 0; ime_status = XLookupNone; has_event = 1;
    assert(!peak_window_epoll(&win, &ev));
    queued.xkey.keycode = 9; queued.xkey.state = ControlMask; has_event = 1;
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_KEY_DOWN);
    assert(ev.key.code == 27 && (ev.key.mod & PEAK_KEYMOD_CTRL));
    assert(!peak_window_epoll(&win, &ev));
    queued.xkey.keycode = 10; queued.xkey.state = Mod1Mask; has_event = 1;
    assert(peak_window_epoll(&win, &ev) && ev.key.key == PEAK_KEY_A && ev.key.code == 'a');
    assert(ev.key.mod & PEAK_KEYMOD_ALT);
    assert(!peak_window_epoll(&win, &ev));
    queued.xkey.keycode = 11; queued.xkey.state = 0; has_event = 1;
    assert(peak_window_epoll(&win, &ev) && ev.key.key == PEAK_KEY_DELETE);
    assert(!peak_window_epoll(&win, &ev));
}
static XEvent private_queue[8];
static int private_count;
static int private_pending(Display *d) { (void)d; return private_count; }
static Bool private_check(Display *d, XEvent *out, Bool (*predicate)(Display *, XEvent *, XPointer), XPointer arg) {
    for (int i = 0; i < private_count; i++) {
        if (!predicate(d, &private_queue[i], arg)) continue;
        *out = private_queue[i];
        memmove(private_queue + i, private_queue + i + 1, (size_t)(--private_count - i) * sizeof *private_queue);
        return True;
    }
    return False;
}
static void private_putback(Display *d, XEvent *ev) {
    (void)d; assert(private_count < 8);
    memmove(private_queue + 1, private_queue, (size_t)private_count++ * sizeof *private_queue);
    private_queue[0] = *ev;
}
static Bool private_filter(XEvent *ev, Window window) {
    assert(window == None);
    if (ev->xany.window != 999) return False;
    assert(private_count < 8);
    XEvent commit = {0}; commit.xkey.type = KeyPress; commit.xkey.window = 123;
    private_queue[private_count++] = commit;
    return True;
}
static void private_ime_case(void) {
    PeakWindow win; PeakEvent ev;
    review_setup(&win, 0); has_event = 0;
    peak_linux.im = (XIM)1; test_window.ic = (XIC)1;
    peak_x11.XPending = private_pending; peak_x11.XCheckIfEvent = private_check;
    peak_x11.XPutBackEvent = private_putback; peak_x11.XFilterEvent = private_filter;
    peak_x11.Xutf8LookupString = lookup_utf8;
    ime_status = XLookupChars; ime_length = 2; ime_unicode = 1;
    memset(private_queue, 0, sizeof private_queue);
    private_queue[0].xany.window = 400; private_queue[0].type = Expose;
    private_queue[1].xany.window = 999; private_queue[1].type = ClientMessage;
    private_queue[2].xany.window = 401; private_queue[2].type = Expose;
    private_count = 3;
    assert(peak_window_pending(&win));
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_KEY_DOWN);
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.n == 2);
    assert((unsigned char)ev.text.bytes[0] == 0xc3 && (unsigned char)ev.text.bytes[1] == 0xa9);
    assert(private_count == 2 && private_queue[0].xany.window == 400 && private_queue[1].xany.window == 401);
    assert(!peak_window_pending(&win));
}
static int state_focused, state_filtered, state_lookups;
static void state_focus(XIC ic) { (void)ic; state_focused = 1; }
static Bool state_filter(XEvent *ev, Window window) {
    assert(window == None);
    if (ev->xany.window == 456) { assert(!"other Peak window must not be filtered"); }
    if (ev->type == KeyPress) {
        assert(state_focused);
        assert(state_filtered == state_lookups);
        state_filtered++;
    }
    return False;
}
static int state_lookup(XIC ic, XKeyPressedEvent *ev, char *buf, int cap, KeySym *ks, Status *status) {
    (void)ic; (void)ev; assert(cap > 0);
    assert(state_filtered == state_lookups + 1);
    state_lookups++;
    buf[0] = state_lookups == 1 ? 'x' : 'y';
    *ks = XK_a; *status = XLookupChars; return 1;
}
static void ime_order_case(void) {
    PeakWindow win; PeakEvent ev;
    struct peak_linux_win other = {0};
    review_setup(&win, 0); has_event = 0;
    peak_linux.im = (XIM)1; test_window.ic = (XIC)1;
    other.window = 456; test_window.next = &other;
    peak_x11.XPending = private_pending; peak_x11.XCheckIfEvent = private_check;
    peak_x11.XPutBackEvent = private_putback; peak_x11.XFilterEvent = state_filter;
    peak_x11.XSetICFocus = state_focus; peak_x11.Xutf8LookupString = state_lookup;
    state_focused = state_filtered = state_lookups = 0;
    memset(private_queue, 0, sizeof private_queue);
    private_queue[0].type = KeyPress; private_queue[0].xkey.window = 456; private_queue[0].xkey.keycode = 10;
    private_queue[1].type = FocusIn; private_queue[1].xfocus.window = 123;
    private_queue[2].type = KeyPress; private_queue[2].xkey.window = 123; private_queue[2].xkey.keycode = 10;
    private_queue[3].type = KeyPress; private_queue[3].xkey.window = 123; private_queue[3].xkey.keycode = 10;
    private_count = 4;
    assert(peak_window_pending(&win));
    assert(!state_focused && !state_filtered);
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_FOCUS && state_focused);
    assert(peak_window_pending(&win) && !state_filtered);
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_KEY_DOWN);
    assert(state_filtered == 1 && state_lookups == 1);
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.bytes[0] == 'x');
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_KEY_DOWN);
    assert(state_filtered == 2 && state_lookups == 2);
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.bytes[0] == 'y');
    assert(private_count == 1 && private_queue[0].xany.window == 456);
    test_window.next = NULL;
}
static void drop_case(void) {
    PeakWindow win; PeakEvent ev;
    review_setup(&win, 0);
    prop_type = peak_linux.uri_list;
    strcpy((char *)prop_bytes, "file:///tmp/x"); prop_n = strlen((char *)prop_bytes);
    queued.xselection.type = SelectionNotify;
    queued.xselection.selection = peak_linux.xdnd_selection;
    queued.xselection.property = 105;
    assert(peak_window_epoll(&win, &ev));
    assert(ev.drop.n == prop_n - 7);
}
#ifndef REVIEW_NO_MAIN
int main(int argc, char **argv) {
    PeakWindow win; PeakEvent ev;
    if (argc > 1 && !strcmp(argv[1], "resize-uaf")) { resize_case(1); return 0; }
    if (argc > 1 && !strcmp(argv[1], "drop-overread")) { drop_case(); return 0; }
    review_setup(&win, 1);
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_KEY_DOWN);
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_TEXT);
    assert(ev.text.n == 2 && (unsigned char)ev.text.bytes[0] == 0xc3 && (unsigned char)ev.text.bytes[1] == 0xa9);
    for (int i = 2; i <= 3; i++) {
        review_setup(&win, i);
        assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_KEY_DOWN);
        assert(ev.key.key == (i == 2 ? PEAK_KEY_ENTER : PEAK_KEY_LEFT));
        assert(!peak_window_epoll(&win, &ev));
    }
    for (int i = 6; i <= 8; i++) {
        const PeakKeyCode expected[] = {PEAK_KEY_RIGHT, PEAK_KEY_UP, PEAK_KEY_DOWN};
        review_setup(&win, i);
        assert(peak_window_epoll(&win, &ev) && ev.key.key == expected[i - 6]);
    }
    for (int i = 4; i <= 5; i++) {
        review_setup(&win, i);
        assert(!peak_window_epoll(&win, &ev));
        queued.xbutton.type = ButtonRelease; has_event = 1;
        assert(!peak_window_epoll(&win, &ev));
    }
    assert(review_clipboard());
    resize_case(1);
    ime_case();
    private_ime_case();
    ime_order_case();
    drop_case();
    return 0;
}
#endif
