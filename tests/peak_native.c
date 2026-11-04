/* Exercise native Peak behavior without relying on a particular compositor. */
#ifndef PEAK_NO_GAMEPAD
#define PEAK_NO_GAMEPAD
#endif
#include "../vendor/godstack/Peak/peak.c"
#include <assert.h>

#if defined(PEAK_LINUX) || defined(PEAK_MACOS)
static void mirror_test(void)
{
    size_t size = peak_page_size();
    assert(size > 1 && !peak_mirror_map(size - 1));
    unsigned char *p = peak_mirror_map(size);
    assert(p);
    p[0] = 0x12;
    p[size - 1] = 0x34;
    assert(p[size] == 0x12 && p[2 * size - 1] == 0x34);
    p[size + 1] = 0x56;
    assert(p[1] == 0x56);
    peak_mirror_unmap(p, size);
}
#endif

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
static void macos_events_test(void)
{
    assert(peak_init());
    PeakWindow win = peak_window_open("Velocitty native regression", 320, 160, 0);
    struct peak_macos_win *w = win.internal.w;
    PeakEvent ev;
    assert(w && ![w->window isReleasedWhenClosed]);
    assert([w->view acceptsFirstResponder]);
    w->q.n = 0; w->q.h = 0;
    [(PeakMacView *)w->view insertText:@"a😀" replacementRange:NSMakeRange(NSNotFound, 0)];
    assert(peak_q_pop(&w->q, &ev) && ev.text.n == 5);
    assert(memcmp(ev.text.bytes, "a\xf0\x9f\x98\x80", 5) == 0);
    [(PeakMacDelegate *)w->delegate windowDidResignKey:nil];
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_FOCUS && !ev.focus.on);
    [(PeakMacDelegate *)w->delegate windowDidBecomeKey:nil];
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
#if defined(PEAK_LINUX) || defined(PEAK_MACOS)
    mirror_test();
#endif
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
