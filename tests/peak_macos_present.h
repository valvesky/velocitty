/* Included by peak_native.c after Peak's macOS implementation. */
static void macos_image_pixels_test(CGImageRef image, const uint32_t *expected, size_t n)
{
    CFDataRef pixels = CGDataProviderCopyData(CGImageGetDataProvider(image));
    assert(pixels && CFDataGetLength(pixels) == (CFIndex)(n * sizeof *expected));
    assert(memcmp(CFDataGetBytePtr(pixels), expected, n * sizeof *expected) == 0);
    CFRelease(pixels);
}

static void macos_present_test(void)
{
    const uint32_t first_pixels[] = {0xff010203, 0xff405060, 0xff708090, 0xffa0b0c0};
    const uint32_t next_pixels[] = {0xffabcdef, 0xff123456, 0xff6789ab, 0xfffedcba};
    PeakWindow win = {0};
    struct peak_macos_win *w = calloc(1, sizeof *w);
    assert(w);
    win.internal.w = w;
    w->layer = [CAMetalLayer new];
    assert(w->layer && peak_internal_macos_buffer(w, 2, 2));

    memcpy(w->buffer, first_pixels, sizeof first_pixels);
    peak_window_present(&win);
    CGImageRef first = (CGImageRef)w->layer.contents;
    assert(first && CGImageGetWidth(first) == 2 && CGImageGetHeight(first) == 2);
    CGImageRetain(first);

    /* An outstanding image must not follow writes to the next frame. */
    memcpy(w->buffer, next_pixels, sizeof next_pixels);
    macos_image_pixels_test(first, first_pixels, 4);
    peak_window_present(&win);
    CGImageRef next = (CGImageRef)w->layer.contents;
    assert(next && next != first);
    CGImageRetain(next);
    macos_image_pixels_test(first, first_pixels, 4);
    macos_image_pixels_test(next, next_pixels, 4);

    /* Invalid geometry must preserve the displayed image without reading
     * beyond the current framebuffer or attempting a wrapped allocation. */
    w->width = 0;
    peak_window_present(&win);
    assert((CGImageRef)w->layer.contents == next);
    w->width = UINT32_MAX;
    w->height = UINT32_MAX;
    peak_window_present(&win);
    assert((CGImageRef)w->layer.contents == next);

    assert(peak_internal_macos_buffer(w, 3, 2));
    memset(w->buffer, 0, 3 * 2 * sizeof *w->buffer);
    macos_image_pixels_test(first, first_pixels, 4);
    macos_image_pixels_test(next, next_pixels, 4);
    peak_window_present(&win);
    peak_window_close(&win);

    /* Retained images also own their data after the window and its buffer
     * have gone away. Their providers release the snapshots with the images. */
    macos_image_pixels_test(first, first_pixels, 4);
    macos_image_pixels_test(next, next_pixels, 4);
    CGImageRelease(first);
    CGImageRelease(next);
}
