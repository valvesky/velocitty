/*
 * macOS window, input, CALayer present, Metal WSI, and AudioQueue.
 * AppKit is Objective-C. This file is compiled as ObjC (clang -x objective-c).
 *
 * * 0.6.0 - @vasco - macos
 */

#include <AppKit/AppKit.h>
#include <AudioToolbox/AudioToolbox.h>
#include <CoreGraphics/CoreGraphics.h>
#include <QuartzCore/QuartzCore.h> /* CATransaction, CAMetalLayer */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef PEAK_VULKAN
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#endif

#define PEAK_AUDIO_FRAMES 256
#define PEAK_AUDIO_BUFFERS 3

struct peak_macos_win {
	NSWindow *window;
	NSView *view;
	CAMetalLayer *layer;
	CGColorSpaceRef color_space;
	id delegate;
	uint32_t *buffer;
	uint32_t width;
	uint32_t height;
	int force_close;
	int flags;
	int cursor_on;
	int relative;
	int touch_n;
	unsigned pointer_buttons;
	unsigned char key_down[128];
	float last_x, last_y;
	int text_rect_set;
	int text_x, text_y, text_w, text_h; /* backing pixels, top-left origin */
	PeakQ q;
};

typedef struct {
	volatile int run;
	AudioQueueRef queue;
	AudioQueueBufferRef buf[PEAK_AUDIO_BUFFERS];
	uint32_t channels;
	uint32_t bytes;
	void (*fill)(int16_t *out, size_t frames, void *userdata);
	void *userdata;
} PeakAudio;

@interface PeakMacDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) struct peak_macos_win *w;
@end

@interface PeakMacView : NSView <NSTextInputClient>
@property(nonatomic, assign) struct peak_macos_win *w;
@property(nonatomic, retain) NSAttributedString *marked;
@property(nonatomic, assign) BOOL key_command;
@property(nonatomic, assign) BOOL key_text;
@property(nonatomic, assign) BOOL key_marked;
@property(nonatomic, assign) NSRange selected;
@end

static int peak_internal_macos_buffer(struct peak_macos_win *w, uint32_t width, uint32_t height);
static PeakKeyCode peak_internal_macos_key_map(unsigned short kc);
static PeakKeyMod peak_internal_macos_mod_map(NSEventModifierFlags flags);
static void peak_internal_macos_key(struct peak_macos_win *w, NSEvent *ev);
static void peak_internal_macos_translate(struct peak_macos_win *w, NSEvent *ev);
static void peak_internal_macos_dispatch(struct peak_macos_win *w, NSEvent *ev);
static void peak_internal_macos_pump(struct peak_macos_win *w);
static void peak_internal_macos_audio_cb(void *ud, AudioQueueRef q, AudioQueueBufferRef buf);
static int peak_platform_init(void);
static void peak_platform_quit(void);
static PeakWindowInternal peak_platform_window_open(const char *name, uint32_t width, uint32_t height, uint32_t flags);
static void peak_platform_window_close(PeakWindowInternal *intern);
static uint32_t *peak_platform_window_buffer(PeakWindowInternal *intern, size_t *width, size_t *height);
static void peak_platform_window_present(PeakWindowInternal *intern);
static bool peak_platform_epoll(PeakWindowInternal *intern, PeakEvent *ev);
static int peak_platform_fd(PeakWindowInternal *intern);
static int peak_platform_pending(PeakWindowInternal *intern);
static int peak_platform_audio_start(uint32_t channels, uint32_t rate, void (*fill)(int16_t *out, size_t frames, void *userdata), void *userdata);
static void peak_platform_audio_stop(void);
static uint64_t peak_platform_get_time(void);
static void peak_platform_sleep_ns(int64_t ns);
static const char **peak_platform_vulkan_get_extensions(uint32_t *count);
static int peak_platform_vulkan_create_surface(PeakWindowInternal *intern, void *instance, const void *allocator, void *out_surface);
static void peak_platform_window_set_title(PeakWindowInternal *intern, const char *name);
static void peak_platform_window_set_size(PeakWindowInternal *intern, uint32_t width, uint32_t height);
static void peak_platform_window_fullscreen(PeakWindowInternal *intern, int on);
static void peak_platform_window_cursor(PeakWindowInternal *intern, int on);
static void peak_platform_window_cursor_shape(PeakWindowInternal *intern, int shape);
static void peak_platform_window_pointer_relative(PeakWindowInternal *intern, int on);
static float peak_platform_window_scale(PeakWindowInternal *intern);
static unsigned peak_platform_window_refresh_rate(PeakWindowInternal *intern);
static void peak_platform_window_set_text_input_rect(PeakWindowInternal *intern, int x, int y, int w, int h);

static NSApplication *peak_macos_app;
static NSAutoreleasePool *peak_macos_pool;
static PeakAudio peak_audio;

static void
peak_platform_window_set_text_input_rect(PeakWindowInternal *intern, int x, int y, int w, int h)
{
	struct peak_macos_win *win = intern ? intern->w : NULL;
	if (!win) return;
	win->text_x = x; win->text_y = y; win->text_w = w > 0 ? w : 1; win->text_h = h > 0 ? h : 1;
	win->text_rect_set = 1;
	[[win->view inputContext] invalidateCharacterCoordinates];
}

static unsigned
peak_platform_window_refresh_rate(PeakWindowInternal *intern)
{
	struct peak_macos_win *w = intern ? intern->w : NULL;
	NSScreen *screen = w ? [w->window screen] : nil;
	if (!screen) return 0;
	if (@available(macOS 12.0, *)) {
		NSInteger hz = [screen maximumFramesPerSecond];
		return hz >= 20 && hz <= 500 ? (unsigned)hz : 0;
	}
	return 0;
}

@implementation PeakMacDelegate
- (void)windowDidExpose:(NSNotification *)notification
{
    (void)notification;
    if (self.w) { PeakEvent ev = {0}; ev.type = PEAK_EVENT_EXPOSE; peak_q_push(&self.w->q, ev); }
}
- (void)windowDidBecomeKey:(NSNotification *)notification
{
    (void)notification;
    if (self.w) { PeakEvent ev = {0}; ev.type = PEAK_EVENT_FOCUS; ev.focus.on = 1; peak_q_push(&self.w->q, ev); }
}
- (void)windowDidResignKey:(NSNotification *)notification
{
    (void)notification;
    if (self.w) {
        self.w->pointer_buttons = 0;
        memset(self.w->key_down, 0, sizeof self.w->key_down);
        PeakEvent ev = {0}; ev.type = PEAK_EVENT_FOCUS; peak_q_push(&self.w->q, ev);
    }
}
- (BOOL)windowShouldClose:(NSWindow *)sender
{
	struct peak_macos_win *w;
	PeakEvent ev;

	(void)sender;
	w = self.w;
	if (!w)
		return YES;
	if (w->force_close)
		return YES;
	memset(&ev, 0, sizeof ev);
	ev.type = PEAK_EVENT_WINDOW_CLOSE;
	peak_q_push(&w->q, ev);
	return NO;
}
@end

@implementation PeakMacView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event
{
    if (!self.w) return;
    BOOL composing = [self hasMarkedText];
    /* These are terminal/application shortcuts outside composition, rather
     * than Cocoa editing commands (Control-C must not become literal text). */
    if (!composing && ([event modifierFlags] & (NSEventModifierFlagControl | NSEventModifierFlagCommand))) {
        peak_internal_macos_key(self.w, event);
        return;
    }
    self.key_command = NO;
    self.key_text = NO;
    self.key_marked = NO;
    BOOL handled = [[self inputContext] handleEvent:event];
    /* A consumed IME key may commit or clear its marked text, so checking
     * only hasMarkedText after interpretation would still leak Return/Esc.
     * Commands returned to the client are terminal keys only outside IME. */
    if (!composing && ![self hasMarkedText] && !self.key_text && !self.key_marked &&
        (!handled || self.key_command))
        peak_internal_macos_key(self.w, event);
}
- (void)keyUp:(NSEvent *)event
{
    if (self.w) peak_internal_macos_key(self.w, event);
}
- (void)doCommandBySelector:(SEL)selector { (void)selector; self.key_command = YES; }
- (void)insertText:(id)value replacementRange:(NSRange)range
{
    (void)range;
    NSString *text = [value isKindOfClass:[NSAttributedString class]] ? [value string] : value;
    const char *utf8 = [text UTF8String];
    if (self.w && utf8 && (unsigned char)utf8[0] >= 32 && (unsigned char)utf8[0] != 127) {
        peak_q_text(&self.w->q, utf8, strlen(utf8));
        self.key_text = YES;
    } else if (utf8 && utf8[0]) self.key_command = YES;
    self.marked = nil;
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selected replacementRange:(NSRange)replacement
{
    (void)replacement;
    self.key_marked = YES;
    self.marked = [value isKindOfClass:[NSAttributedString class]] ? value : [[[NSAttributedString alloc] initWithString:value] autorelease];
    self.selected = selected;
}
- (void)unmarkText { self.key_marked = YES; self.marked = nil; self.selected = NSMakeRange(0, 0); }
- (BOOL)hasMarkedText { return [self.marked length] != 0; }
- (NSRange)markedRange { return [self hasMarkedText] ? NSMakeRange(0, [self.marked length]) : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange
{
    /* Caret inside the preedit (as set by the IME); NSNotFound when idle. */
    return [self hasMarkedText] ? self.selected : NSMakeRange(NSNotFound, 0);
}
- (NSArray *)validAttributesForMarkedText { return [NSArray array]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actual
{
    NSUInteger n = [self.marked length];
    if (!n || range.location == NSNotFound || range.location > n) {
        if (actual) *actual = NSMakeRange(NSNotFound, 0);
        return nil;
    }
    if (range.length > n - range.location) range.length = n - range.location;
    if (actual) *actual = range;
    return [self.marked attributedSubstringFromRange:range];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point { (void)point; return NSNotFound; }
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actual
{
    if (actual) *actual = range;
    /* Candidate window anchor: terminal cursor cell, supplied by the app via
     * peak_platform_window_set_text_input_rect (backing px, top-left origin). */
    NSRect r = NSMakeRect(0, 0, 1, 18);
    struct peak_macos_win *w = self.w;
    if (w && w->text_rect_set) {
        CGFloat sc = [[self window] backingScaleFactor];
        if (sc < 1.0) sc = 1.0;
        CGFloat h = w->text_h / sc;
        r = NSMakeRect(w->text_x / sc, [self bounds].size.height - w->text_y / sc - h, w->text_w / sc, h);
    }
    return [[self window] convertRectToScreen:[self convertRect:r toView:nil]];
}
- (void)dealloc { self.marked = nil; [super dealloc]; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
	(void)sender;
	return NSDragOperationCopy;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
	NSArray *files;
	NSString *p;
	const char *u;
	PeakEvent ev;
	size_t n;

	files = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
	if (!files || ![files count] || !self.w)
		return NO;
	p = [files objectAtIndex:0];
	u = [p UTF8String];
	if (!u)
		return NO;
	n = strlen(u);
	peak_drop_store(u, n);
	memset(&ev, 0, sizeof ev);
	ev.type = PEAK_EVENT_DROP;
	ev.drop.n = n;
	peak_q_push(&self.w->q, ev);
	return YES;
}
@end

static int
peak_internal_macos_buffer(struct peak_macos_win *w, uint32_t width, uint32_t height)
{
	uint32_t *buffer;

	if (!width || !height)
		return 0;
	if (!(buffer = calloc((size_t)width * height, sizeof *buffer)))
		return 0;
	free(w->buffer);
	w->buffer = buffer;
	w->width = width;
	w->height = height;
	return 1;
}

static PeakKeyCode
peak_internal_macos_key_map(unsigned short kc)
{
	switch (kc) {
	case 0x00: return PEAK_KEY_A;
	case 0x0B: return PEAK_KEY_B;
	case 0x08: return PEAK_KEY_C;
	case 0x02: return PEAK_KEY_D;
	case 0x0E: return PEAK_KEY_E;
	case 0x03: return PEAK_KEY_F;
	case 0x05: return PEAK_KEY_G;
	case 0x04: return PEAK_KEY_H;
	case 0x22: return PEAK_KEY_I;
	case 0x26: return PEAK_KEY_J;
	case 0x28: return PEAK_KEY_K;
	case 0x25: return PEAK_KEY_L;
	case 0x2E: return PEAK_KEY_M;
	case 0x2D: return PEAK_KEY_N;
	case 0x1F: return PEAK_KEY_O;
	case 0x23: return PEAK_KEY_P;
	case 0x0C: return PEAK_KEY_Q;
	case 0x0F: return PEAK_KEY_R;
	case 0x01: return PEAK_KEY_S;
	case 0x11: return PEAK_KEY_T;
	case 0x20: return PEAK_KEY_U;
	case 0x09: return PEAK_KEY_V;
	case 0x0D: return PEAK_KEY_W;
	case 0x07: return PEAK_KEY_X;
	case 0x10: return PEAK_KEY_Y;
	case 0x06: return PEAK_KEY_Z;
	case 0x1D: return PEAK_KEY_0;
	case 0x12: return PEAK_KEY_1;
	case 0x13: return PEAK_KEY_2;
	case 0x14: return PEAK_KEY_3;
	case 0x15: return PEAK_KEY_4;
	case 0x17: return PEAK_KEY_5;
	case 0x16: return PEAK_KEY_6;
	case 0x1A: return PEAK_KEY_7;
	case 0x1C: return PEAK_KEY_8;
	case 0x19: return PEAK_KEY_9;
	case 0x7E: return PEAK_KEY_UP;
	case 0x7D: return PEAK_KEY_DOWN;
	case 0x7B: return PEAK_KEY_LEFT;
	case 0x7C: return PEAK_KEY_RIGHT;
	case 0x31: return PEAK_KEY_SPACE;
	case 0x35: return PEAK_KEY_ESCAPE;
	case 0x24: return PEAK_KEY_ENTER;
	case 0x4C: return PEAK_KEY_ENTER;
	case 0x33: return PEAK_KEY_BACKSPACE;
	case 0x30: return PEAK_KEY_TAB;
	case 0x75: return PEAK_KEY_DELETE;
	case 0x72: return PEAK_KEY_INSERT;
	case 0x73: return PEAK_KEY_HOME;
	case 0x77: return PEAK_KEY_END;
	case 0x74: return PEAK_KEY_PAGEUP;
	case 0x79: return PEAK_KEY_PAGEDOWN;
	case 0x7A: return PEAK_KEY_F1;
	case 0x78: return PEAK_KEY_F2;
	case 0x63: return PEAK_KEY_F3;
	case 0x76: return PEAK_KEY_F4;
	case 0x60: return PEAK_KEY_F5;
	case 0x61: return PEAK_KEY_F6;
	case 0x62: return PEAK_KEY_F7;
	case 0x64: return PEAK_KEY_F8;
	case 0x65: return PEAK_KEY_F9;
	case 0x6D: return PEAK_KEY_F10;
	case 0x67: return PEAK_KEY_F11;
	case 0x6F: return PEAK_KEY_F12;
	default: return PEAK_KEY_UNKNOWN;
	}
}

static PeakKeyMod
peak_internal_macos_mod_map(NSEventModifierFlags flags)
{
	PeakKeyMod m;

	m = 0;
	if (flags & NSEventModifierFlagShift)
		m |= PEAK_KEYMOD_SHIFT;
	if (flags & NSEventModifierFlagControl)
		m |= PEAK_KEYMOD_CTRL;
	if (flags & NSEventModifierFlagCommand)
		m |= PEAK_KEYMOD_SUPER;
	if (flags & NSEventModifierFlagOption)
		m |= PEAK_KEYMOD_ALT;
	if (flags & NSEventModifierFlagCapsLock)
		m |= PEAK_KEYMOD_CAPS;
	return m;
}

static void
peak_internal_macos_key(struct peak_macos_win *w, NSEvent *ev)
{
	unsigned short code = [ev keyCode];
	if (code >= sizeof w->key_down) return;
	int pressed = [ev type] == NSEventTypeKeyDown;
	if (!pressed && !w->key_down[code]) return;
	w->key_down[code] = (unsigned char)pressed;
	PeakEvent out = {0};
	out.type = pressed ? PEAK_EVENT_KEY_DOWN : PEAK_EVENT_KEY_UP;
	out.key.key = peak_internal_macos_key_map(code);
	out.key.mod = peak_internal_macos_mod_map([ev modifierFlags]);
	const char *utf8 = [[ev characters] UTF8String];
	out.key.code = (utf8 && utf8[0]) ? (uint32_t)(unsigned char)utf8[0] : 0;
	peak_q_push(&w->q, out);
}

static void
peak_internal_macos_translate(struct peak_macos_win *w, NSEvent *ev)
{
	PeakEvent out;
	NSPoint pt;

    if ([ev window] != w->window) return;
	memset(&out, 0, sizeof out);
	pt = [w->view convertPointToBacking:[w->view convertPoint:[ev locationInWindow] fromView:nil]];
	switch ([ev type]) {
	case NSEventTypeScrollWheel:
        if (pt.x < 0 || pt.y < 0 || pt.x >= w->width || pt.y >= w->height) break;
		out.type = PEAK_EVENT_POINTER;
		out.pointer.state = PEAK_POINTER_PRESSED;
		out.pointer.type = ([ev deltaY] < 0) ? PEAK_POINTER_WHEEL_DOWN : PEAK_POINTER_WHEEL_UP;
		out.pointer.x = (float)pt.x;
		out.pointer.y = (float)((double)w->height - pt.y);
		out.pointer.mod = peak_internal_macos_mod_map([ev modifierFlags]);
		peak_q_push(&w->q, out);
		break;
	case NSEventTypeLeftMouseDown:
	case NSEventTypeRightMouseDown:
	case NSEventTypeOtherMouseDown:
	case NSEventTypeLeftMouseUp:
	case NSEventTypeRightMouseUp:
	case NSEventTypeOtherMouseUp:
	case NSEventTypeMouseMoved:
	case NSEventTypeLeftMouseDragged:
	case NSEventTypeRightMouseDragged:
	case NSEventTypeOtherMouseDragged: {
		NSEventType type = [ev type];
		int pressed = type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown || type == NSEventTypeOtherMouseDown;
		int released = type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseUp || type == NSEventTypeOtherMouseUp;
		int dragged = type == NSEventTypeLeftMouseDragged || type == NSEventTypeRightMouseDragged || type == NSEventTypeOtherMouseDragged;
		unsigned button = (type == NSEventTypeRightMouseDown || type == NSEventTypeRightMouseUp || type == NSEventTypeRightMouseDragged) ? 2u :
			(type == NSEventTypeOtherMouseDown || type == NSEventTypeOtherMouseUp || type == NSEventTypeOtherMouseDragged) ? 4u : 1u;
		int inside = pt.x >= 0 && pt.y >= 0 && pt.x < w->width && pt.y < w->height;
		if (pressed) {
			if (!inside) break;
			w->pointer_buttons |= button;
		} else if (released) {
			if (!(w->pointer_buttons & button)) break;
			w->pointer_buttons &= ~button;
		} else if (dragged) {
			if (!(w->pointer_buttons & button)) break;
		} else if (!inside) break;
		out.type = PEAK_EVENT_POINTER;
		out.pointer.x = (float)pt.x;
		out.pointer.y = (float)((double)w->height - pt.y);
		if (w->relative && ([ev type] == NSEventTypeMouseMoved || [ev type] == NSEventTypeLeftMouseDragged
		    || [ev type] == NSEventTypeRightMouseDragged || [ev type] == NSEventTypeOtherMouseDragged)) {
			out.pointer.x -= w->last_x;
			out.pointer.y -= w->last_y;
		}
		w->last_x = (float)pt.x;
		w->last_y = (float)((double)w->height - pt.y);
		out.pointer.mod = peak_internal_macos_mod_map([ev modifierFlags]);
		if ([ev type] == NSEventTypeMouseMoved || [ev type] == NSEventTypeLeftMouseDragged
		    || [ev type] == NSEventTypeRightMouseDragged || [ev type] == NSEventTypeOtherMouseDragged) {
			out.pointer.state = PEAK_POINTER_MOVED;
			out.pointer.type = ([ev type] == NSEventTypeRightMouseDragged)
				? PEAK_POINTER_RIGHT : ([ev type] == NSEventTypeOtherMouseDragged) ? PEAK_POINTER_MIDDLE : PEAK_POINTER_LEFT;
		} else if ([ev type] == NSEventTypeLeftMouseDown || [ev type] == NSEventTypeRightMouseDown
		    || [ev type] == NSEventTypeOtherMouseDown) {
			out.pointer.state = PEAK_POINTER_PRESSED;
			out.pointer.type = ([ev type] == NSEventTypeRightMouseDown) ? PEAK_POINTER_RIGHT :
			                   ([ev type] == NSEventTypeOtherMouseDown) ? PEAK_POINTER_MIDDLE : PEAK_POINTER_LEFT;
		} else {
			out.pointer.state = PEAK_POINTER_RELEASED;
			out.pointer.type = ([ev type] == NSEventTypeRightMouseUp) ? PEAK_POINTER_RIGHT :
			                   ([ev type] == NSEventTypeOtherMouseUp) ? PEAK_POINTER_MIDDLE : PEAK_POINTER_LEFT;
		}
		peak_q_push(&w->q, out);
		break;
	}
	default:
		break;
	}
}

static void
peak_internal_macos_dispatch(struct peak_macos_win *w, NSEvent *ev)
{
	if ([ev window] == w->window && ([ev type] == NSEventTypeKeyDown || [ev type] == NSEventTypeKeyUp)) {
		if ([ev type] == NSEventTypeKeyDown && ([ev modifierFlags] & NSEventModifierFlagCommand)
		    && ([ev keyCode] == 0x0c || [ev keyCode] == 0x0d)) {
			PeakEvent close = {0}; close.type = PEAK_EVENT_WINDOW_CLOSE; peak_q_push(&w->q, close);
		} else if ([ev type] == NSEventTypeKeyDown) [w->view keyDown:ev];
		else [w->view keyUp:ev];
		return;
	}
	peak_internal_macos_translate(w, ev);
	[peak_macos_app sendEvent:ev];
}

static void
peak_internal_macos_pump(struct peak_macos_win *w)
{
    @autoreleasepool {
	NSEvent *ev;
	NSRect bounds;
	CGFloat scale;
	uint32_t width, height;

	if (!peak_macos_app || !w->window)
		return;
	for (;;) {
		ev = [peak_macos_app nextEventMatchingMask:NSEventMaskAny
			untilDate:[NSDate distantPast]
			inMode:NSDefaultRunLoopMode
			dequeue:YES];
		if (!ev)
			break;
        peak_internal_macos_dispatch(w, ev);
    }
    [peak_macos_app updateWindows];
	bounds = [w->view bounds];
	scale = [w->window backingScaleFactor];
	if (scale < 1.0)
		scale = 1.0;
	width = (uint32_t)(bounds.size.width * scale);
	height = (uint32_t)(bounds.size.height * scale);
	if (width && height && (width != w->width || height != w->height)) {
		PeakEvent evr;

		if (peak_internal_macos_buffer(w, width, height)) {
			memset(&evr, 0, sizeof evr);
			evr.type = PEAK_EVENT_WINDOW_RESIZE;
			evr.resize.width = w->width;
			evr.resize.height = w->height;
			peak_q_push(&w->q, evr);
			w->layer.drawableSize = CGSizeMake((CGFloat)w->width, (CGFloat)w->height);
		}
	}
}

    }

static int
peak_platform_init(void)
{
	if (peak_macos_app)
		return 1;
    if (!peak_macos_pool) peak_macos_pool = [NSAutoreleasePool new];
	/* Without this, NSTextInputClient views show the accent popup on key hold
	 * instead of repeating. registerDefaults keeps a user's explicit choice. */
	[[NSUserDefaults standardUserDefaults] registerDefaults:@{@"ApplePressAndHoldEnabled": @NO}];
	peak_macos_app = [NSApplication sharedApplication];
	if (!peak_macos_app) {
		fputs("Failed to get NSApplication. What system are you fucking using and abusing?", stderr);
		return 0;
	}
	[peak_macos_app setActivationPolicy:NSApplicationActivationPolicyRegular];
	[peak_macos_app finishLaunching];
	return 1;
}

static void
peak_platform_quit(void)
{
    peak_macos_app = nil;
    [peak_macos_pool drain];
    peak_macos_pool = nil;
}

static PeakWindowInternal
peak_platform_window_open(const char *name, uint32_t width, uint32_t height, uint32_t flags)
{
	PeakWindowInternal intern = {0};
	struct peak_macos_win *w;
	PeakMacDelegate *del;
	NSRect rect;

	if (!peak_macos_app && !peak_platform_init())
		return intern;
	if (!(w = calloc(1, sizeof *w)))
		return intern;
	if (!peak_internal_macos_buffer(w, width, height)) {
		free(w);
		return intern;
	}

	rect = NSMakeRect(0, 0, (CGFloat)width, (CGFloat)height);
	w->window = [[NSWindow alloc]
		initWithContentRect:rect
		styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
			| NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
		backing:NSBackingStoreBuffered
		defer:NO];
	if (!w->window) {
		free(w->buffer);
		free(w);
		return intern;
	}
    [w->window setReleasedWhenClosed:NO];
	[w->window setTitle:[NSString stringWithUTF8String:name]];
	w->flags = (int)flags;
	w->cursor_on = 1;
	if (flags & PEAK_WINDOW_TRANSPARENT) {
		[w->window setOpaque:NO];
		[w->window setBackgroundColor:[NSColor clearColor]];
		[w->window setHasShadow:NO];
	}
	if (flags & PEAK_WINDOW_FULLSCREEN)
		[w->window toggleFullScreen:nil];
	[w->window registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
	{
		PeakMacView *view;

		view = [[PeakMacView alloc] initWithFrame:rect];
		view.w = w;
		[w->window setContentView:view];
		w->view = view;
        [view release];
	}
	w->layer = [CAMetalLayer new];
	/* Never animate contents/geometry changes: implicit 0.25s cross-fades are
	 * the "text fades" artifact. Holds even if a present path skips the
	 * CATransaction. */
	{
		id nul = [NSNull null];
		w->layer.actions = @{@"contents": nul, @"bounds": nul, @"position": nul,
			@"contentsScale": nul, @"contentsRect": nul, @"opacity": nul,
			@"onOrderIn": nul, @"onOrderOut": nul, @"sublayers": nul, @"hidden": nul};
	}
	w->layer.contentsGravity = kCAGravityTopLeft;
	w->layer.magnificationFilter = kCAFilterNearest;
	w->layer.minificationFilter = kCAFilterNearest;
	w->layer.contentsScale = [w->window backingScaleFactor] < 1.0 ? 1.0 : [w->window backingScaleFactor];
	[w->view setLayer:w->layer];
	[w->view setWantsLayer:YES];
	[w->view setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawNever];
	if (flags & PEAK_WINDOW_TRANSPARENT)
		w->layer.opaque = NO;
	w->layer.drawableSize = CGSizeMake((CGFloat)width, (CGFloat)height);
	del = [PeakMacDelegate new];
	del.w = w;
	w->delegate = del;
	[w->window setDelegate:del];
    [w->window makeFirstResponder:w->view];
	[w->window setAcceptsMouseMovedEvents:YES];
	[w->window makeKeyAndOrderFront:nil];
	[peak_macos_app activateIgnoringOtherApps:YES];
	intern.w = w;
	return intern;
}

static void
peak_platform_window_close(PeakWindowInternal *intern)
{
	struct peak_macos_win *w;

	w = intern ? intern->w : NULL;
	if (!w)
		return;
	w->force_close = 1;
	if (w->window) {
		[w->window setDelegate:nil];
		[w->window close];
		[w->window release];
	}
	if (w->layer)
		[w->layer release];
	if (w->color_space)
		CGColorSpaceRelease(w->color_space);
	if (w->delegate)
		[w->delegate release];
	free(w->buffer);
	free(w);
	intern->w = NULL;
}

static uint32_t *
peak_platform_window_buffer(PeakWindowInternal *intern, size_t *width, size_t *height)
{
	struct peak_macos_win *w;

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
peak_internal_macos_present_release(void *info, const void *data, size_t size)
{
	(void)info;
	(void)size;
	free((void *)data);
}

static void
peak_platform_window_present(PeakWindowInternal *intern)
{
	struct peak_macos_win *w;
	CGDataProviderRef prov;
	CGImageRef img;
	void *pixels;
	size_t rowbytes, nbytes;

	w = intern ? intern->w : NULL;
	if (!w || !w->layer || !w->buffer)
		return;
	if (!w->width || !w->height || (size_t)w->width > SIZE_MAX / sizeof *w->buffer)
		return;
	rowbytes = (size_t)w->width * sizeof *w->buffer;
	if ((size_t)w->height > SIZE_MAX / rowbytes)
		return;
	nbytes = rowbytes * w->height;
	if (!w->color_space)
		/* sRGB, not DeviceRGB: theme colors are sRGB values. DeviceRGB is
		 * untagged and shown as-is in the display's native gamut, so on
		 * Display P3 panels it looks oversaturated/shifted; a tagged sRGB
		 * image is colour-managed correctly. */
		w->color_space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
	if (!w->color_space) return;
	/* Core Animation may retain the image after this call, across another
	 * draw or resize. The provider must own an immutable frame snapshot. */
	pixels = malloc(nbytes);
	if (!pixels) return;
	memcpy(pixels, w->buffer, nbytes);
	prov = CGDataProviderCreateWithData(NULL, pixels, nbytes, peak_internal_macos_present_release);
	if (!prov) { free(pixels); return; }
	img = CGImageCreate((size_t)w->width, (size_t)w->height, 8, 32, rowbytes, w->color_space,
		kCGBitmapByteOrder32Little | ((w->flags & PEAK_WINDOW_TRANSPARENT)
			? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst),
		prov, NULL, false, kCGRenderingIntentDefault);
	CGDataProviderRelease(prov);
	if (!img) return;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	w->layer.contents = (id)img;
	[CATransaction commit];
	CGImageRelease(img);
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
	NSPasteboard *pb;
	NSString *s;
	char *z;

	(void)intern;
	(void)which;
	z = malloc(n + 1);
	if (!z)
		return 0;
	if (n)
		memcpy(z, utf8, n);
	z[n] = 0;
	s = [[NSString alloc] initWithUTF8String:z];
	free(z);
	if (!s)
		return 0;
	pb = [NSPasteboard generalPasteboard];
	[pb clearContents];
	[pb setString:s forType:NSPasteboardTypeString];
	[s release];
	return 1;
}

static int
peak_platform_clip_request(PeakWindowInternal *intern, PeakClip which)
{
	struct peak_macos_win *w;
	NSPasteboard *pb;
	NSString *s;
	const char *utf8;
	size_t n;
	PeakEvent ev;

	w = intern ? intern->w : NULL;
	if (!w)
		return 0;
	pb = [NSPasteboard generalPasteboard];
	s = [pb stringForType:NSPasteboardTypeString];
	utf8 = s ? [s UTF8String] : "";
	n = utf8 ? strlen(utf8) : 0;
	if (n > PEAK_CLIP_MAX)
		n = PEAK_CLIP_MAX;
	peak_clip_paste_store(which, utf8, n);
	memset(&ev, 0, sizeof ev);
	ev.type = PEAK_EVENT_CLIP;
	ev.clip.which = which;
	ev.clip.n = n;
	peak_q_push(&w->q, ev);
	return 1;
}

static bool
peak_platform_epoll(PeakWindowInternal *intern, PeakEvent *ev)
{
	struct peak_macos_win *w;

	w = intern ? intern->w : NULL;
	if (!w || !w->window)
		return 0;
	if (peak_q_pop(&w->q, ev))
		return 1;
	peak_internal_macos_pump(w);
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
	struct peak_macos_win *w;
	NSEvent *ev;

	w = intern ? intern->w : NULL;
	if (!w)
		return 0;
	if (w->q.n)
		return (int)w->q.n;
	if (!peak_macos_app)
		return 0;
	ev = [peak_macos_app nextEventMatchingMask:NSEventMaskAny
		untilDate:[NSDate distantPast]
		inMode:NSDefaultRunLoopMode
		dequeue:NO];
	return ev ? 1 : 0;
}

static void
peak_internal_macos_audio_cb(void *ud, AudioQueueRef q, AudioQueueBufferRef buf)
{
	(void)ud;
	if (!peak_audio.run)
		return;
	memset(buf->mAudioData, 0, buf->mAudioDataByteSize);
	if (peak_audio.fill)
		peak_audio.fill((int16_t *)buf->mAudioData,
			(size_t)buf->mAudioDataByteSize / (peak_audio.channels * sizeof(int16_t)),
			peak_audio.userdata);
	AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

static int
peak_platform_audio_start(uint32_t channels, uint32_t rate, void (*fill)(int16_t *out, size_t frames, void *userdata), void *userdata)
{
	AudioStreamBasicDescription fmt;
	int i;

	if (channels > 32)
		return 0;
	memset(&fmt, 0, sizeof fmt);
	fmt.mSampleRate = (Float64)rate;
	fmt.mFormatID = kAudioFormatLinearPCM;
	fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
	fmt.mBytesPerPacket = channels * 2;
	fmt.mFramesPerPacket = 1;
	fmt.mBytesPerFrame = channels * 2;
	fmt.mChannelsPerFrame = channels;
	fmt.mBitsPerChannel = 16;
	peak_audio.channels = channels;
	peak_audio.bytes = channels * PEAK_AUDIO_FRAMES * 2;
	peak_audio.fill = fill;
	peak_audio.userdata = userdata;
	peak_audio.run = 1;
	if (AudioQueueNewOutput(&fmt, peak_internal_macos_audio_cb, NULL, NULL, NULL, 0, &peak_audio.queue) != 0)
		goto fail;
	for (i = 0; i < PEAK_AUDIO_BUFFERS; i++) {
		if (AudioQueueAllocateBuffer(peak_audio.queue, peak_audio.bytes, &peak_audio.buf[i]) != 0)
			goto fail;
		peak_audio.buf[i]->mAudioDataByteSize = peak_audio.bytes;
		peak_internal_macos_audio_cb(NULL, peak_audio.queue, peak_audio.buf[i]);
	}
	if (AudioQueueStart(peak_audio.queue, NULL) != 0)
		goto fail;
	return 1;
fail:
	peak_platform_audio_stop();
	return 0;
}

static void
peak_platform_audio_stop(void)
{
	int i;

	peak_audio.run = 0;
	if (peak_audio.queue) {
		AudioQueueStop(peak_audio.queue, 1);
		for (i = 0; i < PEAK_AUDIO_BUFFERS; i++)
			peak_audio.buf[i] = NULL;
		AudioQueueDispose(peak_audio.queue, 1);
		peak_audio.queue = NULL;
	}
	peak_audio.fill = NULL;
	peak_audio.userdata = NULL;
}

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

	if (ns <= 0)
		return;
	ts.tv_sec = ns / 1000000000ll;
	ts.tv_nsec = ns % 1000000000ll;
	nanosleep(&ts, NULL);
}

static const char **
peak_platform_vulkan_get_extensions(uint32_t *count)
{
	static const char *exts[] = {
		"VK_KHR_surface",
		"VK_EXT_metal_surface",
		"VK_KHR_portability_enumeration",
	};
	if (count)
		*count = 3;
	return exts;
}

static int
peak_platform_vulkan_create_surface(PeakWindowInternal *intern, void *instance, const void *allocator, void *out_surface)
{
#ifdef PEAK_VULKAN
	struct peak_macos_win *w;
	VkMetalSurfaceCreateInfoEXT ci;

	w = intern ? intern->w : NULL;
	if (!w || !w->layer)
		return 0;
	memset(&ci, 0, sizeof ci);
	ci.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
	ci.pLayer = (const void *)w->layer;
	return vkCreateMetalSurfaceEXT((VkInstance)instance, &ci,
		(const VkAllocationCallbacks *)allocator, (VkSurfaceKHR *)out_surface) == VK_SUCCESS;
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
	struct peak_macos_win *w;

	w = intern ? intern->w : NULL;
	if (!w || !w->window || !name)
		return;
	[w->window setTitle:[NSString stringWithUTF8String:name]];
}

static void
peak_platform_window_set_size(PeakWindowInternal *intern, uint32_t width, uint32_t height)
{
	struct peak_macos_win *w;
	NSRect r;

	w = intern ? intern->w : NULL;
	if (!w || !w->window)
		return;
	r = [w->window frame];
	r.size.width = (CGFloat)width;
	r.size.height = (CGFloat)height;
	[w->window setFrame:r display:YES];
}

static void
peak_platform_window_fullscreen(PeakWindowInternal *intern, int on)
{
	struct peak_macos_win *w;
	int isfs;

	w = intern ? intern->w : NULL;
	if (!w || !w->window)
		return;
	isfs = ([w->window styleMask] & NSWindowStyleMaskFullScreen) != 0;
	if ((on && !isfs) || (!on && isfs))
		[w->window toggleFullScreen:nil];
}

static void
peak_platform_window_cursor(PeakWindowInternal *intern, int on)
{
	struct peak_macos_win *w;

	w = intern ? intern->w : NULL;
	if (!w)
		return;
	w->cursor_on = on;
	if (on)
		[NSCursor unhide];
	else
		[NSCursor hide];
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
	struct peak_macos_win *w;

	w = intern ? intern->w : NULL;
	if (!w)
		return;
	w->relative = on;
	if (on)
		CGAssociateMouseAndMouseCursorPosition(false);
	else
		CGAssociateMouseAndMouseCursorPosition(true);
}

static float
peak_platform_window_scale(PeakWindowInternal *intern)
{
	struct peak_macos_win *w;
	CGFloat s;

	w = intern ? intern->w : NULL;
	if (!w || !w->window)
		return 1.f;
	s = [w->window backingScaleFactor];
	return s > 0 ? (float)s : 1.f;
}

#include "p_posix.c"
