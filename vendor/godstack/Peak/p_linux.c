#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <linux/joystick.h>
#ifndef PEAK_NO_AUDIO
#include <pthread.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef PEAK_VULKAN
#define VK_USE_PLATFORM_WAYLAND_KHR
#define VK_USE_PLATFORM_XLIB_KHR
#include <vulkan/vulkan.h>
#endif

#define PEAK_X11_LINUX "libX11.so.6"
#ifndef PEAK_NO_AUDIO
#define PEAK_PULSE_LINUX "libpulse-simple.so.0"
#define PEAK_AUDIO_FRAMES 256

#define PEAK_PULSE_API(X) \
    X(pa_simple_new,   void *, (const char *, const char *, int, const char *, const char *, const void *, const void *, const void *, int *)) \
    X(pa_simple_free,  void,   (void *)) \
    X(pa_simple_write, int,    (void *, const void *, size_t, int *))
#endif

#define PEAK_X11_API(X) \
	X(XOpenDisplay,        Display *, (const char *)) \
	X(XCloseDisplay,       int, (Display *)) \
	X(XCreateSimpleWindow, Window, (Display *, Window, int, int, unsigned int, unsigned int, unsigned int, unsigned long, unsigned long)) \
	X(XCreateWindow,       Window, (Display *, Window, int, int, unsigned int, unsigned int, unsigned int, int, unsigned int, Visual *, unsigned long, XSetWindowAttributes *)) \
	X(XGetVisualInfo,      XVisualInfo *, (Display *, long, XVisualInfo *, int *)) \
	X(XCreateColormap,     Colormap, (Display *, Window, Visual *, int)) \
	X(XFreeColormap,       int, (Display *, Colormap)) \
	X(XFree,               int, (void *)) \
	X(XStoreName,          int, (Display *, Window, const char *)) \
	X(XInternAtom,         Atom, (Display *, const char *, Bool)) \
	X(XSetWMProtocols,     Status, (Display *, Window, Atom *, int)) \
	X(XSelectInput,        int, (Display *, Window, long)) \
	X(XCreateGC,           GC, (Display *, Window, unsigned long, XGCValues *)) \
	X(XCreateImage,        XImage *, (Display *, Visual *, unsigned int, int, int, char *, unsigned int, unsigned int, int, int)) \
	X(XMapRaised,          int, (Display *, Window)) \
	X(XFlush,              int, (Display *)) \
	X(XFreeGC,             int, (Display *, GC)) \
	X(XDestroyWindow,      int, (Display *, Window)) \
	X(XCheckIfEvent,       Bool, (Display *, XEvent *, Bool (*)(Display *, XEvent *, XPointer), XPointer)) \
	X(XPutBackEvent,       void, (Display *, XEvent *)) \
	X(XPending,            int, (Display *)) \
	X(XLookupKeysym,       KeySym, (XKeyEvent *, int)) \
	X(XOpenIM, XIM, (Display *, struct _XrmHashBucketRec *, char *, char *)) \
	X(XCloseIM, Status, (XIM)) \
	X(XCreateIC, XIC, (XIM, ...)) \
	X(XDestroyIC, void, (XIC)) \
	X(XGetICValues, char *, (XIC, ...)) \
	X(XSetICFocus, void, (XIC)) \
	X(XUnsetICFocus, void, (XIC)) \
	X(XFilterEvent, Bool, (XEvent *, Window)) \
	X(Xutf8LookupString, int, (XIC, XKeyPressedEvent *, char *, int, KeySym *, Status *)) \
	X(XSupportsLocale, Bool, (void)) \
	X(XSetLocaleModifiers, char *, (const char *)) \
	X(XLookupString,       int, (XKeyEvent *, char *, int, KeySym *, XComposeStatus *)) \
	X(XPutImage,           int, (Display *, Drawable, GC, XImage *, int, int, int, int, unsigned int, unsigned int)) \
	X(XSetSelectionOwner,  int, (Display *, Atom, Window, Time)) \
	X(XConvertSelection,   int, (Display *, Atom, Atom, Atom, Window, Time)) \
	X(XChangeProperty,     int, (Display *, Window, Atom, Atom, int, int, const unsigned char *, int)) \
	X(XGetWindowProperty,  int, (Display *, Window, Atom, long, long, Bool, Atom, Atom *, int *, unsigned long *, unsigned long *, unsigned char **)) \
	X(XDeleteProperty,     int, (Display *, Window, Atom)) \
	X(XSendEvent,          Status, (Display *, Window, Bool, long, XEvent *)) \
	X(XResizeWindow,       int, (Display *, Window, unsigned int, unsigned int)) \
	X(XDefineCursor,       int, (Display *, Window, Cursor)) \
	X(XCreateFontCursor,  Cursor, (Display *, unsigned int)) \
	X(XUndefineCursor,     int, (Display *, Window)) \
	X(XCreatePixmap,       Pixmap, (Display *, Drawable, unsigned int, unsigned int, unsigned int)) \
	X(XFreePixmap,         int, (Display *, Pixmap)) \
	X(XCreatePixmapCursor, Cursor, (Display *, Pixmap, Pixmap, XColor *, XColor *, unsigned int, unsigned int)) \
	X(XFreeCursor,         int, (Display *, Cursor)) \
	X(XWarpPointer,        int, (Display *, Window, Window, int, int, unsigned int, unsigned int, int, int)) \
	X(XGrabPointer,        int, (Display *, Window, Bool, unsigned int, int, int, Window, Cursor, Time)) \
	X(XUngrabPointer,      int, (Display *, Time)) \
	X(XGetWindowAttributes, Status, (Display *, Window, XWindowAttributes *)) \
	X(XQueryPointer,       Bool, (Display *, Window, Window *, Window *, int *, int *, int *, int *, unsigned int *)) \
	X(XQueryTree,          Status, (Display *, Window, Window *, Window *, Window **, unsigned int *))

typedef struct {
#define X(name, ret, args) ret (*name) args;
	PEAK_X11_API(X)
#undef X
} PeakX11Api;

#ifndef PEAK_NO_AUDIO
typedef struct {
#define X(name, ret, args) ret (*name) args;
	PEAK_PULSE_API(X)
#undef X
} PeakPulseApi;

typedef struct {
	int format;
	uint32_t rate;
	uint8_t channels;
} PeakPaSampleSpec;
#endif

struct peak_linux_win;
typedef struct {
	Display *display;
	XIM im;
	struct peak_linux_win *windows;
	Atom wm_delete_window;
	Atom clip_clipboard;
	Atom clip_utf8;
	Atom clip_targets;
	Atom clip_incr;
	Atom clip_text;
	Atom clip_prop;
	Atom net_wm_state;
	Atom net_wm_state_fullscreen;
	Atom xdnd_aware;
	Atom xdnd_enter;
	Atom xdnd_position;
	Atom xdnd_drop;
	Atom xdnd_status;
	Atom xdnd_finished;
	Atom xdnd_selection;
	Atom xdnd_type_list;
	Atom xdnd_action_copy;
	Atom xdnd_prop;
	Atom uri_list;
	Atom net_wm_pid;
} PeakLinux;

#ifndef PEAK_NO_AUDIO
typedef struct {
	volatile int run;
	int thread_on;
	pthread_t thread;
	void *stream;
	int16_t *buf;
	uint32_t channels;
	void (*fill)(int16_t *out, size_t frames, void *userdata);
	void *userdata;
} PeakAudio;
#endif

struct peak_linux_win {
	struct peak_linux_win *next;
	Window window;
	XIC ic;
	char *text_pending;
	size_t text_n, text_off;
	GC gfx_ctx;
	XImage *ximage;
	Visual *visual;
	Colormap colormap;
	uint32_t *buffer;
	uint32_t width;
	uint32_t height;
	int depth;
	int colormap_owned;
	int flags;
	int cursor_on;
	int relative;
	int extra_on;
	int touch_n;
	float last_x, last_y;
	Cursor blank;
	Cursor glyph;
	Window xdnd_source;
	Time xdnd_time;
	PeakEvent extra;
};

static PeakLinux peak_linux;
static PeakX11Api peak_x11;
#ifndef PEAK_NO_AUDIO
static PeakPulseApi peak_pulse;
#endif
static char *peak_clip_incr;
static size_t peak_clip_incr_n;
static PeakClip peak_clip_incr_which;
static int peak_clip_incr_on;
static Atom peak_clip_incr_type;
static PeakClip peak_clip_req_which;
static int peak_clip_req_on;
static int peak_clip_req_xa;
#ifndef PEAK_NO_AUDIO
static PeakAudio peak_audio;
#endif
static int peak_linux_kind;
#define PEAK_LINUX_NONE    0
#define PEAK_LINUX_WAYLAND 1
#define PEAK_LINUX_X11     2

/* X11 and xkbcommon use the same keysym values. */
static PeakKeyCode peak_internal_x11_key_map(KeySym sym);

#include "p_wayland.c"

static void peak_platform_window_set_title(PeakWindowInternal *intern, const char *name);
static void peak_platform_window_set_size(PeakWindowInternal *intern, uint32_t width, uint32_t height);
static void peak_platform_window_fullscreen(PeakWindowInternal *intern, int on);
static void peak_platform_window_cursor(PeakWindowInternal *intern, int on);
static void peak_platform_window_cursor_shape(PeakWindowInternal *intern, int shape);
static void peak_platform_window_pointer_relative(PeakWindowInternal *intern, int on);
static float peak_platform_window_scale(PeakWindowInternal *intern);

static int
peak_internal_x11_load(void *handle)
{
#define X(name, ret, args) peak_x11.name = (ret (*) args)dlsym(handle, #name);
	PEAK_X11_API(X)
#undef X
#define X(name, ret, args) || !peak_x11.name
	if (0 PEAK_X11_API(X))
		return 0;
#undef X
	return 1;
}

static PeakKeyCode
peak_internal_x11_key_map(KeySym sym)
{
	if (sym >= XK_a && sym <= XK_z)
		return (PeakKeyCode)(PEAK_KEY_A + (int)(sym - XK_a));
	if (sym >= XK_A && sym <= XK_Z)
		return (PeakKeyCode)(PEAK_KEY_A + (int)(sym - XK_A));
	if (sym >= XK_0 && sym <= XK_9)
		return (PeakKeyCode)(PEAK_KEY_0 + (int)(sym - XK_0));
	switch (sym) {
	case XK_KP_Up: case XK_Up: return PEAK_KEY_UP;
	case XK_KP_Down: case XK_Down: return PEAK_KEY_DOWN;
	case XK_KP_Left: case XK_Left: return PEAK_KEY_LEFT;
	case XK_KP_Right: case XK_Right: return PEAK_KEY_RIGHT;
	case XK_space: return PEAK_KEY_SPACE;
	case XK_Escape: return PEAK_KEY_ESCAPE;
	case XK_KP_Enter: case XK_Return: return PEAK_KEY_ENTER;
	case XK_BackSpace: return PEAK_KEY_BACKSPACE;
	case XK_Tab:
	case XK_ISO_Left_Tab: return PEAK_KEY_TAB;
	case XK_Delete:
	case XK_KP_Delete: return PEAK_KEY_DELETE;
	case XK_Insert:
	case XK_KP_Insert: return PEAK_KEY_INSERT;
	case XK_Home:
	case XK_KP_Home: return PEAK_KEY_HOME;
	case XK_End:
	case XK_KP_End: return PEAK_KEY_END;
	case XK_Page_Up:
	case XK_KP_Page_Up: return PEAK_KEY_PAGEUP;
	case XK_Page_Down:
	case XK_KP_Page_Down: return PEAK_KEY_PAGEDOWN;
	case XK_F1: return PEAK_KEY_F1;
	case XK_F2: return PEAK_KEY_F2;
	case XK_F3: return PEAK_KEY_F3;
	case XK_F4: return PEAK_KEY_F4;
	case XK_F5: return PEAK_KEY_F5;
	case XK_F6: return PEAK_KEY_F6;
	case XK_F7: return PEAK_KEY_F7;
	case XK_F8: return PEAK_KEY_F8;
	case XK_F9: return PEAK_KEY_F9;
	case XK_F10: return PEAK_KEY_F10;
	case XK_F11: return PEAK_KEY_F11;
	case XK_F12: return PEAK_KEY_F12;
	default: return PEAK_KEY_UNKNOWN;
	}
}

static PeakKeyMod
peak_internal_x11_mod_map(unsigned int state)
{
	PeakKeyMod m;

	m = 0;
	if (state & ShiftMask)
		m |= PEAK_KEYMOD_SHIFT;
	if (state & ControlMask)
		m |= PEAK_KEYMOD_CTRL;
	if (state & Mod1Mask)
		m |= PEAK_KEYMOD_ALT;
	if (state & LockMask)
		m |= PEAK_KEYMOD_CAPS;
	if (state & Mod4Mask)
		m |= PEAK_KEYMOD_SUPER;
	return m;
}

static Bool
peak_internal_x11_window_match(Display *dpy, XEvent *ev, XPointer arg)
{
	(void)dpy;
	return ev->xany.window == *(Window *)arg;
}

/* The predicate must not call Xlib. Filtering happens only after removal. */
static Bool
peak_internal_x11_any_event(Display *display, XEvent *event, XPointer arg)
{
	(void)display; (void)event; (void)arg;
	return True;
}

static int
peak_linux_other_window(struct peak_linux_win *w, Window window)
{
	struct peak_linux_win *p;
	for (p = peak_linux.windows; p; p = p->next)
		if (p != w && p->window == window) return 1;
	return 0;
}

/* Scan private XIM traffic while retaining unrelated events in queue order.
 * A client event is filtered only immediately before its dispatch; in
 * particular, pending() must never advance compose state for a client key. */
static int
peak_linux_next_event(struct peak_linux_win *w, XEvent *out, int dispatch)
{
	XEvent *held = NULL, event;
	size_t n = 0, cap = 0;
	int found = 0, remaining;
	if (!peak_linux.im || !peak_x11.XPending || !peak_x11.XPutBackEvent) {
		int got = peak_x11.XCheckIfEvent(peak_linux.display, out, peak_internal_x11_window_match, (XPointer)&w->window);
		if (got && !dispatch && peak_x11.XPutBackEvent) peak_x11.XPutBackEvent(peak_linux.display, out);
		return got;
	}
	remaining = peak_x11.XPending(peak_linux.display);
	while (remaining-- > 0) {
		if (!peak_x11.XCheckIfEvent(peak_linux.display, &event, peak_internal_x11_any_event, NULL)) break;
		if (event.xany.window == w->window) {
			if (dispatch && peak_x11.XFilterEvent(&event, None)) {
				remaining = peak_x11.XPending(peak_linux.display);
				continue;
			}
			*out = event;
			found = 1;
			break;
		}
		if (!peak_linux_other_window(w, event.xany.window) &&
			!((event.type == KeyPress || event.type == KeyRelease) && event.xkey.keycode != 0) &&
			peak_x11.XFilterEvent(&event, None)) {
			remaining = peak_x11.XPending(peak_linux.display);
			continue;
		}
		if (n == cap) {
			size_t new_cap = cap ? cap * 2 : 16;
			XEvent *next = realloc(held, new_cap * sizeof *held);
			if (!next) { peak_x11.XPutBackEvent(peak_linux.display, &event); break; }
			held = next; cap = new_cap;
		}
		held[n++] = event;
	}
	if (found && !dispatch) peak_x11.XPutBackEvent(peak_linux.display, out);
	while (n) peak_x11.XPutBackEvent(peak_linux.display, &held[--n]);
	free(held);
	return found;
}

static int
peak_linux_buffer(struct peak_linux_win *w, uint32_t width, uint32_t height)
{
	int screen;
	uint32_t *buffer;
	XImage *image;
	if (!width || !height || (size_t)width > SIZE_MAX / height / sizeof *buffer) return 0;
	buffer = calloc((size_t)width * height, sizeof *buffer);
	if (!buffer) return 0;
	screen = DefaultScreen(peak_linux.display);
	image = peak_x11.XCreateImage(peak_linux.display,
		w->visual ? w->visual : DefaultVisual(peak_linux.display, screen),
		w->depth ? (unsigned int)w->depth : (unsigned int)DefaultDepth(peak_linux.display, screen),
		ZPixmap, 0, (char *)buffer, width, height, 32, 0);
	if (!image) { free(buffer); return 0; }
	if (w->ximage) { w->ximage->data = NULL; XDestroyImage(w->ximage); }
	free(w->buffer);
	w->buffer = buffer;
	w->ximage = image;
	w->width = width;
	w->height = height;
	return 1;
}

#ifndef PEAK_NO_GAMEPAD
static int peak_linux_gp_fd[4];
static int peak_linux_gp_on[4];

static void
peak_linux_gamepad_scan(void)
{
	char path[32];
	int i, fd;

	for (i = 0; i < 4; i++) {
		if (peak_linux_gp_fd[i] >= 0)
			continue;
		snprintf(path, sizeof path, "/dev/input/js%d", i);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd >= 0)
			peak_linux_gp_fd[i] = fd;
	}
}

static int
peak_linux_gamepad_poll(PeakEvent *ev)
{
	struct js_event js;
	int i, n;

	peak_linux_gamepad_scan();
	for (i = 0; i < 4; i++) {
		if (peak_linux_gp_fd[i] < 0)
			continue;
		n = (int)read(peak_linux_gp_fd[i], &js, sizeof js);
		if (n < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				continue;
			close(peak_linux_gp_fd[i]);
			peak_linux_gp_fd[i] = -1;
			if (peak_linux_gp_on[i]) {
				peak_linux_gp_on[i] = 0;
				memset(ev, 0, sizeof *ev);
				ev->type = PEAK_EVENT_POINTER_DISCONNECTED;
				return 1;
			}
			continue;
		}
		if (n != (int)sizeof js)
			continue;
		if (js.type & JS_EVENT_INIT)
			continue;
		if (!peak_linux_gp_on[i]) {
			peak_linux_gp_on[i] = 1;
			memset(ev, 0, sizeof *ev);
			ev->type = PEAK_EVENT_POINTER_CONNECTED;
			return 1;
		}
		memset(ev, 0, sizeof *ev);
		ev->type = PEAK_EVENT_POINTER;
		if (js.type & JS_EVENT_BUTTON) {
			ev->pointer.state = js.value ? PEAK_POINTER_PRESSED : PEAK_POINTER_RELEASED;
			ev->pointer.type = (js.number == 1) ? PEAK_POINTER_RIGHT :
			                   (js.number == 2) ? PEAK_POINTER_MIDDLE : PEAK_POINTER_LEFT;
		} else {
			ev->pointer.state = PEAK_POINTER_MOVED;
			ev->pointer.type = PEAK_POINTER_LEFT;
			if (js.number == 0)
				ev->pointer.x = (float)js.value / 32767.f;
			else
				ev->pointer.y = (float)js.value / 32767.f;
		}
		return 1;
	}
	return 0;
}

#else
static int
peak_linux_gamepad_poll(PeakEvent *ev)
{
	(void)ev;
	return 0;
}
#endif

static int
peak_platform_init(void)
{
	void *handle;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND || peak_linux_kind == PEAK_LINUX_X11)
		return 1;
#ifndef PEAK_NO_GAMEPAD
	for (int i = 0; i < 4; i++)
		peak_linux_gp_fd[i] = -1;
#endif
	if (peak_wayland_init()) {
		peak_linux_kind = PEAK_LINUX_WAYLAND;
		return 1;
	}

	if (!peak_x11.XOpenDisplay) {
		if (!(handle = dlopen(PEAK_X11_LINUX, RTLD_LOCAL | RTLD_NOW))) {
			fputs("Failed to load X11 library. What system are you fucking using and abusing?", stderr);
			return 0;
		}
		if (!peak_internal_x11_load(handle)) {
			fputs("Failed to load X11 symbols", stderr);
			return 0;
		}
	}
	if (!peak_linux.display) {
		if (!(peak_linux.display = peak_x11.XOpenDisplay(NULL))) {
			fputs("Failed to open X11 display", stderr);
			return 0;
		}
		setlocale(LC_CTYPE, "");
		if (peak_x11.XSupportsLocale()) {
			if (peak_x11.XSetLocaleModifiers(""))
				peak_linux.im = peak_x11.XOpenIM(peak_linux.display, NULL, NULL, NULL);
			if (!peak_linux.im && peak_x11.XSetLocaleModifiers("@im=none"))
				peak_linux.im = peak_x11.XOpenIM(peak_linux.display, NULL, NULL, NULL);
		}
		peak_linux.wm_delete_window = peak_x11.XInternAtom(peak_linux.display, "WM_DELETE_WINDOW", False);
		peak_linux.net_wm_state = peak_x11.XInternAtom(peak_linux.display, "_NET_WM_STATE", False);
		peak_linux.net_wm_state_fullscreen = peak_x11.XInternAtom(peak_linux.display, "_NET_WM_STATE_FULLSCREEN", False);
		peak_linux.xdnd_aware = peak_x11.XInternAtom(peak_linux.display, "XdndAware", False);
		peak_linux.xdnd_enter = peak_x11.XInternAtom(peak_linux.display, "XdndEnter", False);
		peak_linux.xdnd_position = peak_x11.XInternAtom(peak_linux.display, "XdndPosition", False);
		peak_linux.xdnd_drop = peak_x11.XInternAtom(peak_linux.display, "XdndDrop", False);
		peak_linux.xdnd_status = peak_x11.XInternAtom(peak_linux.display, "XdndStatus", False);
		peak_linux.xdnd_finished = peak_x11.XInternAtom(peak_linux.display, "XdndFinished", False);
		peak_linux.xdnd_selection = peak_x11.XInternAtom(peak_linux.display, "XdndSelection", False);
		peak_linux.xdnd_type_list = peak_x11.XInternAtom(peak_linux.display, "XdndTypeList", False);
		peak_linux.xdnd_action_copy = peak_x11.XInternAtom(peak_linux.display, "XdndActionCopy", False);
		peak_linux.xdnd_prop = peak_x11.XInternAtom(peak_linux.display, "PEAK_XDND", False);
		peak_linux.uri_list = peak_x11.XInternAtom(peak_linux.display, "text/uri-list", False);
		peak_linux.net_wm_pid = peak_x11.XInternAtom(peak_linux.display, "_NET_WM_PID", False);
	}
	peak_linux_kind = PEAK_LINUX_X11;
	return 1;
}

static void
peak_platform_quit(void)
{

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_quit();
		peak_linux_kind = PEAK_LINUX_NONE;
		return;
	}
#ifndef PEAK_NO_GAMEPAD
	for (int i = 0; i < 4; i++) {
		if (peak_linux_gp_fd[i] >= 0) {
			close(peak_linux_gp_fd[i]);
			peak_linux_gp_fd[i] = -1;
		}
		peak_linux_gp_on[i] = 0;
	}
#endif
	/* NOTE: NVIDIA's Vulkan ICD registers an XCloseDisplay hook, then
	 * vkDestroyInstance unloads the ICD. Closing afterwards is a SIGSEGV
	 * into unmapped memory. The connection is dropped on process exit. */
	if (!peak_linux.display)
		return;
	if (peak_linux.im) peak_x11.XCloseIM(peak_linux.im);
	peak_linux.im = NULL;
	peak_linux.display = 0;
	peak_linux_kind = PEAK_LINUX_NONE;
}

static int
peak_linux_visual32(int screen, XVisualInfo *out)
{
	XVisualInfo tpl;
	XVisualInfo *list;
	int n;

	memset(&tpl, 0, sizeof tpl);
	tpl.screen = screen;
	tpl.depth = 32;
	tpl.class = TrueColor;
	list = peak_x11.XGetVisualInfo(peak_linux.display,
		VisualScreenMask | VisualDepthMask | VisualClassMask, &tpl, &n);
	if (!list || n < 1)
		return 0;
	*out = list[0];
	peak_x11.XFree(list);
	return 1;
}

static PeakWindowInternal
peak_platform_window_open(const char *name, uint32_t width, uint32_t height, uint32_t flags)
{
	PeakWindowInternal intern = {0};
	struct peak_linux_win *w;
	XVisualInfo vi;
	int screen;
	long evmask;
	unsigned long xdnd_ver = 5;

	if (peak_linux_kind != PEAK_LINUX_X11 && peak_platform_init() && peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_window_open(name, width, height, flags);
	if (!peak_linux.display && !peak_platform_init())
		return intern;

	w = calloc(1, sizeof *w);
	if (!w)
		return intern;

	screen = DefaultScreen(peak_linux.display);
	evmask = KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask |
		PointerMotionMask | StructureNotifyMask | PropertyChangeMask |
		FocusChangeMask | ExposureMask;
	w->visual = DefaultVisual(peak_linux.display, screen);
	w->depth = DefaultDepth(peak_linux.display, screen);
	if ((flags & PEAK_WINDOW_TRANSPARENT) && peak_linux_visual32(screen, &vi)) {
		XSetWindowAttributes swa;

		memset(&swa, 0, sizeof swa);
		w->visual = vi.visual;
		w->depth = vi.depth;
		w->colormap = peak_x11.XCreateColormap(peak_linux.display,
			RootWindow(peak_linux.display, screen), vi.visual, AllocNone);
		w->colormap_owned = 1;
		swa.colormap = w->colormap;
		swa.border_pixel = 0;
		swa.background_pixel = 0;
		swa.event_mask = evmask;
		w->window = peak_x11.XCreateWindow(peak_linux.display,
			RootWindow(peak_linux.display, screen), 0, 0, width, height, 0,
			vi.depth, InputOutput, vi.visual,
			CWColormap | CWBorderPixel | CWBackPixel | CWEventMask, &swa);
	} else {
		w->window = peak_x11.XCreateSimpleWindow(peak_linux.display,
			RootWindow(peak_linux.display, screen), 0, 0, width, height, 0,
			BlackPixel(peak_linux.display, screen), BlackPixel(peak_linux.display, screen));
		peak_x11.XSelectInput(peak_linux.display, w->window, evmask);
	}
	if (peak_linux.im) {
		long filter_mask = 0;
		w->ic = peak_x11.XCreateIC(peak_linux.im, XNInputStyle, XIMPreeditNothing | XIMStatusNothing,
			XNClientWindow, w->window, XNFocusWindow, w->window, NULL);
		if (w->ic && !peak_x11.XGetICValues(w->ic, XNFilterEvents, &filter_mask, NULL))
			peak_x11.XSelectInput(peak_linux.display, w->window, evmask | filter_mask);
	}
	peak_x11.XStoreName(peak_linux.display, w->window, name);
	peak_x11.XSetWMProtocols(peak_linux.display, w->window, &peak_linux.wm_delete_window, 1);
	w->gfx_ctx = peak_x11.XCreateGC(peak_linux.display, w->window, 0, NULL);

	if (!peak_linux_buffer(w, width, height)) {
		peak_x11.XFreeGC(peak_linux.display, w->gfx_ctx);
		if (w->ic) peak_x11.XDestroyIC(w->ic);
		peak_x11.XDestroyWindow(peak_linux.display, w->window);
		if (w->colormap_owned)
			peak_x11.XFreeColormap(peak_linux.display, w->colormap);
		free(w);
		return intern;
	}

	w->next = peak_linux.windows;
	peak_linux.windows = w;
	w->flags = (int)flags;
	w->cursor_on = 1;
	intern.w = w;
	if (peak_linux.xdnd_aware)
		peak_x11.XChangeProperty(peak_linux.display, w->window, peak_linux.xdnd_aware, XA_ATOM, 32,
			PropModeReplace, (unsigned char *)&xdnd_ver, 1);
	if (peak_linux.net_wm_pid) {
		unsigned long pid;

		pid = (unsigned long)getpid();
		peak_x11.XChangeProperty(peak_linux.display, w->window, peak_linux.net_wm_pid, XA_CARDINAL, 32,
			PropModeReplace, (unsigned char *)&pid, 1);
	}
	if (flags & PEAK_WINDOW_FULLSCREEN)
		peak_platform_window_fullscreen(&intern, 1);
	peak_x11.XMapRaised(peak_linux.display, w->window);
	peak_x11.XFlush(peak_linux.display);
	return intern;
}

static void
peak_platform_window_close(PeakWindowInternal *intern)
{
	struct peak_linux_win *w;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_close(intern);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display)
		return;
	{
		struct peak_linux_win **link = &peak_linux.windows;
		while (*link && *link != w) link = &(*link)->next;
		if (*link) *link = w->next;
	}
	if (w->ic) peak_x11.XDestroyIC(w->ic);
	free(w->text_pending);
	if (w->blank && peak_x11.XFreeCursor)
		peak_x11.XFreeCursor(peak_linux.display, w->blank);
	if (w->glyph && peak_x11.XFreeCursor)
		peak_x11.XFreeCursor(peak_linux.display, w->glyph);
	if (w->ximage) {
		w->ximage->data = NULL;
		XDestroyImage(w->ximage);
	}
	free(w->buffer);
	if (w->gfx_ctx)
		peak_x11.XFreeGC(peak_linux.display, w->gfx_ctx);
	peak_x11.XDestroyWindow(peak_linux.display, w->window);
	if (w->colormap_owned)
		peak_x11.XFreeColormap(peak_linux.display, w->colormap);
	free(w);
	intern->w = NULL;
}

static uint32_t *
peak_platform_window_buffer(PeakWindowInternal *intern, size_t *width, size_t *height)
{
	if (peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_window_buffer(intern, width, height);
	struct peak_linux_win *w;

	w = intern ? intern->w : NULL;
	if (!w || !w->window) {
		*width = 0;
		*height = 0;
		return NULL;
	}
	*width = w->width;
	*height = w->height;
	return w->buffer;
}

static void
peak_platform_window_present_rect(PeakWindowInternal *intern, uint32_t y, uint32_t h)
{
	struct peak_linux_win *w;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_present_rect(intern, y, h);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->ximage || !peak_linux.display)
		return;
	if (y >= (uint32_t)w->height)
		return;
	if (h > (uint32_t)w->height - y)
		h = (uint32_t)w->height - y;
	peak_x11.XPutImage(peak_linux.display, w->window, w->gfx_ctx, w->ximage,
		0, (int)y, 0, (int)y, w->width, h);
	peak_x11.XFlush(peak_linux.display);
}

static void
peak_platform_window_present(PeakWindowInternal *intern)
{
	struct peak_linux_win *w;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_present(intern);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->ximage || !peak_linux.display)
		return;
	peak_x11.XPutImage(peak_linux.display, w->window, w->gfx_ctx, w->ximage,
		0, 0, 0, 0, w->width, w->height);
	peak_x11.XFlush(peak_linux.display);
}

static void
peak_linux_clip_atoms(void)
{
	if (!peak_linux.display || peak_linux.clip_clipboard)
		return;
	peak_linux.clip_clipboard = peak_x11.XInternAtom(peak_linux.display, "CLIPBOARD", False);
	peak_linux.clip_utf8 = peak_x11.XInternAtom(peak_linux.display, "UTF8_STRING", False);
	peak_linux.clip_targets = peak_x11.XInternAtom(peak_linux.display, "TARGETS", False);
	peak_linux.clip_incr = peak_x11.XInternAtom(peak_linux.display, "INCR", False);
	peak_linux.clip_text = peak_x11.XInternAtom(peak_linux.display, "TEXT", False);
	peak_linux.clip_prop = peak_x11.XInternAtom(peak_linux.display, "PEAK_CLIP", False);
}

static Atom
peak_linux_clip_atom(PeakClip which)
{
	peak_linux_clip_atoms();
	return which == PEAK_CLIP_PRIMARY ? XA_PRIMARY : peak_linux.clip_clipboard;
}

static PeakClip
peak_linux_clip_which(Atom a)
{
	peak_linux_clip_atoms();
	if (a == XA_PRIMARY)
		return PEAK_CLIP_PRIMARY;
	return PEAK_CLIP_CLIPBOARD;
}

static void
peak_linux_clip_reply(XSelectionRequestEvent *req, Atom prop)
{
	XEvent ev;

	memset(&ev, 0, sizeof ev);
	ev.xselection.type = SelectionNotify;
	ev.xselection.display = req->display;
	ev.xselection.requestor = req->requestor;
	ev.xselection.selection = req->selection;
	ev.xselection.target = req->target;
	ev.xselection.property = prop;
	ev.xselection.time = req->time;
	peak_x11.XSendEvent(peak_linux.display, req->requestor, False, NoEventMask, &ev);
	peak_x11.XFlush(peak_linux.display);
}

static void
peak_linux_clip_request_sel(XSelectionRequestEvent *req)
{
	const char *p;
	size_t n;
	PeakClip which;
	Atom targets[5];

	peak_linux_clip_atoms();
	if (req->property == None) {
		peak_linux_clip_reply(req, None);
		return;
	}
	which = peak_linux_clip_which(req->selection);
	if (!peak_clip_own_get(which, &p, &n))
		n = 0;
	if (req->target == peak_linux.clip_targets) {
		targets[0] = peak_linux.clip_targets;
		targets[1] = peak_linux.clip_utf8;
		targets[2] = XA_STRING;
		targets[3] = peak_linux.clip_text;
		peak_x11.XChangeProperty(peak_linux.display, req->requestor, req->property,
			XA_ATOM, 32, PropModeReplace, (const unsigned char *)targets, 4);
		peak_linux_clip_reply(req, req->property);
		return;
	}
	if (req->target == peak_linux.clip_utf8 || req->target == peak_linux.clip_text) {
		peak_x11.XChangeProperty(peak_linux.display, req->requestor, req->property,
			peak_linux.clip_utf8, 8, PropModeReplace, (const unsigned char *)p, (int)n);
		peak_linux_clip_reply(req, req->property);
		return;
	}
	if (req->target == XA_STRING) {
		peak_x11.XChangeProperty(peak_linux.display, req->requestor, req->property,
			XA_STRING, 8, PropModeReplace, (const unsigned char *)p, (int)n);
		peak_linux_clip_reply(req, req->property);
		return;
	}
	peak_linux_clip_reply(req, None);
}

static int
peak_linux_clip_incr_add(const char *p, size_t n)
{
	char *q;

	if (peak_clip_incr_n + n > PEAK_CLIP_MAX)
		n = PEAK_CLIP_MAX - peak_clip_incr_n;
	if (!n)
		return 1;
	q = realloc(peak_clip_incr, peak_clip_incr_n + n);
	if (!q)
		return 0;
	memcpy(q + peak_clip_incr_n, p, n);
	peak_clip_incr = q;
	peak_clip_incr_n += n;
	return 1;
}

static int
peak_linux_latin1_utf8(const unsigned char *s, size_t n, char **out, size_t *out_n)
{
	char *d;
	size_t i;
	size_t o;

	d = malloc(n * 2 + 1);
	if (!d)
		return 0;
	o = 0;
	for (i = 0; i < n && o + 2 < n * 2 + 1; i++) {
		if (s[i] < 0x80)
			d[o++] = (char)s[i];
		else {
			d[o++] = (char)(0xC0 | (s[i] >> 6));
			d[o++] = (char)(0x80 | (s[i] & 0x3F));
		}
	}
	*out = d;
	*out_n = o;
	return 1;
}

static int
peak_linux_clip_take_prop(Window window, Atom prop, PeakClip which, PeakEvent *ev)
{
	Atom type;
	int fmt;
	unsigned long nitems;
	unsigned long remain;
	unsigned char *data;
	char *utf8;
	size_t un;

	data = NULL;
	if (peak_x11.XGetWindowProperty(peak_linux.display, window, prop, 0, (long)(PEAK_CLIP_MAX / 4),
			False, AnyPropertyType, &type, &fmt, &nitems, &remain, &data) != Success) {
		peak_clip_req_on = 0;
		return 0;
	}
	if (type == None || !data) {
		if (data)
			peak_x11.XFree(data);
		peak_x11.XDeleteProperty(peak_linux.display, window, prop);
		if (!peak_clip_req_xa && peak_clip_req_on) {
			peak_clip_req_xa = 1;
			peak_x11.XConvertSelection(peak_linux.display, peak_linux_clip_atom(which),
				XA_STRING, peak_linux.clip_prop, window, CurrentTime);
			peak_x11.XFlush(peak_linux.display);
		} else {
			peak_clip_req_on = 0;
		}
		return 0;
	}
	if (type == peak_linux.clip_incr) {
		if (fmt != 32 || nitems != 1 || remain) {
			peak_x11.XFree(data);
			peak_x11.XDeleteProperty(peak_linux.display, window, prop);
			peak_clip_req_on = 0;
			return 0;
		}
		free(peak_clip_incr);
		peak_clip_incr = NULL;
		peak_clip_incr_n = 0;
		peak_clip_incr_on = 1;
		peak_clip_incr_type = None;
		peak_clip_incr_which = which;
		peak_x11.XFree(data);
		peak_x11.XDeleteProperty(peak_linux.display, window, prop);
		return 0;
	}
	utf8 = NULL;
	un = 0;
	if (fmt != 8 || remain || (type != XA_STRING && type != peak_linux.clip_utf8 && type != peak_linux.clip_text)) {
		peak_x11.XFree(data);
		peak_x11.XDeleteProperty(peak_linux.display, window, prop);
		peak_clip_req_on = 0;
		return 0;
	}
	if (type == XA_STRING) {
		if (!peak_linux_latin1_utf8(data, (size_t)nitems, &utf8, &un)) {
			peak_x11.XFree(data);
			peak_x11.XDeleteProperty(peak_linux.display, window, prop);
			peak_clip_req_on = 0;
			return 0;
		}
		peak_clip_paste_store(which, utf8, un);
		free(utf8);
	} else {
		peak_clip_paste_store(which, (const char *)data, (size_t)nitems);
	}
	peak_x11.XFree(data);
	peak_x11.XDeleteProperty(peak_linux.display, window, prop);
	peak_clip_req_on = 0;
	ev->type = PEAK_EVENT_CLIP;
	ev->clip.which = which;
	ev->clip.n = peak_clip.paste_n;
	return 1;
}

static int
peak_linux_clip_property(struct peak_linux_win *w, XPropertyEvent *pe, PeakEvent *ev)
{
	Atom type;
	int fmt;
	unsigned long nitems;
	unsigned long remain;
	unsigned char *data;

	if (!peak_clip_incr_on || pe->state != PropertyNewValue || pe->atom != peak_linux.clip_prop)
		return 0;
	data = NULL;
	if (peak_x11.XGetWindowProperty(peak_linux.display, w->window, pe->atom, 0,
			(long)(PEAK_CLIP_MAX / 4), False, AnyPropertyType, &type, &fmt, &nitems, &remain, &data) != Success)
		goto fail;
	if (remain || fmt != 8 || (type != XA_STRING && type != peak_linux.clip_utf8 && type != peak_linux.clip_text) ||
		(peak_clip_incr_type != None && type != peak_clip_incr_type) || (nitems && !data)) goto fail;
	if (!nitems) {
		char *utf8 = NULL;
		size_t un = 0;
		if (peak_clip_incr_type == XA_STRING) {
			if (!peak_linux_latin1_utf8((const unsigned char *)peak_clip_incr, peak_clip_incr_n, &utf8, &un)) goto fail;
			peak_clip_paste_store(peak_clip_incr_which, utf8, un);
			free(utf8);
		} else peak_clip_paste_store(peak_clip_incr_which, peak_clip_incr ? peak_clip_incr : "", peak_clip_incr_n);
		if (data) peak_x11.XFree(data);
		peak_x11.XDeleteProperty(peak_linux.display, w->window, pe->atom);
		free(peak_clip_incr);
		peak_clip_incr = NULL; peak_clip_incr_n = 0; peak_clip_incr_type = None;
		peak_clip_incr_on = 0; peak_clip_req_on = 0;
		ev->type = PEAK_EVENT_CLIP;
		ev->clip.which = peak_clip_incr_which;
		ev->clip.n = peak_clip.paste_n;
		return 1;
	}
	peak_clip_incr_type = type;
	if (nitems > PEAK_CLIP_MAX - peak_clip_incr_n || !peak_linux_clip_incr_add((const char *)data, (size_t)nitems)) goto fail;
	if (data) peak_x11.XFree(data);
	peak_x11.XDeleteProperty(peak_linux.display, w->window, pe->atom);
	return 0;
fail:
	if (data) peak_x11.XFree(data);
	peak_x11.XDeleteProperty(peak_linux.display, w->window, pe->atom);
	free(peak_clip_incr);
	peak_clip_incr = NULL; peak_clip_incr_n = 0; peak_clip_incr_type = None;
	peak_clip_incr_on = 0; peak_clip_req_on = 0;
	return 0;
}

static void
peak_platform_window_set_class(PeakWindowInternal *intern, const char *name)
{
	struct peak_linux_win *w;
	char buf[512];
	size_t n;
	Atom atom;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_set_class(intern, name);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display || !name || !name[0])
		return;
	n = strlen(name);
	if (n > 200)
		n = 200;
	memcpy(buf, name, n);
	buf[n] = 0;
	memcpy(buf + n + 1, name, n);
	buf[n + 1 + n] = 0;
	atom = peak_x11.XInternAtom(peak_linux.display, "WM_CLASS", False);
	peak_x11.XChangeProperty(peak_linux.display, w->window, atom, XA_STRING, 8,
		PropModeReplace, (const unsigned char *)buf, (int)(n + n + 2));
	peak_x11.XFlush(peak_linux.display);
}

static void
peak_platform_window_set_opacity(PeakWindowInternal *intern, uint8_t alpha)
{
	struct peak_linux_win *w;
	unsigned long val;
	Atom atom;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_set_opacity(intern, alpha);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display)
		return;
	val = (unsigned long)alpha * 0x01010101ul;
	atom = peak_x11.XInternAtom(peak_linux.display, "_NET_WM_WINDOW_OPACITY", False);
	peak_x11.XChangeProperty(peak_linux.display, w->window, atom, XA_CARDINAL, 32,
		PropModeReplace, (const unsigned char *)&val, 1);
	peak_x11.XFlush(peak_linux.display);
}

static void
peak_platform_window_set_title(PeakWindowInternal *intern, const char *name)
{
	struct peak_linux_win *w;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_set_title(intern, name);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display || !name)
		return;
	peak_x11.XStoreName(peak_linux.display, w->window, name);
	peak_x11.XFlush(peak_linux.display);
}

static void
peak_platform_window_set_size(PeakWindowInternal *intern, uint32_t width, uint32_t height)
{
	struct peak_linux_win *w;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_set_size(intern, width, height);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display || !peak_x11.XResizeWindow)
		return;
	peak_x11.XResizeWindow(peak_linux.display, w->window, width, height);
	peak_x11.XFlush(peak_linux.display);
}

static void
peak_platform_window_fullscreen(PeakWindowInternal *intern, int on)
{
	struct peak_linux_win *w;
	XEvent e;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_fullscreen(intern, on);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display || !peak_linux.net_wm_state)
		return;
	memset(&e, 0, sizeof e);
	e.xclient.type = ClientMessage;
	e.xclient.window = w->window;
	e.xclient.message_type = peak_linux.net_wm_state;
	e.xclient.format = 32;
	e.xclient.data.l[0] = on ? 1 : 0;
	e.xclient.data.l[1] = (long)peak_linux.net_wm_state_fullscreen;
	e.xclient.data.l[2] = 0;
	e.xclient.data.l[3] = 1;
	peak_x11.XSendEvent(peak_linux.display, DefaultRootWindow(peak_linux.display), False,
		SubstructureNotifyMask | SubstructureRedirectMask, &e);
	peak_x11.XFlush(peak_linux.display);
}

static void
peak_platform_window_cursor(PeakWindowInternal *intern, int on)
{
	struct peak_linux_win *w;
	Pixmap bm;
	XColor black;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_cursor(intern, on);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display)
		return;
	w->cursor_on = on;
	if (on) {
		if (w->glyph && peak_x11.XDefineCursor)
			peak_x11.XDefineCursor(peak_linux.display, w->window, w->glyph);
		else if (peak_x11.XUndefineCursor)
			peak_x11.XUndefineCursor(peak_linux.display, w->window);
		peak_x11.XFlush(peak_linux.display);
		return;
	}
	if (!w->blank && peak_x11.XCreatePixmap && peak_x11.XCreatePixmapCursor) {
		memset(&black, 0, sizeof black);
		bm = peak_x11.XCreatePixmap(peak_linux.display, w->window, 1, 1, 1);
		w->blank = peak_x11.XCreatePixmapCursor(peak_linux.display, bm, bm, &black, &black, 0, 0);
		peak_x11.XFreePixmap(peak_linux.display, bm);
	}
	if (w->blank)
		peak_x11.XDefineCursor(peak_linux.display, w->window, w->blank);
	peak_x11.XFlush(peak_linux.display);
}

static unsigned
peak_x11_cursor_glyph(int shape)
{
	switch (shape) {
	case 1: return 152; /* XC_xterm */
	case 2: return 60;  /* XC_hand2 */
	case 3: return 150; /* XC_watch */
	case 4: return 34;  /* XC_crosshair */
	case 5: return 0;   /* XC_X_cursor */
	case 6: return 92;  /* XC_question_arrow */
	default: return 68; /* XC_left_ptr */
	}
}

static void
peak_platform_window_cursor_shape(PeakWindowInternal *intern, int shape)
{
	struct peak_linux_win *w;
	Cursor cur;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_cursor_shape(intern, shape);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display || !peak_x11.XCreateFontCursor)
		return;
	cur = peak_x11.XCreateFontCursor(peak_linux.display, peak_x11_cursor_glyph(shape));
	if (!cur)
		return;
	if (w->glyph && peak_x11.XFreeCursor)
		peak_x11.XFreeCursor(peak_linux.display, w->glyph);
	w->glyph = cur;
	if (w->cursor_on && peak_x11.XDefineCursor) {
		peak_x11.XDefineCursor(peak_linux.display, w->window, w->glyph);
		peak_x11.XFlush(peak_linux.display);
	}
}

static void
peak_platform_window_pointer_relative(PeakWindowInternal *intern, int on)
{
	struct peak_linux_win *w;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		peak_wayland_window_pointer_relative(intern, on);
		return;
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display)
		return;
	w->relative = on;
	/* confine_to the window trapped the cursor and ate clicks meant for other apps. */
	if (on && peak_x11.XGrabPointer)
		peak_x11.XGrabPointer(peak_linux.display, w->window, True,
			PointerMotionMask | ButtonPressMask | ButtonReleaseMask,
			GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
	else if (!on && peak_x11.XUngrabPointer)
		peak_x11.XUngrabPointer(peak_linux.display, CurrentTime);
}

static float
peak_platform_window_scale(PeakWindowInternal *intern)
{
	if (peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_window_scale(intern);
	(void)intern;
	return 1.f;
}

static int
peak_platform_drop_drag(PeakWindowInternal *intern, const char *utf8, size_t n)
{
	if (peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_drop_drag(intern, utf8, n);
	(void)intern;
	(void)utf8;
	(void)n;
	return 0;
}

static int
peak_platform_clip_set(PeakWindowInternal *intern, PeakClip which, const char *utf8, size_t n)
{
	if (peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_clip_set(intern, which, utf8, n);
	struct peak_linux_win *w;

	(void)utf8;
	(void)n;
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display)
		return 0;
	peak_linux_clip_atoms();
	peak_x11.XSetSelectionOwner(peak_linux.display, peak_linux_clip_atom(which), w->window, CurrentTime);
	peak_x11.XFlush(peak_linux.display);
	return 1;
}

static int
peak_platform_clip_request(PeakWindowInternal *intern, PeakClip which)
{
	struct peak_linux_win *w;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_clip_request(intern, which);
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display)
		return 0;
	peak_linux_clip_atoms();
	peak_clip_req_on = 1;
	peak_clip_req_which = which;
	peak_clip_req_xa = 0;
	peak_clip_incr_on = 0;
	peak_x11.XConvertSelection(peak_linux.display, peak_linux_clip_atom(which),
		peak_linux.clip_utf8, peak_linux.clip_prop, w->window, CurrentTime);
	peak_x11.XFlush(peak_linux.display);
	return 1;
}

static void
peak_linux_xdnd_finished(struct peak_linux_win *w, int ok)
{
	XEvent r;

	if (!w || !w->xdnd_source || !peak_linux.display || !peak_linux.xdnd_finished)
		return;
	memset(&r, 0, sizeof r);
	r.xclient.type = ClientMessage;
	r.xclient.display = peak_linux.display;
	r.xclient.window = w->xdnd_source;
	r.xclient.message_type = peak_linux.xdnd_finished;
	r.xclient.format = 32;
	r.xclient.data.l[0] = (long)w->window;
	r.xclient.data.l[1] = ok ? 1 : 0;
	r.xclient.data.l[2] = ok ? (long)peak_linux.xdnd_action_copy : 0;
	peak_x11.XSendEvent(peak_linux.display, w->xdnd_source, False, 0, &r);
	peak_x11.XFlush(peak_linux.display);
}

static bool
peak_platform_epoll(PeakWindowInternal *intern, PeakEvent *ev)
{
	struct peak_linux_win *w;
	XEvent xev;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		if (peak_wayland_epoll(intern, ev))
			return 1;
		return peak_linux_gamepad_poll(ev);
	}
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display)
		return 0;
	if (w->extra_on) {
		*ev = w->extra;
		w->extra_on = 0;
		return 1;
	}
	if (w->text_pending) {
		size_t n = w->text_n - w->text_off;
		if (n > sizeof ev->text.bytes) {
			n = sizeof ev->text.bytes;
			while (n && ((unsigned char)w->text_pending[w->text_off + n] & 0xc0) == 0x80) n--;
		}
		if (n) {
			ev->type = PEAK_EVENT_TEXT; ev->text.n = n;
			memcpy(ev->text.bytes, w->text_pending + w->text_off, n);
			w->text_off += n;
			if (w->text_off == w->text_n) { free(w->text_pending); w->text_pending = NULL; }
			return 1;
		}
		free(w->text_pending); w->text_pending = NULL;
	}
	if (peak_linux_gamepad_poll(ev))
		return 1;

	while (peak_linux_next_event(w, &xev, 1)) {
		switch (xev.type) {
		case ClientMessage:
			if ((Atom)xev.xclient.data.l[0] == peak_linux.wm_delete_window) {
				ev->type = PEAK_EVENT_WINDOW_CLOSE;
				return 1;
			}
			if (xev.xclient.message_type == peak_linux.xdnd_enter) {
				w->xdnd_source = (Window)xev.xclient.data.l[0];
				continue;
			}
			if (xev.xclient.message_type == peak_linux.xdnd_position) {
				XEvent r;

				w->xdnd_source = (Window)xev.xclient.data.l[0];
				memset(&r, 0, sizeof r);
				r.xclient.type = ClientMessage;
				r.xclient.display = peak_linux.display;
				r.xclient.window = w->xdnd_source;
				r.xclient.message_type = peak_linux.xdnd_status;
				r.xclient.format = 32;
				r.xclient.data.l[0] = (long)w->window;
				r.xclient.data.l[1] = 3;
				r.xclient.data.l[4] = (long)peak_linux.xdnd_action_copy;
				peak_x11.XSendEvent(peak_linux.display, w->xdnd_source, False, 0, &r);
				peak_x11.XFlush(peak_linux.display);
				continue;
			}
			if (xev.xclient.message_type == peak_linux.xdnd_drop) {
				Time t;

				w->xdnd_source = (Window)xev.xclient.data.l[0];
				t = (Time)xev.xclient.data.l[2];
				w->xdnd_time = t ? t : CurrentTime;
				peak_x11.XConvertSelection(peak_linux.display, peak_linux.xdnd_selection,
					peak_linux.uri_list, peak_linux.xdnd_prop ? peak_linux.xdnd_prop : peak_linux.clip_prop,
					w->window, w->xdnd_time);
				peak_x11.XFlush(peak_linux.display);
				continue;
			}
			continue;
		case KeyPress:
		case KeyRelease: {
			char legacy[8], buf[64];
			KeySym ks = 0;
			int n = 0, legacy_n, commit_only = 0;
			char *text = buf;
			Status status = XLookupNone;
			legacy_n = xev.xkey.keycode ? peak_x11.XLookupString(&xev.xkey, legacy, sizeof legacy, &ks, NULL) : 0;
			ev->type = (xev.type == KeyPress) ? PEAK_EVENT_KEY_DOWN : PEAK_EVENT_KEY_UP;
			ev->key.key = peak_internal_x11_key_map(ks ? ks : (xev.xkey.keycode ? peak_x11.XLookupKeysym(&xev.xkey, 0) : 0));
			ev->key.mod = peak_internal_x11_mod_map(xev.xkey.state);
			ev->key.code = legacy_n > 0 ? (uint32_t)(unsigned char)legacy[0] : 0;
			if (ev->key.key == PEAK_KEY_UNKNOWN && legacy_n == 1 && (unsigned char)legacy[0] == 0x7f)
				ev->key.key = PEAK_KEY_DELETE;
			if (xev.type == KeyPress && w->ic) {
				KeySym lookup_sym = NoSymbol;
				n = peak_x11.Xutf8LookupString(w->ic, &xev.xkey, buf, sizeof buf, &lookup_sym, &status);
				if (status == XBufferOverflow && n > 0 && n <= PEAK_CLIP_MAX) {
					text = malloc((size_t)n);
					if (text) n = peak_x11.Xutf8LookupString(w->ic, &xev.xkey, text, n, &lookup_sym, &status);
					else n = 0;
				}
				if (status == XLookupNone || status == XBufferOverflow) {
					if (text != buf) free(text);
					continue;
				}
				if (status == XLookupChars || (status == XLookupBoth && (n != 1 || (unsigned char)text[0] >= 128))) {
					commit_only = 1;
					ev->key.key = PEAK_KEY_UNKNOWN;
					ev->key.code = 0;
					ev->key.mod = 0;
				} else if (status == XLookupKeySym || status == XLookupBoth) {
					ev->key.key = peak_internal_x11_key_map(lookup_sym);
				}
				if (status != XLookupChars && status != XLookupBoth) n = 0;
			} else if (xev.type == KeyPress && legacy_n > 0) {
				size_t un = 0;
				if (peak_linux_latin1_utf8((unsigned char *)legacy, (size_t)legacy_n, &text, &un)) n = (int)un;
				else text = buf;
			}
			if (n > 0 && (unsigned char)text[0] >= 32 && (unsigned char)text[0] != 0x7f &&
				ev->key.key != PEAK_KEY_DELETE && ev->key.key != PEAK_KEY_BACKSPACE &&
				!(!commit_only && xev.xkey.keycode && (ev->key.mod & (PEAK_KEYMOD_CTRL | PEAK_KEYMOD_ALT | PEAK_KEYMOD_SUPER)) && n == 1 && (unsigned char)text[0] < 128)) {
				if (text == buf) { text = malloc((size_t)n); if (text) memcpy(text, buf, (size_t)n); }
				if (text) { w->text_pending = text; w->text_n = (size_t)n; w->text_off = 0; text = NULL; }
			}
			if (text != buf) free(text);
			return 1;
		}
		case ButtonPress:
		case ButtonRelease:
			if (xev.xbutton.button < Button1 || xev.xbutton.button > Button5) continue;
			ev->type = PEAK_EVENT_POINTER;
			ev->pointer.state = (xev.type == ButtonPress) ? PEAK_POINTER_PRESSED : PEAK_POINTER_RELEASED;
			ev->pointer.x = (float)xev.xbutton.x;
			ev->pointer.y = (float)xev.xbutton.y;
			ev->pointer.mod = peak_internal_x11_mod_map(xev.xbutton.state);
			if (xev.xbutton.button == Button4)
				ev->pointer.type = PEAK_POINTER_WHEEL_UP;
			else if (xev.xbutton.button == Button5)
				ev->pointer.type = PEAK_POINTER_WHEEL_DOWN;
			else if (xev.xbutton.button == Button2)
				ev->pointer.type = PEAK_POINTER_MIDDLE;
			else if (xev.xbutton.button == Button3)
				ev->pointer.type = PEAK_POINTER_RIGHT;
			else
				ev->pointer.type = PEAK_POINTER_LEFT;
			return 1;
		case MotionNotify:
			ev->type = PEAK_EVENT_POINTER;
			ev->pointer.state = PEAK_POINTER_MOVED;
			ev->pointer.mod = peak_internal_x11_mod_map(xev.xmotion.state);
			ev->pointer.type = (xev.xmotion.state & Button3Mask) ? PEAK_POINTER_RIGHT :
			                   (xev.xmotion.state & Button2Mask) ? PEAK_POINTER_MIDDLE : PEAK_POINTER_LEFT;
			if (w->relative) {
				ev->pointer.x = (float)xev.xmotion.x - w->last_x;
				ev->pointer.y = (float)xev.xmotion.y - w->last_y;
			} else {
				ev->pointer.x = (float)xev.xmotion.x;
				ev->pointer.y = (float)xev.xmotion.y;
			}
			w->last_x = (float)xev.xmotion.x;
			w->last_y = (float)xev.xmotion.y;
			if (w->relative && peak_x11.XWarpPointer)
				peak_x11.XWarpPointer(peak_linux.display, None, w->window, 0, 0, 0, 0,
					(int)w->width / 2, (int)w->height / 2);
			return 1;
		case FocusIn:
			if (w->ic) peak_x11.XSetICFocus(w->ic);
			ev->type = PEAK_EVENT_FOCUS;
			ev->focus.on = 1;
			return 1;
		case FocusOut:
			if (w->ic) peak_x11.XUnsetICFocus(w->ic);
			if (w->relative && peak_x11.XUngrabPointer)
				peak_x11.XUngrabPointer(peak_linux.display, CurrentTime);
			ev->type = PEAK_EVENT_FOCUS;
			ev->focus.on = 0;
			return 1;
		case Expose:
			if (xev.xexpose.count != 0)
				continue;
			ev->type = PEAK_EVENT_EXPOSE;
			return 1;
		case ConfigureNotify: {
			uint32_t width = (uint32_t)xev.xconfigure.width;
			uint32_t height = (uint32_t)xev.xconfigure.height;
			if (width == w->width && height == w->height)
				continue;
			if (!peak_linux_buffer(w, width, height))
				continue;
			ev->type = PEAK_EVENT_WINDOW_RESIZE;
			ev->resize.width = w->width;
			ev->resize.height = w->height;
			return 1;
		}
		case SelectionRequest:
			peak_linux_clip_request_sel(&xev.xselectionrequest);
			continue;
		case SelectionClear:
			continue;
		case SelectionNotify:
			if (xev.xselection.selection == peak_linux.xdnd_selection) {
				Atom type = 0;
				int fmt = 0;
				unsigned long nitems = 0, after = 0;
				unsigned char *data = NULL;
				const char *p, *nl;

				if (xev.xselection.property == None) {
					peak_linux_xdnd_finished(w, 0);
					continue;
				}
				if (peak_x11.XGetWindowProperty(peak_linux.display, w->window, xev.xselection.property,
						0, 0x10000, True, AnyPropertyType, &type, &fmt, &nitems, &after, &data) == Success && data && type == peak_linux.uri_list && fmt == 8 && !after) {
					p = (const char *)data;
					if (nitems >= 7 && !memcmp(p, "file://", 7)) { p += 7; nitems -= 7; }
					nl = memchr(p, '\n', nitems);
					if (nl) nitems = (unsigned long)(nl - p);
					while (nitems && (p[nitems - 1] == '\r' || p[nitems - 1] == '\n'))
						nitems--;
					peak_drop_store(p, (size_t)nitems);
					ev->type = PEAK_EVENT_DROP;
					ev->drop.n = (size_t)nitems;
					peak_x11.XFree(data);
					peak_linux_xdnd_finished(w, 1);
					return 1;
				}
				if (data)
					peak_x11.XFree(data);
				peak_linux_xdnd_finished(w, 0);
				continue;
			}
			if (!peak_clip_req_on)
				continue;
			if (xev.xselection.property == None) {
				if (!peak_clip_req_xa) {
					peak_linux_clip_atoms();
					peak_clip_req_xa = 1;
					peak_x11.XConvertSelection(peak_linux.display,
						peak_linux_clip_atom(peak_clip_req_which), XA_STRING,
						peak_linux.clip_prop, w->window, CurrentTime);
					peak_x11.XFlush(peak_linux.display);
				} else {
					peak_clip_req_on = 0;
				}
				continue;
			}
			if (peak_linux_clip_take_prop(w->window, xev.xselection.property,
					peak_clip_req_which, ev))
				return 1;
			continue;
		case PropertyNotify:
			if (peak_linux_clip_property(w, &xev.xproperty, ev))
				return 1;
			continue;
		default:
			continue;
		}
	}
	return 0;
}

static int
peak_platform_fd(PeakWindowInternal *intern)
{
	if (peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_fd(intern);
	(void)intern;
	if (!peak_linux.display)
		return -1;
	return ConnectionNumber(peak_linux.display);
}

static int
peak_platform_pending(PeakWindowInternal *intern)
{
	struct peak_linux_win *w;
	XEvent ev;

	if (peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_pending(intern);
	w = intern ? intern->w : NULL;
	if (!w || !w->window || !peak_linux.display) return 0;
	if (w->extra_on || w->text_pending) return 1;
	if (!peak_x11.XPending) return 0;
	return peak_linux_next_event(w, &ev, 0);
}

#ifndef PEAK_NO_AUDIO
static int
peak_internal_pulse_load(void)
{
	void *handle;

	if (peak_pulse.pa_simple_new)
		return 1;
	if (!(handle = dlopen(PEAK_PULSE_LINUX, RTLD_LOCAL | RTLD_NOW))) {
		fputs("Failed to load PulseAudio library. What system are you fucking using and abusing?", stderr);
		return 0;
	}
#define X(name, ret, args) peak_pulse.name = (ret (*) args)dlsym(handle, #name);
	PEAK_PULSE_API(X)
#undef X
#define X(name, ret, args) || !peak_pulse.name
	if (0 PEAK_PULSE_API(X)) {
		fputs("Failed to load PulseAudio symbols", stderr);
		return 0;
	}
#undef X
	return 1;
}

static void *
peak_internal_audio_thread(void *arg)
{
	size_t n;
	int error;

	(void)arg;
	n = (size_t)peak_audio.channels * PEAK_AUDIO_FRAMES;
	while (peak_audio.run) {
		memset(peak_audio.buf, 0, n * sizeof(int16_t));
		if (peak_audio.fill)
			peak_audio.fill(peak_audio.buf, PEAK_AUDIO_FRAMES, peak_audio.userdata);
		if (peak_pulse.pa_simple_write(peak_audio.stream, peak_audio.buf, n * sizeof(int16_t), &error) < 0)
			break;
	}
	return NULL;
}

static int
peak_platform_audio_start(uint32_t channels, uint32_t rate, void (*fill)(int16_t *out, size_t frames, void *userdata), void *userdata)
{
	PeakPaSampleSpec ss;
	int error;

	if (channels > 32)
		return 0;
	if (!peak_internal_pulse_load())
		return 0;

	ss.format = 3; /* PA_SAMPLE_S16LE */
	ss.rate = rate;
	ss.channels = (uint8_t)channels;
	peak_audio.stream = peak_pulse.pa_simple_new(NULL, "Peak", 1, NULL, "playback", &ss, NULL, NULL, &error);
	if (!peak_audio.stream) {
		fputs("Failed to open PulseAudio stream", stderr);
		return 0;
	}
	if (!(peak_audio.buf = calloc((size_t)channels * PEAK_AUDIO_FRAMES, sizeof(int16_t)))) {
		peak_pulse.pa_simple_free(peak_audio.stream);
		peak_audio.stream = NULL;
		return 0;
	}
	peak_audio.fill = fill;
	peak_audio.userdata = userdata;
	peak_audio.channels = channels;
	peak_audio.run = 1;
	if (pthread_create(&peak_audio.thread, NULL, peak_internal_audio_thread, NULL) != 0) {
		peak_audio.thread_on = 0;
		peak_audio.run = 0;
		free(peak_audio.buf);
		peak_audio.buf = NULL;
		peak_pulse.pa_simple_free(peak_audio.stream);
		peak_audio.stream = NULL;
		return 0;
	}
	peak_audio.thread_on = 1;
	return 1;
}
#endif

static uint64_t
peak_platform_get_time(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * NANOS_PER_SEC + (uint64_t)ts.tv_nsec;
}

static void
peak_platform_sleep_ns(int64_t ns)
{
	struct timespec ts;
	if (ns <= 0) return;
	ts.tv_sec = ns / 1000000000ll;
	ts.tv_nsec = ns % 1000000000ll;
	nanosleep(&ts, NULL);
}

static const char **
peak_platform_vulkan_get_extensions(uint32_t *count)
{
	static const char *exts[] = {
		"VK_KHR_surface",
		"VK_KHR_xlib_surface",
	};
	if (peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_vulkan_get_extensions(count);
	if (count) *count = 2;
	return exts;
}

static int
peak_platform_vulkan_create_surface(PeakWindowInternal *intern, void *instance, const void *allocator, void *out_surface)
{
	if (peak_linux_kind == PEAK_LINUX_WAYLAND)
		return peak_wayland_vulkan_create_surface(intern, instance, allocator, out_surface);
#ifdef PEAK_VULKAN
	struct peak_linux_win *w;
	VkXlibSurfaceCreateInfoKHR ci;
	w = intern ? intern->w : NULL;
	if (!w || !peak_linux.display || !w->window) return 0;
	memset(&ci, 0, sizeof ci);
	ci.sType = VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR;
	ci.dpy = peak_linux.display;
	ci.window = w->window;
	return vkCreateXlibSurfaceKHR((VkInstance)instance, &ci, (const VkAllocationCallbacks *)allocator, (VkSurfaceKHR *)out_surface) == VK_SUCCESS;
#else
	(void)intern; (void)instance; (void)allocator; (void)out_surface;
	return 0;
#endif
}

#ifndef PEAK_NO_AUDIO
static void
peak_platform_audio_stop(void)
{
	if (!peak_audio.run && !peak_audio.stream)
		return;
	peak_audio.run = 0;
	if (peak_audio.thread_on) {
		pthread_join(peak_audio.thread, NULL);
		peak_audio.thread_on = 0;
	}
	if (peak_audio.stream) {
		peak_pulse.pa_simple_free(peak_audio.stream);
		peak_audio.stream = NULL;
	}
	free(peak_audio.buf);
	peak_audio.buf = NULL;
	peak_audio.fill = NULL;
	peak_audio.userdata = NULL;
}
#else
static int
peak_platform_audio_start(uint32_t channels, uint32_t rate, void (*fill)(int16_t *out, size_t frames, void *userdata), void *userdata)
{
	(void)channels;
	(void)rate;
	(void)fill;
	(void)userdata;
	return 0;
}

static void
peak_platform_audio_stop(void)
{
}
#endif

static int
peak_linux_net_pid(Window w)
{
	Atom type;
	int fmt;
	unsigned long nitems;
	unsigned long after;
	unsigned char *data;
	int pid;

	type = 0;
	fmt = 0;
	nitems = 0;
	after = 0;
	data = NULL;
	pid = 0;
	if (!peak_linux.display || !peak_linux.net_wm_pid || !w)
		return 0;
	if (peak_x11.XGetWindowProperty(peak_linux.display, w, peak_linux.net_wm_pid,
			0, 1, False, XA_CARDINAL, &type, &fmt, &nitems, &after, &data) == Success
			&& data && nitems)
		pid = (int)(*(unsigned long *)data);
	if (data)
		peak_x11.XFree(data);
	return pid;
}

int
peak_pointer_pid(PeakWindow *win)
{
	Window root;
	Window root_ret;
	Window child;
	Window parent;
	Window w;
	Window *kids;
	int rx;
	int ry;
	int wx;
	int wy;
	unsigned int mask;
	unsigned int n;
	int pid;

	(void)win;
	if (peak_linux_kind != PEAK_LINUX_X11 || !peak_linux.display || !peak_x11.XQueryPointer
			|| !peak_x11.XQueryTree)
		return 0;
	root = DefaultRootWindow(peak_linux.display);
	child = 0;
	if (!peak_x11.XQueryPointer(peak_linux.display, root, &root_ret, &child,
			&rx, &ry, &wx, &wy, &mask) || !child)
		return 0;
	w = child;
	for (;;) {
		child = 0;
		if (!peak_x11.XQueryPointer(peak_linux.display, w, &root_ret, &child,
				&rx, &ry, &wx, &wy, &mask) || !child || child == w)
			break;
		w = child;
	}
	for (;;) {
		pid = peak_linux_net_pid(w);
		if (pid)
			return pid;
		kids = NULL;
		n = 0;
		parent = 0;
		if (!peak_x11.XQueryTree(peak_linux.display, w, &root_ret, &parent, &kids, &n))
			return 0;
		if (kids)
			peak_x11.XFree(kids);
		if (!parent || parent == root_ret || parent == w)
			return 0;
		w = parent;
	}
}

int
peak_pointer_local(PeakWindow *win, int *x, int *y)
{
	struct peak_linux_win *xw;
	struct peak_wayland_win *ww;
	Window root;
	Window child;
	int rx;
	int ry;
	int wx;
	int wy;
	unsigned int mask;
	int pid;

	if (!win || !win->internal.w)
		return 0;
	if (peak_linux_kind == PEAK_LINUX_WAYLAND) {
		ww = win->internal.w;
		if (!ww->pointer_in)
			return 0;
		wx = (int)ww->last_x;
		wy = (int)ww->last_y;
		if (wx < 0 || wy < 0 || wx >= (int)ww->width || wy >= (int)ww->height)
			return 0;
		if (x)
			*x = wx;
		if (y)
			*y = wy;
		return 1;
	}
	if (peak_linux_kind != PEAK_LINUX_X11 || !peak_linux.display || !peak_x11.XQueryPointer)
		return 0;
	xw = win->internal.w;
	if (!xw->window)
		return 0;
	if (!peak_x11.XQueryPointer(peak_linux.display, xw->window, &root, &child,
			&rx, &ry, &wx, &wy, &mask))
		return 0;
	if (wx < 0 || wy < 0 || wx >= (int)xw->width || wy >= (int)xw->height)
		return 0;
	pid = peak_pointer_pid(win);
	if (pid && pid != (int)getpid())
		return 0;
	if (x)
		*x = wx;
	if (y)
		*y = wy;
	return 1;
}

#define PEAK_HAS_POINTER_PID 1
#include "p_posix.c"
