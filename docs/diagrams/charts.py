#!/usr/bin/env python3
"""Draw the README diagrams and charts as light and dark SVG.

Usage: python3 docs/diagrams/charts.py
Writes six pairs next to this file: deploys, runner-ends, measured, cost,
attempts, and autoscale, each as <name>-light.svg and <name>-dark.svg.
Every figure is copied from the README and docs/runs/. Change a figure
there first, then here.

The canvas is 360 units wide, the width of a phone column, so text keeps its
size when GitHub fits the image to a phone. The README caps the width on a
desktop with the img width attribute.
"""
import textwrap
from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent
W = 360
M, R = 16, 344  # left and right text margins
CH = 0.6        # width of one monospace character, as a share of the font size
MONO = 'ui-monospace, "SFMono-Regular", "SF Mono", Menlo, Consolas, monospace'

# Quoin tokens (chrome) and Quoin chart palette (data marks).
THEMES = {
    "light": dict(paper="#FCFBF9", ink="#2B2926", ink2="#6A625A", rule="#D2CCC3", tint="#EBE6DD",
                  series=["#33703F", "#0084A9", "#916A0B", "#90302B", "#23749E"]),
    "dark": dict(paper="#0E1C2B", ink="#E8E2D6", ink2="#A8A296", rule="#2D4152", tint="#1F3142",
                 series=["#6DA361", "#17A1C8", "#9C7300", "#D17276", "#559ACA"]),
}
GREEN, BLUE, OCHRE, RED, STEEL = range(5)


def text(x, y, s, size, fill, anchor="start", weight=None):
    extra = ""
    if anchor != "start":
        extra += f' text-anchor="{anchor}"'
    if weight:
        extra += f' font-weight="{weight}"'
    return f'<text x="{x:g}" y="{y:g}" font-size="{size}" fill="{fill}"{extra}>{escape(s)}</text>'


def rect(x, y, w, h, fill, rx=2):
    return f'<rect x="{x:.1f}" y="{y:g}" width="{max(w, 0):.1f}" height="{h:g}" rx="{rx}" fill="{fill}"/>'


def fit(s, size, width):
    """Split a string into lines that fit a width at this font size."""
    return textwrap.wrap(s, max(int(width / (size * CH)), 1), break_on_hyphens=False)


def para(x, y, s, size, fill, width, weight=None):
    """Wrapped text from baseline y. Returns (elements, next baseline)."""
    lines = fit(s, size, width)
    lead = size + 5
    return [text(x, y + i * lead, line, size, fill, weight=weight) for i, line in enumerate(lines)], y + len(lines) * lead


def note(y, s, c):
    return para(M, y, s, 12, c["ink2"], R - M)


def head(title, c):
    """Chart title and rule. Returns (elements, next baseline)."""
    b, y = para(M, 30, title, 15, c["ink"], R - M, weight=600)
    b.append(f'<line x1="{M}" y1="{y - 8}" x2="{R}" y2="{y - 8}" stroke="{c["rule"]}"/>')
    return b, y + 16


def svg(h, title, desc, body, c):
    return (
        f'<svg viewBox="0 0 {W} {h:g}" xmlns="http://www.w3.org/2000/svg" role="img" '
        f'font-family=\'{MONO}\'>\n<title>{escape(title)}</title>\n<desc>{escape(desc)}</desc>\n'
        f'<rect width="{W}" height="{h:g}" rx="6" fill="{c["paper"]}"/>\n'
        + "\n".join(body) + "\n</svg>\n"
    )


def arrow(points, colour, c, dashed=False, width=1.5):
    """Line through the points with a head at the last one."""
    (x1, y1), (x2, y2) = points[-2], points[-1]
    d = "M" + " L".join(f"{x:g} {y:g}" for x, y in points)
    dash = ' stroke-dasharray="5 4"' if dashed else ""
    if x1 == x2:  # vertical last segment
        s = 1 if y2 > y1 else -1
        tip = f"{x2 - 5:g},{y2 - 8 * s:g} {x2 + 5:g},{y2 - 8 * s:g} {x2:g},{y2:g}"
    else:
        s = 1 if x2 > x1 else -1
        tip = f"{x2 - 8 * s:g},{y2 - 5:g} {x2 - 8 * s:g},{y2 + 5:g} {x2:g},{y2:g}"
    return (f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="{width}"{dash}/>'
            f'<polygon points="{tip}" fill="{colour}"/>')


def tag(x, y, s, fill, c, anchor="middle"):
    """A label on a paper patch, so it stays readable over a line."""
    w = len(s) * 12 * CH + 10
    x0 = x - w / 2 if anchor == "middle" else x - 4
    return rect(x0, y - 13, w, 18, c["paper"], rx=3) + text(x, y, s, 12, fill, anchor=anchor)


def kind(c):
    """Outline colour for each kind of box."""
    s = c["series"]
    return dict(backend=s[GREEN], database=s[STEEL], cloud=s[OCHRE], external=c["ink2"],
                security=s[RED], bus=s[BLUE])


def box_lines(sub, extra, w):
    return fit(sub, 12, w - 16), (fit(extra, 12, w - 16) if extra else [])


def box_h(sub, extra, w):
    a, b = box_lines(sub, extra, w)
    return 38 + 16 * (len(a) + len(b))


def box(x, y, w, h, label, sub, extra, k, c):
    """A labelled box: name, description lines, and an optional coloured line."""
    col = kind(c)[k]
    a, e = box_lines(sub, extra, w)
    b = [f'<rect x="{x}" y="{y:g}" width="{w}" height="{h:g}" rx="5" fill="{c["tint"]}" stroke="{col}" stroke-width="1.5"/>',
         text(x + w / 2, y + 23, label, 12.5, c["ink"], anchor="middle", weight=600)]
    for i, line in enumerate(a):
        b.append(text(x + w / 2, y + 41 + i * 16, line, 12, c["ink2"], anchor="middle"))
    for i, line in enumerate(e):
        b.append(text(x + w / 2, y + 41 + (len(a) + i) * 16, line, 12, col, anchor="middle"))
    return b


def region(x, y, w, h, c):
    return (f'<rect x="{x}" y="{y:g}" width="{w}" height="{h:g}" rx="8" fill="none" '
            f'stroke="{c["series"][OCHRE]}" stroke-dasharray="7 5"/>')


def legend(y, entries, c):
    """Two-column key. entries: (kind, label). Returns (elements, next y)."""
    b = [text(M, y, "Legend", 12.5, c["ink"], weight=600)]
    for i, (k, label) in enumerate(entries):
        x, yy = (M, 188)[i % 2], y + 22 + (i // 2) * 22
        b.append(f'<rect x="{x}" y="{yy - 10}" width="16" height="11" rx="2.5" fill="{c["tint"]}" stroke="{kind(c)[k]}" stroke-width="1.5"/>')
        b.append(text(x + 24, yy, label, 12, c["ink2"]))
    return b, y + 22 + ((len(entries) + 1) // 2) * 22


def deploys(c):
    """What the kit deploys: client and registry outside the cluster, four parts inside."""
    d = DEPLOYS
    ink2, bw = c["ink2"], 148
    xl, xr = 24, 188
    b = []
    y1 = 16
    h1 = max(box_h(d["client"][1], None, 156), box_h(d["ngc"][1], None, 156))
    b += box(16, y1, 156, h1, *d["client"], None, "external", c)
    b += box(188, y1, 156, h1, *d["ngc"], None, "external", c)
    y2 = y1 + h1 + 48
    h2 = box_h(d["nim"][1], d["nim"][2], 312)
    y3 = y2 + h2 + 48
    h3 = max(box_h(d["cache"][1], None, bw), box_h(d["gpu"][1], d["gpu"][2], bw))
    y4 = y3 + h3 + 48
    h4 = box_h(d["autoscaler"][1], None, bw)
    b.append(region(8, y2 - 14, 344, y4 + h4 + 14 - (y2 - 14), c))
    b.append(arrow([(94, y1 + h1), (94, y2)], c["series"][GREEN], c, width=2))
    b.append(tag(94, y1 + h1 + 27, "OpenAI-compatible API", c["series"][GREEN], c))
    b.append(arrow([(266, y1 + h1), (266, y2)], ink2, c))
    b.append(tag(266, y1 + h1 + 27, "image pull", ink2, c))
    b += box(xl, y2, 312, h2, *d["nim"], "backend", c)
    b.append(arrow([(xl + bw / 2, y2 + h2), (xl + bw / 2, y3)], ink2, c))
    b.append(tag(xl + bw / 2, y2 + h2 + 27, "model files", ink2, c))
    b.append(arrow([(xr + bw / 2, y2 + h2), (xr + bw / 2, y3)], ink2, c))
    b.append(tag(xr + bw / 2, y2 + h2 + 27, "scheduled on", ink2, c))
    b += box(xl, y3, bw, box_h(d["cache"][1], None, bw), *d["cache"], None, "database", c)
    b += box(xr, y3, bw, h3, *d["gpu"], "cloud", c)
    b.append(arrow([(xr + bw / 2, y4), (xr + bw / 2, y3 + h3)], c["series"][BLUE], c, dashed=True))
    b.append(tag(xr + bw / 2, y3 + h3 + 27, "adds and removes", c["series"][BLUE], c))
    b += box(xr, y4, bw, h4, *d["autoscaler"], None, "cloud", c)
    lines = fit(d["cluster"], 12, 156)
    for i, line in enumerate(lines):
        b.append(text(20, y4 + h4 - 4 - (len(lines) - 1 - i) * 17, line, 12, c["series"][OCHRE], weight=600))
    leg, y = legend(y4 + h4 + 42, [("backend", "Backend"), ("database", "Database"),
                                   ("cloud", "Cloud"), ("external", "External")], c)
    return svg(y, d["title"], d["desc"], b + leg, c)


def runner_ends(c):
    """How the runner ends: the runner's steps on the left, the watchdog on the right."""
    n = RUNNER
    ink2, bw = c["ink2"], 148
    xl, xr = 16, 196
    cl, cr = xl + bw / 2, xr + bw / 2

    def h(key):
        return box_h(n[key][1], n[key][2], bw)

    top = 12
    y1 = top + 30
    r1 = max(h("preflight"), h("arm"))
    y2 = y1 + r1 + 34
    y3 = y2 + h("steps") + 34
    y4 = y3 + h("teardown") + 34
    r4 = max(h("confirm"), h("takeover"))
    y5 = y4 + r4 + 56
    b = [region(8, top, 164, y5 + h("done") + 12 - top, c),
         region(188, top, 164, y4 + r4 + 12 - top, c),
         text(18, top + 19, n["lanes"][0], 12, c["series"][OCHRE], weight=600),
         text(194, top + 19, n["lanes"][1], 12, c["series"][OCHRE], weight=600)]
    b.append(arrow([(xl + bw, y1 + 27), (xr, y1 + 27)], ink2, c))
    b.append(arrow([(cr - 34, y1 + h("arm")), (cr - 34, y1 + r1 + 17), (cl, y1 + r1 + 17), (cl, y2)], ink2, c))
    b.append(arrow([(cl, y2 + h("steps")), (cl, y3)], ink2, c))
    b.append(arrow([(cl, y3 + h("teardown")), (cl, y4)], ink2, c))
    b.append(arrow([(cr + 30, y1 + h("arm")), (cr + 30, y4)], c["series"][BLUE], c, dashed=True))
    b.append(tag(cr + 30, (y2 + y4) / 2, "takes over", c["series"][BLUE], c))
    b.append(arrow([(xr, y4 + 27), (xl + bw, y4 + 27)], ink2, c))
    b.append(arrow([(cl - 30, y4 + h("confirm")), (cl - 30, y5)], c["series"][GREEN], c, width=2))
    b.append(tag(cl - 20, y4 + h("confirm") + 22, "yes", c["series"][GREEN], c, anchor="start"))
    turn = y4 + r4 + 34
    b.append(arrow([(cl + 30, y4 + h("confirm")), (cl + 30, turn), (cr, turn), (cr, y5)], c["series"][RED], c, dashed=True))
    b.append(tag(cl + 40, y4 + h("confirm") + 22, "no", c["series"][RED], c, anchor="start"))
    for key, x, y in (("preflight", xl, y1), ("arm", xr, y1), ("steps", xl, y2), ("teardown", xl, y3),
                      ("confirm", xl, y4), ("takeover", xr, y4), ("done", xl, y5), ("manual", xr, y5)):
        label, sub, extra, k = n[key]
        b += box(x, y, bw, h(key), label, sub, extra, k, c)
    leg, y = legend(y5 + max(h("done"), h("manual")) + 40,
                    [("backend", "Runner step"), ("security", "Check"), ("bus", "Watchdog action"),
                     ("cloud", "Clean exit"), ("external", "Manual follow-up")], c)
    return svg(y, n["title"], n["desc"], b + leg, c)


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
    b, y = head("Measured side by side", c)
    for label, rows in panels:
        lines, y = para(M, y, label, 13, c["ink"], R - M, weight=600)
        b += lines
        top = max(v for v, _ in rows)
        for j, (v, shown) in enumerate(rows):
            b.append(text(M, y + 4, names[j], 12, c["ink2"]))
            b.append(text(R, y + 4, shown, 12, c["ink"], anchor="end"))
            b.append(rect(M, y + 11, R - M, 14, c["tint"]))
            b.append(rect(M, y + 11, (R - M) * v / top, 14, colours[j]))
            y += 44
        y += 10
    b.append(f'<line x1="{M}" y1="{y - 12}" x2="{R}" y2="{y - 12}" stroke="{c["rule"]}"/>')
    lines, y = note(y + 10, "One run each, on different hardware. This is a record of each run, "
                    "not a benchmark of the two platforms.", c)
    desc = ("Scale-up 385 s on OKE and 77 s on GKE. Scale-down 312 s on OKE with timers set to "
            "3 minutes and 752 s on GKE with the default delay. Script start to NIM Ready with "
            "autoscale 23 min 04 s on OKE and 16 min 07 s on GKE. Posted list cost for every "
            "start $1.17 on OKE and $1.19 on GKE.")
    return svg(y, "Measured side by side", desc, b + lines, c)


def autoscale(c):
    """The GPU node pool going 0 to 1 to 0, with the two measured spans."""
    a = AUTOSCALE
    steps = [("Pool at 0 nodes", "cluster up, no GPU"),
             ("NIM pod Pending", "asks for one GPU"),
             ("GPU node Ready", "autoscaler added it"),
             ("NIM serving", a["serving"]),
             ("Pool back at 0", "autoscaler removed it")]
    spans = {1: (a["up"], GREEN), 3: (a["down"], BLUE)}
    b, y = head("GPU node autoscaling, 0 to 1 to 0", c)
    y -= 12
    for i, (label, sub) in enumerate(steps):
        edge = c["series"][GREEN] if i in (0, 4) else c["rule"]
        b.append(f'<rect x="{M}" y="{y}" width="{R - M}" height="46" rx="4" fill="{c["tint"]}" stroke="{edge}"/>')
        b.append(text(M + 14, y + 19, label, 13, c["ink"], weight=600))
        b.append(text(M + 14, y + 37, sub, 12, c["ink2"]))
        if i < 4:
            label, colour = spans.get(i, ("", None))
            stroke = c["series"][colour] if label else c["ink2"]
            b.append(arrow([(M + 24, y + 50), (M + 24, y + 78)], stroke, c, width=2 if label else 1.5))
            if label:
                b.append(text(M + 42, y + 69, label, 13, c["ink"], weight=600))
        y += 82
    lines, y = note(y - 14, a["foot"], c)
    return svg(y, "GPU node autoscaling, 0 to 1 to 0", a["desc"], b + lines, c)


# Box entries: (name, description, coloured line or None[, kind]).
DEPLOYS = dict(
    title="Nimble OKE: what it deploys",
    desc=("A client (curl or an OpenAI SDK) calls the NIM pod over the OpenAI-compatible API on port "
          "8000. The NIM pod runs llama3-8b-instruct 1.0.3. It pulls its image from the NGC registry "
          "and keeps model files on a 100 Gi block volume. It is scheduled on one GPU node, "
          "VM.GPU.A10.1. With --autoscale, the Cluster Autoscaler on the E4.Flex system node adds and "
          "removes that node. The pod, volume, GPU node, and autoscaler sit inside the OKE enhanced "
          "cluster, Kubernetes v1.34.1."),
    client=("Client", "curl or OpenAI SDK"),
    ngc=("NGC registry", "nvcr.io/nim/meta"),
    nim=("NIM pod", "llama3-8b-instruct 1.0.3", "port 8000"),
    cache=("Block volume", "100 Gi model cache"),
    gpu=("GPU node", "VM.GPU.A10.1, one A10 24 GB", "pool size 0 to 1"),
    autoscaler=("Cluster Autoscaler", "on the E4.Flex system node"),
    cluster="OKE enhanced cluster, Kubernetes v1.34.1",
)
RUNNER = dict(
    title="How the runner ends",
    desc=("Preflight checks that the step timeouts fit the watchdog limit. The watchdog is armed in "
          "its own session before anything billable exists. The steps run, each with a hard timeout. "
          "Teardown runs from a trap on every exit and is retried until the deletes are confirmed; "
          "the runner then exits 0 with the cluster deleted. If the runner dies or the time limit "
          "passes, the watchdog runs teardown. If teardown cannot be confirmed, the runner exits "
          "non-zero, prints the oci delete commands, and leaves the watchdog armed."),
    lanes=("Runner", "Watchdog, own session"),
    preflight=("Preflight", "timeouts fit the limit", None, "security"),
    arm=("Arm watchdog", "before any cost", None, "security"),
    steps=("Run steps", "each has a hard timeout", None, "backend"),
    teardown=("Teardown", "trap on every exit", None, "backend"),
    confirm=("Deletes confirmed", "retried until yes", None, "security"),
    done=("Exit 0", "cluster deleted", None, "cloud"),
    takeover=("Watchdog teardown", "runner died or time limit", None, "bus"),
    manual=("Exit non-zero", "prints oci delete commands", "watchdog stays armed", "external"),
)
AUTOSCALE = dict(
    serving="5 of 5, then replicas 0", up="scale-up: 385 s", down="scale-down: 312 s",
    foot=("Run 2, 2026-10-01, one VM.GPU.A10.1. Measured once. "
          "Scale-down ran with the autoscaler timers set to 3 minutes."),
    desc=("The GPU node pool starts at 0 nodes. The NIM pod goes Pending and asks for one GPU. "
          "The GPU node is Ready 385 s later. NIM serves 5 of 5 requests, then replicas are set "
          "to 0. The pool is back at 0 nodes 312 s after that."),
)


def cost(c):
    """Posted OCI cost per run, stacked by billing line."""
    lines = [("GPU, VM.GPU.A10.1", GREEN), ("Enhanced cluster fee", BLUE),
             ("System node, E4.Flex", OCHRE), ("Block volume", STEEL)]
    runs = [("Run 1, fixed pool", [0.5217, 0.0716, 0.0255, 0.0109], "$0.63"),
            ("Run 2, autoscale", [0.4622, 0.0382, 0.0252, 0.0091], "$0.53")]
    scale = 268 / 0.63
    b, y = head("Posted OCI cost by billing line", c)
    for name, vals, total in runs:
        b.append(text(M, y, name, 13, c["ink"]))
        x = float(M)
        for v, (_, s) in zip(vals, lines):
            b.append(rect(x, y + 9, v * scale - 1.5, 22, c["series"][s], rx=1))
            x += v * scale
        b.append(text(x + 8, y + 25, total, 13, c["ink"], weight=600))
        y += 58
    b.append(f'<line x1="{M}" y1="{y - 12}" x2="{R}" y2="{y - 12}" stroke="{c["rule"]}"/>')
    b.append(text(R - 82, y + 10, "Run 1", 12, c["ink2"], anchor="end"))
    b.append(text(R, y + 10, "Run 2", 12, c["ink2"], anchor="end"))
    y += 34
    for k, (name, s) in enumerate(lines):
        b.append(rect(M, y - 10, 11, 11, c["series"][s]))
        b.append(text(M + 18, y, name, 12, c["ink"]))
        b.append(text(R - 82, y, f"${runs[0][1][k]:.4f}", 12, c["ink"], anchor="end"))
        b.append(text(R, y, f"${runs[1][1][k]:.4f}", 12, c["ink"], anchor="end"))
        y += 24
    foot, y = note(y + 8, "Posted usage from OCI Cost Analysis, read on 2026-10-02. Not an invoice.", c)
    desc = ("Run 1 posted $0.63: GPU $0.5217, enhanced cluster $0.0716, system node $0.0255, "
            "block volume $0.0109. Run 2 posted $0.53: GPU $0.4622, enhanced cluster $0.0382, "
            "system node $0.0252, block volume $0.0091.")
    return svg(y, "Posted OCI cost by billing line", desc, b + foot, c)


def attempts(c):
    """Six starts on 2026-10-01, each bar placed on a UTC time axis."""
    t0, t1 = 18 * 60 + 40, 20 * 60 + 50  # 18:40 to 20:50 UTC, in minutes

    def px(minute):
        return M + (R - M) * (minute - t0) / (t1 - t0)

    rows = [  # label, shown time, start minute, duration in minutes, PASS, note
        ("1  Fixed pool", "18:46 UTC", 18 * 60 + 46, 12.67, False, "FAIL at node pool create · $0.0017"),
        ("2  Fixed pool", "19:00 UTC", 19 * 60, 54.2, True, "PASS · $0.63"),
        ("3  IAM setup, apply", "about 20:00 UTC", 20 * 60, 0, False, "FAIL, 403 · $0"),
        ("4  IAM setup, check", "about 20:05 UTC", 20 * 60 + 5, 0, False, "false FAIL · $0"),
        ("5  Autoscale", "20:07 UTC", 20 * 60 + 7, 0.03, False, "FAIL in preflight · $0"),
        ("6  Autoscale", "20:12 UTC", 20 * 60 + 12, 35.57, True, "PASS · $0.53"),
    ]
    b, y = head("Every attempt on 2026-10-01", c)
    for hour in (19, 20):
        b.append(text(px(hour * 60), y - 2, f"{hour}:00", 12, c["ink2"], anchor="middle"))
    b.append(text(R, y - 2, "UTC", 12, c["ink2"], anchor="end"))
    y += 24
    for label, when, start, dur, ok, shown in rows:
        colour = c["series"][GREEN] if ok else c["series"][RED]
        b.append(text(M, y, label, 13, c["ink"]))
        b.append(text(R, y, when, 12, c["ink2"], anchor="end"))
        b.append(rect(M, y + 9, R - M, 14, c["tint"]))
        for hour in (19, 20):
            x = px(hour * 60)
            b.append(f'<line x1="{x:.1f}" y1="{y + 9}" x2="{x:.1f}" y2="{y + 23}" stroke="{c["rule"]}"/>')
        x = px(start)
        b.append(rect(x, y + 9, max(px(start + dur) - x, 5), 14, colour))
        b.append(text(M, y + 41, shown, 12, c["ink"]))
        y += 66
    foot, y = note(y + 6, "Each bar sits on one time axis, 18:40 to 20:50 UTC. Attempts 3 and 4 have no "
                   "phase log; their times come from the fix commits. The day's posted total is $1.17.", c)
    desc = ("Six starts on 2026-10-01. 18:46 fixed pool failed at node pool create, $0.0017. "
            "19:00 fixed pool passed, $0.63. About 20:00 IAM apply failed with 403. About 20:05 IAM "
            "check gave a false fail. 20:07 autoscale failed in preflight. 20:12 autoscale passed, $0.53.")
    return svg(y, "Every attempt on 2026-10-01", desc, b + foot, c)


def main():
    for name, fn in (("deploys", deploys), ("runner-ends", runner_ends), ("measured", measured),
                     ("cost", cost), ("attempts", attempts), ("autoscale", autoscale)):
        for theme, c in THEMES.items():
            (HERE / f"{name}-{theme}.svg").write_text(fn(c))
        print("built", name)


if __name__ == "__main__":
    main()
