/* Native event dispatch with a deterministic input method: consumed control
 * keys must not reach the PTY, even when the method commits/unmarks text. */
enum {
    MAC_INPUT_COMMAND,
    MAC_INPUT_TEXT,
    MAC_INPUT_MARK,
    MAC_INPUT_CONSUME,
    MAC_INPUT_COMMIT,
    MAC_INPUT_CANCEL,
    MAC_INPUT_UNHANDLED,
};

@interface PeakMacTestInputContext : NSTextInputContext
@property(nonatomic, assign) PeakMacView *view;
@property(nonatomic, assign) int action;
@property(nonatomic, assign) unsigned calls;
@end

@implementation PeakMacTestInputContext
- (BOOL)handleEvent:(NSEvent *)event
{
    self.calls++;
    switch (self.action) {
    case MAC_INPUT_COMMAND: [self.view doCommandBySelector:@selector(insertNewline:)]; break;
    case MAC_INPUT_TEXT: [self.view insertText:[event characters] replacementRange:NSMakeRange(NSNotFound, 0)]; break;
    case MAC_INPUT_MARK: [self.view setMarkedText:@"あ" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)]; break;
    case MAC_INPUT_CONSUME: break;
    case MAC_INPUT_COMMIT: [self.view insertText:@"あ" replacementRange:NSMakeRange(NSNotFound, 0)]; break;
    case MAC_INPUT_CANCEL: [self.view unmarkText]; break;
    case MAC_INPUT_UNHANDLED: return NO;
    }
    return YES;
}
@end

@interface PeakMacTestView : PeakMacView
@property(nonatomic, retain) NSTextInputContext *test_context;
@end

@implementation PeakMacTestView
- (NSTextInputContext *)inputContext { return self.test_context; }
- (void)dealloc { self.test_context = nil; [super dealloc]; }
@end

static NSEvent *macos_test_key(struct peak_macos_win *w, NSEventType type, unsigned short code, NSEventModifierFlags flags, NSString *text)
{
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:0
        windowNumber:[w->window windowNumber] context:nil characters:text charactersIgnoringModifiers:text
        isARepeat:NO keyCode:code];
}

static void macos_test_key_pair(struct peak_macos_win *w, unsigned short code, NSEventModifierFlags flags, NSString *text)
{
    peak_internal_macos_dispatch(w, macos_test_key(w, NSEventTypeKeyDown, code, flags, text));
    peak_internal_macos_dispatch(w, macos_test_key(w, NSEventTypeKeyUp, code, flags, text));
}

static void macos_input_test(struct peak_macos_win *w)
{
    PeakEvent ev;
    NSView *original = [w->view retain];
    PeakMacTestView *view = [[PeakMacTestView alloc] initWithFrame:[original frame]];
    PeakMacTestInputContext *context = [[PeakMacTestInputContext alloc] initWithClient:view];
    view.w = w;
    context.view = view;
    view.test_context = context;
    [w->window setContentView:view];
    w->view = view;
    [w->window makeFirstResponder:view];
    w->q.n = 0; w->q.h = 0;

    /* The input system returns ordinary editing commands to the terminal. */
    context.action = MAC_INPUT_COMMAND;
    const unsigned short codes[] = {0x24, 0x33, 0x30, 0x7e, 0x35};
    const PeakKeyCode keys[] = {PEAK_KEY_ENTER, PEAK_KEY_BACKSPACE, PEAK_KEY_TAB, PEAK_KEY_UP, PEAK_KEY_ESCAPE};
    for (size_t i = 0; i < sizeof codes / sizeof codes[0]; i++) {
        macos_test_key_pair(w, codes[i], NSEventModifierFlagShift, @"\r");
        assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_DOWN && ev.key.key == keys[i]);
        assert(ev.key.mod & PEAK_KEYMOD_SHIFT);
        assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_UP && ev.key.key == keys[i]);
        assert(!peak_q_pop(&w->q, &ev));
    }

    /* Terminal/application shortcuts retain their native modifier bytes. */
    unsigned calls = context.calls;
    macos_test_key_pair(w, 0x08, NSEventModifierFlagControl, @"\x03");
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_DOWN && ev.key.code == 3 && (ev.key.mod & PEAK_KEYMOD_CTRL));
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_UP);
    macos_test_key_pair(w, 0x08, NSEventModifierFlagCommand, @"c");
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_DOWN && ev.key.key == PEAK_KEY_C && (ev.key.mod & PEAK_KEYMOD_SUPER));
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_UP);
    macos_test_key_pair(w, 0x09, NSEventModifierFlagCommand, @"v");
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_DOWN && ev.key.key == PEAK_KEY_V);
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_UP);
    assert(context.calls == calls && !peak_q_pop(&w->q, &ev));

    context.action = MAC_INPUT_TEXT;
    macos_test_key_pair(w, 0x00, 0, @"a");
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.n == 1 && ev.text.bytes[0] == 'a');
    assert(!peak_q_pop(&w->q, &ev));

    /* Option composition, navigation and confirmation run through the same
     * dispatcher as real events. Key-up must not escape a consumed press. */
    context.action = MAC_INPUT_MARK;
    macos_test_key_pair(w, 0x0e, NSEventModifierFlagOption, @"´");
    assert([view hasMarkedText] && !peak_q_pop(&w->q, &ev));
    context.action = MAC_INPUT_CONSUME;
    macos_test_key_pair(w, 0x7e, 0, @"\uf700");
    macos_test_key_pair(w, 0x33, 0, @"\x7f");
    assert([view hasMarkedText] && !peak_q_pop(&w->q, &ev));
    context.action = MAC_INPUT_COMMIT;
    macos_test_key_pair(w, 0x24, 0, @"\r");
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_TEXT && ev.text.n == 3);
    assert(memcmp(ev.text.bytes, "\xe3\x81\x82", 3) == 0);
    assert(![view hasMarkedText] && !peak_q_pop(&w->q, &ev));

    context.action = MAC_INPUT_MARK;
    macos_test_key_pair(w, 0x00, 0, @"a");
    context.action = MAC_INPUT_CANCEL;
    macos_test_key_pair(w, 0x35, 0, @"\x1b");
    assert(![view hasMarkedText] && !peak_q_pop(&w->q, &ev));

    /* Input methods may consume keys without publishing marked text. */
    context.action = MAC_INPUT_CONSUME;
    macos_test_key_pair(w, 0x24, 0, @"\r");
    assert(!peak_q_pop(&w->q, &ev));
    context.action = MAC_INPUT_UNHANDLED;
    macos_test_key_pair(w, 0x24, 0, @"\r");
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_DOWN && ev.key.key == PEAK_KEY_ENTER);
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_KEY_UP && ev.key.key == PEAK_KEY_ENTER);
    assert(!peak_q_pop(&w->q, &ev));

    [w->window setContentView:original];
    w->view = original;
    [w->window makeFirstResponder:original];
    [original release];
    view.test_context = nil;
    context.view = nil;
    [context release];
    [view release];
}

static NSEvent *macos_test_mouse(struct peak_macos_win *w, NSEventType type, NSPoint point)
{
    return [NSEvent mouseEventWithType:type location:[w->view convertPoint:point toView:nil]
        modifierFlags:0 timestamp:0 windowNumber:[w->window windowNumber] context:nil
        eventNumber:1 clickCount:1 pressure:0];
}

static void macos_pointer_test(struct peak_macos_win *w)
{
    PeakEvent ev;
    assert([w->window acceptsMouseMovedEvents]);
    w->q.n = 0; w->q.h = 0;
    peak_internal_macos_translate(w, macos_test_mouse(w, NSEventTypeMouseMoved, NSMakePoint(10, 10)));
    assert(peak_q_pop(&w->q, &ev) && ev.type == PEAK_EVENT_POINTER && ev.pointer.state == PEAK_POINTER_MOVED);

    const NSEventType down[] = {NSEventTypeLeftMouseDown, NSEventTypeRightMouseDown, NSEventTypeOtherMouseDown};
    const NSEventType drag[] = {NSEventTypeLeftMouseDragged, NSEventTypeRightMouseDragged, NSEventTypeOtherMouseDragged};
    const NSEventType up[] = {NSEventTypeLeftMouseUp, NSEventTypeRightMouseUp, NSEventTypeOtherMouseUp};
    const PeakPointerType button[] = {PEAK_POINTER_LEFT, PEAK_POINTER_RIGHT, PEAK_POINTER_MIDDLE};
    for (size_t i = 0; i < 3; i++) {
        peak_internal_macos_translate(w, macos_test_mouse(w, down[i], NSMakePoint(10, 10)));
        assert(peak_q_pop(&w->q, &ev) && ev.pointer.state == PEAK_POINTER_PRESSED && ev.pointer.type == button[i]);
        peak_internal_macos_translate(w, macos_test_mouse(w, drag[i], NSMakePoint(-10, -10)));
        assert(peak_q_pop(&w->q, &ev) && ev.pointer.state == PEAK_POINTER_MOVED && ev.pointer.type == button[i]);
        assert(ev.pointer.x < 0 && ev.pointer.y > w->height);
        peak_internal_macos_translate(w, macos_test_mouse(w, up[i], NSMakePoint(-10, -10)));
        assert(peak_q_pop(&w->q, &ev) && ev.pointer.state == PEAK_POINTER_RELEASED && ev.pointer.type == button[i]);
        assert(!w->pointer_buttons && !peak_q_pop(&w->q, &ev));
        peak_internal_macos_translate(w, macos_test_mouse(w, down[i], NSMakePoint(-10, -10)));
        peak_internal_macos_translate(w, macos_test_mouse(w, drag[i], NSMakePoint(-10, -10)));
        peak_internal_macos_translate(w, macos_test_mouse(w, up[i], NSMakePoint(-10, -10)));
        assert(!w->pointer_buttons && !peak_q_pop(&w->q, &ev));
    }
}
