#include <fcntl.h>
#include <io.h>

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif

#ifndef HPCON
typedef HANDLE HPCON;
#endif

#define PEAK_PROC_MAX 32
#define PEAK_WAIT_SLICE 1

typedef HRESULT (WINAPI *PeakCreatePseudoConsole)(COORD, HANDLE, HANDLE, DWORD, HPCON *);
typedef HRESULT (WINAPI *PeakResizePseudoConsole)(HPCON, COORD);
typedef void (WINAPI *PeakClosePseudoConsole)(HPCON);

#define PEAK_WRITE_CAPACITY 65536

typedef struct PeakProcRec {
    HANDLE writer, write_event, closer;
    HPCON closing_pc;
    CRITICAL_SECTION write_lock;
    int write_lock_live, write_closed;
    size_t write_head, write_len;
    unsigned char write_buf[PEAK_WRITE_CAPACITY];
	HANDLE read;
	HANDLE write;
	HANDLE proc;
	HPCON pc;
	int pid;
} PeakProcRec;

static PeakProcRec peak_procs[PEAK_PROC_MAX];
static PeakCreatePseudoConsole peak_create_pc;
static PeakResizePseudoConsole peak_resize_pc;
static PeakClosePseudoConsole peak_close_pc;
static int peak_conpty_tried;
static char peak_pipe_name[MAX_PATH];
static int peak_stdout_saved = -1;

static PeakProc peak_internal_proc_fail(void);
static void peak_internal_conpty_load(void);
static PeakProcRec *peak_internal_proc_find(HANDLE h);
static PeakProcRec *peak_internal_proc_slot(void);
static void peak_internal_proc_clear(PeakProcRec *r);
static int peak_internal_join_argv(char *out, size_t cap, const char *file, const char **argv);
static HANDLE peak_internal_write_handle(PEAK_HANDLE fd);
static int peak_internal_pipe_ready(HANDLE h);
static void peak_internal_pipe_name(const char *path, char *out, size_t cap);
static size_t peak_internal_io_n(size_t n);

static PeakProc
peak_internal_proc_fail(void)
{
	PeakProc p;

	p.fd = PEAK_HANDLE_INVALID;
	p.pid = 0;
	return p;
}

static void
peak_internal_conpty_load(void)
{
	HMODULE k;

	if (peak_conpty_tried)
		return;
	peak_conpty_tried = 1;
	k = GetModuleHandleA("kernel32.dll");
	if (!k)
		return;
	peak_create_pc = (PeakCreatePseudoConsole)(void *)GetProcAddress(k, "CreatePseudoConsole");
	peak_resize_pc = (PeakResizePseudoConsole)(void *)GetProcAddress(k, "ResizePseudoConsole");
	peak_close_pc = (PeakClosePseudoConsole)(void *)GetProcAddress(k, "ClosePseudoConsole");
}

static PeakProcRec *
peak_internal_proc_find(HANDLE h)
{
	int i;

	if (!h || h == INVALID_HANDLE_VALUE)
		return NULL;
	for (i = 0; i < PEAK_PROC_MAX; i++) {
		if (peak_procs[i].read == h)
			return &peak_procs[i];
	}
	return NULL;
}

static PeakProcRec *
peak_internal_proc_slot(void)
{
	int i;

	for (i = 0; i < PEAK_PROC_MAX; i++) {
		if (!peak_procs[i].read)
			return &peak_procs[i];
	}
	return NULL;
}

static DWORD WINAPI
peak_internal_close_console(LPVOID userdata)
{
    PeakProcRec *r = userdata;
    peak_close_pc(r->closing_pc);
    return 0;
}

static DWORD WINAPI
peak_internal_writer(LPVOID userdata)
{
    PeakProcRec *r = userdata;
    for (;;) {
        WaitForSingleObject(r->write_event, INFINITE);
        for (;;) {
            DWORD got = 0;
            size_t n, head;
            EnterCriticalSection(&r->write_lock);
            if (r->write_closed) { LeaveCriticalSection(&r->write_lock); return 0; }
            n = r->write_len;
            head = r->write_head;
            if (n > PEAK_WRITE_CAPACITY - head) n = PEAK_WRITE_CAPACITY - head;
            LeaveCriticalSection(&r->write_lock);
            if (!n) break;
            int ok = WriteFile(r->write, r->write_buf + head, (DWORD)n, &got, NULL);
            EnterCriticalSection(&r->write_lock);
            if (!ok || !got) r->write_closed = 1;
            else { r->write_head = (head + got) % PEAK_WRITE_CAPACITY; r->write_len -= got; }
            int closed = r->write_closed;
            LeaveCriticalSection(&r->write_lock);
            if (closed) return 0;
        }
    }
}

static void
peak_internal_proc_clear(PeakProcRec *r)
{
    if (!r) return;
    if (r->write_lock_live) {
        EnterCriticalSection(&r->write_lock);
        r->write_closed = 1;
        LeaveCriticalSection(&r->write_lock);
        if (r->write_event) SetEvent(r->write_event);
        if (r->writer) {
            /* Repeat cancellation to cover a worker entering WriteFile just
             * after the first cancellation, without blocking the UI thread. */
            while (WaitForSingleObject(r->writer, 10) == WAIT_TIMEOUT) CancelSynchronousIo(r->writer);
            CloseHandle(r->writer);
        }
        if (r->write_event) CloseHandle(r->write_event);
        DeleteCriticalSection(&r->write_lock);
    }
	if (r->write && r->write != r->read && r->write != INVALID_HANDLE_VALUE)
		CloseHandle(r->write);
    if (r->closer) { WaitForSingleObject(r->closer, INFINITE); CloseHandle(r->closer); }
	if (r->pc && peak_close_pc)
		peak_close_pc(r->pc);
	if (r->proc)
		CloseHandle(r->proc);
	memset(r, 0, sizeof *r);
}

static size_t
peak_internal_io_n(size_t n)
{
	if (n > (size_t)0x40000000)
		return (size_t)0x40000000;
	return n;
}

static int
peak_internal_quote_arg(char *out, size_t cap, size_t *n, const char *arg)
{
    if (*n && *n + 1 < cap) out[(*n)++] = ' ';
    if (*n + 1 >= cap) return 0;
    /* cmd.exe does not recognize quoted switches such as "/c": quote only
     * arguments that CommandLineToArgvW would otherwise split or alter. */
    if (*arg && !strpbrk(arg, " \t\n\v\"")) {
        size_t len = strlen(arg);
        if (len >= cap - *n) return 0;
        memcpy(out + *n, arg, len + 1);
        *n += len;
        return 1;
    }
    out[(*n)++] = '"';
    for (;;) {
        size_t slashes = 0;
        while (*arg == '\\') { slashes++; arg++; }
        size_t count = (*arg == '"' || !*arg) ? slashes * 2 : slashes;
        if (*arg == '"') count++;
        if (count >= cap - *n) return 0;
        while (count--) out[(*n)++] = '\\';
        if (!*arg) break;
        if (*n + 1 >= cap) return 0;
        out[(*n)++] = *arg++;
    }
    if (*n + 1 >= cap) return 0;
    out[(*n)++] = '"'; out[*n] = 0;
    return 1;
}

static int
peak_internal_join_argv(char *out, size_t cap, const char *file, const char **argv)
{
    size_t n = 0;
    if (!out || cap < 2) return 0;
    out[0] = 0;
    if (file && !peak_internal_quote_arg(out, cap, &n, file)) return 0;
    if (argv) for (int i = file ? 1 : 0; argv[i]; i++)
        if (!peak_internal_quote_arg(out, cap, &n, argv[i])) return 0;
    return 1;
}

static HANDLE
peak_internal_write_handle(PEAK_HANDLE fd)
{
	PeakProcRec *r;

	r = peak_internal_proc_find((HANDLE)fd);
	if (r && r->write && r->write != INVALID_HANDLE_VALUE)
		return r->write;
	return (HANDLE)fd;
}

static int
peak_internal_pipe_ready(HANDLE h)
{
	DWORD avail, flags;

	if (!h || h == INVALID_HANDLE_VALUE)
		return 0;
	if (PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL))
		return avail > 0;
	if (GetNamedPipeHandleStateA(h, &flags, NULL, NULL, NULL, NULL, 0))
		return 0;
	return 1;
}

static void
peak_internal_pipe_name(const char *path, char *out, size_t cap)
{
	size_t i, n;

	if (!path)
		path = "peak";
	n = (size_t)snprintf(out, cap, "\\\\.\\pipe\\peak_");
	if (n >= cap) {
		out[0] = 0;
		return;
	}
	for (i = 0; path[i] && n + 1 < cap; i++) {
		char c;

		c = path[i];
		if (c == '\\' || c == '/' || c == ':' || c == ' ')
			c = '_';
		out[n++] = c;
	}
	out[n] = 0;
}

PeakProc
peak_pipe_spawn(const char *file, const char **argv, uint32_t cols, uint32_t rows)
{
	return peak_pty_spawn(file, argv, cols, rows, 0, 0);
}

void
peak_pipe_resize(PeakProc *p, uint32_t cols, uint32_t rows)
{
	peak_pty_resize(p, cols, rows, 0, 0);
}

PeakProc
peak_pty_spawn(const char *file, const char **argv, uint32_t cols, uint32_t rows, uint32_t xpixel, uint32_t ypixel)
{
	PeakProc p;
	PeakProcRec *rec;
	HANDLE in_r, in_w, out_r, out_w;
	HPCON pc;
	COORD size;
	SIZE_T attr_n;
	STARTUPINFOEXA si;
	PROCESS_INFORMATION pi;
	char cmd[32768];
	SECURITY_ATTRIBUTES sa;

	(void)xpixel;
	(void)ypixel;
	p = peak_internal_proc_fail();
	if (!file || !argv)
		return p;
	peak_internal_conpty_load();
	if (!peak_create_pc)
		return p;
	rec = peak_internal_proc_slot();
	if (!rec)
		return p;
	if (!peak_internal_join_argv(cmd, sizeof cmd, file, argv))
		return p;
	memset(&sa, 0, sizeof sa);
	sa.nLength = sizeof sa;
	sa.bInheritHandle = TRUE;
	in_r = in_w = out_r = out_w = NULL;
	if (!CreatePipe(&in_r, &in_w, &sa, 0) || !CreatePipe(&out_r, &out_w, &sa, 0))
		goto fail_pipes;
	size.X = cols ? (SHORT)cols : 80;
	size.Y = rows ? (SHORT)rows : 24;
	if (peak_create_pc(size, in_r, out_w, 0, &pc) != S_OK)
		goto fail_pipes;
	CloseHandle(in_r);
	in_r = NULL;
	CloseHandle(out_w);
	out_w = NULL;
	memset(&si, 0, sizeof si);
	si.StartupInfo.cb = sizeof si;
	/* Without explicit invalid stdio, a child of a redirected parent writes to
	 * the parent's pipes instead of the pseudoconsole. */
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
	si.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
	si.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
	attr_n = 0;
	InitializeProcThreadAttributeList(NULL, 1, 0, &attr_n);
	si.lpAttributeList = malloc(attr_n);
	if (!si.lpAttributeList || !InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_n))
		goto fail_pc;
	if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pc, sizeof pc, NULL, NULL))
		goto fail_attr;
	memset(&pi, 0, sizeof pi);
	if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &si.StartupInfo, &pi))
		goto fail_attr;
	CloseHandle(pi.hThread);
	DeleteProcThreadAttributeList(si.lpAttributeList);
	free(si.lpAttributeList);
	rec->read = out_r;
	rec->write = in_w;
	rec->proc = pi.hProcess;
	rec->pc = pc;
    rec->pid = (int)pi.dwProcessId;
    InitializeCriticalSection(&rec->write_lock);
    rec->write_lock_live = 1;
    rec->write_event = CreateEventA(NULL, FALSE, FALSE, NULL);
    rec->writer = rec->write_event ? CreateThread(NULL, 0, peak_internal_writer, rec, 0, NULL) : NULL;
    if (!rec->writer) {
        TerminateProcess(rec->proc, 1);
        CloseHandle(rec->read);
        peak_internal_proc_clear(rec);
        return p;
    }
	p.fd = out_r;
	p.pid = rec->pid;
	return p;

fail_attr:
	if (si.lpAttributeList) {
		DeleteProcThreadAttributeList(si.lpAttributeList);
		free(si.lpAttributeList);
	}
fail_pc:
	if (peak_close_pc)
		peak_close_pc(pc);
fail_pipes:
	if (in_r)
		CloseHandle(in_r);
	if (in_w)
		CloseHandle(in_w);
	if (out_r)
		CloseHandle(out_r);
	if (out_w)
		CloseHandle(out_w);
	return p;
}

void
peak_pty_resize(PeakProc *pty, uint32_t cols, uint32_t rows, uint32_t xpixel, uint32_t ypixel)
{
	PeakProcRec *r;
	COORD size;

	(void)xpixel;
	(void)ypixel;
	if (!pty)
		return;
	r = peak_internal_proc_find((HANDLE)pty->fd);
	if (!r || !r->pc || !peak_resize_pc)
		return;
	size.X = cols ? (SHORT)cols : 80;
	size.Y = rows ? (SHORT)rows : 24;
	peak_resize_pc(r->pc, size);
}

int
peak_pty_reap(PeakProc *pty)
{
	PeakProcRec *r;
	DWORD code;

	if (!pty || pty->pid <= 0)
		return 0;
	r = peak_internal_proc_find((HANDLE)pty->fd);
	if (!r || !r->proc)
		return 0;
	if (WaitForSingleObject(r->proc, 0) != WAIT_OBJECT_0)
		return 0;
	GetExitCodeProcess(r->proc, &code);
	pty->pid = 0;
	return 1;
}

void
peak_pty_close(PeakProc *pty)
{
	PeakProcRec *r;

	if (!pty)
		return;
	r = peak_internal_proc_find((HANDLE)pty->fd);
	if (r) {
        if (r->proc && WaitForSingleObject(r->proc, 0) == WAIT_TIMEOUT) TerminateProcess(r->proc, 0);
        if (r->proc) WaitForSingleObject(r->proc, INFINITE);
		if (r->read)
			CloseHandle(r->read);
		peak_internal_proc_clear(r);
	} else if (pty->fd != PEAK_HANDLE_INVALID) {
		CloseHandle((HANDLE)pty->fd);
	}
	pty->fd = PEAK_HANDLE_INVALID;
	pty->pid = 0;
}

int
peak_wait(PeakWindow *win, const PEAK_HANDLE *fds, uint32_t n, int timeout_ms)
{
	DWORD left, slice, got;
	uint32_t i;

	left = timeout_ms < 0 ? INFINITE : (DWORD)timeout_ms;
	for (;;) {
		if (win && peak_window_pending(win) > 0)
			return 1;
		for (i = 0; i < n; i++) {
			if (fds && peak_internal_pipe_ready((HANDLE)fds[i]))
				return 1;
		}
		if (timeout_ms == 0)
			return 0;
		slice = PEAK_WAIT_SLICE;
		if (left != INFINITE) {
			if (left == 0)
				return 0;
			if (left < slice)
				slice = left;
		}
		if (win)
			got = MsgWaitForMultipleObjectsEx(0, NULL, slice, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
		else
			got = WaitForSingleObject(GetCurrentProcess(), slice);
		(void)got;
		if (left != INFINITE) {
			if (left <= slice)
				return 0;
			left -= slice;
		}
	}
}

int
peak_runtime_dir(char *buf, size_t cap, const char *app)
{
	char root[MAX_PATH];
	DWORD n;

	if (!buf || cap < 2 || !app || !app[0])
		return 0;
	n = GetEnvironmentVariableA("LOCALAPPDATA", root, MAX_PATH);
	if (!n || n >= MAX_PATH) {
		n = GetTempPathA(MAX_PATH, root);
		if (!n || n >= MAX_PATH)
			return 0;
	}
	if (snprintf(buf, cap, "%s\\%s", root, app) < 0 || strlen(buf) >= cap)
		return 0;
	if (!CreateDirectoryA(buf, NULL) && GetLastError() != ERROR_ALREADY_EXISTS)
		return 0;
	return 1;
}

PEAK_HANDLE
peak_sock_listen(const char *path)
{
	HANDLE h;

	peak_internal_pipe_name(path, peak_pipe_name, sizeof peak_pipe_name);
	if (!peak_pipe_name[0])
		return PEAK_HANDLE_INVALID;
	h = CreateNamedPipeA(peak_pipe_name, PIPE_ACCESS_DUPLEX,
		PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT, PIPE_UNLIMITED_INSTANCES,
		4096, 4096, 0, NULL);
	if (h == INVALID_HANDLE_VALUE)
		return PEAK_HANDLE_INVALID;
	return h;
}

PEAK_HANDLE
peak_sock_accept(PEAK_HANDLE listen_fd)
{
	HANDLE h;
	DWORD err;

	(void)listen_fd;
	if (!peak_pipe_name[0])
		return PEAK_HANDLE_INVALID;
	h = CreateNamedPipeA(peak_pipe_name, PIPE_ACCESS_DUPLEX,
		PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT, PIPE_UNLIMITED_INSTANCES,
		4096, 4096, 0, NULL);
	if (h == INVALID_HANDLE_VALUE)
		return PEAK_HANDLE_INVALID;
	if (ConnectNamedPipe(h, NULL))
		return h;
	err = GetLastError();
	if (err == ERROR_PIPE_CONNECTED)
		return h;
	CloseHandle(h);
	return PEAK_HANDLE_INVALID;
}

PEAK_HANDLE
peak_sock_connect(const char *path)
{
	char name[MAX_PATH];
	HANDLE h;
	DWORD mode;

	peak_internal_pipe_name(path, name, sizeof name);
	if (!name[0])
		return PEAK_HANDLE_INVALID;
	h = CreateFileA(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
	if (h == INVALID_HANDLE_VALUE)
		return PEAK_HANDLE_INVALID;
	mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
	SetNamedPipeHandleState(h, &mode, NULL, NULL);
	return h;
}

int
peak_sock_send(PEAK_HANDLE sock, const void *buf, size_t n, PEAK_HANDLE pass)
{
	(void)pass;
	return peak_fd_write(sock, buf, n) > 0;
}

int
peak_sock_recv(PEAK_HANDLE sock, void *buf, size_t n, PEAK_HANDLE *pass)
{
	if (pass)
		*pass = PEAK_HANDLE_INVALID;
	return peak_fd_read(sock, buf, n);
}

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

int
peak_filesystem_mkdir(const char *path)
{
	if (!path || !path[0])
		return 0;
	return CreateDirectoryA(path, NULL) != 0;
}

int
peak_filesystem_rm(const char *path)
{
	DWORD attr;

	if (!path || !path[0])
		return 0;
	attr = GetFileAttributesA(path);
	if (attr == INVALID_FILE_ATTRIBUTES)
		return 0;
	if (attr & FILE_ATTRIBUTE_DIRECTORY)
		return RemoveDirectoryA(path) != 0;
	return DeleteFileA(path) != 0;
}

int
peak_filesystem_cwd(char *buf, size_t cap)
{
	if (!buf || cap < 2)
		return 0;
	return GetCurrentDirectoryA((DWORD)cap, buf) != 0;
}

int
peak_filesystem_chdir(const char *path)
{
	if (!path || !path[0])
		return 0;
	return SetCurrentDirectoryA(path) != 0;
}

int
peak_filesystem_rename(const char *from, const char *to)
{
	if (!from || !from[0] || !to || !to[0])
		return 0;
	return MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING) != 0;
}

int
peak_fd_read(PEAK_HANDLE fd, void *buf, size_t n)
{
	DWORD got;
	HANDLE h;

	if (fd == PEAK_HANDLE_INVALID || !buf)
		return 0;
	h = (HANDLE)fd;
	n = peak_internal_io_n(n);
	if (!PeekNamedPipe(h, NULL, 0, NULL, &got, NULL)) {
		if (!ReadFile(h, buf, (DWORD)n, &got, NULL))
			return 0;
		return got ? (int)got : 0;
	}
    if (!got) {
        PeakProcRec *r = peak_internal_proc_find(h);
        if (r && r->proc && WaitForSingleObject(r->proc, 0) == WAIT_OBJECT_0) {
            if (r->pc && !r->closer) {
                /* ClosePseudoConsole flushes final output and can block on its
                 * pipe. Keep draining on the caller while a worker closes it. */
                r->closing_pc = r->pc;
                r->pc = NULL;
                r->closer = CreateThread(NULL, 0, peak_internal_close_console, r, 0, NULL);
                if (!r->closer) { r->pc = r->closing_pc; return 0; }
            } else if (!r->closer) return 0;
        }
        return -1;
    }
	if (got > n)
		got = (DWORD)n;
	if (!ReadFile(h, buf, got, &got, NULL))
		return 0;
	return got ? (int)got : 0;
}

int
peak_fd_write(PEAK_HANDLE fd, const void *buf, size_t n)
{
	DWORD got;
	HANDLE h;

	if (fd == PEAK_HANDLE_INVALID || !buf)
		return 0;
    PeakProcRec *r = peak_internal_proc_find((HANDLE)fd);
    if (r && r->write_lock_live) {
        size_t tail, first;
        EnterCriticalSection(&r->write_lock);
        if (r->write_closed) { LeaveCriticalSection(&r->write_lock); return 0; }
        if (n > PEAK_WRITE_CAPACITY - r->write_len) n = PEAK_WRITE_CAPACITY - r->write_len;
        tail = (r->write_head + r->write_len) % PEAK_WRITE_CAPACITY;
        first = n < PEAK_WRITE_CAPACITY - tail ? n : PEAK_WRITE_CAPACITY - tail;
        memcpy(r->write_buf + tail, buf, first);
        memcpy(r->write_buf, (const unsigned char *)buf + first, n - first);
        r->write_len += n;
        LeaveCriticalSection(&r->write_lock);
        if (!n) return -1;
        SetEvent(r->write_event);
        return (int)n;
    }
	h = peak_internal_write_handle(fd);
	n = peak_internal_io_n(n);
	if (!WriteFile(h, buf, (DWORD)n, &got, NULL))
		return 0;
	return got ? (int)got : 0;
}

size_t
peak_pipe_capacity(PEAK_HANDLE fd)
{
	(void)fd;
	return 0;
}

size_t
peak_pipe_set_capacity(PEAK_HANDLE fd, size_t n)
{
	(void)fd;
	(void)n;
	return 0;
}

void
peak_fd_close(PEAK_HANDLE fd)
{
	PeakProcRec *r;

	if (fd == PEAK_HANDLE_INVALID)
		return;
	r = peak_internal_proc_find((HANDLE)fd);
	if (r) {
		if (r->read)
			CloseHandle(r->read);
		r->read = NULL;
		if (r->write && r->write != INVALID_HANDLE_VALUE) {
			CloseHandle(r->write);
			r->write = NULL;
		}
		return;
	}
	CloseHandle((HANDLE)fd);
}

PeakProc
peak_job_run(const char *cmd, const char *cwd)
{
	PeakProc p;
	PeakProcRec *rec;
	HANDLE rd, wr, nul;
	SECURITY_ATTRIBUTES sa;
	STARTUPINFOA si;
	PROCESS_INFORMATION pi;
	char line[1024];

	p = peak_internal_proc_fail();
	if (!cmd || !cmd[0])
		return p;
	rec = peak_internal_proc_slot();
	if (!rec)
		return p;
	if (snprintf(line, sizeof line, "cmd.exe /c %s", cmd) < 0)
		return p;
	memset(&sa, 0, sizeof sa);
	sa.nLength = sizeof sa;
	sa.bInheritHandle = TRUE;
	rd = wr = nul = NULL;
	if (!CreatePipe(&rd, &wr, &sa, 0))
		return p;
	SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0);
	nul = CreateFileA("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, NULL);
	memset(&si, 0, sizeof si);
	si.cb = sizeof si;
	si.dwFlags = STARTF_USESTDHANDLES;
	si.hStdInput = nul ? nul : GetStdHandle(STD_INPUT_HANDLE);
	si.hStdOutput = wr;
	si.hStdError = wr;
	memset(&pi, 0, sizeof pi);
	if (!CreateProcessA(NULL, line, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL,
			cwd && cwd[0] ? cwd : NULL, &si, &pi)) {
		CloseHandle(rd);
		CloseHandle(wr);
		if (nul)
			CloseHandle(nul);
		return p;
	}
	CloseHandle(wr);
	if (nul)
		CloseHandle(nul);
	CloseHandle(pi.hThread);
	rec->read = rd;
	rec->write = NULL;
	rec->proc = pi.hProcess;
	rec->pc = NULL;
	rec->pid = (int)pi.dwProcessId;
	p.fd = rd;
	p.pid = rec->pid;
	return p;
}

int
peak_job_reap(PeakProc *job, int *code)
{
	PeakProcRec *r;
	DWORD ec;

	if (!job || job->pid <= 0)
		return 0;
	r = peak_internal_proc_find((HANDLE)job->fd);
	if (!r || !r->proc)
		return 0;
	if (WaitForSingleObject(r->proc, 0) != WAIT_OBJECT_0)
		return 0;
	if (code) {
		GetExitCodeProcess(r->proc, &ec);
		*code = (int)ec;
	}
	job->pid = 0;
	return 1;
}

void
peak_job_kill(PeakProc *job)
{
	PeakProcRec *r;

	if (!job)
		return;
	r = peak_internal_proc_find((HANDLE)job->fd);
	if (r) {
		if (r->proc)
			TerminateProcess(r->proc, 1);
		if (r->read)
			CloseHandle(r->read);
		peak_internal_proc_clear(r);
	} else if (job->fd != PEAK_HANDLE_INVALID) {
		CloseHandle((HANDLE)job->fd);
	}
	job->fd = PEAK_HANDLE_INVALID;
	job->pid = 0;
}

int
peak_pid_cwd(int pid, char *buf, size_t cap)
{
	if (!buf || cap < 2)
		return 0;
	if (pid != (int)GetCurrentProcessId())
		return 0;
	return GetCurrentDirectoryA((DWORD)cap, buf) != 0;
}

size_t
peak_page_size(void)
{
	SYSTEM_INFO si;

	GetSystemInfo(&si);
	return si.dwPageSize ? (size_t)si.dwPageSize : 4096;
}

void *
peak_mirror_map(size_t size)
{
	HANDLE map;
	void *base;
	void *a, *b;
	int i;

	if (!size || size % peak_page_size())
		return NULL;
	if (size > 0x7fffffff)
		return NULL;
	map = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, (DWORD)size, NULL);
	if (!map)
		return NULL;
	for (i = 0; i < 16; i++) {
		base = VirtualAlloc(NULL, size * 2, MEM_RESERVE, PAGE_NOACCESS);
		if (!base)
			break;
		VirtualFree(base, 0, MEM_RELEASE);
		a = MapViewOfFileEx(map, FILE_MAP_ALL_ACCESS, 0, 0, size, base);
		if (!a)
			continue;
		b = MapViewOfFileEx(map, FILE_MAP_ALL_ACCESS, 0, 0, size, (char *)base + size);
		if (b) {
			CloseHandle(map);
			return base;
		}
		UnmapViewOfFile(a);
	}
	CloseHandle(map);
	return NULL;
}

void
peak_mirror_unmap(void *p, size_t size)
{
	if (!p || !size)
		return;
	UnmapViewOfFile(p);
	UnmapViewOfFile((char *)p + size);
}

int
peak_pid(void)
{
	return (int)GetCurrentProcessId();
}

int
peak_env_set(const char *name, const char *value)
{
	if (!name || !name[0])
		return 0;
	return SetEnvironmentVariableA(name, value) != 0;
}

int
peak_env_get(const char *name, char *buf, size_t cap)
{
	DWORD n;

	if (!name || !name[0] || !buf || cap < 2 || cap > 0x7fffffff)
		return 0;
	n = GetEnvironmentVariableA(name, buf, (DWORD)cap);
	if (n == 0 || n >= cap)
		return 0;
	return buf[0] != 0;
}

int
peak_filesystem_list(const char *path, int (*fn)(const char *name, void *ud), void *ud)
{
	char pat[MAX_PATH];
	WIN32_FIND_DATAA fd;
	HANDLE h;

	if (!path || !path[0] || !fn)
		return 0;
	if (snprintf(pat, sizeof pat, "%s\\*", path) < 0)
		return 0;
	h = FindFirstFileA(pat, &fd);
	if (h == INVALID_HANDLE_VALUE)
		return 0;
	do {
		if (fn(fd.cFileName, ud) == 0)
			break;
	} while (FindNextFileA(h, &fd));
	FindClose(h);
	return 1;
}

int
peak_filesystem_symlink(const char *target, const char *path)
{
	(void)target;
	(void)path;
	return 0;
}

int
peak_filesystem_readlink(const char *path, char *dst, size_t cap)
{
	(void)path;
	(void)dst;
	(void)cap;
	return 0;
}

int
peak_child_arm(void)
{
	return 1;
}

void
peak_child_disarm(void)
{
}

PEAK_HANDLE
peak_child_fd(void)
{
	return PEAK_HANDLE_INVALID;
}

void
peak_child_ack(void)
{
}

int
peak_usr1_arm(void)
{
	return 1;
}

void
peak_usr1_disarm(void)
{
}

PEAK_HANDLE
peak_usr1_fd(void)
{
	return PEAK_HANDLE_INVALID;
}

int
peak_usr1_ack(void)
{
	return 0;
}

int
peak_child_reap(int *pid, int *code)
{
	(void)pid;
	(void)code;
	return 0;
}

int
peak_stdout_silence(void)
{
	int nfd;

	if (peak_stdout_saved >= 0)
		return 1;
	peak_stdout_saved = _dup(_fileno(stdout));
	if (peak_stdout_saved < 0)
		return 0;
	nfd = _open("NUL", _O_WRONLY);
	if (nfd < 0) {
		_close(peak_stdout_saved);
		peak_stdout_saved = -1;
		return 0;
	}
	if (_dup2(nfd, _fileno(stdout)) < 0) {
		_close(nfd);
		_close(peak_stdout_saved);
		peak_stdout_saved = -1;
		return 0;
	}
	_close(nfd);
	return 1;
}

int
peak_stdout_restore(void)
{
	if (peak_stdout_saved < 0)
		return 0;
	fflush(stdout);
	_dup2(peak_stdout_saved, _fileno(stdout));
	_close(peak_stdout_saved);
	peak_stdout_saved = -1;
	return 1;
}
