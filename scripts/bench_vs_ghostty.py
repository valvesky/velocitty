#!/usr/bin/env python3
"""Velocitty vs Ghostty: headless VT throughput on kitty's six benchmarks.

Builds velocitty-bench, dumps the `kitten __benchmark__` payloads, runs
`velocitty-bench +terminal-stream` and `ghostty-bench +terminal-stream` on
the same files with Velocitty exact and --drop modes (interleaved, median\nof --runs), and writes results.json,
chart.svg and chart.png (when rsvg-convert is available).

  scripts/bench_vs_ghostty.py --ghostty-bench PATH [--reps 10] [--runs 5]
                              [--metric cpu|wall] [--out bench/vs-ghostty]

Build ghostty-bench from a Ghostty checkout with
`zig build -Demit-bench -Doptimize=ReleaseFast -Dapp-runtime=none`.
CPU time (user + sys of the child) is the default metric: it moves far less
than wall time when the machine is busy. Standard library only.
"""

import argparse
import base64
import datetime
import json
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

# Compatibility palette shared with startup charts; comparison markers use icons.
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
BASELINE = "#c3c2b7"
SERIES = {"velocitty": "#2a78d6", "velocitty_skip": "#15836b", "ghostty": "#eb6834"}
LABEL_COLORS = {"velocitty": "#966500", "velocitty_skip": "#214fa3", "ghostty": INK_2}


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
    tools = {
        "velocitty": (vbench, []),
        "velocitty_skip": (vbench, ["--drop"]),
        "ghostty": (args.ghostty_bench, []),
    }
    rows = []
    for key, label in TESTS:
        path = os.path.join(data, f"kitten-{key}.bin")
        size = os.path.getsize(path)
        commands = {k: [bench, "+terminal-stream", f"--data={path}", *flags]
                    for k, (bench, flags) in tools.items()}
        samples = {k: [] for k in tools}
        order = list(tools)
        round_order = []
        for i in range(args.runs):
            # Rotate the first process to avoid always favoring one mode.
            current = order[i % len(order):] + order[:i % len(order)]
            round_order.append(current)
            for k in current:
                samples[k].append(timed(commands[k]))
        row = {"test": key, "label": label, "bytes": size, "round_order": round_order}
        for k, values in samples.items():
            cpu = statistics.median(c for c, _ in values)
            wall = statistics.median(w for _, w in values)
            row[k] = {
                "cpu_s": cpu, "wall_s": wall,
                "cpu_mbps": size / MIB / cpu, "wall_mbps": size / MIB / wall,
                "command": commands[k],
                "samples": [{"cpu_s": c, "wall_s": w} for c, w in values],
            }
        rows.append(row)
        rate = lambda k: row[k][f"{args.metric}_mbps"]
        print(f"{label:<18} exact {fmt_rate(rate('velocitty')):>12}   "
              f"skip text {fmt_rate(rate('velocitty_skip')):>12}   "
              f"ghostty {fmt_rate(rate('ghostty')):>12}", flush=True)
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
        "modes": {"velocitty": "exact", "velocitty_skip": "--drop (pressure-triggered obsolete-span skipping)", "ghostty": "exact"},
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


def marker_definitions():
    """Embed marker images so chart rendering needs no external assets/fonts."""
    out = ['<defs>']
    for key, filename in (("velocitty", "lightning.png"),
                          ("velocitty_skip", "lightning-inverted.png"),
                          ("ghostty", "ghost-emoji.png")):
        with open(os.path.join(ROOT, "assets", "benchmarks", filename), "rb") as source:
            data = base64.b64encode(source.read()).decode("ascii")
        out.append(f'<symbol id="marker-{key}" viewBox="0 0 96 96"><image width="96" height="96" href="data:image/png;base64,{data}"/></symbol>')
    out.append('</defs>')
    return "\n".join(out)


def marker(key, cx, cy, size, role):
    return (f'<use data-series="{key}" data-role="{role}" href="#marker-{key}" '
            f'x="{cx - size / 2:.1f}" y="{cy - size / 2:.1f}" width="{size}" height="{size}"/>')


def chart(res):
    """Grouped bars with independent linear scales; supports exact-only results."""
    metric = res["metric"]
    rows = res["rows"]
    series = [k for k in SERIES if any(k in r for r in rows)]
    if any(k not in r for k in series for r in rows):
        raise ValueError("every workload must contain the same benchmark modes")
    pitch = 240 if "velocitty_skip" in series else 190
    W, H = 2000, 300 + pitch * len(rows) + 250
    x0, x1 = 600, 1320
    top = 300
    skipping = "velocitty_skip" in series
    font = 'font-family="system-ui, -apple-system, Segoe UI, sans-serif"'
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" {font}>',
        marker_definitions(),
        f'<rect width="{W}" height="{H}" fill="{SURFACE}"/>',
        f'<text x="90" y="125" font-size="64" font-weight="500" fill="{INK}">VT processing throughput</text>',
        f'<text x="90" y="180" font-size="28" fill="{INK_2}">Higher is better · independent scale per workload · compare bar lengths within each workload only</text>',
        f'<text x="{x0}" y="260" font-size="22" fill="{MUTED}">Throughput · linear scale from zero</text>',
        f'<text x="1540" y="260" font-size="22" fill="{MUTED}" text-anchor="end">Throughput</text>',
        f'<text x="1910" y="260" font-size="22" fill="{MUTED}" text-anchor="end">vs Ghostty exact</text>',
    ]
    labels = {"velocitty": "Velocitty exact", "velocitty_skip": "Velocitty text skipping", "ghostty": "Ghostty exact"}
    bottom = top + pitch * len(rows)
    for i, row in enumerate(rows):
        row_top = top + pitch * i
        rates = {k: row[k][f"{metric}_mbps"] for k in series}
        hi = max(rates.values())
        out.append(f'<line x1="90" y1="{row_top}" x2="1910" y2="{row_top}" stroke="{GRID}"/>')
        out.append(f'<text x="90" y="{row_top + 35}" font-size="30" font-weight="600" fill="{INK}">{esc(row["label"])}</text>')
        for j, k in enumerate(series):
            cy = row_top + 75 + 50 * j
            width = rates[k] / hi * (x1 - x0)
            out.append(marker(k, 300, cy, 28, "series"))
            out.append(f'<text x="326" y="{cy + 8}" font-size="23" fill="{INK_2}">{labels[k]}</text>')
            out.append(f'<rect data-role="bar" data-row="{i}" data-series="{k}" x="{x0}" y="{cy - 12}" width="{width:.1f}" height="24" rx="4" fill="{SERIES[k]}"/>')
            out.append(f'<text x="1540" y="{cy + 8}" font-size="25" font-weight="500" fill="{INK}" text-anchor="end">{fmt_rate(rates[k])}</text>')
            comparison = "reference" if k == "ghostty" else ratio_text(rates[k], rates["ghostty"])
            out.append(f'<text x="1910" y="{cy + 8}" font-size="24" fill="{INK_2}" text-anchor="end">{comparison}</text>')
    fy = bottom + 125
    metric_txt = "CPU time (user + sys)" if metric == "cpu" else "wall time"
    load = f" · load avg {res['load_avg_1m']:.1f}" if res.get("load_avg_1m") is not None else ""
    out.append(f'<text x="90" y="{fy}" font-size="22" fill="{INK_2}">velocitty-bench +terminal-stream (Velocitty {esc(res["velocitty"])}) · ghostty-bench +terminal-stream (Ghostty {esc(res["ghostty"])})</text>')
    if skipping:
        out.append(f'<text x="90" y="{fy + 35}" font-size="21" fill="{INK_2}">Exact: all cell writes · text skipping: --drop, only proven-obsolete writes omitted · no rendering/presentation</text>')
    out += [
        f'<line x1="90" y1="{fy + 60}" x2="1910" y2="{fy + 60}" stroke="{GRID}" stroke-width="2"/>',
        f'<text x="90" y="{fy + 100}" font-size="22" fill="{INK_2}">{esc(res["cpu"])} · {res["grid"]} cells · median of {res["runs"]} runs, {metric_txt}{load} · MB = 2^20 bytes</text>',
        f'<text x="1910" y="{fy + 100}" font-size="22" fill="{INK_2}" text-anchor="end">{res["date"][:10]}</text>',
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
