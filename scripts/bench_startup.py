#!/usr/bin/env python3
"""Velocitty vs foot vs Monstar: fresh-process launch-and-exit distributions.

  python3 scripts/bench_startup.py --monstar /path/to/monstar [--runs 100]
  python3 scripts/bench_startup.py --chart-only [--out bench/startup]

Runs each terminal with `-e /usr/bin/true`, sequentially in shuffled rounds.
Writes raw wall-clock samples and metadata to results.json, plus chart.svg and
chart.png (if rsvg-convert is available), using bench_vs_ghostty.py's style.
Requires a live Linux Wayland session. Uses existing user configurations and
warm caches, not server/client modes. Windows may briefly appear or steal focus.
Measures process launch through exit (including shutdown and harness overhead),
NOT time to first frame. No builds, installs, or configuration changes are made.
Standard library only.
"""

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import random
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import time

import bench_vs_ghostty as style

ROOT = Path(__file__).resolve().parent.parent
SERIES = {"velocitty": "Velocitty", "foot": "foot", "monstar": "Monstar"}
COLORS = {"velocitty": style.SERIES["velocitty"], "foot": style.SERIES["ghostty"], "monstar": "#8963c7"}


def percentile(values, fraction):
    """Linearly interpolated sample quantile (including endpoints)."""
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def summarize(samples):
    if not samples or any(not math.isfinite(v) or v <= 0 for v in samples):
        raise ValueError("startup samples must be finite, positive milliseconds")
    q1, median, q3 = (percentile(samples, p) for p in (0.25, 0.5, 0.75))
    iqr = q3 - q1
    inside = [v for v in samples if q1 - 1.5 * iqr <= v <= q3 + 1.5 * iqr]
    whisker_low, whisker_high = min(inside), max(inside)
    return {
        "min_ms": min(samples), "q1_ms": q1, "median_ms": median,
        "q3_ms": q3, "max_ms": max(samples), "mean_ms": statistics.mean(samples),
        "whisker_low_ms": whisker_low, "whisker_high_ms": whisker_high,
        "outliers_ms": sorted(v for v in samples if v < whisker_low or v > whisker_high),
    }


def resolve_binary(value):
    found = shutil.which(value)
    if found is None:
        raise ValueError(f"executable not found: {value}")
    return os.path.abspath(found)


def timed(command, timeout):
    """Use communicate's pipe readiness, not wait(timeout)'s polling timer."""
    start = time.perf_counter_ns()
    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        _, stderr = process.communicate(timeout=timeout)
    except BaseException:
        # Isolate each launch so a timed-out terminal cannot leave its child alive.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    elapsed_ms = (time.perf_counter_ns() - start) / 1_000_000
    if process.returncode:
        detail = stderr.decode(errors="replace").strip()[-4000:]
        raise RuntimeError(f"{shlex.join(command)} exited {process.returncode}: {detail}")
    return elapsed_ms


def binary_metadata(key, path):
    binary = Path(path)
    info = {"path": path, "bytes": binary.stat().st_size,
            "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    # Velocitty does not implement --version: that flag would launch a shell.
    if key != "velocitty":
        result = subprocess.run([path, "--version"], capture_output=True, text=True,
                                timeout=5, check=True)
        info["version"] = (result.stdout + result.stderr).strip()
    return info


def measure(args):
    commands = {key: [resolve_binary(getattr(args, key)), "-e", resolve_binary("true")]
                for key in SERIES}
    binaries = {key: binary_metadata(key, cmd[0]) for key, cmd in commands.items()}
    samples = {key: [] for key in SERIES}
    order = []
    rng = random.Random(args.seed)
    for warmup, count in ((True, args.warmup), (False, args.runs)):
        for index in range(count):
            keys = list(SERIES)
            rng.shuffle(keys)
            if not warmup:
                order.append(keys)
            for key in keys:
                elapsed = timed(commands[key], args.timeout)
                if not warmup:
                    samples[key].append(elapsed)
            phase = "warmup" if warmup else "measured"
            print(f"\r{phase}: {index + 1}/{count} rounds", end="", flush=True)
        if count:
            print()
    rows = []
    for key, label in SERIES.items():
        row = {"terminal": key, "label": label, "command": commands[key],
               "binary": binaries[key], "samples_ms": samples[key],
               "summary": summarize(samples[key])}
        rows.append(row)
        print(f"{label:<12} median {row['summary']['median_ms']:.2f} ms")
    return {
        "schema_version": 1,
        "benchmark": "startup-launch-and-exit",
        "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "cpu": style.cpu_model(), "platform": os.uname().release,
        "load_avg_1m": os.getloadavg()[0],
        "runs": args.runs, "warmup": args.warmup, "seed": args.seed,
        "timeout_s": args.timeout, "round_order": order,
        "environment": {k: os.environ.get(k) for k in
                        ("WAYLAND_DISPLAY", "DISPLAY", "XDG_SESSION_TYPE", "XDG_CONFIG_HOME")},
        "cwd": os.getcwd(),
        "method": "Wall time from Popen through communicate; new process group per launch; "
                  "existing user configs; warm caches; no server/client; includes shutdown; "
                  "not first-frame latency. Warmups excluded; no measured samples discarded.",
        "rows": rows,
    }


def fmt_ms(value):
    return f"{value:.1f} ms" if value < 1000 else f"{value / 1000:.2f} s"


def log_ticks(low, high):
    """1/2/5 ticks with padding, including single-valued distributions."""
    low, high = low / 1.1, high * 1.1
    ticks = sorted(m * 10.0 ** e
                   for e in range(math.floor(math.log10(low)) - 1, math.ceil(math.log10(high)) + 2)
                   for m in (1, 2, 5))
    lower = max(t for t in ticks if t <= low)
    upper = min(t for t in ticks if t >= high)
    return [t for t in ticks if lower <= t <= upper]


def chart(result):
    """Horizontal Tukey box plots, sharing the Ghostty comparison's style."""
    rows = result["rows"]
    summaries = [summarize(row["samples_ms"]) for row in rows]
    ticks = log_ticks(min(s["min_ms"] for s in summaries), max(s["max_ms"] for s in summaries))
    low, high = math.log10(ticks[0]), math.log10(ticks[-1])
    width, pitch, top = 2000, 130, 280
    bottom = top + pitch * len(rows)
    height, x0, x1 = bottom + 270, 500, 1830

    def x(value):
        return x0 + (math.log10(value) - low) / (high - low) * (x1 - x0)

    def text(px, py, value, size=26, color=style.INK_2, anchor="start"):
        return (f'<text x="{px:.1f}" y="{py:.1f}" font-size="{size}" '
                f'fill="{color}" text-anchor="{anchor}">{style.esc(str(value))}</text>')

    def line(ax, ay, bx, by, color, stroke=2):
        return (f'<line x1="{ax:.1f}" y1="{ay:.1f}" x2="{bx:.1f}" y2="{by:.1f}" '
                f'stroke="{color}" stroke-width="{stroke}"/>')

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" font-family="system-ui, -apple-system, Segoe UI, sans-serif" '
        'role="img" aria-labelledby="title description">',
        '<title id="title">Velocitty vs foot vs Monstar startup distribution</title>',
        '<desc id="description">Launch-and-exit wall times. Lower is better; not first-frame latency.</desc>',
        f'<rect width="{width}" height="{height}" fill="{style.SURFACE}"/>',
        text(90, 125, "Startup distribution", 64, style.INK),
        text(90, 172, "Velocitty vs foot vs Monstar · fresh launch-and-exit runs of true", 30),
        text(1910, 235, "Lower is better", 24, anchor="end"),
        text(475, 252, "Median", 24, anchor="end"),
    ]
    for tick in ticks:
        gx = x(tick)
        out += [line(gx, top, gx, bottom, style.GRID),
                text(gx, bottom + 45, fmt_ms(tick), anchor="middle")]
    for i, (row, summary) in enumerate(zip(rows, summaries)):
        cy = top + pitch * (i + 0.5)
        color = COLORS[row["terminal"]]
        left, right = x(summary["whisker_low_ms"]), x(summary["whisker_high_ms"])
        q1, q3, median = (x(summary[k]) for k in ("q1_ms", "q3_ms", "median_ms"))
        out += [text(90, cy + 10, row["label"], 30, style.INK),
                text(475, cy + 10, fmt_ms(summary["median_ms"]), 26, style.INK, "end"),
                line(left, cy, right, cy, style.MUTED, 3),
                line(left, cy - 13, left, cy + 13, style.MUTED),
                line(right, cy - 13, right, cy + 13, style.MUTED),
                f'<rect x="{q1:.1f}" y="{cy - 21:.1f}" width="{max(1, q3 - q1):.1f}" '
                f'height="42" rx="5" fill="{color}" fill-opacity="0.23" stroke="{color}" stroke-width="3"/>',
                line(median, cy - 21, median, cy + 21, color, 4)]
        # At most 40 evenly sampled outlier dots per row; all samples stay in JSON.
        outliers = summary["outliers_ms"]
        if len(outliers) > 40:
            outliers = [outliers[round(i * (len(outliers) - 1) / 39)] for i in range(40)]
        for j, value in enumerate(outliers):
            out.append(f'<circle cx="{x(value):.1f}" cy="{cy + (j % 3 - 1) * 5:.1f}" r="3.5" fill="{color}"/>')
    out += [
        text((x0 + x1) / 2, bottom + 85, "Launch-to-exit wall time · log scale", 22, style.MUTED, "middle"),
        text(90, bottom + 130, "Box: middle 50% · center line: median · whiskers: 1.5× IQR · dots: sampled outliers", 22),
        line(90, bottom + 155, 1910, bottom + 155, style.GRID),
        text(90, bottom + 195, f"{result['cpu']} · {result['runs']} runs per terminal · {result['warmup']} warmups · shuffled rounds", 22),
        text(1910, bottom + 195, result["date"][:10], 22, anchor="end"),
        text(90, bottom + 235, "Existing user configs · warm caches · includes shutdown and harness overhead · not time to first frame", 22),
        "</svg>",
    ]
    return "\n".join(out)


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def nonnegative_int(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be a nonnegative integer")
    return number


def positive_float(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for key in SERIES:
        parser.add_argument(f"--{key}", default=key, help=f"{key} executable (default: PATH)")
    parser.add_argument("--runs", type=positive_int, default=100)
    parser.add_argument("--warmup", type=nonnegative_int, default=5, help="excluded warmup rounds per terminal (default: 5)")
    parser.add_argument("--timeout", type=positive_float, default=10, help="seconds per launch (default: 10)")
    parser.add_argument("--seed", type=int, default=0, help="round-order random seed (default: 0)")
    parser.add_argument("--out", type=Path, default=ROOT / "bench" / "startup")
    parser.add_argument("--chart-only", action="store_true", help="redraw OUT/results.json without launching terminals")
    args = parser.parse_args(argv)
    try:
        if args.chart_only:
            result = json.loads((args.out / "results.json").read_text())
        else:
            if not sys.platform.startswith("linux") or not os.environ.get("WAYLAND_DISPLAY"):
                raise ValueError("measurement requires a live Linux Wayland session (foot and Monstar are Wayland terminals)")
            result = measure(args)
        svg = chart(result)
        args.out.mkdir(parents=True, exist_ok=True)
        if not args.chart_only:
            (args.out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            print(f"wrote {args.out / 'results.json'}")
        (args.out / "chart.svg").write_text(svg)
        print(f"wrote {args.out / 'chart.svg'}")
        if shutil.which("rsvg-convert"):
            subprocess.run(["rsvg-convert", "-o", str(args.out / "chart.png"),
                            str(args.out / "chart.svg")], check=True)
            print(f"wrote {args.out / 'chart.png'}")
        else:
            print("PNG skipped: rsvg-convert not found", file=sys.stderr)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"error: {error}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
