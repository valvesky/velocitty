/* Exercise native Peak behavior without relying on a particular compositor. */
#ifndef PEAK_NO_GAMEPAD
#define PEAK_NO_GAMEPAD
#endif
#include "../vendor/godstack/Peak/peak.c"
#include <assert.h>

static void text_queue_test(void)
{
    PeakQ q = {0};
    PeakEvent ev;
    char text[68];
    memset(text, 'a', 62);
    memcpy(text + 62, "\xf0\x9f\x98\x80Z", 5);
    text[67] = 0;
    peak_q_text(&q, text, 67);
    assert(peak_q_pop(&q, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.n == 62);
    assert(peak_q_pop(&q, &ev) && ev.text.n == 5);
    assert(memcmp(ev.text.bytes, "\xf0\x9f\x98\x80Z", 5) == 0);
    assert(!peak_q_pop(&q, &ev));
}

#if defined(PEAK_WIN32) || defined(PEAK_MACOS)
static void primary_test(void)
{
    PeakWindow win = {0};
    PeakEvent ev;
    const char *owned;
    size_t n;
    char text[32];
    assert(peak_clip_set(NULL, PEAK_CLIP_CLIPBOARD, "clipboard", 9));
    assert(peak_clip_set(NULL, PEAK_CLIP_PRIMARY, "selection", 9));
    assert(peak_clip_own_get(PEAK_CLIP_CLIPBOARD, &owned, &n));
    assert(n == 9 && memcmp(owned, "clipboard", 9) == 0);
    assert(peak_clip_request(&win, PEAK_CLIP_PRIMARY));
    assert(peak_window_epoll(&win, &ev) && ev.type == PEAK_EVENT_CLIP);
    assert(ev.clip.which == PEAK_CLIP_PRIMARY);
    assert(peak_clip_take(&win, text, sizeof text, &n));
    assert(n == 9 && memcmp(text, "selection", 9) == 0);
}
#endif

#ifdef PEAK_WIN32
static struct peak_win32_win fake_window;
static HANDLE WINAPI test_prop(HWND hwnd, LPCSTR name) { (void)hwnd; (void)name; return &fake_window; }
static SHORT WINAPI test_key_state(int key) { (void)key; return 0; }
static HDC WINAPI test_begin_paint(HWND hwnd, LPPAINTSTRUCT paint) { (void)hwnd; memset(paint, 0, sizeof *paint); return NULL; }
static BOOL WINAPI test_end_paint(HWND hwnd, const PAINTSTRUCT *paint) { (void)hwnd; (void)paint; return TRUE; }

static void windows_events_test(void)
{
    PeakEvent ev;
    peak_user32.GetPropA = test_prop;
    peak_user32.GetKeyState = test_key_state;
    peak_user32.BeginPaint = test_begin_paint;
    peak_user32.EndPaint = test_end_paint;
    peak_internal_win32_wndproc((HWND)1, WM_SETFOCUS, 0, 0);
    assert(peak_q_pop(&fake_window.q, &ev) && ev.type == PEAK_EVENT_FOCUS && ev.focus.on);
    peak_internal_win32_wndproc((HWND)1, WM_KILLFOCUS, 0, 0);
    assert(peak_q_pop(&fake_window.q, &ev) && ev.type == PEAK_EVENT_FOCUS && !ev.focus.on);
    peak_internal_win32_wndproc((HWND)1, WM_PAINT, 0, 0);
    assert(peak_q_pop(&fake_window.q, &ev) && ev.type == PEAK_EVENT_EXPOSE);
    peak_internal_win32_wndproc((HWND)1, WM_KEYDOWN, 'C', 0);
    assert(peak_q_pop(&fake_window.q, &ev) && ev.key.code == 'c');
    peak_internal_win32_wndproc((HWND)1, WM_CHAR, 0xd83d, 0);
    assert(!peak_q_pop(&fake_window.q, &ev));
    peak_internal_win32_wndproc((HWND)1, WM_CHAR, 0xde00, 0);
    assert(peak_q_pop(&fake_window.q, &ev) && ev.text.n == 4);
    assert(memcmp(ev.text.bytes, "\xf0\x9f\x98\x80", 4) == 0);
    peak_internal_win32_wndproc((HWND)1, WM_CHAR, 'a', 0);
    peak_internal_win32_wndproc((HWND)1, WM_CHAR, 'b', 0);
    assert(peak_q_pop(&fake_window.q, &ev) && ev.text.n == 1 && ev.text.bytes[0] == 'a');
    assert(peak_q_pop(&fake_window.q, &ev) && ev.text.n == 1 && ev.text.bytes[0] == 'b');
}

static void windows_argv_test(void)
{
    const char *argv[] = {"program.exe", "a b", "print(\"a b\")", "C:\\folder\\", "", NULL};
    char command[2048];
    WCHAR wide[2048], expected[256];
    int argc;
    assert(peak_internal_join_argv(command, sizeof command, argv[0], argv));
    assert(MultiByteToWideChar(CP_UTF8, 0, command, -1, wide, 2048));
    LPWSTR *parsed = CommandLineToArgvW(wide, &argc);
    assert(parsed && argc == 5);
    for (int i = 0; i < argc; i++) {
        assert(MultiByteToWideChar(CP_UTF8, 0, argv[i], -1, expected, 256));
        assert(lstrcmpW(expected, parsed[i]) == 0);
    }
    LocalFree(parsed);
    assert(!peak_internal_join_argv(command, 8, argv[0], argv));
    /* cmd.exe ignores quoted switches, so plain arguments stay bare. */
    const char *shell[] = {"cmd.exe", "/d", "/c", "echo ready", NULL};
    assert(peak_internal_join_argv(command, sizeof command, shell[0], shell));
    assert(strcmp(command, "cmd.exe /d /c \"echo ready\"") == 0);
}
#endif

#ifdef PEAK_MACOS
#include <pthread.h>
#include "peak_macos_input.h"
#include "peak_macos_present.h"

struct macos_wake_args { int fd; int window_event; };

static void *macos_delayed_wake(void *opaque)
{
    struct macos_wake_args *args = opaque;
    struct timespec delay = {0, 40000000};
    nanosleep(&delay, NULL);
    if (args->window_event) {
        @autoreleasepool {
            NSEvent *ev = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
                context:nil subtype:0 data1:12345 data2:0];
            [peak_macos_app postEvent:ev atStart:YES];
        }
    } else {
        assert(write(args->fd, "x", 1) == 1);
    }
    return NULL;
}

static void macos_wait_test(PeakWindow *win)
{
    int fds[2];
    assert(pipe(fds) == 0);
    for (int window_event = 0; window_event < 2; window_event++) {
        struct macos_wake_args args = {fds[1], window_event};
        pthread_t thread;
        int woke = 0;
        NSEvent *ev;
        while ((ev = [peak_macos_app nextEventMatchingMask:NSEventMaskAny
            untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) {}
        uint64_t start = peak_get_time();
        assert(pthread_create(&thread, NULL, macos_delayed_wake, &args) == 0);
        while (!woke && peak_get_time() - start < 700000000ull) {
            struct peak_macos_win *w = win->internal.w;
            w->q.n = 0; w->q.h = 0;
            peak_wait(win, &fds[0], 1, 1000);
            if (!window_event) {
                struct pollfd pfd = {fds[0], POLLIN, 0};
                woke = poll(&pfd, 1, 0) > 0;
            } else {
                while ((ev = [peak_macos_app nextEventMatchingMask:NSEventMaskAny
                    untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) {
                    if ([ev type] == NSEventTypeApplicationDefined && [ev data1] == 12345) woke = 1;
                }
            }
            if (!window_event) peak_internal_macos_pump(win->internal.w);
        }
        uint64_t elapsed = peak_get_time() - start;
        assert(pthread_join(thread, NULL) == 0);
        assert(woke && elapsed < 700000000ull);
        if (!window_event) { char byte; assert(read(fds[0], &byte, 1) == 1); }
    }
    close(fds[0]);
    close(fds[1]);
}

static void macos_events_test(void)
{
    assert(peak_init());
    macos_present_test();
    PeakWindow win = peak_window_open("Velocitty native regression", 320, 160, 0);
    struct peak_macos_win *w = win.internal.w;
    PeakEvent ev;
    assert(w && ![w->window isReleasedWhenClosed]);
    assert([w->view acceptsFirstResponder]);
    macos_input_test(w);
    macos_pointer_test(w);
    assert(peak_window_refresh_rate(&win) <= 500);
    macos_wait_test(&win);
    peak_window_present(&win);
    CGColorSpaceRef color_space = w->color_space;
    assert(color_space && w->layer.contents);
    peak_window_present(&win);
    assert(w->color_space == color_space && w->layer.contents);
    w->q.n = 0; w->q.h = 0;
    [(PeakMacView *)w->view insertText:@"a😀" replacementRange:NSMakeRange(NSNotFound, 0)];
    assert(peak_q_pop(&w->q, &ev) && ev.text.n == 5);
    assert(memcmp(ev.text.bytes, "a\xf0\x9f\x98\x80", 5) == 0);
    [(PeakMacDelegate *)w->delegate windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:w->window]];
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_FOCUS && !ev.focus.on);
    [(PeakMacDelegate *)w->delegate windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:w->window]];
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_FOCUS && ev.focus.on);
    [w->window performClose:nil];
    int closed = 0;
    while (peak_q_pop(&w->q, &ev)) if (ev.type == PEAK_EVENT_WINDOW_CLOSE) closed = 1;
    assert(closed);
    peak_window_close(&win);
    peak_quit();
}
#endif

int main(void)
{
    text_queue_test();
#if defined(PEAK_WIN32) || defined(PEAK_MACOS)
    primary_test();
#endif
#ifdef PEAK_WIN32
    windows_argv_test();
    windows_events_test();
#endif
#ifdef PEAK_MACOS
    macos_events_test();
#endif
    puts("Peak native text, clipboard, keyboard, window and argv regressions passed.");
    return 0;
}
