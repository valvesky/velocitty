/*
 * Win32 window, input, StretchDIBits present, and waveOut audio.
 * user32.dll, gdi32.dll, and winmm.dll are loaded at runtime.
 *
 * * 0.4.0 - @vasco - win32
 * * 0.5.0 - @vasco - audio start/stop, s16le pull callback
 */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

/* windows.h must precede mmsystem.h */
#include <windows.h>
#include <shellapi.h>
#include <imm.h>
#include <mmsystem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef PEAK_VULKAN
#define VK_USE_PLATFORM_WIN32_KHR
#include <vulkan/vulkan.h>
#endif

#define PEAK_WIN32_USER32 "user32.dll"
#define PEAK_WIN32_GDI32  "gdi32.dll"
#define PEAK_WIN32_WINMM  "winmm.dll"
#define PEAK_WIN32_CLASS  L"PeakWindow"
#define PEAK_WIN32_PROP   "Peak"
#define PEAK_AUDIO_FRAMES  256
#define PEAK_AUDIO_BUFFERS 2

#define PEAK_USER32_API(X) \
        X(RegisterClassExW,   ATOM,    WINAPI, (const WNDCLASSEXW *)) \
        X(UnregisterClassW,   BOOL,    WINAPI, (LPCWSTR, HINSTANCE)) \
        X(CreateWindowExW,    HWND,    WINAPI, (DWORD, LPCWSTR, LPCWSTR, DWORD, int, int, int, int, HWND, HMENU, HINSTANCE, LPVOID)) \
        X(DestroyWindow,      BOOL,    WINAPI, (HWND)) \
        X(ShowWindow,         BOOL,    WINAPI, (HWND, int)) \
        X(GetDC,              HDC,     WINAPI, (HWND)) \
        X(ReleaseDC,          int,     WINAPI, (HWND, HDC)) \
        X(PeekMessageW,       BOOL,    WINAPI, (LPMSG, HWND, UINT, UINT, UINT)) \
        X(TranslateMessage,   BOOL,    WINAPI, (const MSG *)) \
        X(DispatchMessageW,   LRESULT, WINAPI, (const MSG *)) \
        X(DefWindowProcW,     LRESULT, WINAPI, (HWND, UINT, WPARAM, LPARAM)) \
        X(SetPropA,           BOOL,    WINAPI, (HWND, LPCSTR, HANDLE)) \
        X(GetPropA,           HANDLE,  WINAPI, (HWND, LPCSTR)) \
        X(RemovePropA,        HANDLE,  WINAPI, (HWND, LPCSTR)) \
        X(BeginPaint,         HDC,     WINAPI, (HWND, LPPAINTSTRUCT)) \
        X(EndPaint,           BOOL,    WINAPI, (HWND, const PAINTSTRUCT *)) \
        X(AdjustWindowRectEx, BOOL,    WINAPI, (LPRECT, DWORD, BOOL, DWORD)) \
        X(LoadCursorA,        HCURSOR, WINAPI, (HINSTANCE, LPCSTR)) \
        X(GetKeyState,        SHORT,   WINAPI, (int)) \
        X(OpenClipboard,      BOOL,    WINAPI, (HWND)) \
        X(CloseClipboard,     BOOL,    WINAPI, (void)) \
        X(EmptyClipboard,     BOOL,    WINAPI, (void)) \
        X(SetClipboardData,   HANDLE,  WINAPI, (UINT, HANDLE)) \
        X(GetClipboardData,   HANDLE,  WINAPI, (UINT)) \
        X(SetWindowTextW,     BOOL,    WINAPI, (HWND, LPCWSTR)) \
        X(SetWindowPos,       BOOL,    WINAPI, (HWND, HWND, int, int, int, int, UINT)) \
        X(ShowCursor,         int,     WINAPI, (BOOL)) \
        X(SetCursor,          HCURSOR, WINAPI, (HCURSOR)) \
        X(SetCursorPos,       BOOL,    WINAPI, (int, int)) \
        X(GetCursorPos,       BOOL,    WINAPI, (LPPOINT)) \
        X(ScreenToClient,     BOOL,    WINAPI, (HWND, LPPOINT)) \
        X(ClientToScreen,     BOOL,    WINAPI, (HWND, LPPOINT)) \
        X(GetClientRect,      BOOL,    WINAPI, (HWND, LPRECT)) \
        X(GetWindowRect,      BOOL,    WINAPI, (HWND, LPRECT)) \
        X(GetWindowLongPtrA,  LONG_PTR,WINAPI, (HWND, int)) \
        X(SetWindowLongPtrA,  LONG_PTR,WINAPI, (HWND, int, LONG_PTR)) \
        X(GetSystemMetrics,   int,     WINAPI, (int)) \
        X(UpdateLayeredWindow,BOOL,    WINAPI, (HWND, HDC, POINT *, SIZE *, HDC, POINT *, COLORREF, BLENDFUNCTION *, DWORD)) \
        X(SetCapture,         HWND,    WINAPI, (HWND)) \
        X(ReleaseCapture,     BOOL,    WINAPI, (void)) \
        X(GetWindowPlacement, BOOL,    WINAPI, (HWND, WINDOWPLACEMENT *)) \
        X(SetWindowPlacement, BOOL,    WINAPI, (HWND, const WINDOWPLACEMENT *))

#define PEAK_GDI32_API(X) \
        X(StretchDIBits, int, WINAPI, (HDC, int, int, int, int, int, int, int, int, const void *, const BITMAPINFO *, UINT, DWORD)) \
        X(CreateCompatibleDC, HDC, WINAPI, (HDC)) \
        X(CreateDIBSection, HBITMAP, WINAPI, (HDC, const BITMAPINFO *, UINT, void **, HANDLE, DWORD)) \
        X(SelectObject, HGDIOBJ, WINAPI, (HDC, HGDIOBJ)) \
        X(DeleteDC, BOOL, WINAPI, (HDC)) \
        X(DeleteObject, BOOL, WINAPI, (HGDIOBJ))

#define PEAK_WINMM_API(X) \
        X(waveOutOpen,            MMRESULT, WINAPI, (LPHWAVEOUT, UINT, LPCWAVEFORMATEX, DWORD_PTR, DWORD_PTR, DWORD)) \
        X(waveOutClose,           MMRESULT, WINAPI, (HWAVEOUT)) \
        X(waveOutPrepareHeader,   MMRESULT, WINAPI, (HWAVEOUT, LPWAVEHDR, UINT)) \
        X(waveOutUnprepareHeader, MMRESULT, WINAPI, (HWAVEOUT, LPWAVEHDR, UINT)) \
        X(waveOutWrite,           MMRESULT, WINAPI, (HWAVEOUT, LPWAVEHDR, UINT)) \
        X(waveOutReset,           MMRESULT, WINAPI, (HWAVEOUT))

typedef struct {
#define X(name, ret, conv, args) ret (conv *name) args;
	PEAK_USER32_API(X)
#undef X
} PeakUser32Api;

typedef struct {
#define X(name, ret, conv, args) ret (conv *name) args;
	PEAK_GDI32_API(X)
#undef X
} PeakGdi32Api;

typedef struct {
#define X(name, ret, conv, args) ret (conv *name) args;
	PEAK_WINMM_API(X)
#undef X
} PeakWinmmApi;

typedef struct {
	volatile int run;
	HANDLE thread;
	HANDLE event;
	HWAVEOUT out;
	WAVEHDR hdr[PEAK_AUDIO_BUFFERS];
	int16_t *pcm[PEAK_AUDIO_BUFFERS];
	uint32_t channels;
	uint32_t bytes;
	void (*fill)(int16_t *out, size_t frames, void *userdata);
	void *userdata;
} PeakAudio;

typedef struct {
	HMODULE user32;
	HMODULE gdi32;
	int class_reg;
	int timer_period;
} PeakWin32;

struct peak_win32_win {
    WCHAR high_surrogate;
	int ime_x, ime_y, ime_w, ime_h;
	int ime_set;
	int ime_applied;
	int ime_ax, ime_ay, ime_aw, ime_ah;
	HWND hwnd;
	HDC hdc;
	uint32_t *buffer;
	uint32_t width;
	uint32_t height;
	int flags;
	int cursor_on;
	int relative;
	int layered;
	int wheel_acc;
	int touch_n;
	float last_x, last_y;
	WINDOWPLACEMENT place;
	DWORD style, ex;
	PeakQ q;
};


static int peak_internal_user32_load(HMODULE handle);
static int peak_internal_gdi32_load(HMODULE handle);
static PeakKeyCode peak_internal_win32_key_map(WPARAM vk);
static PeakKeyMod peak_internal_win32_mod_map(void);
static int peak_internal_win32_buffer(struct peak_win32_win *w, uint32_t width, uint32_t height);
static LRESULT CALLBACK peak_internal_win32_wndproc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);
static int peak_platform_init(void);
static void peak_platform_quit(void);
static PeakWindowInternal peak_platform_window_open(const char *name, uint32_t width, uint32_t height, uint32_t flags);
static void peak_platform_window_close(PeakWindowInternal *intern);
static uint32_t *peak_platform_window_buffer(PeakWindowInternal *intern, size_t *width, size_t *height);
static void peak_platform_window_present(PeakWindowInternal *intern);
static void peak_platform_window_present_rect(PeakWindowInternal *intern, uint32_t y, uint32_t h);
static void peak_internal_win32_timer_begin(void);
static void peak_internal_win32_timer_end(void);
static bool peak_platform_epoll(PeakWindowInternal *intern, PeakEvent *ev);
static int peak_platform_fd(PeakWindowInternal *intern);
static int peak_platform_pending(PeakWindowInternal *intern);
static int peak_internal_winmm_load(void);
static void peak_internal_win32_audio_fill(int i);
static DWORD WINAPI peak_internal_win32_audio_thread(LPVOID arg);
static void peak_platform_audio_stop(void);
static int peak_platform_audio_start(uint32_t channels, uint32_t rate, void (*fill)(int16_t *out, size_t frames, void *userdata), void *userdata);
static uint64_t peak_platform_get_time(void);
static void peak_platform_sleep_ns(int64_t ns);
static const char **peak_platform_vulkan_get_extensions(uint32_t *count);
static int peak_platform_vulkan_create_surface(PeakWindowInternal *intern, void *instance, const void *allocator, void *out_surface);
static void peak_platform_window_set_title(PeakWindowInternal *intern, const char *name);
static void peak_platform_window_set_text_input_rect(PeakWindowInternal *intern, int x, int y, int w, int h);
static void peak_internal_win32_ime_apply(struct peak_win32_win *w, int force);
static void peak_platform_window_set_size(PeakWindowInternal *intern, uint32_t width, uint32_t height);
static void peak_platform_window_fullscreen(PeakWindowInternal *intern, int on);
static void peak_platform_window_cursor(PeakWindowInternal *intern, int on);
static void peak_platform_window_cursor_shape(PeakWindowInternal *intern, int shape);
static void peak_platform_window_pointer_relative(PeakWindowInternal *intern, int on);
static float peak_platform_window_scale(PeakWindowInternal *intern);

static PeakWin32 peak_win32;
static PeakUser32Api peak_user32;
static PeakGdi32Api peak_gdi32;
static PeakWinmmApi peak_winmm;
static PeakAudio peak_audio;
static void (WINAPI *peak_DragAcceptFiles)(HWND, BOOL);
static UINT (WINAPI *peak_DragQueryFileA)(HDROP, UINT, LPSTR, UINT);
static void (WINAPI *peak_DragFinish)(HDROP);
static HIMC (WINAPI *peak_ImmGetContext)(HWND);
static BOOL (WINAPI *peak_ImmReleaseContext)(HWND, HIMC);
static BOOL (WINAPI *peak_ImmSetCompositionWindow)(HIMC, LPCOMPOSITIONFORM);
static BOOL (WINAPI *peak_ImmSetCandidateWindow)(HIMC, LPCANDIDATEFORM);
static int peak_imm_tried;

static int
peak_internal_user32_load(HMODULE handle)
{
#define X(name, ret, conv, args) peak_user32.name = (ret (conv *) args)(void *)GetProcAddress(handle, #name);
	PEAK_USER32_API(X)
#undef X
#define X(name, ret, conv, args) || !peak_user32.name
	if (0 PEAK_USER32_API(X))
		return 0;
#undef X
	return 1;
}

static int
peak_internal_gdi32_load(HMODULE handle)
{
#define X(name, ret, conv, args) peak_gdi32.name = (ret (conv *) args)(void *)GetProcAddress(handle, #name);
	PEAK_GDI32_API(X)
#undef X
#define X(name, ret, conv, args) || !peak_gdi32.name
	if (0 PEAK_GDI32_API(X))
		return 0;
#undef X
	return 1;
}

static PeakKeyCode
peak_internal_win32_key_map(WPARAM vk)
{
	if (vk >= 'A' && vk <= 'Z')
		return (PeakKeyCode)(PEAK_KEY_A + (int)(vk - 'A'));
	if (vk >= '0' && vk <= '9')
		return (PeakKeyCode)(PEAK_KEY_0 + (int)(vk - '0'));
	switch (vk) {
	case VK_UP:
		return PEAK_KEY_UP;
	case VK_DOWN:
		return PEAK_KEY_DOWN;
	case VK_LEFT:
		return PEAK_KEY_LEFT;
	case VK_RIGHT:
		return PEAK_KEY_RIGHT;
	case VK_SPACE:
		return PEAK_KEY_SPACE;
	case VK_ESCAPE:
		return PEAK_KEY_ESCAPE;
	case VK_RETURN:
		return PEAK_KEY_ENTER;
	case VK_BACK:
		return PEAK_KEY_BACKSPACE;
	case VK_TAB:
		return PEAK_KEY_TAB;
	case VK_DELETE:
		return PEAK_KEY_DELETE;
	case VK_INSERT:
		return PEAK_KEY_INSERT;
	case VK_HOME:
		return PEAK_KEY_HOME;
	case VK_END:
		return PEAK_KEY_END;
	case VK_PRIOR:
		return PEAK_KEY_PAGEUP;
	case VK_NEXT:
		return PEAK_KEY_PAGEDOWN;
	case VK_F1: return PEAK_KEY_F1;
	case VK_F2: return PEAK_KEY_F2;
	case VK_F3: return PEAK_KEY_F3;
	case VK_F4: return PEAK_KEY_F4;
	case VK_F5: return PEAK_KEY_F5;
	case VK_F6: return PEAK_KEY_F6;
	case VK_F7: return PEAK_KEY_F7;
	case VK_F8: return PEAK_KEY_F8;
	case VK_F9: return PEAK_KEY_F9;
	case VK_F10: return PEAK_KEY_F10;
	case VK_F11: return PEAK_KEY_F11;
	case VK_F12: return PEAK_KEY_F12;
	default:
		return PEAK_KEY_UNKNOWN;
	}
}

static PeakKeyMod
peak_internal_win32_mod_map(void)
{
	PeakKeyMod m;

	m = 0;
	if (peak_user32.GetKeyState(VK_SHIFT) & 0x8000)
		m |= PEAK_KEYMOD_SHIFT;
	if (peak_user32.GetKeyState(VK_CONTROL) & 0x8000)
		m |= PEAK_KEYMOD_CTRL;
	if (peak_user32.GetKeyState(VK_MENU) & 0x8000)
		m |= PEAK_KEYMOD_ALT;
	if (peak_user32.GetKeyState(VK_CAPITAL) & 1)
		m |= PEAK_KEYMOD_CAPS;
	if (peak_user32.GetKeyState(VK_LWIN) & 0x8000 || peak_user32.GetKeyState(VK_RWIN) & 0x8000)
		m |= PEAK_KEYMOD_SUPER;
	return m;
}

static int
peak_internal_win32_buffer(struct peak_win32_win *w, uint32_t width, uint32_t height)
{
	uint32_t *buffer;

	if (!(buffer = calloc((size_t)width * height, sizeof *buffer)))
		return 0;
	free(w->buffer);
	w->buffer = buffer;
	w->width = width;
	w->height = height;
	return 1;
}

static LRESULT CALLBACK
peak_internal_win32_wndproc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
	struct peak_win32_win *w;
	PeakEvent ev;
	CREATESTRUCTW *cs;

	if (msg == WM_NCCREATE) {
		cs = (CREATESTRUCTW *)lparam;
		peak_user32.SetPropA(hwnd, PEAK_WIN32_PROP, cs->lpCreateParams);
	}

	w = (struct peak_win32_win *)peak_user32.GetPropA(hwnd, PEAK_WIN32_PROP);
	if (!w)
		return peak_user32.DefWindowProcW(hwnd, msg, wparam, lparam);

	switch (msg) {
	case WM_CLOSE:
		memset(&ev, 0, sizeof ev);
		ev.type = PEAK_EVENT_WINDOW_CLOSE;
		peak_q_push(&w->q, ev);
		return 0;
	case WM_SIZE: {
		uint32_t width, height;

		if (wparam == SIZE_MINIMIZED)
			return 0;
		width = (uint32_t)LOWORD(lparam);
		height = (uint32_t)HIWORD(lparam);
		if (!width || !height || (width == w->width && height == w->height))
			return 0;
		if (!peak_internal_win32_buffer(w, width, height))
			return 0;
		memset(&ev, 0, sizeof ev);
		ev.type = PEAK_EVENT_WINDOW_RESIZE;
		ev.resize.width = w->width;
		ev.resize.height = w->height;
		peak_q_push(&w->q, ev);
		return 0;
	}
	case WM_KEYDOWN: /* FALLTHROUGH */
	case WM_KEYUP: /* FALLTHROUGH */
	case WM_SYSKEYDOWN: /* FALLTHROUGH */
	case WM_SYSKEYUP:
		/* Alt+F4 (close) and Alt+Space (system menu) belong to the system. */
		if ((msg == WM_SYSKEYDOWN || msg == WM_SYSKEYUP) && (wparam == VK_F4 || wparam == VK_SPACE))
			return peak_user32.DefWindowProcW(hwnd, msg, wparam, lparam);
		memset(&ev, 0, sizeof ev);
		ev.type = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) ? PEAK_EVENT_KEY_DOWN : PEAK_EVENT_KEY_UP;
		ev.key.key = peak_internal_win32_key_map(wparam);
		ev.key.mod = peak_internal_win32_mod_map();
        ev.key.code = MapVirtualKeyW((UINT)wparam, MAPVK_VK_TO_CHAR) & 0x7fffffff;
        if (ev.key.code >= 'A' && ev.key.code <= 'Z' &&
            !((ev.key.mod & PEAK_KEYMOD_SHIFT) != 0 ^ (ev.key.mod & PEAK_KEYMOD_CAPS) != 0))
            ev.key.code += 'a' - 'A';
        /* AltGr is text input, not a Control+Alt shortcut. */
        if ((peak_user32.GetKeyState(VK_RMENU) & 0x8000) && (ev.key.mod & PEAK_KEYMOD_CTRL))
            ev.key.mod &= ~(PEAK_KEYMOD_CTRL | PEAK_KEYMOD_ALT);
		peak_q_push(&w->q, ev);
		return 0;
	case WM_SYSCHAR:
		/* The key already arrived via WM_SYSKEYDOWN; swallow to avoid the beep. */
		if (wparam == ' ')
			return peak_user32.DefWindowProcW(hwnd, msg, wparam, lparam);
		return 0;
    case WM_CHAR: {
        WCHAR chars[2];
        char utf8[8];
        int count = 1, n;
        WCHAR ch = (WCHAR)wparam;
        if (ch >= 0xd800 && ch <= 0xdbff) { w->high_surrogate = ch; return 0; }
        chars[0] = ch;
        if (w->high_surrogate && ch >= 0xdc00 && ch <= 0xdfff) {
            chars[0] = w->high_surrogate; chars[1] = ch; count = 2;
        }
        w->high_surrogate = 0;
        n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, chars, count, utf8, sizeof utf8, NULL, NULL);
        if (n > 0 && ch >= 32 && ch != 0x7f) peak_q_text(&w->q, utf8, (size_t)n);
        return 0;
    }
    case 0x02e0: { /* WM_DPICHANGED */
        const RECT *r = (const RECT *)lparam;
        peak_user32.SetWindowPos(hwnd, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
	case WM_MOUSEWHEEL: {
		POINT pt;
		int delta;

		delta = (int)(short)HIWORD(wparam);
		if ((delta > 0 && w->wheel_acc < 0) || (delta < 0 && w->wheel_acc > 0))
			w->wheel_acc = 0;
		w->wheel_acc += delta;
		pt.x = (short)LOWORD(lparam);
		pt.y = (short)HIWORD(lparam);
		peak_user32.ScreenToClient(hwnd, &pt);
		while (w->wheel_acc >= WHEEL_DELTA || w->wheel_acc <= -WHEEL_DELTA) {
			memset(&ev, 0, sizeof ev);
			ev.type = PEAK_EVENT_POINTER;
			ev.pointer.state = PEAK_POINTER_PRESSED;
			ev.pointer.type = (w->wheel_acc > 0) ? PEAK_POINTER_WHEEL_UP : PEAK_POINTER_WHEEL_DOWN;
			ev.pointer.x = (float)pt.x;
			ev.pointer.y = (float)pt.y;
			ev.pointer.mod = peak_internal_win32_mod_map();
			peak_q_push(&w->q, ev);
			w->wheel_acc += (w->wheel_acc > 0) ? -WHEEL_DELTA : WHEEL_DELTA;
		}
		return 0;
	}
	case WM_DROPFILES:
		if (peak_DragQueryFileA) {
			char path[MAX_PATH];
			UINT n;

			n = peak_DragQueryFileA((HDROP)wparam, 0, path, MAX_PATH);
			if (n) {
				peak_drop_store(path, n);
				memset(&ev, 0, sizeof ev);
				ev.type = PEAK_EVENT_DROP;
				ev.drop.n = n;
				peak_q_push(&w->q, ev);
			}
			if (peak_DragFinish)
				peak_DragFinish((HDROP)wparam);
		}
		return 0;
	case WM_MOUSEMOVE: /* FALLTHROUGH */
	case WM_LBUTTONDOWN: /* FALLTHROUGH */
	case WM_LBUTTONUP: /* FALLTHROUGH */
	case WM_RBUTTONDOWN: /* FALLTHROUGH */
	case WM_RBUTTONUP: /* FALLTHROUGH */
	case WM_MBUTTONDOWN: /* FALLTHROUGH */
	case WM_MBUTTONUP:
		memset(&ev, 0, sizeof ev);
		ev.type = PEAK_EVENT_POINTER;
		ev.pointer.x = (float)(short)LOWORD(lparam);
		ev.pointer.y = (float)(short)HIWORD(lparam);
		if (w->relative && msg == WM_MOUSEMOVE) {
			ev.pointer.x -= w->last_x;
			ev.pointer.y -= w->last_y;
		}
		w->last_x = (float)(short)LOWORD(lparam);
		w->last_y = (float)(short)HIWORD(lparam);
		if (msg == WM_MOUSEMOVE) {
			ev.pointer.state = PEAK_POINTER_MOVED;
			ev.pointer.type = (wparam & MK_RBUTTON) ? PEAK_POINTER_RIGHT :
			                  (wparam & MK_MBUTTON) ? PEAK_POINTER_MIDDLE : PEAK_POINTER_LEFT;
		} else if (msg == WM_LBUTTONDOWN || msg == WM_RBUTTONDOWN || msg == WM_MBUTTONDOWN) {
			ev.pointer.state = PEAK_POINTER_PRESSED;
			if (peak_user32.SetCapture)
				peak_user32.SetCapture(hwnd);
			ev.pointer.type = (msg == WM_RBUTTONDOWN) ? PEAK_POINTER_RIGHT :
			                  (msg == WM_MBUTTONDOWN) ? PEAK_POINTER_MIDDLE : PEAK_POINTER_LEFT;
		} else {
			ev.pointer.state = PEAK_POINTER_RELEASED;
			if (!w->relative && !(wparam & (MK_LBUTTON | MK_RBUTTON | MK_MBUTTON)) && peak_user32.ReleaseCapture)
				peak_user32.ReleaseCapture();
			ev.pointer.type = (msg == WM_RBUTTONUP) ? PEAK_POINTER_RIGHT :
			                  (msg == WM_MBUTTONUP) ? PEAK_POINTER_MIDDLE : PEAK_POINTER_LEFT;
		}
		ev.pointer.mod = peak_internal_win32_mod_map();
		peak_q_push(&w->q, ev);
		if (w->relative && msg == WM_MOUSEMOVE && peak_user32.SetCursorPos) {
			POINT pt;
			RECT rc;

			peak_user32.GetClientRect(w->hwnd, &rc);
			pt.x = (rc.right - rc.left) / 2;
			pt.y = (rc.bottom - rc.top) / 2;
			peak_user32.ClientToScreen(w->hwnd, &pt);
			peak_user32.SetCursorPos(pt.x, pt.y);
			w->last_x = (float)((rc.right - rc.left) / 2);
			w->last_y = (float)((rc.bottom - rc.top) / 2);
		}
		return 0;
	case WM_IME_STARTCOMPOSITION:
		peak_internal_win32_ime_apply(w, 1);
		return peak_user32.DefWindowProcW(hwnd, msg, wparam, lparam);
    case WM_SETFOCUS:
    case WM_KILLFOCUS:
        memset(&ev, 0, sizeof ev);
        ev.type = PEAK_EVENT_FOCUS;
        ev.focus.on = msg == WM_SETFOCUS;
        peak_q_push(&w->q, ev);
        return 0;
	case WM_PAINT: {
		PAINTSTRUCT ps;

		peak_user32.BeginPaint(hwnd, &ps);
        peak_user32.EndPaint(hwnd, &ps);
        memset(&ev, 0, sizeof ev);
        ev.type = PEAK_EVENT_EXPOSE;
        peak_q_push(&w->q, ev);
		return 0;
	}
	case WM_ERASEBKGND:
		return 1;
	case WM_DESTROY:
		peak_user32.RemovePropA(hwnd, PEAK_WIN32_PROP);
		return 0;
	default:
		return peak_user32.DefWindowProcW(hwnd, msg, wparam, lparam);
	}
}

static int
peak_platform_init(void)
{
	WNDCLASSEXW wc;

	peak_internal_win32_timer_begin();
	if (!peak_user32.CreateWindowExW) {
		if (!(peak_win32.user32 = LoadLibraryA(PEAK_WIN32_USER32))) {
			fputs("Failed to load user32.dll. What system are you fucking using and abusing?", stderr);
			return 0;
		}
		if (!peak_internal_user32_load(peak_win32.user32)) {
			fputs("Failed to load user32 symbols", stderr);
			return 0;
		}
	}
	if (!peak_gdi32.StretchDIBits) {
		if (!(peak_win32.gdi32 = LoadLibraryA(PEAK_WIN32_GDI32))) {
			fputs("Failed to load gdi32.dll. What system are you fucking using and abusing?", stderr);
			return 0;
		}
		if (!peak_internal_gdi32_load(peak_win32.gdi32)) {
			fputs("Failed to load gdi32 symbols", stderr);
			return 0;
		}
	}
	if (!peak_DragAcceptFiles) {
		HMODULE sh;

		sh = LoadLibraryA("shell32.dll");
		if (sh) {
			peak_DragAcceptFiles = (void (WINAPI *)(HWND, BOOL))(void *)GetProcAddress(sh, "DragAcceptFiles");
			peak_DragQueryFileA = (UINT (WINAPI *)(HDROP, UINT, LPSTR, UINT))(void *)GetProcAddress(sh, "DragQueryFileA");
			peak_DragFinish = (void (WINAPI *)(HDROP))(void *)GetProcAddress(sh, "DragFinish");
		}
	}
	if (!peak_win32.class_reg) {
		memset(&wc, 0, sizeof wc);
		wc.cbSize = sizeof wc;
		wc.style = CS_OWNDC;
		wc.lpfnWndProc = peak_internal_win32_wndproc;
        wc.hInstance = GetModuleHandleA(NULL);
        wc.hIcon = LoadIconW(wc.hInstance, MAKEINTRESOURCEW(1));
        wc.hIconSm = wc.hIcon;
		wc.hCursor = peak_user32.LoadCursorA(NULL, IDC_ARROW);
		wc.lpszClassName = PEAK_WIN32_CLASS;
		if (!peak_user32.RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
			fputs("Failed to register window class", stderr);
			return 0;
		}
		peak_win32.class_reg = 1;
	}
	return 1;
}

static void
peak_internal_win32_timer_begin(void)
{
	typedef UINT (WINAPI *TimerFn)(UINT);
	HMODULE mm;
	TimerFn fn;

	if (peak_win32.timer_period)
		return;
	if (!(mm = LoadLibraryA(PEAK_WIN32_WINMM)))
		return;
	fn = (TimerFn)(void *)GetProcAddress(mm, "timeBeginPeriod");
	if (fn && fn(1) == 0)
		peak_win32.timer_period = 1;
}

static void
peak_internal_win32_timer_end(void)
{
	typedef UINT (WINAPI *TimerFn)(UINT);
	HMODULE mm;
	TimerFn fn;

	if (!peak_win32.timer_period)
		return;
	peak_win32.timer_period = 0;
	if (!(mm = GetModuleHandleA(PEAK_WIN32_WINMM)))
		return;
	fn = (TimerFn)(void *)GetProcAddress(mm, "timeEndPeriod");
	if (fn)
		fn(1);
}

static void
peak_platform_quit(void)
{
	peak_internal_win32_timer_end();
	if (!peak_win32.class_reg)
		return;
	peak_user32.UnregisterClassW(PEAK_WIN32_CLASS, GetModuleHandleA(NULL));
	peak_win32.class_reg = 0;
}

static PeakWindowInternal
peak_platform_window_open(const char *name, uint32_t width, uint32_t height, uint32_t flags)
{
	PeakWindowInternal intern = {0};
	struct peak_win32_win *w;
	DWORD style, ex;
	RECT r;
	HINSTANCE inst;

	if (!peak_user32.CreateWindowExW && !peak_platform_init())
		return intern;

	if (!(w = calloc(1, sizeof *w)))
		return intern;
	if (!peak_internal_win32_buffer(w, width, height)) {
		free(w);
		return intern;
	}

	ex = (flags & PEAK_WINDOW_TRANSPARENT) ? WS_EX_LAYERED : 0;
	style = (flags & PEAK_WINDOW_FULLSCREEN) ? (WS_POPUP | WS_VISIBLE) : WS_OVERLAPPEDWINDOW;
	r.left = 0;
	r.top = 0;
	r.right = (LONG)width;
	r.bottom = (LONG)height;
	peak_user32.AdjustWindowRectEx(&r, style, FALSE, ex);
	inst = GetModuleHandleA(NULL);
	WCHAR title[1024];
    if (!MultiByteToWideChar(CP_UTF8, 0, name, -1, title, 1024)) title[0] = 0;
    w->hwnd = peak_user32.CreateWindowExW(ex, PEAK_WIN32_CLASS, title, style,
		CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left, r.bottom - r.top,
		NULL, NULL, inst, w);
	if (!w->hwnd) {
		free(w->buffer);
		free(w);
		return intern;
	}

	w->hdc = peak_user32.GetDC(w->hwnd);
	if (!w->hdc) {
		peak_user32.DestroyWindow(w->hwnd);
		free(w->buffer);
		free(w);
		return intern;
	}

	w->flags = (int)flags;
	w->cursor_on = 1;
	w->layered = !!(flags & PEAK_WINDOW_TRANSPARENT);
	w->style = style;
	w->ex = ex;
	if (peak_DragAcceptFiles)
		peak_DragAcceptFiles(w->hwnd, TRUE);
	peak_user32.ShowWindow(w->hwnd, SW_SHOWNORMAL);
	if (flags & PEAK_WINDOW_FULLSCREEN) {
		intern.w = w;
		peak_platform_window_fullscreen(&intern, 1);
		return intern;
	}
	intern.w = w;
	return intern;
}

static void
peak_platform_window_close(PeakWindowInternal *intern)
{
	struct peak_win32_win *w;

	if (!intern || !intern->w)
		return;
	w = intern->w;
	if (w->hdc && w->hwnd)
		peak_user32.ReleaseDC(w->hwnd, w->hdc);
	if (w->hwnd) {
		peak_user32.RemovePropA(w->hwnd, PEAK_WIN32_PROP);
		peak_user32.DestroyWindow(w->hwnd);
	}
	free(w->buffer);
	free(w);
	intern->w = NULL;
}

static uint32_t *
peak_platform_window_buffer(PeakWindowInternal *intern, size_t *width, size_t *height)
{
	struct peak_win32_win *w;

	w = intern ? intern->w : NULL;
	if (!w) {
		*width = 0;
		*height = 0;
		return NULL;
	}
	*width = w->width;
	*height = w->height;
	return w->buffer;
}

static void
peak_platform_window_present(PeakWindowInternal *intern)
{
	struct peak_win32_win *w;
	BITMAPINFO bmi;

	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd || !w->hdc || !w->buffer)
		return;

	memset(&bmi, 0, sizeof bmi);
	bmi.bmiHeader.biSize = sizeof (BITMAPINFOHEADER);
	bmi.bmiHeader.biWidth = (LONG)w->width;
	bmi.bmiHeader.biHeight = -(LONG)w->height;
	bmi.bmiHeader.biPlanes = 1;
	bmi.bmiHeader.biBitCount = 32;
	bmi.bmiHeader.biCompression = BI_RGB;
	if (w->layered && peak_user32.UpdateLayeredWindow && peak_gdi32.CreateCompatibleDC) {
		HDC mem;
		HBITMAP dib, old;
		void *bits;
		SIZE size;
		POINT dst, src;
		BLENDFUNCTION blend;

		mem = peak_gdi32.CreateCompatibleDC(w->hdc);
		if (!mem)
			return;
		dib = peak_gdi32.CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
		if (!dib) {
			peak_gdi32.DeleteDC(mem);
			return;
		}
		old = peak_gdi32.SelectObject(mem, dib);
		if (bits)
			memcpy(bits, w->buffer, (size_t)w->width * w->height * 4);
		dst.x = dst.y = 0;
		src.x = src.y = 0;
		size.cx = (LONG)w->width;
		size.cy = (LONG)w->height;
		blend.BlendOp = AC_SRC_OVER;
		blend.BlendFlags = 0;
		blend.SourceConstantAlpha = 255;
		blend.AlphaFormat = AC_SRC_ALPHA;
		{
			RECT wr;

			peak_user32.GetWindowRect(w->hwnd, &wr);
			dst.x = wr.left;
			dst.y = wr.top;
		}
		peak_user32.UpdateLayeredWindow(w->hwnd, w->hdc, &dst, &size, mem, &src, 0, &blend, ULW_ALPHA);
		peak_gdi32.SelectObject(mem, old);
		peak_gdi32.DeleteObject(dib);
		peak_gdi32.DeleteDC(mem);
		return;
	}
	peak_gdi32.StretchDIBits(w->hdc,
		0, 0, (int)w->width, (int)w->height,
		0, 0, (int)w->width, (int)w->height,
		w->buffer, &bmi, DIB_RGB_COLORS, SRCCOPY);
}

static void
peak_internal_win32_blit_rows(struct peak_win32_win *w, uint32_t x, uint32_t y, uint32_t cw, uint32_t h)
{
	BITMAPINFO bmi;

	if (x >= w->width || y >= w->height || !cw || !h)
		return;
	if (cw > w->width - x)
		cw = w->width - x;
	if (h > w->height - y)
		h = w->height - y;
	memset(&bmi, 0, sizeof bmi);
	bmi.bmiHeader.biSize = sizeof (BITMAPINFOHEADER);
	bmi.bmiHeader.biWidth = (LONG)w->width;
	bmi.bmiHeader.biHeight = -(LONG)h;
	bmi.bmiHeader.biPlanes = 1;
	bmi.bmiHeader.biBitCount = 32;
	bmi.bmiHeader.biCompression = BI_RGB;
	/* Bits start at row y; the DIB is h rows tall, so source rows are 0..h. */
	peak_gdi32.StretchDIBits(w->hdc,
		(int)x, (int)y, (int)cw, (int)h,
		(int)x, 0, (int)cw, (int)h,
		w->buffer + (size_t)y * w->width, &bmi, DIB_RGB_COLORS, SRCCOPY);
}

static void
peak_platform_window_present_rect(PeakWindowInternal *intern, uint32_t y, uint32_t h)
{
	struct peak_win32_win *w;

	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd || !w->hdc || !w->buffer)
		return;
	if (w->layered) {
		peak_platform_window_present(intern);
		return;
	}
	peak_internal_win32_blit_rows(w, 0, y, w->width, h);
}

static int
peak_platform_drop_drag(PeakWindowInternal *intern, const char *utf8, size_t n)
{
	(void)intern;
	(void)utf8;
	(void)n;
	return 0;
}

static int
peak_platform_clip_set(PeakWindowInternal *intern, PeakClip which, const char *utf8, size_t n)
{
	struct peak_win32_win *w;
	wchar_t *wide;
	int wlen;
	HGLOBAL mem;
	wchar_t *lock;

	(void)which;
	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd || !peak_user32.OpenClipboard)
		return 0;
	wlen = MultiByteToWideChar(CP_UTF8, 0, utf8 ? utf8 : "", n ? (int)n : 0, NULL, 0);
	if (wlen < 0)
		return 0;
	wide = malloc(((size_t)wlen + 1) * sizeof *wide);
	if (!wide)
		return 0;
	MultiByteToWideChar(CP_UTF8, 0, utf8 ? utf8 : "", n ? (int)n : 0, wide, wlen);
	wide[wlen] = 0;
	if (!peak_user32.OpenClipboard(w->hwnd)) {
		free(wide);
		return 0;
	}
	peak_user32.EmptyClipboard();
	mem = GlobalAlloc(GMEM_MOVEABLE, ((size_t)wlen + 1) * sizeof (wchar_t));
	if (!mem) {
		peak_user32.CloseClipboard();
		free(wide);
		return 0;
	}
	lock = GlobalLock(mem);
	if (!lock) {
		GlobalFree(mem);
		peak_user32.CloseClipboard();
		free(wide);
		return 0;
	}
	memcpy(lock, wide, ((size_t)wlen + 1) * sizeof (wchar_t));
	GlobalUnlock(mem);
	free(wide);
	if (!peak_user32.SetClipboardData(CF_UNICODETEXT, mem)) {
		GlobalFree(mem);
		peak_user32.CloseClipboard();
		return 0;
	}
	peak_user32.CloseClipboard();
	return 1;
}

static int
peak_platform_clip_request(PeakWindowInternal *intern, PeakClip which)
{
	struct peak_win32_win *w;
	HANDLE mem;
	wchar_t *lock;
	char *utf8;
	int n;
	PeakEvent ev;

	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd || !peak_user32.OpenClipboard)
		return 0;
	if (!peak_user32.OpenClipboard(w->hwnd)) {
		const char *p;
		size_t pn;

		if (!peak_clip_own_get(which, &p, &pn))
			return 0;
		peak_clip_paste_store(which, p, pn);
		memset(&ev, 0, sizeof ev);
		ev.type = PEAK_EVENT_CLIP;
		ev.clip.which = which;
		ev.clip.n = pn;
		peak_q_push(&w->q, ev);
		return 1;
	}
	mem = peak_user32.GetClipboardData(CF_UNICODETEXT);
	if (!mem) {
		peak_user32.CloseClipboard();
		return 0;
	}
	lock = GlobalLock(mem);
	if (!lock) {
		peak_user32.CloseClipboard();
		return 0;
	}
	n = WideCharToMultiByte(CP_UTF8, 0, lock, -1, NULL, 0, NULL, NULL);
	if (n <= 0) {
		GlobalUnlock(mem);
		peak_user32.CloseClipboard();
		return 0;
	}
	utf8 = malloc((size_t)n);
	if (!utf8) {
		GlobalUnlock(mem);
		peak_user32.CloseClipboard();
		return 0;
	}
	WideCharToMultiByte(CP_UTF8, 0, lock, -1, utf8, n, NULL, NULL);
	GlobalUnlock(mem);
	peak_user32.CloseClipboard();
	if (n > 0 && utf8[n - 1] == 0)
		n--;
	if ((size_t)n > PEAK_CLIP_MAX)
		n = (int)PEAK_CLIP_MAX;
	peak_clip_paste_store(which, utf8, (size_t)n);
	free(utf8);
	memset(&ev, 0, sizeof ev);
	ev.type = PEAK_EVENT_CLIP;
	ev.clip.which = which;
	ev.clip.n = peak_clip.paste_n;
	peak_q_push(&w->q, ev);
	return 1;
}

static bool
peak_platform_epoll(PeakWindowInternal *intern, PeakEvent *ev)
{
	MSG msg;
	struct peak_win32_win *w;

	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd)
		return 0;

	if (peak_q_pop(&w->q, ev))
		return 1;
	while (peak_user32.PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
		if (msg.message == WM_QUIT) {
			PeakEvent close;

			memset(&close, 0, sizeof close);
			close.type = PEAK_EVENT_WINDOW_CLOSE;
			peak_q_push(&w->q, close);
			if (peak_q_pop(&w->q, ev))
				return 1;
			continue;
		}
		peak_user32.TranslateMessage(&msg);
		peak_user32.DispatchMessageW(&msg);
		if (peak_q_pop(&w->q, ev))
			return 1;
	}
	return peak_q_pop(&w->q, ev);
}

static int
peak_platform_fd(PeakWindowInternal *intern)
{
	(void)intern;
	return -1;
}

static int
peak_platform_pending(PeakWindowInternal *intern)
{
	struct peak_win32_win *w;
	MSG msg;

	w = intern ? intern->w : NULL;
	if (!w)
		return 0;
	if (w->q.n)
		return (int)w->q.n;
	if (peak_user32.PeekMessageW && peak_user32.PeekMessageW(&msg, NULL, 0, 0, PM_NOREMOVE))
		return 1;
	return 0;
}

static int
peak_internal_winmm_load(void)
{
	HMODULE handle;

	if (peak_winmm.waveOutOpen)
		return 1;
	if (!(handle = LoadLibraryA(PEAK_WIN32_WINMM))) {
		fputs("Failed to load winmm.dll. What system are you fucking using and abusing?", stderr);
		return 0;
	}
#define X(name, ret, conv, args) peak_winmm.name = (ret (conv *) args)(void *)GetProcAddress(handle, #name);
	PEAK_WINMM_API(X)
#undef X
#define X(name, ret, conv, args) || !peak_winmm.name
	if (0 PEAK_WINMM_API(X)) {
		fputs("Failed to load winmm symbols", stderr);
		return 0;
	}
#undef X
	return 1;
}

static void
peak_internal_win32_audio_fill(int i)
{
	memset(peak_audio.pcm[i], 0, peak_audio.bytes);
	if (peak_audio.fill)
		peak_audio.fill(peak_audio.pcm[i], PEAK_AUDIO_FRAMES, peak_audio.userdata);
	peak_winmm.waveOutWrite(peak_audio.out, &peak_audio.hdr[i], sizeof (WAVEHDR));
}

static DWORD WINAPI
peak_internal_win32_audio_thread(LPVOID arg)
{
	int i, did;

	(void)arg;
	for (;;) {
		did = 0;
		if (!peak_audio.run)
			break;
		for (i = 0; i < PEAK_AUDIO_BUFFERS; i++) {
			if (peak_audio.hdr[i].dwFlags & WHDR_DONE) {
				peak_internal_win32_audio_fill(i);
				did = 1;
			}
		}
		if (did)
			continue;
		WaitForSingleObject(peak_audio.event, INFINITE);
		ResetEvent(peak_audio.event);
	}
	return 0;
}

static void
peak_platform_audio_stop(void)
{
	int i;

	peak_audio.run = 0;
	if (peak_audio.event)
		SetEvent(peak_audio.event);
	if (peak_audio.thread) {
		WaitForSingleObject(peak_audio.thread, INFINITE);
		CloseHandle(peak_audio.thread);
		peak_audio.thread = NULL;
	}
	if (peak_audio.out) {
		peak_winmm.waveOutReset(peak_audio.out);
		for (i = 0; i < PEAK_AUDIO_BUFFERS; i++) {
			if (peak_audio.hdr[i].dwFlags & WHDR_PREPARED)
				peak_winmm.waveOutUnprepareHeader(peak_audio.out, &peak_audio.hdr[i], sizeof (WAVEHDR));
			free(peak_audio.pcm[i]);
			peak_audio.pcm[i] = NULL;
			memset(&peak_audio.hdr[i], 0, sizeof peak_audio.hdr[i]);
		}
		peak_winmm.waveOutClose(peak_audio.out);
		peak_audio.out = NULL;
	}
	if (peak_audio.event) {
		CloseHandle(peak_audio.event);
		peak_audio.event = NULL;
	}
	peak_audio.fill = NULL;
	peak_audio.userdata = NULL;
}

static int
peak_platform_audio_start(uint32_t channels, uint32_t rate, void (*fill)(int16_t *out, size_t frames, void *userdata), void *userdata)
{
	WAVEFORMATEX fmt;
	int i;

	if (channels > 32)
		return 0;
	if (!peak_internal_winmm_load())
		return 0;

	memset(&fmt, 0, sizeof fmt);
	fmt.wFormatTag = WAVE_FORMAT_PCM;
	fmt.nChannels = (WORD)channels;
	fmt.nSamplesPerSec = rate;
	fmt.wBitsPerSample = 16;
	fmt.nBlockAlign = (WORD)(channels * 2);
	fmt.nAvgBytesPerSec = rate * fmt.nBlockAlign;

	peak_audio.event = CreateEventA(NULL, TRUE, FALSE, NULL);
	if (!peak_audio.event)
		return 0;
	if (peak_winmm.waveOutOpen(&peak_audio.out, WAVE_MAPPER, &fmt, (DWORD_PTR)peak_audio.event, 0, CALLBACK_EVENT) != MMSYSERR_NOERROR) {
		CloseHandle(peak_audio.event);
		peak_audio.event = NULL;
		fputs("Failed to open waveOut device", stderr);
		return 0;
	}

	peak_audio.channels = channels;
	peak_audio.bytes = (uint32_t)channels * PEAK_AUDIO_FRAMES * sizeof (int16_t);
	peak_audio.fill = fill;
	peak_audio.userdata = userdata;
	peak_audio.run = 1;

	for (i = 0; i < PEAK_AUDIO_BUFFERS; i++) {
		if (!(peak_audio.pcm[i] = calloc(1, peak_audio.bytes)))
			goto fail;
		memset(&peak_audio.hdr[i], 0, sizeof peak_audio.hdr[i]);
		peak_audio.hdr[i].lpData = (LPSTR)peak_audio.pcm[i];
		peak_audio.hdr[i].dwBufferLength = peak_audio.bytes;
		if (peak_winmm.waveOutPrepareHeader(peak_audio.out, &peak_audio.hdr[i], sizeof (WAVEHDR)) != MMSYSERR_NOERROR)
			goto fail;
		peak_audio.hdr[i].dwFlags |= WHDR_DONE;
	}

	for (i = 0; i < PEAK_AUDIO_BUFFERS; i++)
		peak_internal_win32_audio_fill(i);

	peak_audio.thread = CreateThread(NULL, 0, peak_internal_win32_audio_thread, NULL, 0, NULL);
	if (!peak_audio.thread)
		goto fail;
	return 1;

fail:
	peak_platform_audio_stop();
	return 0;
}

static uint64_t
peak_platform_get_time(void)
{
	LARGE_INTEGER count, freq;

	QueryPerformanceCounter(&count);
	QueryPerformanceFrequency(&freq);
	return (uint64_t)((count.QuadPart * 1000000000ull) / freq.QuadPart);
}

static void
peak_platform_sleep_ns(int64_t ns)
{
	if (ns <= 0)
		return;
	Sleep((DWORD)(ns / 1000000));
}

static const char **
peak_platform_vulkan_get_extensions(uint32_t *count)
{
	static const char *exts[] = {
		"VK_KHR_surface",
		"VK_KHR_win32_surface",
	};
	if (count)
		*count = 2;
	return exts;
}

static int
peak_platform_vulkan_create_surface(PeakWindowInternal *intern, void *instance, const void *allocator, void *out_surface)
{
#ifdef PEAK_VULKAN
	struct peak_win32_win *w;
	VkWin32SurfaceCreateInfoKHR ci;

	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd)
		return 0;
	memset(&ci, 0, sizeof ci);
	ci.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
	ci.hwnd = w->hwnd;
	ci.hinstance = GetModuleHandleA(NULL);
	return vkCreateWin32SurfaceKHR((VkInstance)instance, &ci, (const VkAllocationCallbacks *)allocator, (VkSurfaceKHR *)out_surface) == VK_SUCCESS;
#else
	(void)intern;
	(void)instance;
	(void)allocator;
	(void)out_surface;
	return 0;
#endif
}

static void
peak_platform_window_set_class(PeakWindowInternal *intern, const char *name)
{
	(void)intern;
	(void)name;
}

static void
peak_platform_window_set_opacity(PeakWindowInternal *intern, uint8_t alpha)
{
	(void)intern;
	(void)alpha;
}

static void
peak_platform_window_set_title(PeakWindowInternal *intern, const char *name)
{
	struct peak_win32_win *w;

	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd || !name || !peak_user32.SetWindowTextW)
		return;
	WCHAR title[1024];
    if (MultiByteToWideChar(CP_UTF8, 0, name, -1, title, 1024)) peak_user32.SetWindowTextW(w->hwnd, title);
}

static void
peak_platform_window_set_size(PeakWindowInternal *intern, uint32_t width, uint32_t height)
{
	struct peak_win32_win *w;
	RECT r;

	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd || !peak_user32.SetWindowPos)
		return;
	r.left = 0;
	r.top = 0;
	r.right = (LONG)width;
	r.bottom = (LONG)height;
	peak_user32.AdjustWindowRectEx(&r, w->style ? w->style : WS_OVERLAPPEDWINDOW, FALSE, w->ex);
	peak_user32.SetWindowPos(w->hwnd, NULL, 0, 0, r.right - r.left, r.bottom - r.top, SWP_NOMOVE | SWP_NOZORDER);
}

static void
peak_platform_window_fullscreen(PeakWindowInternal *intern, int on)
{
	struct peak_win32_win *w;
	int sw, sh;

	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd || !peak_user32.SetWindowLongPtrA)
		return;
	if (on) {
		w->place.length = sizeof w->place;
		peak_user32.GetWindowPlacement(w->hwnd, &w->place);
		w->style = (DWORD)peak_user32.GetWindowLongPtrA(w->hwnd, GWL_STYLE);
		peak_user32.SetWindowLongPtrA(w->hwnd, GWL_STYLE, (LONG_PTR)((w->style & ~WS_OVERLAPPEDWINDOW) | WS_POPUP));
		sw = peak_user32.GetSystemMetrics(SM_CXSCREEN);
		sh = peak_user32.GetSystemMetrics(SM_CYSCREEN);
		peak_user32.SetWindowPos(w->hwnd, HWND_TOP, 0, 0, sw, sh, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
	} else {
		peak_user32.SetWindowLongPtrA(w->hwnd, GWL_STYLE, (LONG_PTR)(w->style | WS_OVERLAPPEDWINDOW));
		peak_user32.SetWindowPlacement(w->hwnd, &w->place);
		peak_user32.SetWindowPos(w->hwnd, NULL, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
	}
}

static void
peak_platform_window_cursor(PeakWindowInternal *intern, int on)
{
	struct peak_win32_win *w;

	w = intern ? intern->w : NULL;
	if (!w)
		return;
	if (on == w->cursor_on)
		return;
	w->cursor_on = on;
	if (peak_user32.ShowCursor)
		peak_user32.ShowCursor(on ? TRUE : FALSE);
}

static void
peak_platform_window_cursor_shape(PeakWindowInternal *intern, int shape)
{
	(void)intern;
	(void)shape;
}

static void
peak_platform_window_pointer_relative(PeakWindowInternal *intern, int on)
{
	struct peak_win32_win *w;

	w = intern ? intern->w : NULL;
	if (!w || !w->hwnd)
		return;
	w->relative = on;
	if (on && peak_user32.SetCapture)
		peak_user32.SetCapture(w->hwnd);
	else if (!on && peak_user32.ReleaseCapture)
		peak_user32.ReleaseCapture();
}

static float
peak_platform_window_scale(PeakWindowInternal *intern)
{
    struct peak_win32_win *w = intern ? intern->w : NULL;
    typedef UINT (WINAPI *GetDpiFn)(HWND);
    GetDpiFn get_dpi = (GetDpiFn)GetProcAddress(GetModuleHandleA("user32.dll"), "GetDpiForWindow");
    UINT dpi = (w && get_dpi) ? get_dpi(w->hwnd) : 96;
    return dpi ? (float)dpi / 96.f : 1.f;
}

static void
peak_internal_win32_ime_apply(struct peak_win32_win *w, int force)
{
	HIMC imc;
	COMPOSITIONFORM cf;
	CANDIDATEFORM df;

	if (!w || !w->hwnd || !w->ime_set)
		return;
	if (!peak_imm_tried) {
		HMODULE imm;

		peak_imm_tried = 1;
		imm = LoadLibraryA("imm32.dll");
		if (imm) {
			peak_ImmGetContext = (HIMC (WINAPI *)(HWND))(void *)GetProcAddress(imm, "ImmGetContext");
			peak_ImmReleaseContext = (BOOL (WINAPI *)(HWND, HIMC))(void *)GetProcAddress(imm, "ImmReleaseContext");
			peak_ImmSetCompositionWindow = (BOOL (WINAPI *)(HIMC, LPCOMPOSITIONFORM))(void *)GetProcAddress(imm, "ImmSetCompositionWindow");
			peak_ImmSetCandidateWindow = (BOOL (WINAPI *)(HIMC, LPCANDIDATEFORM))(void *)GetProcAddress(imm, "ImmSetCandidateWindow");
		}
	}
	if (!peak_ImmGetContext || !peak_ImmReleaseContext || !peak_ImmSetCompositionWindow || !peak_ImmSetCandidateWindow)
		return;
	if (!force && w->ime_applied && w->ime_ax == w->ime_x && w->ime_ay == w->ime_y &&
	    w->ime_aw == w->ime_w && w->ime_ah == w->ime_h)
		return;
	imc = peak_ImmGetContext(w->hwnd);
	if (!imc)
		return;
	memset(&cf, 0, sizeof cf);
	cf.dwStyle = CFS_POINT;
	cf.ptCurrentPos.x = w->ime_x;
	cf.ptCurrentPos.y = w->ime_y;
	peak_ImmSetCompositionWindow(imc, &cf);
	memset(&df, 0, sizeof df);
	df.dwIndex = 0;
	df.dwStyle = CFS_EXCLUDE;
	df.ptCurrentPos.x = w->ime_x;
	df.ptCurrentPos.y = w->ime_y + w->ime_h;
	df.rcArea.left = w->ime_x;
	df.rcArea.top = w->ime_y;
	df.rcArea.right = w->ime_x + w->ime_w;
	df.rcArea.bottom = w->ime_y + w->ime_h;
	peak_ImmSetCandidateWindow(imc, &df);
	peak_ImmReleaseContext(w->hwnd, imc);
	w->ime_applied = 1;
	w->ime_ax = w->ime_x;
	w->ime_ay = w->ime_y;
	w->ime_aw = w->ime_w;
	w->ime_ah = w->ime_h;
}

static void
peak_platform_window_set_text_input_rect(PeakWindowInternal *intern, int x, int y, int w, int h)
{
	struct peak_win32_win *win;

	win = intern ? intern->w : NULL;
	if (!win || !win->hwnd)
		return;
	if (win->ime_set && win->ime_x == x && win->ime_y == y && win->ime_w == w && win->ime_h == h)
		return;
	win->ime_x = x;
	win->ime_y = y;
	win->ime_w = w;
	win->ime_h = h;
	win->ime_set = 1;
	peak_internal_win32_ime_apply(win, 0);
}

#include "p_win32_proc.c"
