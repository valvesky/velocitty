#!/usr/bin/env bash
# Kernel PTY only: child writes 1 GiB to the slave, parent drains the master.
# No vt, no parse, no present. Echo/canon off so the line discipline cannot stall.
set -euo pipefail

ROUNDS=10
MIB=1024

if ! command -v python3 >/dev/null; then
	echo "missing python3" >&2
	exit 1
fi

pty_round() {
	MIB="$MIB" python3 - <<'PY'
import os, sys, time, tty

mib = int(os.environ["MIB"])
size = mib * 1024 * 1024
chunk = 64 * 1024
buf = b"A" * chunk

master, slave = os.openpty()
tty.setraw(slave)

pid = os.fork()
if pid == 0:
    os.close(master)
    left = size
    while left:
        n = os.write(slave, buf if left >= chunk else buf[:left])
        left -= n
    os.close(slave)
    os._exit(0)

os.close(slave)
got = 0
t0 = time.perf_counter()
while got < size:
    n = os.read(master, chunk)
    if not n:
        break
    got += len(n)
dt = time.perf_counter() - t0
os.close(master)
os.waitpid(pid, 0)
if got != size:
    sys.stderr.write("short read: %d of %d\n" % (got, size))
    sys.exit(1)
sys.stdout.write("%.6f\n" % dt)
PY
}

sum_t=0
echo "PTY  ${MIB} MiB x ${ROUNDS}  (slave write, master drain, 64 KiB reads)"
for ((i = 1; i <= ROUNDS; i++)); do
	t=$(pty_round)
	mibs=$(awk -v m="$MIB" -v t="$t" 'BEGIN { printf "%.2f", m / t }')
	echo "  round $i  ${t}s  ${mibs} MiB/s"
	sum_t=$(awk -v a="$sum_t" -v b="$t" 'BEGIN { printf "%.6f", a + b }')
done
avg=$(awk -v m="$MIB" -v n="$ROUNDS" -v t="$sum_t" 'BEGIN { printf "%.2f", (m * n) / t }')
echo
printf 'PTY_AVERAGE  %s MiB/s\n' "$avg"
