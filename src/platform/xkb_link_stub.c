/* Link-time stubs. Not shipped; the target's libxkbcommon.so.0
 * satisfies these at runtime. Used for every arch: host libxkbcommon
 * needs glibc symbols Zig's libc does not provide. */
#define S(name) void name(void) {}

S(xkb_context_new)
S(xkb_context_unref)
S(xkb_compose_table_new_from_locale)
S(xkb_compose_table_unref)
S(xkb_compose_state_new)
S(xkb_compose_state_unref)
S(xkb_compose_state_feed)
S(xkb_compose_state_get_status)
S(xkb_compose_state_get_utf8)
S(xkb_compose_state_reset)
S(xkb_keysym_to_utf8)
