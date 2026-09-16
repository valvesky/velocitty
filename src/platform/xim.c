/* XCreateIC is varargs; keep the nested-list setup in C. */
#include <X11/Xlib.h>

XIC zt_create_ic(XIM xim, Window win) {
    if (!xim) return NULL;
    return XCreateIC(
        xim,
        XNInputStyle, XIMPreeditNothing | XIMStatusNothing,
        XNClientWindow, win,
        XNFocusWindow, win,
        (void *)0);
}
