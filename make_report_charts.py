#!/usr/bin/env python3
"""Draw the charts for PERFORMANCE-REPORT.md from a benchmark.sh result file.

Two SVGs per chart, one per colour scheme, paired in the report with
<picture> (GitHub strips <style>, so a single self-switching SVG would lose
its dark-mode rules):

  report-large-files-{light,dark}.svg  1 GB throughput per client, with the
                                       time a 10 GB dataset would take
  report-small-files-{light,dark}.svg  seconds per small-file operation,
                                       log scale

Every number is read from the result file, not typed here.

Run:  python3 make_report_charts.py results/benchmark.txt
"""

import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

THEMES = {
    "light": {"bg": "#ffffff", "text": "#1f2328", "muted": "#59636e",
              "accent": "#0969da", "grey": "#8c959f", "grid": "#d0d7de",
              "axis": "#8c959f", "bad": "#cf222e"},
    "dark": {"bg": "#0d1117", "text": "#e6edf3", "muted": "#8b949e",
             "accent": "#58a6ff", "grey": "#6e7681", "grid": "#30363d",
             "axis": "#6e7681", "bad": "#f85149"},
}
FONT = "-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif"

# Client order and names as benchmark.ps1 prints its columns.
CLIENTS = [("SMB", "Z:"), ("WebDAV", "W:"), ("rclone", "R:")]


def parse(path):
    """Return {operation: [smb_s, webdav_s, rclone_s]} from the results table."""
    ops = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^(\S.*?)\s{2,}(\d.*)$", line.rstrip())
        if not m:
            continue
        secs = [float(v) for v in re.findall(r"([\d.]+) s\b", m.group(2))]
        if len(secs) == 3:
            ops[m.group(1).strip()] = secs
    return ops


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, t, colour="text", size=13, weight=None, anchor="start"):
    w = f' font-weight="{weight}"' if weight else ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" font-size="{size}"'
            f'{w} fill="{t[colour]}" text-anchor="{anchor}">{esc(s)}</text>')


# ------------------------------------------------------------------------------
# Chart 1: large files
# ------------------------------------------------------------------------------
def large_files(ops, t):
    big = next(k for k in ops if k.endswith("write") and "GB" in k and "x" not in k)
    size_gb = float(big.split()[0])
    rows = []
    for direction in ("read", "write"):
        key = f"{big.split()[0]} GB {direction}"
        for (name, drive), sec in zip(CLIENTS, ops[key]):
            mbps = size_gb * 1024 / sec
            rows.append((direction.capitalize(), name, drive, mbps))
    peak = max(r[3] for r in rows)

    W, left, right, y0, bar, gap, group_gap = 860, 150, 560, 100, 24, 8, 36
    col = 690                    # the 10 GB column, clear of the longest bar's label
    H = y0 + 2 * 3 * (bar + gap) + group_gap + 20
    x = lambda v: left + v / peak * (right - left)
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
           f'role="img" aria-label="SMB moves large files fastest; Windows WebDAV cannot open files over 4 GB">',
           f'<rect width="{W}" height="{H}" fill="{t["bg"]}"/>',
           text(0, 26, "SMB moves large files fastest; Windows WebDAV can't open files over 4 GB", t, size=17, weight=600),
           text(0, 50, f"Throughput for a {size_gb:g} GB file (median of 3 runs), and the time a 10 GB dataset would take at that rate", t, "muted"),
           text(col, 84, "Time for 10 GB", t, "muted", weight=600)]
    y = y0
    for gi, direction in enumerate(("Read", "Write")):
        out.append(text(0, y - 10, direction, t, weight=600))
        for (d, name, drive, mbps) in [r for r in rows if r[0] == direction]:
            colour = t["accent"] if name == "SMB" else t["grey"]
            out.append(text(left - 12, y + bar / 2 + 5, f"{name} ({drive})", t, anchor="end"))
            out.append(f'<rect x="{left}" y="{y}" width="{x(mbps) - left:.1f}" height="{bar}" fill="{colour}" rx="2"/>')
            out.append(text(x(mbps) + 8, y + bar / 2 + 5, f"{mbps:,.0f} MB/s", t))
            if name == "WebDAV":
                out.append(text(col, y + bar / 2 + 5, "not possible (4 GB limit)", t, "bad"))
            else:
                minutes = 10240 / mbps / 60
                out.append(text(col, y + bar / 2 + 5, f"{minutes:.1f} min", t))
            y += bar + gap
        y += group_gap
    out.append(f'<line x1="{left}" x2="{left}" y1="{y0 - 4}" y2="{y - group_gap - gap + 4}" stroke="{t["axis"]}"/>')
    out.append("</svg>")
    return "".join(out)


# ------------------------------------------------------------------------------
# Chart 2: small files
# ------------------------------------------------------------------------------
def small_files(ops, t):
    count = next(k for k in ops if k.startswith("List")).split()[1]
    order = [
        (f"Write {int(count):,} files", next(k for k in ops if k.endswith("KB write"))),
        (f"Read {int(count):,} files", next(k for k in ops if k.endswith("KB read"))),
        (f"List {int(count):,} files", next(k for k in ops if k.startswith("List"))),
        (f"Delete {int(count):,} files", next(k for k in ops if k.startswith("Delete"))),
        ("Rename the folder", "Rename folder"),
    ]
    W, left, right, y0, row = 860, 170, 820, 118, 52
    H = y0 + len(order) * row + 26
    lo, hi = math.log10(0.01), math.log10(1000)
    x = lambda v: left + (math.log10(max(v, 0.01)) - lo) / (hi - lo) * (right - left)
    styles = {"SMB": (t["accent"], 1.0), "WebDAV": (t["grey"], 1.0), "rclone": (t["grey"], 0.5)}

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
           f'role="img" aria-label="SMB is fastest at every small-file operation except listing">',
           f'<rect width="{W}" height="{H}" fill="{t["bg"]}"/>',
           text(0, 26, "SMB is fastest at every small-file operation except listing", t, size=17, weight=600),
           text(0, 50, "Seconds per operation on 4 KB files, median of 3 runs. Log scale: each gridline is 10 times the last.", t, "muted")]
    # legend
    lx = 2
    for name, drive in CLIENTS:
        colour, op = styles[name]
        shape = (f'<rect x="{lx}" y="68" width="12" height="12" fill="{colour}" fill-opacity="{op}"/>' if name == "rclone"
                 else f'<circle cx="{lx + 6}" cy="74" r="6.5" fill="{colour}" fill-opacity="{op}"/>')
        out.append(shape + text(lx + 18, 79, f"{name} ({drive})", t))
        lx += 150
    # grid
    for tick in (0.01, 0.1, 1, 10, 100, 1000):
        out.append(f'<line x1="{x(tick):.1f}" x2="{x(tick):.1f}" y1="{y0 - 22}" y2="{H - 30}" stroke="{t["grid"]}"/>')
        label = f"{tick:g} s" if tick < 1 else f"{tick:,.0f} s"
        out.append(text(x(tick), H - 10, label, t, "muted", size=12, anchor="middle"))
    # rows
    for i, (label, key) in enumerate(order):
        y = y0 + i * row
        secs = ops[key]
        out.append(text(left - 14, y + 5, label, t, anchor="end"))
        out.append(f'<line x1="{x(min(secs)):.1f}" x2="{x(max(secs)):.1f}" y1="{y}" y2="{y}" stroke="{t["grid"]}" stroke-width="3"/>')
        # value labels alternate above/below to stay clear of each other
        placed = []
        for (name, drive), s in sorted(zip(CLIENTS, secs), key=lambda p: p[1]):
            colour, op = styles[name]
            cx = x(s)
            if name == "rclone":
                out.append(f'<rect x="{cx - 7:.1f}" y="{y - 7}" width="14" height="14" fill="{colour}" fill-opacity="{op}"/>')
            else:
                out.append(f'<circle cx="{cx:.1f}" cy="{y}" r="7.5" fill="{colour}" fill-opacity="{op}"/>')
            above = not placed or abs(cx - placed[-1][0]) > 44 or not placed[-1][1]
            placed.append((cx, above))
            val = f"{s:.2f}" if s < 1 else (f"{s:.1f}" if s < 10 else f"{s:,.0f}")
            out.append(text(cx, y - 14 if above else y + 24, val, t, "muted", size=12, anchor="middle"))
    out.append("</svg>")
    return "".join(out)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results", "benchmark.txt")
    ops = parse(src)
    for name, theme in THEMES.items():
        for stem, fn in (("report-large-files", large_files), ("report-small-files", small_files)):
            path = os.path.join(HERE, f"{stem}-{name}.svg")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(fn(ops, theme))
            print(f"  {stem}-{name}.svg")


if __name__ == "__main__":
    main()
