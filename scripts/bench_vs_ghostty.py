#!/usr/bin/env python3
"""Velocitty vs Ghostty: headless VT throughput on kitty's six benchmarks.

Builds velocitty-bench, dumps the `kitten __benchmark__` payloads, runs
`velocitty-bench +terminal-stream` and `ghostty-bench +terminal-stream` on
the same files (interleaved, median of --runs), and writes results.json,
chart.svg and chart.png (when rsvg-convert is available).

  scripts/bench_vs_ghostty.py --ghostty-bench PATH [--reps 10] [--runs 5]
                              [--metric cpu|wall] [--out bench/vs-ghostty]

Build ghostty-bench from a Ghostty checkout with
`zig build -Demit-bench -Doptimize=ReleaseFast -Dapp-runtime=none`.
CPU time (user + sys of the child) is the default metric: it moves far less
than wall time when the machine is busy. Standard library only.
"""

import argparse
import datetime
import json
import math
import os
import platform
import re
import resource
import shutil
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = [
    ("ascii", "ASCII"),
    ("unicode", "Unicode"),
    ("unique_unicode", "Unique Unicode"),
    ("csi", "CSI"),
    ("images", "Images"),
    ("long_escape_codes", "Long escape codes"),
]
MIB = 1024 * 1024

# Chart palette: categorical slots 1-2 of the dataviz reference palette
# (validated: CVD and normal-vision separation, >= 3:1 on the surface).
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
BASELINE = "#c3c2b7"
SERIES = {"velocitty": "#2a78d6", "ghostty": "#eb6834"}


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def timed(cmd):
    """(cpu seconds, wall seconds) of one child run."""
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.perf_counter()
    run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t1 = time.perf_counter()
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    return (r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime), t1 - t0


def cpu_model():
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    return re.sub(r"\s+", " ", line.split(":", 1)[1]).strip()
    except OSError:
        pass
    return platform.processor() or platform.machine()


def ghostty_version(bench):
    p = subprocess.run([bench, "+terminal-stream"], capture_output=True, text=True)
    m = re.search(r"ghostty version=(\S+)", p.stderr + p.stdout)
    return m.group(1) if m else "unknown"


def git_rev():
    try:
        rev = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True).stdout.strip()
        return rev + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def measure(args):
    vbench = args.velocitty_bench
    if vbench is None:
        run(["zig", "build", "bench-install"], cwd=ROOT)
        vbench = os.path.join(ROOT, "zig-out", "bin", "velocitty-bench")
    data = os.path.join(args.out, "data")
    os.makedirs(data, exist_ok=True)
    run([vbench, "--only", "kitten", "--mib", str(args.reps), "--dump", data], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tools = {"velocitty": vbench, "ghostty": args.ghostty_bench}
    rows = []
    for key, label in TESTS:
        path = os.path.join(data, f"kitten-{key}.bin")
        size = os.path.getsize(path)
        samples = {k: [] for k in tools}
        for _ in range(args.runs):
            for k, bench in tools.items():
                samples[k].append(timed([bench, "+terminal-stream", f"--data={path}"]))
        row = {"test": key, "label": label, "bytes": size}
        for k, s in samples.items():
            cpu = statistics.median(c for c, _ in s)
            wall = statistics.median(w for _, w in s)
            row[k] = {"cpu_s": cpu, "wall_s": wall, "cpu_mbps": size / MIB / cpu, "wall_mbps": size / MIB / wall}
        rows.append(row)
        v, g = row["velocitty"][f"{args.metric}_mbps"], row["ghostty"][f"{args.metric}_mbps"]
        print(f"{label:<18} velocitty {fmt_rate(v):>12}   ghostty {fmt_rate(g):>12}   {ratio_text(v, g)}", flush=True)
    load = os.getloadavg()[0] if hasattr(os, "getloadavg") else None
    return {
        "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "cpu": cpu_model(),
        "load_avg_1m": load,
        "grid": "120x80",
        "reps": args.reps,
        "runs": args.runs,
        "metric": args.metric,
        "velocitty": git_rev(),
        "ghostty": ghostty_version(args.ghostty_bench),
        "rows": rows,
    }


def fmt_rate(mbps):
    if mbps >= 1000:
        return f"{mbps / 1024:.2f} GB/s"
    return f"{mbps:.1f} MB/s"


def ratio_text(v, g):
    if max(v, g) / min(v, g) < 1.05:
        return "even"
    if v >= g:
        return f"{v / g:.1f}× faster"
    return f"{g / v:.1f}× slower"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def chart(res):
    """Dumbbell chart on a log throughput axis, one row per benchmark."""
    metric = res["metric"]
    rows = res["rows"]
    vals = [r[k][f"{metric}_mbps"] for r in rows for k in SERIES]
    # Ticks: decades in MB/s, then GB/s on 1024 multiples (MB = 2^20 bytes).
    ticks = [(10.0 ** e, f"{10 ** e} MB/s") for e in range(0, 3)] + [(1024.0 * 10 ** e, f"{10 ** e} GB/s") for e in range(0, 4)]
    lo = max(t for t, _ in ticks if t <= min(vals))
    hi = min(t for t, _ in ticks if t >= max(vals))
    ticks = [t for t in ticks if lo <= t[0] <= hi]
    pitch = 120
    W, H = 2000, 300 + pitch * len(rows) + 210
    x0, x1 = 500, 1640
    top = 300

    def x(v):
        return x0 + (math.log10(v) - math.log10(lo)) / (math.log10(hi) - math.log10(lo)) * (x1 - x0)

    font = 'font-family="system-ui, -apple-system, Segoe UI, sans-serif"'
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" {font}>',
        f'<rect width="{W}" height="{H}" fill="{SURFACE}"/>',
        f'<text x="90" y="125" font-size="64" font-weight="500" fill="{INK}">VT processing throughput</text>',
        f'<text x="90" y="172" font-size="30" fill="{INK_2}">Headless processing across six kitten benchmarks</text>',
        f'<text x="1910" y="235" font-size="24" fill="{INK_2}" text-anchor="end">Higher is better</text>',
    ]
    # Legend.
    lx = 540
    for k, name in (("velocitty", "Velocitty"), ("ghostty", "Ghostty")):
        out.append(f'<circle cx="{lx}" cy="226" r="10" fill="{SERIES[k]}"/>')
        out.append(f'<text x="{lx + 26}" y="236" font-size="30" fill="{INK}">{name}</text>')
        lx += 245
    out.append(f'<text x="1910" y="285" font-size="24" fill="{INK_2}" text-anchor="end">Velocitty vs Ghostty</text>')
    # Decade gridlines and axis labels.
    bottom = top + pitch * len(rows)
    for t, label in ticks:
        gx = x(t)
        out.append(f'<line x1="{gx:.1f}" y1="{top}" x2="{gx:.1f}" y2="{bottom}" stroke="{GRID}" stroke-width="2"/>')
        out.append(f'<text x="{gx:.1f}" y="{bottom + 45}" font-size="26" fill="{INK_2}" text-anchor="middle">{label}</text>')
    out.append(f'<text x="{(x0 + x1) / 2:.0f}" y="{bottom + 80}" font-size="22" fill="{MUTED}" text-anchor="middle">Throughput · log scale</text>')
    # Rows.
    for i, r in enumerate(rows):
        cy = top + pitch // 2 + pitch * i
        v = r["velocitty"][f"{metric}_mbps"]
        g = r["ghostty"][f"{metric}_mbps"]
        out.append(f'<text x="475" y="{cy + 10}" font-size="30" fill="{INK}" text-anchor="end">{esc(r["label"])}</text>')
        out.append(f'<line x1="{x(v):.1f}" y1="{cy}" x2="{x(g):.1f}" y2="{cy}" stroke="{BASELINE}" stroke-width="4" stroke-linecap="round"/>')
        # Ghostty's value above its dot, Velocitty's below: never on top of each other.
        for k, val, dy in (("ghostty", g, -26), ("velocitty", v, 46)):
            out.append(f'<circle cx="{x(val):.1f}" cy="{cy}" r="11" fill="{SERIES[k]}" stroke="{SURFACE}" stroke-width="2"/>')
            out.append(f'<text x="{x(val):.1f}" y="{cy + dy}" font-size="24" fill="{INK if k == "velocitty" else INK_2}" text-anchor="middle">{fmt_rate(val)}</text>')
        out.append(f'<text x="1910" y="{cy + 12}" font-size="34" fill="{INK}" text-anchor="end">{ratio_text(v, g)}</text>')
    # Footer.
    fy = bottom + 125
    metric_txt = "CPU time (user + sys)" if metric == "cpu" else "wall time"
    load = f" · load avg {res['load_avg_1m']:.1f}" if res.get("load_avg_1m") is not None else ""
    out += [
        f'<text x="90" y="{fy}" font-size="22" fill="{INK_2}">velocitty-bench +terminal-stream (Velocitty {esc(res["velocitty"])}) · ghostty-bench +terminal-stream (Ghostty {esc(res["ghostty"])})</text>',
        f'<line x1="90" y1="{fy + 30}" x2="1910" y2="{fy + 30}" stroke="{GRID}" stroke-width="2"/>',
        f'<text x="90" y="{fy + 72}" font-size="22" fill="{INK_2}">{esc(res["cpu"])} · {res["grid"]} cells · median of {res["runs"]} runs, {metric_txt}{load} · MB = 2^20 bytes</text>',
        f'<text x="1910" y="{fy + 72}" font-size="22" fill="{INK_2}" text-anchor="end">{res["date"][:10]}</text>',
        "</svg>",
    ]
    return "\n".join(out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ghostty-bench", help="path to ghostty-bench (required unless --chart-only)")
    p.add_argument("--velocitty-bench", help="path to velocitty-bench (default: zig build bench-install)")
    p.add_argument("--reps", type=int, default=10, help="kitten payload repetitions per file (default 10)")
    p.add_argument("--runs", type=int, default=5, help="runs per tool and test, median taken (default 5)")
    p.add_argument("--metric", choices=("cpu", "wall"), default="cpu")
    p.add_argument("--out", default=os.path.join(ROOT, "bench", "vs-ghostty"))
    p.add_argument("--chart-only", action="store_true", help="redraw chart from OUT/results.json")
    args = p.parse_args()
    if not args.chart_only and not args.ghostty_bench:
        p.error("--ghostty-bench is required")
    os.makedirs(args.out, exist_ok=True)
    res_path = os.path.join(args.out, "results.json")
    if args.chart_only:
        with open(res_path) as f:
            res = json.load(f)
    else:
        res = measure(args)
        with open(res_path, "w") as f:
            json.dump(res, f, indent=2)
    svg = os.path.join(args.out, "chart.svg")
    with open(svg, "w") as f:
        f.write(chart(res))
    if not args.chart_only:
        print(f"wrote {res_path}")
    print(f"wrote {svg}")
    if shutil.which("rsvg-convert"):
        png = os.path.join(args.out, "chart.png")
        run(["rsvg-convert", "-o", png, svg])
        print(f"wrote {png}")


if __name__ == "__main__":
    sys.exit(main())
