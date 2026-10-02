#!/usr/bin/env python3
"""Draw the README charts as light and dark SVG.

Usage: python3 docs/diagrams/charts.py
Writes measured-*.svg, cost-*.svg, attempts-*.svg, and autoscale-*.svg next to this file.
Every figure is copied from the README tables and docs/runs/. Change a figure
there first, then here.
"""
from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
W = 1000
MONO = 'ui-monospace, "SFMono-Regular", "SF Mono", Menlo, Consolas, monospace'

# Quoin tokens (chrome) and Quoin chart palette (data marks).
THEMES = {
    "light": dict(paper="#FCFBF9", ink="#2B2926", ink2="#6A625A", rule="#D2CCC3", tint="#EBE6DD",
                  series=["#33703F", "#0084A9", "#916A0B", "#90302B", "#23749E"]),
    "dark": dict(paper="#0E1C2B", ink="#E8E2D6", ink2="#A8A296", rule="#2D4152", tint="#1F3142",
                 series=["#6DA361", "#17A1C8", "#9C7300", "#D17276", "#559ACA"]),
}
GREEN, BLUE, OCHRE, RED, STEEL = range(5)


def text(x, y, s, size, fill, anchor="start", weight=None, ls=0):
    extra = ""
    if anchor != "start":
        extra += f' text-anchor="{anchor}"'
    if weight:
        extra += f' font-weight="{weight}"'
    if ls:
        extra += f' letter-spacing="{ls}"'
    return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}"{extra}>{escape(s)}</text>'


def rect(x, y, w, h, fill, rx=2):
    return f'<rect x="{x:.1f}" y="{y}" width="{max(w, 0):.1f}" height="{h}" rx="{rx}" fill="{fill}"/>'


def svg(h, title, desc, body, c):
    return (
        f'<svg viewBox="0 0 {W} {h}" xmlns="http://www.w3.org/2000/svg" role="img" '
        f'font-family=\'{MONO}\'>\n<title>{escape(title)}</title>\n<desc>{escape(desc)}</desc>\n'
        f'<rect width="{W}" height="{h}" rx="6" fill="{c["paper"]}"/>\n'
        + text(40, 44, title, 17, c["ink"], weight=600)
        + f'\n<line x1="40" y1="60" x2="960" y2="60" stroke="{c["rule"]}"/>\n'
        + "\n".join(body) + "\n</svg>\n"
    )


def measured(c):
    """Four paired bars: nimble-oke on OKE against nim-gke on GKE."""
    panels = [
        ("Scale-up: pod Pending to GPU node Ready", [(385, "385 s"), (77, "77 s")]),
        ("Scale-down: zero replicas to no GPU node",
         [(312, "312 s, timers set to 3 min"), (752, "752 s, default delay")]),
        ("Script start to NIM Ready, autoscale", [(1384, "23 min 04 s"), (967, "16 min 07 s")]),
        ("Posted list cost, every start", [(1.17, "$1.17"), (1.19, "$1.19")]),
    ]
    names = ["OKE, one A10", "GKE, one L4"]
    colours = [c["series"][GREEN], c["series"][BLUE]]
    b = []
    for i, (label, rows) in enumerate(panels):
        x0 = 40 + (i % 2) * 470
        y0 = 96 + (i // 2) * 150
        b.append(text(x0, y0, label, 12.5, c["ink"], weight=600))
        top = max(v for v, _ in rows)
        for j, (v, shown) in enumerate(rows):
            y = y0 + 18 + j * 42
            b.append(text(x0, y + 15, names[j], 11.5, c["ink2"]))
            b.append(rect(x0 + 110, y, 330, 22, c["tint"]))
            w = 330 * v / top
            b.append(rect(x0 + 110, y, w, 22, colours[j]))
            b.append(text(x0 + 110, y + 36, shown, 11.5, c["ink"]))
    b.append(f'<line x1="40" y1="398" x2="960" y2="398" stroke="{c["rule"]}"/>')
    b.append(text(40, 422, "One run each, on different hardware. This is a record of each run, "
                  "not a benchmark of the two platforms.", 11.5, c["ink2"]))
    desc = ("Scale-up 385 s on OKE and 77 s on GKE. Scale-down 312 s on OKE with timers set to "
            "3 minutes and 752 s on GKE with the default delay. Script start to NIM Ready with "
            "autoscale 23 min 04 s on OKE and 16 min 07 s on GKE. Posted list cost for every "
            "start $1.17 on OKE and $1.19 on GKE.")
    return svg(444, "Measured side by side", desc, b, c)


def cost(c):
    """Posted OCI cost per run, stacked by billing line."""
    lines = [("GPU, VM.GPU.A10.1", GREEN), ("Enhanced cluster fee", BLUE),
             ("System node, E4.Flex", OCHRE), ("Block volume", STEEL)]
    runs = [("Run 1, fixed pool", [0.5217, 0.0716, 0.0255, 0.0109], "$0.63"),
            ("Run 2, autoscale", [0.4622, 0.0382, 0.0252, 0.0091], "$0.53")]
    scale = 640 / 0.70
    b = []
    for i, (name, vals, total) in enumerate(runs):
        y = 92 + i * 56
        b.append(text(40, y + 19, name, 12.5, c["ink"]))
        x = 220.0
        for v, (_, s) in zip(vals, lines):
            b.append(rect(x, y, v * scale - 1.5, 28, c["series"][s], rx=1))
            x += v * scale
        b.append(text(x + 10, y + 19, total, 13, c["ink"], weight=600))
    b.append(f'<line x1="40" y1="214" x2="960" y2="214" stroke="{c["rule"]}"/>')
    b.append(text(600, 240, "Run 1", 11.5, c["ink2"], anchor="end"))
    b.append(text(720, 240, "Run 2", 11.5, c["ink2"], anchor="end"))
    for k, (name, s) in enumerate(lines):
        y = 264 + k * 24
        b.append(rect(40, y - 11, 12, 12, c["series"][s]))
        b.append(text(62, y, name, 12, c["ink"]))
        b.append(text(600, y, f"${runs[0][1][k]:.4f}", 12, c["ink"], anchor="end"))
        b.append(text(720, y, f"${runs[1][1][k]:.4f}", 12, c["ink"], anchor="end"))
    b.append(text(40, 372, "Posted usage from OCI Cost Analysis, read on 2026-10-02. Not an invoice.",
                  11.5, c["ink2"]))
    desc = ("Run 1 posted $0.63: GPU $0.5217, enhanced cluster $0.0716, system node $0.0255, "
            "block volume $0.0109. Run 2 posted $0.53: GPU $0.4622, enhanced cluster $0.0382, "
            "system node $0.0252, block volume $0.0091.")
    return svg(394, "Posted OCI cost by billing line", desc, b, c)


def attempts(c):
    """Six starts on 2026-10-01, on a UTC time axis."""
    t0, t1 = 18 * 60 + 40, 20 * 60 + 50  # 18:40 to 20:50 UTC, in minutes
    x0, x1 = 300, 940

    def px(minute):
        return x0 + (x1 - x0) * (minute - t0) / (t1 - t0)

    rows = [  # label, start minute, duration in minutes, PASS, note
        ("1  Fixed pool", 18 * 60 + 46, 12.67, False, "FAIL at node pool create · $0.0017"),
        ("2  Fixed pool", 19 * 60, 54.2, True, "PASS · $0.63"),
        ("3  IAM setup, apply", 20 * 60, 0, False, "FAIL, 403 · $0"),
        ("4  IAM setup, check", 20 * 60 + 5, 0, False, "false FAIL · $0"),
        ("5  Autoscale", 20 * 60 + 7, 0.03, False, "FAIL in preflight · $0"),
        ("6  Autoscale", 20 * 60 + 12, 35.57, True, "PASS · $0.53"),
    ]
    b = []
    for hour in (19, 20):
        x = px(hour * 60)
        b.append(f'<line x1="{x:.1f}" y1="78" x2="{x:.1f}" y2="322" stroke="{c["rule"]}" stroke-dasharray="3 4"/>')
        b.append(text(x, 342, f"{hour}:00 UTC", 11, c["ink2"], anchor="middle"))
    for i, (label, start, dur, ok, note) in enumerate(rows):
        y = 84 + i * 40
        colour = c["series"][GREEN] if ok else c["series"][RED]
        b.append(text(40, y + 17, label, 12.5, c["ink"]))
        x = px(start)
        w = max(px(start + dur) - x, 6)
        b.append(rect(x, y, w, 24, colour))
        right = x + w + 10
        if right + len(note) * 7.2 > 960:  # no room on the right: put the note on the left
            b.append(text(x - 10, y + 17, note, 11.5, c["ink"], anchor="end"))
        else:
            b.append(text(right, y + 17, note, 11.5, c["ink"]))
    b.append(text(40, 372, "Attempts 3 and 4 have no phase log; their times come from the fix commits. "
                  "The day's posted total is $1.17.", 11.5, c["ink2"]))
    desc = ("Six starts on 2026-10-01. 18:46 fixed pool failed at node pool create, $0.0017. "
            "19:00 fixed pool passed, $0.63. About 20:00 IAM apply failed with 403. About 20:05 IAM "
            "check gave a false fail. 20:07 autoscale failed in preflight. 20:12 autoscale passed, $0.53.")
    return svg(394, "Every attempt on 2026-10-01", desc, b, c)


def autoscale(c):
    """The GPU node pool going 0 to 1 to 0 in run 2, with the two measured spans."""
    steps = [("Pool at 0 nodes", "cluster up, no GPU"),
             ("NIM pod Pending", "asks for one GPU"),
             ("GPU node Ready", "autoscaler added it"),
             ("NIM serving", "5 of 5, then replicas 0"),
             ("Pool back at 0", "autoscaler removed it")]
    b = []
    for i, (label, sub) in enumerate(steps):
        x = 40 + i * 190
        edge = c["series"][GREEN] if i in (0, 4) else c["rule"]
        b.append(f'<rect x="{x}" y="92" width="160" height="66" rx="4" fill="{c["tint"]}" stroke="{edge}"/>')
        b.append(text(x + 80, 120, label, 12.5, c["ink"], anchor="middle", weight=600))
        b.append(text(x + 80, 141, sub, 10.5, c["ink2"], anchor="middle"))
        if i < 4:
            b.append(f'<path d="M{x + 164} 125 H{x + 182} m-6 -5 l6 5 l-6 5" fill="none" stroke="{c["ink2"]}" stroke-width="1.5"/>')
    for first, label, colour in ((1, "scale-up: 385 s", GREEN), (3, "scale-down: 312 s", BLUE)):
        xa, xb = 40 + first * 190 + 80, 40 + (first + 1) * 190 + 80
        b.append(f'<path d="M{xa} 170 V182 H{xb} V170" fill="none" stroke="{c["series"][colour]}" stroke-width="2"/>')
        b.append(text((xa + xb) / 2, 204, label, 13, c["ink"], anchor="middle", weight=600))
    b.append(text(40, 244, "Run 2, 2026-10-01, one VM.GPU.A10.1. Measured once. "
                  "Scale-down ran with the autoscaler timers set to 3 minutes.", 11.5, c["ink2"]))
    desc = ("The GPU node pool starts at 0 nodes. The NIM pod goes Pending and asks for one GPU. "
            "The GPU node is Ready 385 s later. NIM serves 5 of 5 requests, then replicas are set "
            "to 0. The pool is back at 0 nodes 312 s after that.")
    return svg(266, "GPU node autoscaling, 0 to 1 to 0", desc, b, c)


def main():
    for name, fn in (("measured", measured), ("cost", cost), ("attempts", attempts),
                     ("autoscale", autoscale)):
        for theme, c in THEMES.items():
            (HERE / f"{name}-{theme}.svg").write_text(fn(c))
        print("built", name)


if __name__ == "__main__":
    main()
