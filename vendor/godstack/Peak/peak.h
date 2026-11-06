/* ===========================================================================
 * PEAK - Copyright @ Vasco Alves - See LICENSE at the end of file.
 *
 * figlet font: maxiwi
 *
 * Platform layer.
 * It just works, don't think about it too much.
 *
 * SURVIVOR:
 * - One header. OS lives in p_linux.c / p_wayland.c / p_win32.c /
 *   p_macos.c / p_posix.c / p_emscripten.c. peak.c dispatches.
 * - Callers use peak_* and PEAK_HANDLE. They do not include OS headers
 *   for Peak work. Missing: 0 / PEAK_HANDLE_INVALID, never #error a living OS.
 * - PEAK_* detect macros are for Peak .c and rare WSI. Detecting != supported.
 *
 * SUPPORTED PLATFORMS:
 * - Desktop: Win32, MacOS and Linux (Wayland & X11).
 * - Web via emscripten.
 *
 * PREFIX: PEAK (macros)  Peak (types)  peak_ (functions)
 *
 * MACRO FLAGS (you define):
 * - PEAK_VULKAN         Vulkan WSI. Sets VK_USE_PLATFORM_*.
 * - PEAK_NO_AUDIO       audio off. start returns 0. no pthread / pulse.
 * - PEAK_NO_GAMEPAD     Linux joystick polling off; window pointer input only.
 * - P_LOG_WARN_ENABLED  default 1. PWARN.
 * - P_LOG_INFO_ENABLED  default 1. PINFO.
 * - P_LOG_DEBUG_ENABLED default 0. PDEBUG.
 * - P_LOG_TRACE_ENABLED default 0. PTRACE.
 *
 * DEFINED:
 * - PEAK_WEB                wasm / emscripten
 * - PEAK_WIN32              Windows
 * - PEAK_APPLE              Darwin
 * - PEAK_IOS                iPhone
 * - PEAK_MACOS              macOS
 * - PEAK_ANDROID            also PEAK_LINUX
 * - PEAK_LINUX              Linux
 * - PEAK_BSD                *BSD
 * - PEAK_UNIX               Linux / BSD / Apple
 * - PEAK_WINDOW_TRANSPARENT window_open: ARGB visual
 * - PEAK_WINDOW_FULLSCREEN  window_open: start fullscreen
 * - PEAK_HANDLE             fd, or HANDLE on Win32
 * - PEAK_HANDLE_INVALID     closed / failed
 * - PEAK                    extern
 *
 * The platform detection macros may be useful in your project,
 * feel free to use them. Detecting a platform does not mean it's supported.
 *
 * =========================================================================== */

#ifndef PEAK_H
#define PEAK_H

#if !defined(_WIN32) && !defined(_WIN64) && !defined(__APPLE__) && !defined(__MACH__) \
 && !defined(__wasm__) && !defined(__wasm32__) && !defined(__wasm64__) && !defined(__EMSCRIPTEN__)
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#endif

#define PEAK_MAJOR "0"
#define PEAK_MINOR "11"
#define PEAK_PATCH "5"

/* CHANGE LOG
 * 0.0.0 - @vasco - prototyping
 * 0.1.0 - @vasco - linux x11 that automagically loads X11 DLL
 * 0.1.1 - @vasco - fixed event handling on linux
 * 0.1.2 - @vasco - better handling of windows, if multiple windows becomes necessary in the future
 * 0.2.0 - @vasco - multiple windows, major-ish API changes.
 * 0.3.0 - @vasco - web via emscripten
 * 0.4.0 - @vasco - win32
 * 0.5.0 - @vasco - audio start/stop, s16le pull callback
 * 0.5.1 - @vasco - log, file, time, vulkan extensions
 * 0.5.2 - @vasco - vulkan surface from window
 * 0.5.3 - @vasco - skip XCloseDisplay after vulkan teardown
 * 0.5.4 - @vasco - posix feature test macro before includes
 * 0.5.5 - @vasco - include peak.c; no PEAK_IMPLEMENTATION
 * 0.5.6 - @vasco - digits, tab, backspace, delete; key.code from XLookupString
 * 0.5.7 - @vasco - peak_window_fd; X11 ConnectionNumber
 * 0.5.8 - @vasco - peak_window_pending; XPending so idle poll can sleep
 * 0.5.9 - @vasco - wheel up/down as PeakPointerType (X11 Button4/5)
 * 0.6.0 - @vasco - macos (Cocoa/Metal/AudioQueue)
 * 0.6.1 - @vasco - PEAK_WINDOW_TRANSPARENT (X11 ARGB visual)
 * 0.6.2 - @vasco - PEAK_HANDLE, pty, wait, sock, job, mirror ring
 * 0.6.3 - @vasco - win32 sizeof style; platform fn prototypes
 * 0.6.4 - @vasco - win32 audio_stop before start
 * 0.6.5 - @vasco - ISO_Left_Tab; linux syscall prototype
 * 0.6.6 - @vasco - pending is this window only; WSI events no longer spin poll
 * 0.7.0 - @vasco - clipboard; keymod flags; Insert; pointer.mod; PEAK_EVENT_CLIP
 * 0.8.0 - @vasco - keys F1-12 Home End Page Super; title size fullscreen cursor relative scale; text/drop; filesystem; sock_connect; wayland then x11; pointer connect
 * 0.9.0 - @vasco - pid, env, dir list, symlink, child reap fd, sock SCM_RIGHTS, pointer pid
 * 0.9.1 - @vasco - PEAK_NO_AUDIO; linux skips pthread and pulse
 * 0.10.0 - @vasco - peak_aligned_alloc / peak_aligned_free
 * 0.10.1 - @vasco - wayland marshal new_id slots; create_pool no longer sends size as fd
 * 0.10.2 - @vasco - wayland seat v4; wl_keyboard.repeat_info; xdg_toplevel bounds/caps
 * 0.10.3 - @vasco - wayland read socket; data device clip; pointer/key mods
 * 0.10.4 - @vasco - wayland pump drains socket; xdg first commit before map
 * 0.10.5 - @vasco - wayland client key repeat (repeat_info + timerfd)
 * 0.10.6 - @vasco - wayland file drop + peak_drop_drag (data_device v3)
 * 0.10.7 - @vasco - wayland dnd: defer offer destroy across drop+leave; finish live copy/move only
 * 0.10.8 - @vasco - wayland compositor keymap via libxkbcommon (layout, group, compose)
 * 0.10.9 - @vasco - peak_env_get; SIGUSR1 wakeup fd
 * 0.10.10 - @vasco - peak_pipe_capacity / peak_pipe_set_capacity
 * 0.11.0 - @vasco - peak_pipe_spawn / peak_pipe_resize
 * 0.11.1 - @vasco - pipe spawn: pipe + vt-fast.so; slave no OPOST
 * 0.11.2 - @vasco - focus/expose events; set_class; set_opacity
 * 0.11.3 - @vasco - wayland fractional scale, cursor shape, primary, alpha, wheel
 * 0.11.4 - @vasco - pty spawn keeps OPOST|ONLCR; child COLUMNS and LINES
 * 0.11.5 - @vasco - Delete is treated as a key
 * 0.11.6 - @vasco - aligned_alloc and aligned_free are now macros
 * 0.11.7 - @vasco - peak_window_set_text_input_rect; IME candidate window at the cursor (macos, win32)
 */

#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#if !defined(__cplusplus)
#if !( \
    (defined(__STDC__) && __STDC__ == 1 && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L)\
)
#error "Peak requires C99."
#endif
#endif

//   █
//   █      █           █
// ███ ███ ███ ███ ███ ███
// █ █ ███  █  ███ █    █
// █ █ █    █  █   █    █
// ███ ███  ██ ███ ███  ██

#if defined(__wasm__) || defined(__wasm32__) || defined(__wasm64__) || defined(__EMSCRIPTEN__)
    #define PEAK_WEB
#elif defined(_WIN32) || defined(_WIN64) || defined(__WIN32__) || defined(__TOS_WIN__)
    #define PEAK_WIN32
    #ifndef WIN32_LEAN_AND_MEAN
        #define WIN32_LEAN_AND_MEAN
    #endif
#elif defined(__APPLE__) || defined(__MACH__)
    #include <TargetConditionals.h>
    #define PEAK_APPLE
    #if TARGET_OS_IPHONE
        #define PEAK_IOS
    #else
        #define PEAK_MACOS
    #endif
#elif defined(__ANDROID__)
    #define PEAK_ANDROID
    #define PEAK_LINUX
#elif defined(__linux__)
    #define PEAK_LINUX
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__) || defined(__bsdi__) || defined(__DragonFly__)
    #define PEAK_BSD
#endif

#if defined(PEAK_LINUX) || defined(PEAK_BSD) || defined(PEAK_APPLE)
    #define PEAK_UNIX
#endif

#ifdef PEAK_VULKAN
#if defined(PEAK_LINUX)
#ifndef VK_USE_PLATFORM_WAYLAND_KHR
#define VK_USE_PLATFORM_WAYLAND_KHR
#endif
#ifndef VK_USE_PLATFORM_XLIB_KHR
#define VK_USE_PLATFORM_XLIB_KHR
#endif
#elif defined(PEAK_WIN32) && !defined(VK_USE_PLATFORM_WIN32_KHR)
#define VK_USE_PLATFORM_WIN32_KHR
#elif defined(PEAK_MACOS) && !defined(VK_USE_PLATFORM_METAL_EXT)
#define VK_USE_PLATFORM_METAL_EXT
#endif
#endif

#if defined(PEAK_WIN32)
typedef void *PEAK_HANDLE;
#else
typedef int PEAK_HANDLE;
#endif
#define PEAK_HANDLE_INVALID ((PEAK_HANDLE)(intptr_t)-1)
#define PEAK extern

// █     █
//          █
// █ ███ █ ███
// █ █ █ █  █
// █ █ █ █  █
// █ █ █ █  ██

PEAK int  peak_init(void);
PEAK void peak_quit(void);

//                  █
// ███ █ █ ███ ███ ███
// ███ █ █ ███ █ █  █
// █   █ █ █   █ █  █
// ███  █  ███ █ █  ██

typedef enum {
    PEAK_KEYMOD_NONE  = 0,
    PEAK_KEYMOD_SHIFT = 1 << 0,
    PEAK_KEYMOD_CTRL  = 1 << 1,
    PEAK_KEYMOD_ALT   = 1 << 2,
    PEAK_KEYMOD_CAPS  = 1 << 3,
    PEAK_KEYMOD_SUPER = 1 << 4,
} PeakKeyMod;

typedef enum {
    PEAK_KEY_UNKNOWN = 0,
    PEAK_KEY_UP, PEAK_KEY_DOWN, PEAK_KEY_LEFT, PEAK_KEY_RIGHT,
    PEAK_KEY_SPACE, PEAK_KEY_ESCAPE, PEAK_KEY_ENTER,
    PEAK_KEY_BACKSPACE, PEAK_KEY_TAB, PEAK_KEY_DELETE, PEAK_KEY_INSERT,
    PEAK_KEY_HOME, PEAK_KEY_END, PEAK_KEY_PAGEUP, PEAK_KEY_PAGEDOWN,
    PEAK_KEY_F1, PEAK_KEY_F2, PEAK_KEY_F3, PEAK_KEY_F4, PEAK_KEY_F5, PEAK_KEY_F6,
    PEAK_KEY_F7, PEAK_KEY_F8, PEAK_KEY_F9, PEAK_KEY_F10, PEAK_KEY_F11, PEAK_KEY_F12,
    PEAK_KEY_0, PEAK_KEY_1, PEAK_KEY_2, PEAK_KEY_3, PEAK_KEY_4,
    PEAK_KEY_5, PEAK_KEY_6, PEAK_KEY_7, PEAK_KEY_8, PEAK_KEY_9,
    PEAK_KEY_A, PEAK_KEY_B, PEAK_KEY_C, PEAK_KEY_D, PEAK_KEY_E, PEAK_KEY_F, PEAK_KEY_G, PEAK_KEY_H, PEAK_KEY_I,
    PEAK_KEY_J, PEAK_KEY_K, PEAK_KEY_L, PEAK_KEY_M, PEAK_KEY_N, PEAK_KEY_O, PEAK_KEY_P, PEAK_KEY_Q, PEAK_KEY_R,
    PEAK_KEY_S, PEAK_KEY_T, PEAK_KEY_U, PEAK_KEY_V, PEAK_KEY_W, PEAK_KEY_X, PEAK_KEY_Y, PEAK_KEY_Z,
} PeakKeyCode;

typedef enum {
    PEAK_CLIP_CLIPBOARD = 0, /* Ctrl-C/V, OSC 52 */
    PEAK_CLIP_PRIMARY,       /* mouse select, middle paste */
} PeakClip;

typedef enum {
    PEAK_EVENT_NONE = 0,
    PEAK_EVENT_KEY_DOWN,
    PEAK_EVENT_KEY_UP,
    PEAK_EVENT_WINDOW_CLOSE,
    PEAK_EVENT_WINDOW_RESIZE,
    PEAK_EVENT_POINTER,
    PEAK_EVENT_POINTER_CONNECTED,
    PEAK_EVENT_POINTER_DISCONNECTED,
    PEAK_EVENT_CLIP,
    PEAK_EVENT_TEXT,
    PEAK_EVENT_DROP,
    PEAK_EVENT_FOCUS,
    PEAK_EVENT_EXPOSE,
    PEAK_EVENT_LAST
} PeakEventType;

typedef enum {
    PEAK_POINTER_MOVED = 0,
    PEAK_POINTER_PRESSED,
    PEAK_POINTER_RELEASED
} PeakPointerState;

typedef enum {
    PEAK_POINTER_LEFT = 0,
    PEAK_POINTER_RIGHT,
    PEAK_POINTER_MIDDLE,
    PEAK_POINTER_TOUCH,
    PEAK_POINTER_WHEEL_UP,
    PEAK_POINTER_WHEEL_DOWN,
} PeakPointerType;

typedef struct {
    PeakEventType type;
    union {
        struct { PeakKeyCode key; PeakKeyMod mod; uint32_t code; } key;
        struct { uint32_t width, height; } resize;
        struct { PeakPointerState state; PeakPointerType type; float x, y; PeakKeyMod mod; } pointer;
        struct { PeakClip which; size_t n; } clip;
        struct { size_t n; char bytes[64]; } text;
        struct { size_t n; } drop;
        struct { int on; } focus; /* 1 gained, 0 lost */
    };
} PeakEvent;

//       █       █
//               █
// █ █ █ █ ███ ███ ███ █ █ █
// █ █ █ █ █ █ █ █ █ █ █ █ █
// █ █ █ █ █ █ █ █ █ █ █ █ █
//  █ █  █ █ █ ███ ███  █ █

enum PeakWindowFlags {
    PEAK_WINDOW_TRANSPARENT = 1 << 0,
    PEAK_WINDOW_FULLSCREEN  = 1 << 1
};

typedef struct peak_window_internal_t {
    void *w;
} PeakWindowInternal;

typedef struct PeakWindow {
    PeakWindowInternal internal;
    int (*tick)(struct PeakWindow *win, void *userdata);
    void *userdata;
    uint32_t *buffer;
    uint32_t width;
    uint32_t height;
    uint32_t bufsize;
    uint16_t *audio;
    int running;
} PeakWindow;

PEAK PeakWindow peak_window_open(const char *name, uint32_t width, uint32_t height, uint32_t flags);
PEAK void       peak_window_close(PeakWindow *window);
PEAK void       peak_window_run(PeakWindow *win, int (*peak_tick)(PeakWindow *win, void *userdata), void *userdata); /* hijack main loop (web) */
PEAK int        peak_window_epoll(PeakWindow *win, PeakEvent *ev);
PEAK int        peak_window_fd(PeakWindow *win); /* display connection fd, or -1 */
PEAK int        peak_window_pending(PeakWindow *win); /* queued window events; 0 if none */
PEAK uint32_t  *peak_window_backbuffer(PeakWindow *win, size_t *width, size_t *height);
PEAK void       peak_window_clear(PeakWindow *win, float r, float g, float b, float a);
PEAK void       peak_window_present(PeakWindow *win);
/* Present only buffer rows [y, y+h); the rest of the last present is kept.
   Falls back to a full present when the backend cannot keep it. */
PEAK void       peak_window_present_rect(PeakWindow *win, uint32_t y, uint32_t h);
PEAK void       peak_window_set_title(PeakWindow *win, const char *name);
PEAK void       peak_window_set_class(PeakWindow *win, const char *name); /* WM_CLASS / app_id */
PEAK void       peak_window_set_text_input_rect(PeakWindow *win, int x, int y, int w, int h); /* IME cursor cell, buffer pixels, top-left origin; no-op if unsupported */
PEAK void       peak_window_set_opacity(PeakWindow *win, uint8_t alpha); /* 0..255; no-op if the OS has none */
PEAK void       peak_window_set_size(PeakWindow *win, uint32_t width, uint32_t height);
PEAK void       peak_window_fullscreen(PeakWindow *win, int on);
PEAK void       peak_window_cursor(PeakWindow *win, int on); /* 1 show, 0 hide */
/* 0 default, 1 text, 2 hand, 3 wait, 4 crosshair, 5 not-allowed, 6 help */
PEAK void       peak_window_cursor_shape(PeakWindow *win, int shape);
PEAK void       peak_window_pointer_relative(PeakWindow *win, int on); /* 1 deltas, 0 absolute */
PEAK float      peak_window_scale(PeakWindow *win); /* framebuffer / window; 1.0 if unknown */
PEAK unsigned   peak_window_refresh_rate(PeakWindow *win); /* Hz, or 0 if unknown */

//           █ █
//           █
// ███ █ █ ███ █ ███
//   █ █ █ █ █ █ █ █
// ███ █ █ █ █ █ █ █
// ███ ███ ███ █ ███

PEAK int  peak_audio_start(uint32_t channels, uint32_t rate, void (*fill)(int16_t *out, size_t frames, void *userdata), void *userdata); /* device pulls interleaved s16le */
PEAK void peak_audio_stop(void);

//     █
//  █
// ███ █ █████ ███
//  █  █ █ █ █ ███
//  █  █ █ █ █ █
//  ██ █ █ █ █ ███

#define NANOS_PER_SEC 1000000000ull

PEAK uint64_t peak_get_time(void); /* nanoseconds */
PEAK void     peak_sleep_ns(int64_t ns);

//  ██ █ █
//  █    █
// ███ █ █  ███
//  █  █ █  ███
//  █  █ █  █
//  █  █ ██ ███

PEAK int   peak_file_exists(const char *path);
PEAK void *peak_file_alloc(const char *path, unsigned long *buf_size);
PEAK int   peak_file_write(const char *path, const void *buf, size_t n); /* create/overwrite */

/* NOTE(vasco): both these functions are now macros so that they can be replaced 
 * by the peak_debug_ macros */
#if defined(PEAK_WIN32)
#   define peak_aligned_alloc(size, alignment) ((size) ? _aligned_malloc((size), (alignment)) : NULL)
#   define peak_aligned_free(p) do { if (p) _aligned_free(p); } while (0)
#else
#   define peak_aligned_alloc(size, alignment) ((size) ? aligned_alloc((alignment), (size)) : NULL)
#   define peak_aligned_free(p) do { if (p) free(p); } while (0)
#endif

PEAK int peak_pid(void);
PEAK int peak_env_set(const char *name, const char *value); /* NULL unsets */
PEAK int peak_env_get(const char *name, char *buf, size_t cap); /* 1 if set and fits */

PEAK int peak_filesystem_mkdir(const char *path); /* one level */
PEAK int peak_filesystem_rm(const char *path); /* unlink, or rmdir if empty */
PEAK int peak_filesystem_cwd(char *buf, size_t cap);
PEAK int peak_filesystem_chdir(const char *path);
PEAK int peak_filesystem_rename(const char *from, const char *to);
PEAK int peak_filesystem_list(const char *path, int (*fn)(const char *name, void *ud), void *ud); /* fn 0 stops; 1 if opened */
PEAK int peak_filesystem_symlink(const char *target, const char *path);
PEAK int peak_filesystem_readlink(const char *path, char *dst, size_t cap);

// ███ ███ ███ ███
// █ █ █   █ █ █
// █ █ █   █ █ █
// ███ █   ███ ███
// █
// █

typedef struct PeakProc {
    PEAK_HANDLE fd; /* PEAK_HANDLE_INVALID if closed / failed */
    int pid;        /* 0 if none */
} PeakProc;

/* Child + PTY. File descriptor is nonblocking. Fails as PEAK_HANDLE_INVALID. */
PEAK PeakProc peak_pty_spawn(const char *file, const char **argv, uint32_t cols, uint32_t rows, uint32_t xpixel, uint32_t ypixel);
PEAK PeakProc peak_pipe_spawn(const char *file, const char **argv, uint32_t cols, uint32_t rows);
PEAK void     peak_pipe_resize(PeakProc *p, uint32_t cols, uint32_t rows);
PEAK void     peak_pty_resize(PeakProc *pty, uint32_t cols, uint32_t rows, uint32_t xpixel, uint32_t ypixel);
PEAK int      peak_pty_reap(PeakProc *pty); /* 1 if dead */
PEAK void     peak_pty_close(PeakProc *pty);

/* Off-grid shell. */
PEAK PeakProc peak_job_run(const char *cmd, const char *cwd);
PEAK int      peak_job_reap(PeakProc *job, int *code); /* 1 if exited */
PEAK void     peak_job_kill(PeakProc *job);
PEAK int      peak_pid_cwd(int pid, char *buf, size_t cap);

/* Dead-child wakeup. fd pollable or INVALID. Missing OS: arm 1, fd INVALID, reap 0. */
PEAK int         peak_child_arm(void);
PEAK void        peak_child_disarm(void);
PEAK PEAK_HANDLE peak_child_fd(void);
PEAK void        peak_child_ack(void);
PEAK int         peak_child_reap(int *pid, int *code); /* 1 if one */

/* SIGUSR1 wakeup. fd pollable or INVALID. Missing OS: arm 1, fd INVALID, ack 0. */
PEAK int         peak_usr1_arm(void);
PEAK void        peak_usr1_disarm(void);
PEAK PEAK_HANDLE peak_usr1_fd(void);
PEAK int         peak_usr1_ack(void); /* 1 if fired */

PEAK int peak_stdout_silence(void); /* stdout -> platform null */
PEAK int peak_stdout_restore(void);

// █
//
// █ ███
// █ █ █
// █ █ █
// █ ███

/* Sleep until window (nullable) or any fd is ready. timeout_ms: -1 block, 0 poll. 1 if ready. */
PEAK int peak_wait(PeakWindow *win, const PEAK_HANDLE *fds, uint32_t n, int timeout_ms);

/* Local stream (unix socket / named pipe). listen/accept fds are nonblocking. */
PEAK int         peak_runtime_dir(char *buf, size_t cap, const char *app);
PEAK PEAK_HANDLE peak_sock_listen(const char *path);
PEAK PEAK_HANDLE peak_sock_accept(PEAK_HANDLE listen_fd);
PEAK PEAK_HANDLE peak_sock_connect(const char *path);
PEAK int         peak_sock_send(PEAK_HANDLE sock, const void *buf, size_t n, PEAK_HANDLE pass);
PEAK int         peak_sock_recv(PEAK_HANDLE sock, void *buf, size_t n, PEAK_HANDLE *pass);
PEAK int         peak_pointer_pid(PeakWindow *win); /* _NET_WM_PID under pointer; 0 if none */
PEAK int         peak_pointer_local(PeakWindow *win, int *x, int *y); /* 1 if pointer is in this window */

/* Byte IO on Peak fds (pty, sock, job). -1 would-block, 0 EOF, >0 count. */
PEAK int  peak_fd_read(PEAK_HANDLE fd, void *buf, size_t n);
PEAK int  peak_fd_write(PEAK_HANDLE fd, const void *buf, size_t n);
PEAK void peak_fd_close(PEAK_HANDLE fd);
/* Kernel pipe buffer. 0 if not a pipe. set returns the size in force. */
PEAK size_t peak_pipe_capacity(PEAK_HANDLE fd);
PEAK size_t peak_pipe_set_capacity(PEAK_HANDLE fd, size_t n);

//     █
//
// ███ █ ███ ███
// █   █ █ █ █ █
// █   █ █ █ █ █
// █   █ █ █ ███
//             █
//           ███

/* Page-mirrored ring: size must be page-aligned. pointer valid for size*2. */
PEAK size_t peak_page_size(void);
PEAK void  *peak_mirror_map(size_t size);
PEAK void   peak_mirror_unmap(void *p, size_t size);

//      ██
//      █
// ███ ███ █ █
// █ █  █   █
// █ █  █   █
// ███  █  █ █
//   █
// ███

PEAK const char **peak_vulkan_get_extensions(uint32_t *count);
PEAK int          peak_vulkan_create_surface(PeakWindow *win, void *instance, const void *allocator, void *out_surface); /* needs PEAK_VULKAN */

//     █  █
//     █
// ███ █  █ ███
// █   █  █ █ █
// █   █  █ █ █
// ███ ██ █ ███
//          █
//          █

/* UTF-8 clipboard. Cap 1 MiB. win NULL: process-local slot. PRIMARY aliases
 * CLIPBOARD on Win32/macOS/web. request completes as PEAK_EVENT_CLIP; take copies. */
PEAK int peak_clip_set(PeakWindow *win, PeakClip which, const char *utf8, size_t n);
PEAK int peak_clip_request(PeakWindow *win, PeakClip which);
PEAK int peak_clip_take(PeakWindow *win, char *dst, size_t cap, size_t *n);

/* UTF-8 text / drop path. Cap 1 MiB. Completes as PEAK_EVENT_TEXT / DROP; take copies. */
PEAK int peak_text_take(PeakWindow *win, char *dst, size_t cap, size_t *n);
PEAK int peak_drop_take(PeakWindow *win, char *dst, size_t cap, size_t *n);
PEAK int peak_drop_drag(PeakWindow *win, const char *utf8, size_t n); /* start OS drag; 0 if none */

//   █     █
//   █     █
// ███ ███ ███ █ █ ███
// █ █ ███ █ █ █ █ █ █
// █ █ █   █ █ █ █ █ █
// ███ ███ ███ ███ ███
//                   █
//                 ███

typedef enum PeakLogLevel {
    P_LOG_LEVEL_FATAL = 0,
    P_LOG_LEVEL_ERROR,
    P_LOG_LEVEL_WARN,
    P_LOG_LEVEL_INFO,
    P_LOG_LEVEL_DEBUG,
    P_LOG_LEVEL_TRACE,
    P_COUNT_LOG_LEVEL
} PeakLogLevel;

#define P_PREFIX_LEN 7
static const char *p_prefix[P_COUNT_LOG_LEVEL] = {
    [P_LOG_LEVEL_FATAL] = "[FATAL]",
    [P_LOG_LEVEL_ERROR] = "[ERROR]",
    [P_LOG_LEVEL_WARN]  = "[WARNI]",
    [P_LOG_LEVEL_INFO]  = "[INFOR]",
    [P_LOG_LEVEL_DEBUG] = "[DEBUG]",
    [P_LOG_LEVEL_TRACE] = "[TRACE]",
};

#ifndef P_LOG_WARN_ENABLED
#define P_LOG_WARN_ENABLED 1
#endif
#ifndef P_LOG_INFO_ENABLED
#define P_LOG_INFO_ENABLED 1
#endif
#ifndef P_LOG_DEBUG_ENABLED
#define P_LOG_DEBUG_ENABLED 0
#endif
#ifndef P_LOG_TRACE_ENABLED
#define P_LOG_TRACE_ENABLED 0
#endif

#define PFATAL(message, ...) peak_log_printf(P_LOG_LEVEL_FATAL, message, ##__VA_ARGS__)
#define PERROR(message, ...) peak_log_printf(P_LOG_LEVEL_ERROR, message, ##__VA_ARGS__)
#if P_LOG_WARN_ENABLED == 1
#define PWARN(message, ...)  peak_log_printf(P_LOG_LEVEL_WARN, message, ##__VA_ARGS__)
#else
#define PWARN(message, ...)
#endif
#if P_LOG_INFO_ENABLED == 1
#define PINFO(message, ...)  peak_log_printf(P_LOG_LEVEL_INFO, message, ##__VA_ARGS__)
#else
#define PINFO(message, ...)
#endif
#if P_LOG_DEBUG_ENABLED == 1
#define PDEBUG(message, ...) peak_log_printf(P_LOG_LEVEL_DEBUG, message, ##__VA_ARGS__)
#else
#define PDEBUG(message, ...)
#endif
#if P_LOG_TRACE_ENABLED == 1
#define PTRACE(message, ...) peak_log_printf(P_LOG_LEVEL_TRACE, message, ##__VA_ARGS__)
#else
#define PTRACE(message, ...)
#endif

PEAK void  peak_log_printf(PeakLogLevel level, const char *src, ...);
PEAK void *peak_debug_malloc_impl(size_t size, const char *file, int line, const char *func);
PEAK void *peak_debug_calloc_impl(size_t count, size_t size, const char *file, int line, const char *func);
PEAK void  peak_debug_free_impl(void *ptr, const char *file, int line, const char *func);
PEAK void *peak_debug_realloc_impl(void *ptr, size_t size, const char *file, int line, const char *func);
PEAK void  peak_debug_memory_report(void);

#endif /* PEAK_H */


/*
------------------------------------------------------------------------------
MIT License
Copyright (c) 2026 Vasco Alves
Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
------------------------------------------------------------------------------
*/
