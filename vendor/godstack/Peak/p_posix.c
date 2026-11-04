#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <util.h>
#else
#include <pty.h>
#endif
#ifdef __linux__
#include <sys/syscall.h>
long syscall(long number, ...);
#ifndef F_SETPIPE_SZ
#define F_SETPIPE_SZ 1031
#endif
#ifndef F_GETPIPE_SZ
#define F_GETPIPE_SZ 1032
#endif
#endif

#define PEAK_WAIT_MAX 64
#define PEAK_PROC_MAX 32

typedef struct PeakProcRec {
	int used;
	int out;
	int tty;
} PeakProcRec;

static PeakProcRec peak_procs[PEAK_PROC_MAX];

static int peak_internal_nb(int fd);
static PeakProc peak_internal_proc_fail(void);
static void peak_internal_put_size(uint32_t cols, uint32_t rows);
static void peak_internal_winch(int pid);
static int peak_internal_memfd(void);
static size_t peak_internal_io_n(size_t n);
static PeakProcRec *peak_internal_proc_find(int fd);
static PeakProcRec *peak_internal_proc_slot(void);
static void peak_internal_proc_clear(PeakProcRec *r);
static void peak_internal_proc_bind(int out, int tty);
static int peak_internal_read(int fd, void *buf, size_t n);
static void peak_internal_tty_no_opost(int fd);
static void peak_internal_tty_unix(int fd);
static int peak_internal_fast_so(char *dst, size_t cap);
static int peak_internal_status_code(int status);
static void peak_internal_sigchld(int sig);
static void peak_internal_sigusr1(int sig);

static int peak_child_r = -1;
static int peak_child_w = -1;
static int peak_usr1_r = -1;
static int peak_usr1_w = -1;
static int peak_stdout_saved = -1;

static int
peak_internal_nb(int fd)
{
	int flags;

	if (fd < 0)
		return -1;
	flags = fcntl(fd, F_GETFL);
	if (flags >= 0)
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);
	flags = fcntl(fd, F_GETFD);
	if (flags >= 0)
		fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
	return fd;
}

static PeakProc
peak_internal_proc_fail(void)
{
	PeakProc p;

	p.fd = PEAK_HANDLE_INVALID;
	p.pid = 0;
	return p;
}

static void
peak_internal_put_size(uint32_t cols, uint32_t rows)
{
	char col[16];
	char row[16];

	if (!cols)
		cols = 80;
	if (!rows)
		rows = 24;
	snprintf(col, sizeof col, "%u", cols);
	snprintf(row, sizeof row, "%u", rows);
	setenv("COLUMNS", col, 1);
	setenv("LINES", row, 1);
}

static void
peak_internal_winch(int pid)
{
	if (pid <= 0)
		return;
	kill(pid, SIGWINCH);
	kill(-pid, SIGWINCH);
}

static int
peak_internal_memfd(void)
{
#ifdef __linux__
	return (int)syscall(SYS_memfd_create, "peak", 0);
#else
	char name[64];
	int fd;

	snprintf(name, sizeof name, "/peak.%d.%d", (int)getpid(), rand());
	fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
	if (fd >= 0)
		shm_unlink(name);
	return fd;
#endif
}

static size_t
peak_internal_io_n(size_t n)
{
	if (n > (size_t)0x40000000)
		return (size_t)0x40000000;
	return n;
}

static PeakProcRec *
peak_internal_proc_find(int fd)
{
	int i;

	if (fd < 0)
		return NULL;
	for (i = 0; i < PEAK_PROC_MAX; i++) {
		if (peak_procs[i].used && peak_procs[i].out == fd)
			return &peak_procs[i];
	}
	return NULL;
}

static PeakProcRec *
peak_internal_proc_slot(void)
{
	int i;

	for (i = 0; i < PEAK_PROC_MAX; i++) {
		if (!peak_procs[i].used)
			return &peak_procs[i];
	}
	return NULL;
}

static void
peak_internal_proc_clear(PeakProcRec *r)
{
	if (!r)
		return;
	if (r->out >= 0)
		close(r->out);
	if (r->tty >= 0 && r->tty != r->out)
		close(r->tty);
	r->out = -1;
	r->tty = -1;
	r->used = 0;
}

static void
peak_internal_proc_bind(int out, int tty)
{
	PeakProcRec *r;

	if (out < 0 || tty < 0)
		return;
	r = peak_internal_proc_find(out);
	if (!r)
		r = peak_internal_proc_slot();
	if (!r)
		return;
	r->out = out;
	r->tty = tty;
	r->used = 1;
}

static int
peak_internal_read(int fd, void *buf, size_t n)
{
	ssize_t r;

	if (fd < 0 || !buf)
		return 0;
	for (;;) {
		r = read(fd, buf, n);
		if (r > 0)
			return (int)r;
		if (r == 0)
			return 0;
		if (errno == EINTR)
			continue;
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			return -1;
		return 0;
	}
}

void
peak_internal_tty_no_opost(int fd)
{
	struct termios tio;

	if (fd < 0)
		return;
	if (tcgetattr(fd, &tio) < 0)
		return;
	tio.c_oflag &= ~OPOST;
	(void)tcsetattr(fd, TCSANOW, &tio);
}

/* Cooked Unix tty: kernel turns NL into CR NL (ONLCR). Raw apps (nvim) clear
 * OPOST themselves and send LF as terminfo cud1 (index, same column). */
static void
peak_internal_tty_unix(int fd)
{
	struct termios tio;

	if (fd < 0)
		return;
	if (tcgetattr(fd, &tio) < 0)
		return;
	tio.c_oflag |= OPOST | ONLCR;
	(void)tcsetattr(fd, TCSANOW, &tio);
}

static int
peak_internal_status_code(int status)
{
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	if (WIFSIGNALED(status))
		return 128 + WTERMSIG(status);
	return 1;
}

static void
peak_internal_sigchld(int sig)
{
	int saved;
	char x;

	(void)sig;
	saved = errno;
	x = 0;
	if (peak_child_w >= 0)
		(void)write(peak_child_w, &x, 1);
	errno = saved;
}

static void
peak_internal_sigusr1(int sig)
{
	int saved;
	char x;

	(void)sig;
	saved = errno;
	x = 0;
	if (peak_usr1_w >= 0)
		(void)write(peak_usr1_w, &x, 1);
	errno = saved;
}

static int
peak_internal_fast_so(char *dst, size_t cap)
{
	char exe[4096];
	char *slash;
#ifdef __APPLE__
	uint32_t n;

	n = sizeof exe;
	if (_NSGetExecutablePath(exe, &n) != 0)
		return 0;
#else
	ssize_t n;

	n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	if (n <= 0)
		return 0;
	exe[n] = 0;
#endif
	slash = strrchr(exe, '/');
	if (!slash)
		return 0;
	slash[1] = 0;
	if (snprintf(dst, cap, "%svt-fast.so", exe) >= (int)cap)
		return 0;
	return access(dst, R_OK) == 0;
}

PeakProc
peak_pty_spawn(const char *file, const char **argv, uint32_t cols, uint32_t rows, uint32_t xpixel, uint32_t ypixel)
{
	PeakProc p;
	struct winsize ws;
	int master, slave, pid;

	if (!file || !argv)
		return peak_internal_proc_fail();
	memset(&ws, 0, sizeof ws);
	ws.ws_row = (unsigned short)rows;
	ws.ws_col = (unsigned short)cols;
	ws.ws_xpixel = (unsigned short)xpixel;
	ws.ws_ypixel = (unsigned short)ypixel;
	if (openpty(&master, &slave, NULL, NULL, &ws) < 0)
		return peak_internal_proc_fail();
	peak_internal_tty_unix(slave);
	pid = fork();
	if (pid < 0) {
		close(master);
		close(slave);
		return peak_internal_proc_fail();
	}
	if (pid == 0) {
		close(master);
		setsid();
		if (ioctl(slave, TIOCSCTTY, NULL) < 0)
			_Exit(1);
		dup2(slave, STDIN_FILENO);
		dup2(slave, STDOUT_FILENO);
		dup2(slave, STDERR_FILENO);
		if (slave > STDERR_FILENO)
			close(slave);
		peak_internal_put_size(cols, rows);
		execvp(file, (char *const *)argv);
		_Exit(127);
	}
	close(slave);
	p.fd = peak_internal_nb(master);
	p.pid = pid;
	(void)peak_pipe_set_capacity(p.fd, (size_t)1 << 20);
	return p;
}

PeakProc
peak_pipe_spawn(const char *file, const char **argv, uint32_t cols, uint32_t rows)
{
	PeakProc p;
	PeakProcRec *rec;
	struct winsize ws;
	int master, slave;
	int out[2];
	int pid;

	if (!file || !argv)
		return peak_internal_proc_fail();
	peak_internal_put_size(cols, rows);
	rec = peak_internal_proc_slot();
	if (!rec)
		return peak_internal_proc_fail();
	memset(&ws, 0, sizeof ws);
	ws.ws_row = (unsigned short)rows;
	ws.ws_col = (unsigned short)cols;
	if (openpty(&master, &slave, NULL, NULL, &ws) < 0)
		return peak_internal_proc_fail();
	peak_internal_tty_no_opost(slave);
	if (pipe(out) < 0) {
		close(master);
		close(slave);
		return peak_internal_proc_fail();
	}
	(void)peak_pipe_set_capacity(out[0], (size_t)1 << 20);
	(void)peak_pipe_set_capacity(out[1], (size_t)1 << 20);
	pid = fork();
	if (pid < 0) {
		close(master);
		close(slave);
		close(out[0]);
		close(out[1]);
		return peak_internal_proc_fail();
	}
	if (pid == 0) {
		char so[4096];
		char num[32];

		close(master);
		close(out[0]);
		setsid();
		if (ioctl(slave, TIOCSCTTY, NULL) < 0)
			_Exit(1);
		dup2(slave, STDIN_FILENO);
		dup2(out[1], STDOUT_FILENO);
		dup2(slave, STDERR_FILENO);
		fcntl(slave, F_SETFD, 0);
		fcntl(out[1], F_SETFD, 0);
		snprintf(num, sizeof num, "%d", slave);
		setenv("PEAK_FAST_TTY", num, 1);
		snprintf(num, sizeof num, "%d", out[1]);
		setenv("PEAK_FAST_PIPE", num, 1);
		if (peak_internal_fast_so(so, sizeof so)) {
#ifdef __APPLE__
			setenv("DYLD_INSERT_LIBRARIES", so, 1);
			setenv("DYLD_FORCE_FLAT_NAMESPACE", "1", 1);
#else
			{
				const char *old;

				old = getenv("LD_PRELOAD");
				if (old && old[0]) {
					char preload[8192];

					snprintf(preload, sizeof preload, "%s:%s", so, old);
					setenv("LD_PRELOAD", preload, 1);
				} else
					setenv("LD_PRELOAD", so, 1);
			}
#endif
		}
		execvp(file, (char *const *)argv);
		_Exit(127);
	}
	close(slave);
	close(out[1]);
	rec->out = peak_internal_nb(out[0]);
	rec->tty = peak_internal_nb(master);
	rec->used = 1;
	p.fd = rec->out;
	p.pid = pid;
	return p;
}

void
peak_pipe_resize(PeakProc *p, uint32_t cols, uint32_t rows)
{
	if (!p)
		return;
	peak_internal_put_size(cols, rows);
	peak_pty_resize(p, cols, rows, 0, 0);
	peak_internal_winch(p->pid);
}

void
peak_pty_resize(PeakProc *pty, uint32_t cols, uint32_t rows, uint32_t xpixel, uint32_t ypixel)
{
	struct winsize ws;
	PeakProcRec *r;
	int fd;

	if (!pty || pty->fd < 0)
		return;
	fd = pty->fd;
	r = peak_internal_proc_find(fd);
	if (r && r->tty >= 0)
		fd = r->tty;
	memset(&ws, 0, sizeof ws);
	ws.ws_row = (unsigned short)rows;
	ws.ws_col = (unsigned short)cols;
	ws.ws_xpixel = (unsigned short)xpixel;
	ws.ws_ypixel = (unsigned short)ypixel;
	ioctl(fd, TIOCSWINSZ, &ws);
}

int
peak_pty_reap(PeakProc *pty)
{
	int r;

	if (!pty || pty->pid <= 0)
		return 0;
	r = waitpid(pty->pid, NULL, WNOHANG);
	if (r <= 0)
		return 0;
	pty->pid = 0;
	return 1;
}

void
peak_pty_close(PeakProc *pty)
{
	PeakProcRec *r;

	if (!pty)
		return;
	if (pty->fd >= 0) {
		r = peak_internal_proc_find(pty->fd);
		if (r)
			peak_internal_proc_clear(r);
		else
			close(pty->fd);
		pty->fd = PEAK_HANDLE_INVALID;
	}
	if (pty->pid > 0) {
		waitpid(pty->pid, NULL, 0);
		pty->pid = 0;
	}
}

#ifdef PEAK_MACOS
/* A plain poll cannot wake for an AppKit event. Register the PTY descriptors
 * with the main run loop while waiting for an NSEvent, and post a harmless
 * application event when a descriptor becomes readable. Do not consume the
 * event here: the normal window pump owns event dispatch. */
static void
peak_internal_macos_fd_ready(CFFileDescriptorRef fd, CFOptionFlags types, void *info)
{
	(void)fd; (void)types; (void)info;
	NSEvent *ev = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
		location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0
		context:nil subtype:0 data1:0 data2:0];
	[peak_macos_app postEvent:ev atStart:YES];
}

static int
peak_internal_macos_wait(struct pollfd *pfd, uint32_t n, int timeout_ms)
{
	CFFileDescriptorRef descriptors[PEAK_WAIT_MAX] = {0};
	CFRunLoopSourceRef sources[PEAK_WAIT_MAX] = {0};
	CFRunLoopRef loop = CFRunLoopGetCurrent();
	uint32_t i;
	int ready, failed = 0;
	@autoreleasepool {
		ready = poll(pfd, (nfds_t)n, 0);
		if (ready > 0 || timeout_ms == 0) return ready > 0;
		for (i = 0; i < n; i++) {
			descriptors[i] = CFFileDescriptorCreate(NULL, pfd[i].fd, false,
				peak_internal_macos_fd_ready, NULL);
			if (!descriptors[i]) { failed = 1; break; }
			sources[i] = CFFileDescriptorCreateRunLoopSource(NULL, descriptors[i], 0);
			if (!sources[i]) { failed = 1; break; }
			CFRunLoopAddSource(loop, sources[i], kCFRunLoopDefaultMode);
			CFFileDescriptorEnableCallBacks(descriptors[i], kCFFileDescriptorReadCallBack);
		}
		if (!failed) {
			NSDate *until = timeout_ms < 0 ? [NSDate distantFuture] :
				[NSDate dateWithTimeIntervalSinceNow:(double)timeout_ms / 1000.0];
			[peak_macos_app nextEventMatchingMask:NSEventMaskAny untilDate:until
				inMode:NSDefaultRunLoopMode dequeue:NO];
		}
		for (i = 0; i < n; i++) {
			if (sources[i]) { CFRunLoopRemoveSource(loop, sources[i], kCFRunLoopDefaultMode); CFRelease(sources[i]); }
			if (descriptors[i]) { CFFileDescriptorInvalidate(descriptors[i]); CFRelease(descriptors[i]); }
		}
		/* Allocation failure still bounds event latency without losing PTY data. */
		if (failed) return poll(pfd, (nfds_t)n, timeout_ms < 0 || timeout_ms > 2 ? 2 : timeout_ms) > 0;
		return poll(pfd, (nfds_t)n, 0) > 0 ||
			[peak_macos_app nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
				inMode:NSDefaultRunLoopMode dequeue:NO] != nil;
	}
}
#endif

int
peak_wait(PeakWindow *win, const PEAK_HANDLE *fds, uint32_t n, int timeout_ms)
{
	struct pollfd pfd[PEAK_WAIT_MAX];
	PeakProcRec *rec;
	uint32_t i, np;
	int xfd;

	np = 0;
	if (n > PEAK_WAIT_MAX - 2)
		n = PEAK_WAIT_MAX - 2;
	if (win) {
		xfd = peak_window_fd(win);
		if (xfd >= 0) {
			pfd[np].fd = xfd;
			pfd[np].events = POLLIN;
			np++;
		}
		if (peak_window_pending(win) > 0)
			timeout_ms = 0;
	}
	for (i = 0; i < n; i++) {
		if (!fds || fds[i] < 0)
			continue;
		if (np >= PEAK_WAIT_MAX)
			break;
		pfd[np].fd = fds[i];
		pfd[np].events = POLLIN | POLLHUP | POLLERR;
		np++;
		rec = peak_internal_proc_find(fds[i]);
		if (rec && rec->tty >= 0 && rec->tty != fds[i] && np < PEAK_WAIT_MAX) {
			pfd[np].fd = rec->tty;
			pfd[np].events = POLLIN | POLLHUP | POLLERR;
			np++;
		}
	}
	if (!np)
		return 0;
#ifdef PEAK_MACOS
	if (win && peak_macos_app)
		return peak_internal_macos_wait(pfd, np, timeout_ms);
#endif
	return poll(pfd, (nfds_t)np, timeout_ms) > 0;
}

int
peak_runtime_dir(char *buf, size_t cap, const char *app)
{
	const char *rt;
	int n;

	if (!buf || cap < 2 || !app || !app[0])
		return 0;
	rt = getenv("XDG_RUNTIME_DIR");
	if (rt && rt[0])
		n = snprintf(buf, cap, "%s/%s", rt, app);
	else
		n = snprintf(buf, cap, "/tmp/%s-%d", app, (int)getuid());
	if (n < 0 || (size_t)n >= cap)
		return 0;
	if (mkdir(buf, 0700) < 0 && errno != EEXIST)
		return 0;
	return 1;
}

PEAK_HANDLE
peak_sock_listen(const char *path)
{
	struct sockaddr_un addr;
	int fd;
	size_t n;

	if (!path || !path[0])
		return PEAK_HANDLE_INVALID;
	n = strlen(path);
	if (n >= sizeof addr.sun_path)
		return PEAK_HANDLE_INVALID;
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return PEAK_HANDLE_INVALID;
	peak_internal_nb(fd);
	memset(&addr, 0, sizeof addr);
	addr.sun_family = AF_UNIX;
	memcpy(addr.sun_path, path, n + 1);
	unlink(path);
	if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
		close(fd);
		return PEAK_HANDLE_INVALID;
	}
	if (chmod(path, 0600) < 0 || listen(fd, 8) < 0) {
		unlink(path);
		close(fd);
		return PEAK_HANDLE_INVALID;
	}
	return fd;
}

PEAK_HANDLE
peak_sock_accept(PEAK_HANDLE listen_fd)
{
	int fd;

	if (listen_fd < 0)
		return PEAK_HANDLE_INVALID;
	for (;;) {
		fd = accept(listen_fd, NULL, NULL);
		if (fd >= 0)
			return peak_internal_nb(fd);
		if (errno == EINTR)
			continue;
		return PEAK_HANDLE_INVALID;
	}
}

PEAK_HANDLE
peak_sock_connect(const char *path)
{
	struct sockaddr_un addr;
	int fd;
	size_t n;

	if (!path || !path[0])
		return PEAK_HANDLE_INVALID;
	n = strlen(path);
	if (n >= sizeof addr.sun_path)
		return PEAK_HANDLE_INVALID;
	fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0)
		return PEAK_HANDLE_INVALID;
	memset(&addr, 0, sizeof addr);
	addr.sun_family = AF_UNIX;
	memcpy(addr.sun_path, path, n + 1);
	if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
		close(fd);
		return PEAK_HANDLE_INVALID;
	}
	return peak_internal_nb(fd);
}

int
peak_sock_send(PEAK_HANDLE sock, const void *buf, size_t n, PEAK_HANDLE pass)
{
	struct msghdr msg;
	struct iovec iov;
	union {
		struct cmsghdr c;
		char b[CMSG_SPACE(sizeof(int) * 2)];
	} u;
	struct cmsghdr *c;
	PeakProcRec *rec;
	int fds[2];
	int nf;
	ssize_t r;

	if (sock < 0 || !buf || !n)
		return 0;
	memset(&msg, 0, sizeof msg);
	iov.iov_base = (void *)buf;
	iov.iov_len = n;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	if (pass != PEAK_HANDLE_INVALID) {
		nf = 1;
		fds[0] = (int)pass;
		rec = peak_internal_proc_find(pass);
		if (rec && rec->tty >= 0) {
			fds[1] = rec->tty;
			nf = 2;
		}
		memset(&u, 0, sizeof u);
		msg.msg_control = u.b;
		msg.msg_controllen = CMSG_SPACE(sizeof(int) * (size_t)nf);
		c = CMSG_FIRSTHDR(&msg);
		if (!c)
			return 0;
		c->cmsg_level = SOL_SOCKET;
		c->cmsg_type = SCM_RIGHTS;
		c->cmsg_len = CMSG_LEN(sizeof(int) * (size_t)nf);
		memcpy(CMSG_DATA(c), fds, sizeof(int) * (size_t)nf);
	}
	for (;;) {
		r = sendmsg(sock, &msg, 0);
		if (r > 0)
			return 1;
		if (r == 0)
			return 0;
		if (errno == EINTR)
			continue;
		return 0;
	}
}

int
peak_sock_recv(PEAK_HANDLE sock, void *buf, size_t n, PEAK_HANDLE *pass)
{
	struct msghdr msg;
	struct iovec iov;
	union {
		struct cmsghdr c;
		char b[CMSG_SPACE(sizeof(int) * 2)];
	} u;
	struct cmsghdr *c;
	ssize_t r;
	int fds[2];
	int nf;
	int out;
	int tty;

	if (pass)
		*pass = PEAK_HANDLE_INVALID;
	if (sock < 0 || !buf || !n)
		return -1;
	memset(&msg, 0, sizeof msg);
	memset(&u, 0, sizeof u);
	iov.iov_base = buf;
	iov.iov_len = peak_internal_io_n(n);
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = u.b;
	msg.msg_controllen = sizeof u.b;
	for (;;) {
		r = recvmsg(sock, &msg, 0);
		if (r > 0)
			break;
		if (r == 0)
			return 0;
		if (errno == EINTR)
			continue;
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			return -1;
		return 0;
	}
	for (c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
		if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
			continue;
		if (c->cmsg_len < CMSG_LEN(sizeof(int)))
			continue;
		nf = c->cmsg_len >= CMSG_LEN(sizeof(int) * 2) ? 2 : 1;
		memcpy(fds, CMSG_DATA(c), sizeof(int) * (size_t)nf);
		if (fds[0] < 0)
			continue;
		out = peak_internal_nb(fds[0]);
		if (pass && *pass == PEAK_HANDLE_INVALID)
			*pass = out;
		else
			close(out);
		if (nf < 2 || fds[1] < 0)
			continue;
		tty = peak_internal_nb(fds[1]);
		if (pass && *pass == out)
			peak_internal_proc_bind(out, tty);
		else
			close(tty);
	}
	return (int)r;
}

#ifndef PEAK_HAS_POINTER_PID
int
peak_pointer_pid(PeakWindow *win)
{
	(void)win;
	return 0;
}

int
peak_pointer_local(PeakWindow *win, int *x, int *y)
{
	(void)win;
	(void)x;
	(void)y;
	return 0;
}
#endif

int
peak_filesystem_mkdir(const char *path)
{
	if (!path || !path[0])
		return 0;
	return mkdir(path, 0777) == 0;
}

int
peak_filesystem_rm(const char *path)
{
	if (!path || !path[0])
		return 0;
	if (unlink(path) == 0)
		return 1;
	if (errno == EISDIR || errno == EPERM)
		return rmdir(path) == 0;
	return 0;
}

int
peak_filesystem_cwd(char *buf, size_t cap)
{
	if (!buf || cap < 2)
		return 0;
	return getcwd(buf, cap) != NULL;
}

int
peak_filesystem_chdir(const char *path)
{
	if (!path || !path[0])
		return 0;
	return chdir(path) == 0;
}

int
peak_filesystem_rename(const char *from, const char *to)
{
	if (!from || !from[0] || !to || !to[0])
		return 0;
	return rename(from, to) == 0;
}

int
peak_pid(void)
{
	return (int)getpid();
}

int
peak_env_set(const char *name, const char *value)
{
	if (!name || !name[0])
		return 0;
	if (value)
		return setenv(name, value, 1) == 0;
	return unsetenv(name) == 0;
}

int
peak_env_get(const char *name, char *buf, size_t cap)
{
	const char *v;
	size_t n;

	if (!name || !name[0] || !buf || cap < 2)
		return 0;
	v = getenv(name);
	if (!v || !v[0])
		return 0;
	n = strlen(v);
	if (n >= cap)
		return 0;
	memcpy(buf, v, n + 1);
	return 1;
}

int
peak_filesystem_list(const char *path, int (*fn)(const char *name, void *ud), void *ud)
{
	DIR *d;
	struct dirent *e;

	if (!path || !path[0] || !fn)
		return 0;
	d = opendir(path);
	if (!d)
		return 0;
	while ((e = readdir(d))) {
		if (!e->d_name[0])
			continue;
		if (fn(e->d_name, ud) == 0)
			break;
	}
	closedir(d);
	return 1;
}

int
peak_filesystem_symlink(const char *target, const char *path)
{
	if (!target || !target[0] || !path || !path[0])
		return 0;
	return symlink(target, path) == 0;
}

int
peak_filesystem_readlink(const char *path, char *dst, size_t cap)
{
	ssize_t n;

	if (!path || !path[0] || !dst || cap < 2)
		return 0;
	n = readlink(path, dst, cap - 1);
	if (n < 0)
		return 0;
	dst[n] = 0;
	return 1;
}

int
peak_child_arm(void)
{
	int p[2];
	struct sigaction sa;

	if (peak_child_r >= 0)
		return 1;
	if (pipe(p) < 0)
		return 0;
	peak_internal_nb(p[0]);
	peak_internal_nb(p[1]);
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = peak_internal_sigchld;
	sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
	sigemptyset(&sa.sa_mask);
	if (sigaction(SIGCHLD, &sa, NULL) != 0) {
		close(p[0]);
		close(p[1]);
		return 0;
	}
	peak_child_r = p[0];
	peak_child_w = p[1];
	return 1;
}

void
peak_child_disarm(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof sa);
	sa.sa_handler = SIG_DFL;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGCHLD, &sa, NULL);
	if (peak_child_r >= 0) {
		close(peak_child_r);
		peak_child_r = -1;
	}
	if (peak_child_w >= 0) {
		close(peak_child_w);
		peak_child_w = -1;
	}
}

PEAK_HANDLE
peak_child_fd(void)
{
	return peak_child_r >= 0 ? peak_child_r : PEAK_HANDLE_INVALID;
}

void
peak_child_ack(void)
{
	char buf[64];

	if (peak_child_r < 0)
		return;
	while (read(peak_child_r, buf, sizeof buf) > 0)
		;
}

int
peak_usr1_arm(void)
{
	int p[2];
	struct sigaction sa;

	if (peak_usr1_r >= 0)
		return 1;
	if (pipe(p) < 0)
		return 0;
	peak_internal_nb(p[0]);
	peak_internal_nb(p[1]);
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = peak_internal_sigusr1;
	sa.sa_flags = SA_RESTART;
	sigemptyset(&sa.sa_mask);
	if (sigaction(SIGUSR1, &sa, NULL) != 0) {
		close(p[0]);
		close(p[1]);
		return 0;
	}
	peak_usr1_r = p[0];
	peak_usr1_w = p[1];
	return 1;
}

void
peak_usr1_disarm(void)
{
	struct sigaction sa;

	memset(&sa, 0, sizeof sa);
	sa.sa_handler = SIG_DFL;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGUSR1, &sa, NULL);
	if (peak_usr1_r >= 0) {
		close(peak_usr1_r);
		peak_usr1_r = -1;
	}
	if (peak_usr1_w >= 0) {
		close(peak_usr1_w);
		peak_usr1_w = -1;
	}
}

PEAK_HANDLE
peak_usr1_fd(void)
{
	return peak_usr1_r >= 0 ? peak_usr1_r : PEAK_HANDLE_INVALID;
}

int
peak_usr1_ack(void)
{
	char buf[64];
	int n;
	int hit;

	if (peak_usr1_r < 0)
		return 0;
	hit = 0;
	while ((n = (int)read(peak_usr1_r, buf, sizeof buf)) > 0)
		hit = 1;
	return hit;
}

int
peak_child_reap(int *pid, int *code)
{
	int r, status;

	r = waitpid(-1, &status, WNOHANG);
	if (r <= 0)
		return 0;
	if (pid)
		*pid = r;
	if (code)
		*code = peak_internal_status_code(status);
	return 1;
}

int
peak_stdout_silence(void)
{
	int nfd;

	if (peak_stdout_saved >= 0)
		return 1;
	peak_stdout_saved = dup(STDOUT_FILENO);
	if (peak_stdout_saved < 0)
		return 0;
	nfd = open("/dev/null", O_WRONLY);
	if (nfd < 0) {
		close(peak_stdout_saved);
		peak_stdout_saved = -1;
		return 0;
	}
	if (dup2(nfd, STDOUT_FILENO) < 0) {
		close(nfd);
		close(peak_stdout_saved);
		peak_stdout_saved = -1;
		return 0;
	}
	close(nfd);
	return 1;
}

int
peak_stdout_restore(void)
{
	if (peak_stdout_saved < 0)
		return 0;
	fflush(stdout);
	dup2(peak_stdout_saved, STDOUT_FILENO);
	close(peak_stdout_saved);
	peak_stdout_saved = -1;
	return 1;
}

int
peak_fd_read(PEAK_HANDLE fd, void *buf, size_t n)
{
	PeakProcRec *r;
	int got;
	int tgot;

	if (fd < 0 || !buf)
		return 0;
	n = peak_internal_io_n(n);
	r = peak_internal_proc_find(fd);
	got = peak_internal_read(fd, buf, n);
	if (got > 0 || !r || r->tty < 0)
		return got;
	tgot = peak_internal_read(r->tty, buf, n);
	if (tgot > 0)
		return tgot;
	if (got == 0)
		return 0;
	return tgot;
}

int
peak_fd_write(PEAK_HANDLE fd, const void *buf, size_t n)
{
	PeakProcRec *rec;
	ssize_t r;

	if (fd < 0 || !buf)
		return 0;
	rec = peak_internal_proc_find(fd);
	if (rec && rec->tty >= 0)
		fd = rec->tty;
	n = peak_internal_io_n(n);
	for (;;) {
		r = write(fd, buf, n);
		if (r > 0)
			return (int)r;
		if (r == 0)
			return 0;
		if (errno == EINTR)
			continue;
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			return -1;
		return 0;
	}
}

void
peak_fd_close(PEAK_HANDLE fd)
{
	PeakProcRec *r;

	if (fd < 0)
		return;
	r = peak_internal_proc_find(fd);
	if (r) {
		peak_internal_proc_clear(r);
		return;
	}
	close(fd);
}

size_t
peak_pipe_capacity(PEAK_HANDLE fd)
{
#ifdef __linux__
	int r;

	if (fd < 0)
		return 0;
	r = fcntl(fd, F_GETPIPE_SZ);
	if (r > 0)
		return (size_t)r;
#else
	(void)fd;
#endif
	return 0;
}

size_t
peak_pipe_set_capacity(PEAK_HANDLE fd, size_t n)
{
#ifdef __linux__
	int want[4];
	int i;
	int r;

	if (fd < 0)
		return 0;
	want[0] = n > (size_t)0x7fffffff ? 0x7fffffff : (int)n;
	want[1] = 1 << 20;
	want[2] = 65536;
	want[3] = 0;
	for (i = 0; i < 3; i++) {
		if (want[i] < 4096)
			continue;
		r = fcntl(fd, F_SETPIPE_SZ, want[i]);
		if (r > 0)
			return (size_t)r;
	}
#else
	(void)fd;
	(void)n;
#endif
	return 0;
}

PeakProc
peak_job_run(const char *cmd, const char *cwd)
{
	PeakProc p;
	int pipefd[2], pid;

	if (!cmd || !cmd[0])
		return peak_internal_proc_fail();
	if (pipe(pipefd) < 0)
		return peak_internal_proc_fail();
	pid = fork();
	if (pid < 0) {
		close(pipefd[0]);
		close(pipefd[1]);
		return peak_internal_proc_fail();
	}
	if (pid == 0) {
		int nullfd;

		close(pipefd[0]);
		dup2(pipefd[1], STDOUT_FILENO);
		dup2(pipefd[1], STDERR_FILENO);
		if (pipefd[1] > STDERR_FILENO)
			close(pipefd[1]);
		nullfd = open("/dev/null", O_RDONLY);
		if (nullfd >= 0) {
			dup2(nullfd, STDIN_FILENO);
			if (nullfd > STDERR_FILENO)
				close(nullfd);
		}
		if (cwd && cwd[0] && chdir(cwd) < 0) {
			/* inherit parent cwd */
		}
		execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
		_Exit(127);
	}
	close(pipefd[1]);
	(void)peak_pipe_set_capacity(pipefd[0], (size_t)1 << 20);
	p.fd = peak_internal_nb(pipefd[0]);
	p.pid = pid;
	return p;
}

int
peak_job_reap(PeakProc *job, int *code)
{
	int r, status;

	if (!job || job->pid <= 0)
		return 0;
	r = waitpid(job->pid, &status, WNOHANG);
	if (r <= 0)
		return 0;
	job->pid = 0;
	if (code)
		*code = peak_internal_status_code(status);
	return 1;
}

void
peak_job_kill(PeakProc *job)
{
	if (!job)
		return;
	if (job->fd >= 0) {
		close(job->fd);
		job->fd = PEAK_HANDLE_INVALID;
	}
	if (job->pid > 0) {
		kill(job->pid, SIGKILL);
		waitpid(job->pid, NULL, 0);
		job->pid = 0;
	}
}

int
peak_pid_cwd(int pid, char *buf, size_t cap)
{
	char path[64];
	ssize_t n;

	if (pid <= 0 || !buf || cap < 2)
		return 0;
#ifdef __linux__
	snprintf(path, sizeof path, "/proc/%d/cwd", pid);
	n = readlink(path, buf, cap - 1);
	if (n < 0)
		return 0;
	buf[n] = 0;
	return 1;
#else
	(void)path;
	(void)n;
	if (pid != (int)getpid())
		return 0;
	return getcwd(buf, cap) != NULL;
#endif
}

size_t
peak_page_size(void)
{
	long n;

	n = sysconf(_SC_PAGESIZE);
	if (n <= 0)
		return 4096;
	return (size_t)n;
}

void *
peak_mirror_map(size_t size)
{
	int fd;
	char *base;
	void *a, *b;

	if (!size || size % peak_page_size())
		return NULL;
	fd = peak_internal_memfd();
	if (fd < 0 || ftruncate(fd, (off_t)size) < 0) {
		if (fd >= 0)
			close(fd);
		return NULL;
	}
	base = mmap(NULL, size * 2, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (base == MAP_FAILED) {
		close(fd);
		return NULL;
	}
	a = mmap(base, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
	b = mmap(base + size, size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
	close(fd);
	if (a == MAP_FAILED || b == MAP_FAILED) {
		munmap(base, size * 2);
		return NULL;
	}
	return base;
}

void
peak_mirror_unmap(void *p, size_t size)
{
	if (!p || !size)
		return;
	munmap(p, size * 2);
}
