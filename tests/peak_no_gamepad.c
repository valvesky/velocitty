/* cc -Igodstack/Peak tests/peak_no_gamepad.c -o /tmp/velocitty-peak-no-gamepad -ldl -lpthread -lm */
#include <assert.h>
#include <errno.h>
#include <fcntl.h>

static int opens;

static int
tracked_open(const char *path, int flags, ...)
{
	(void)path;
	(void)flags;
	opens++;
	errno = ENOENT;
	return -1;
}

#define open tracked_open
#define PEAK_NO_GAMEPAD
#include "../godstack/Peak/peak.c"
#undef open

int
main(void)
{
	PeakEvent ev, before;

	memset(&ev, 0x5a, sizeof ev);
	memcpy(&before, &ev, sizeof ev);
	for (int i = 0; i < 32; i++)
		assert(!peak_linux_gamepad_poll(&ev));
	assert(!opens); /* No joystick devices are opened, even for polling. */
	assert(!memcmp(&ev, &before, sizeof ev)); /* No synthetic (0,0) click. */
	puts("Peak joystick-disabled tests passed");
	return 0;
}
