/* Headless regression tests for Peak's Wayland click routing.
 * cc -Igodstack/Peak tests/peak_pointer.c -o /tmp/peak-pointer -ldl -lpthread -lm
 */
#include "../godstack/Peak/peak.c"
#include <assert.h>

static int geometry, input, destroyed;
static struct wl_proxy *marshal(struct wl_proxy *p, uint32_t op,
    const struct wl_interface *iface, uint32_t version, uint32_t flags,
    union wl_argument *a)
{
    (void)iface; (void)version; (void)flags;
    if (p == (struct wl_proxy *)1 && op == 3) {
        assert(a[2].i == 100 && a[3].i == 80);
        geometry++;
    }
    if (p == (struct wl_proxy *)2 && op == 1) {
        assert(a[2].i == 100 && a[3].i == 80);
    }
    if (p == (struct wl_proxy *)3 && op == 5) {
        assert(a[0].o == (struct wl_object *)2);
        input++;
    }
    if (p == (struct wl_proxy *)2 && op == 0) destroyed++;
    return (struct wl_proxy *)2;
}
static uint32_t version(struct wl_proxy *p) { (void)p; return 1; }
static void destroy(struct wl_proxy *p) { (void)p; }

int main(void)
{
    struct peak_wayland_win w = {0};
    w.logical_w = 100; w.logical_h = 80;
    w.width = 200; w.height = 160; /* 2x framebuffer is NOT the hit box. */
    w.surface = (struct wl_surface *)3;
    w.xdg_surface = (struct xdg_surface *)1;
    w.attached_w = 200;
    peak_wayland.compositor = (struct wl_compositor *)4;
    wl_region_interface.name = "wl_region";
    peak_wl.wl_proxy_marshal_array_flags = marshal;
    peak_wl.wl_proxy_get_version = version;
    peak_wl.wl_proxy_destroy = destroy;
    peak_wayland_clip_input(&w);
    assert(geometry == 1 && input == 1 && destroyed == 1);

    assert(peak_wayland_ptr_inside(&w, 0, 0));
    assert(peak_wayland_ptr_inside(&w, 99.5f, 79.5f));
    assert(!peak_wayland_ptr_inside(&w, -0.5f, 10));
    assert(!peak_wayland_ptr_inside(&w, 100, 10));
    assert(!peak_wayland_ptr_inside(&w, 10, 80));
    assert(!peak_wayland_ptr_inside(&w, 150, 10));

    peak_wayland.wins[0] = &w;
    peak_wayland_pointer_enter(NULL, NULL, 1, w.surface,
        wl_fixed_from_int(90), wl_fixed_from_int(40));
    peak_wayland_pointer_button(NULL, NULL, 2, 0, BTN_SIDE, 1);
    assert(w.q.n == 0); /* Extra buttons must not become left clicks. */
    peak_wayland_pointer_button(NULL, NULL, 3, 0, BTN_LEFT, 1);
    assert(w.q.n == 1 && peak_wayland.buttons == 1);
    assert(w.q.e[0].pointer.x == 180);
    w.logical_w = 50; /* Configure without motion, then another click. */
    peak_wayland_pointer_button(NULL, NULL, 4, 0, BTN_LEFT, 1);
    assert(w.q.n == 2 && peak_wayland.buttons == 0);
    assert(w.q.e[1].pointer.state == PEAK_POINTER_RELEASED);
    peak_wayland_wheel(&w, 1, 1);
    assert(w.q.n == 2);

    w.logical_w = 100;
    peak_wayland_pointer_enter(NULL, NULL, 5, w.surface,
        wl_fixed_from_int(20), wl_fixed_from_int(20));
    peak_wayland_pointer_button(NULL, NULL, 6, 0, BTN_LEFT, 1);
    peak_wayland_pointer_leave(NULL, NULL, 7, w.surface);
    assert(peak_wayland.hover == NULL && peak_wayland.buttons == 0);
    unsigned n = w.q.n;
    peak_wayland_pointer_button(NULL, NULL, 8, 0, BTN_LEFT, 1);
    peak_wayland_wheel(&w, 1, 1);
    assert(w.q.n == n); /* Other applications' input stays out. */
    puts("Peak Wayland pointer tests passed");
    return 0;
}
