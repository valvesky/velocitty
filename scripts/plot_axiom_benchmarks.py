#!/usr/bin/env python3
"""Render the captured 1.3 -> 1.3.1 instruction comparison as SVG and PNG."""

import argparse
import html
import json
from pathlib import Path
import shutil
import statistics
import subprocess


ROOT = Path(__file__).resolve().parents[1]
WORKLOADS = (
    ("progress", "Progress redraws", "106-byte updates"),
    ("progress-short", "Short redraws", "26-byte updates"),
    ("ascii", "Scrolling ASCII", "CRLF lines"),
    ("unicode", "Unicode", "Mixed scripts and emoji"),
    ("csi-short", "CSI redraws", "Cursor moves and short SGR"),
)


def comparison(data):
    rows = []
    for name, label, detail in WORKLOADS:
        samples = [
            [s["instructions"] for s in data["samples"]
             if s["workload"] == name and s["binary"] == binary]
            for binary in (0, 1)
        ]
        if not samples[0] or len(samples[0]) != len(samples[1]):
            raise ValueError(f"missing or unmatched samples for {name}")
        before, after = (statistics.median(s) for s in samples)
        if before <= 0 or after <= 0:
            raise ValueError(f"invalid instruction count for {name}")
        rows.append((label, detail, before, after))
    return rows


def chart(data):
    rows = comparison(data)
    width, height = 1800, 1120
    left, plot_width, top, pitch = 570, 810, 285, 130
    ink, secondary, grid = "#0b0b0b", "#52514e", "#e1e0d9"
    before_color, after_color = "#c3c2b7", "#15836b"
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="title description" '
        'font-family="system-ui, -apple-system, Segoe UI, sans-serif">',
        '<title id="title">Velocitty 1.3.1: fewer instructions for progress redraws</title>',
        '<desc id="description">User-mode instructions normalized to the 1.3 baseline. '
        'Lower is better. Progress redraws use about 65 percent fewer instructions.</desc>',
        f'<rect width="{width}" height="{height}" fill="#fcfcfb"/>',
        f'<text x="80" y="100" font-size="54" font-weight="500" fill="{ink}">Less work for progress redraws</text>',
        f'<text x="80" y="151" font-size="28" fill="{secondary}">User-mode instructions · 1.3 baseline = 100% · lower is better</text>',
        f'<rect x="80" y="190" width="28" height="23" rx="3" fill="{before_color}"/>',
        f'<text x="122" y="210" font-size="24" fill="{secondary}">1.3 before</text>',
        f'<rect x="370" y="190" width="28" height="23" rx="3" fill="{after_color}"/>',
        f'<text x="412" y="210" font-size="24" fill="{secondary}">1.3.1 progress proof</text>',
        f'<text x="1720" y="259" text-anchor="end" font-size="23" fill="{secondary}">Change</text>',
    ]
    for percent in (0, 25, 50, 75, 100):
        x = left + plot_width * percent / 100
        svg.append(f'<line x1="{x}" y1="275" x2="{x}" y2="940" stroke="{grid}"/>')
        svg.append(f'<text x="{x}" y="259" text-anchor="middle" font-size="21" fill="{secondary}">{percent}%</text>')
    for i, (label, detail, before, after) in enumerate(rows):
        y = top + i * pitch
        ratio = after / before
        change = (ratio - 1) * 100
        svg.extend((
            f'<text x="80" y="{y + 30}" font-size="29" font-weight="600" fill="{ink}">{html.escape(label)}</text>',
            f'<text x="80" y="{y + 61}" font-size="22" fill="{secondary}">{html.escape(detail)}</text>',
            f'<text x="80" y="{y + 95}" font-size="23" fill="{secondary}">{before / 1e6:.2f}M → {after / 1e6:.2f}M</text>',
            f'<rect data-row="{i}" data-series="before" x="{left}" y="{y + 20}" width="{plot_width}" height="24" rx="3" fill="{before_color}"/>',
            f'<rect data-row="{i}" data-series="after" x="{left}" y="{y + 58}" width="{plot_width * ratio:.3f}" height="24" rx="3" fill="{after_color}"/>',
            f'<text x="{left + plot_width + 14}" y="{y + 41}" font-size="22" fill="{secondary}">100%</text>',
            f'<text x="{left + plot_width * ratio + 14:.3f}" y="{y + 79}" font-size="22" fill="{ink}">{ratio * 100:.1f}%</text>',
            f'<text x="1720" y="{y + 72}" text-anchor="end" font-size="30" font-weight="500" fill="{after_color}">{change:+.1f}%</text>',
        ))
    svg.extend((
        f'<line x1="80" y1="969" x2="1720" y2="969" stroke="{grid}" stroke-width="2"/>',
        f'<text x="80" y="1011" font-size="23" fill="{secondary}">Intel Core i7-10610U · 120×80 cells · 1 MiB ring · median of 3 interleaved runs</text>',
        f'<text x="80" y="1047" font-size="22" fill="{secondary}">perf stat instructions:u · +terminal-stream --drop · no rendering or presentation · 2026-11-02</text>',
        f'<text x="80" y="1083" font-size="21" fill="{secondary}">Identical input per workload. These are instruction counts, not frame rates or input-latency measurements.</text>',
        '</svg>',
    ))
    return "\n".join(svg) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, default=ROOT / "docs/performance-1.3.1.json")
    parser.add_argument("--output", type=Path, default=ROOT / "docs/velocitty-1.3.1-performance")
    args = parser.parse_args()
    data = json.loads(args.results.read_text())
    # The version contains dots, so preserve the complete prefix when adding a suffix.
    svg, png = Path(str(args.output) + ".svg"), Path(str(args.output) + ".png")
    svg.write_text(chart(data))
    renderer = shutil.which("rsvg-convert")
    if renderer is None:
        parser.error("PNG export requires rsvg-convert (librsvg)")
    subprocess.run([renderer, "-o", str(png), str(svg)], check=True)
    print(f"wrote {svg} and {png}")


if __name__ == "__main__":
    main()
