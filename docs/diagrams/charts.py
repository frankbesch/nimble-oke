#!/usr/bin/env python3
"""Draw the README diagrams and charts as light and dark SVG.

Usage: python3 docs/diagrams/charts.py
Writes six charts as <name>-light.svg and <name>-dark.svg, in three pairs of
equal height (PAIRS, D-262), plus the docs pages' pairs. Every figure is copied from the README
and docs/runs/. Change a figure there first, then here. The drawing code is
quoin_readme.py, a copy kept in step by promptkits/quoin/github/sync.py.
"""
from pathlib import Path

from quoin_readme import (THEMES, GREEN, BLUE, OCHRE, RED, STEEL, M, R, text, rect, para, note,
                          head, svg, pair, panels, deploys, runner_ends, measured, autoscale)

HERE = Path(__file__).resolve().parent

MEASURED = dict(
    title="Measured side by side",
    names=["OKE, one A10", "GKE, one L4"],
    panels=[
        ("Scale-up: pod Pending to GPU node Ready", [(385, "385 s"), (77, "77 s")]),
        ("Scale-down: zero replicas to no GPU node",
         [(312, "312 s, timers set to 3 min"), (752, "752 s, default delay")]),
        ("Script start to NIM Ready, autoscale", [(1384, "23 min 04 s"), (967, "16 min 07 s")]),
        ("Posted list cost, every start", [(1.17, "$1.17"), (1.19, "$1.19")]),
    ],
    note=("One run each, on different hardware. This is a record of each run, "
          "not a benchmark of the two platforms."),
    desc=("Scale-up 385 s on OKE and 77 s on GKE. Scale-down 312 s on OKE with timers set to "
          "3 minutes and 752 s on GKE with the default delay. Script start to NIM Ready with "
          "autoscale 23 min 04 s on OKE and 16 min 07 s on GKE. Posted list cost for every "
          "start $1.17 on OKE and $1.19 on GKE."),
)

COST_DESC = ("Run 1 posted $0.63: GPU $0.5217, enhanced cluster $0.0716, system node $0.0255, "
            "block volume $0.0109. Run 2 posted $0.53: GPU $0.4622, enhanced cluster $0.0382, "
            "system node $0.0252, block volume $0.0091.")


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


def cost(c, spread=0.0, h=0):
    """Posted OCI cost, one panel per billing line, both runs on one dollar scale
    (the ggplot2 trial's layout, Frank 2026-10-02)."""
    lines = [("GPU, VM.GPU.A10.1", GREEN, 0.5217, 0.4622), ("Enhanced cluster fee", BLUE, 0.0716, 0.0382),
             ("System node, E4.Flex", OCHRE, 0.0255, 0.0252), ("Block volume", STEEL, 0.0109, 0.0091)]
    return panels(dict(
        title="Posted OCI cost by billing line",
        sub="Run 1, fixed pool: $0.63. Run 2, autoscale: $0.53.",
        panels=[(name, s, [("Run 1", r1, f"${r1:.4f}"), ("Run 2", r2, f"${r2:.4f}")])
                for name, s, r1, r2 in lines],
        notes=["Posted usage from OCI Cost Analysis, read on 2026-10-02. Not an invoice."],
        desc=COST_DESC), c, spread, h)


def attempts(c, spread=0.0, h=0):
    """Six starts on 2026-10-01, each bar placed on a UTC time axis.
    spread opens the gap between rows."""
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
        y += 66 + round(20 * spread)
    foot, y = note(y + 6, "Each bar sits on one time axis, 18:40 to 20:50 UTC. Attempts 3 and 4 have no "
                   "phase log; their times come from the fix commits. The day's posted total is $1.17.", c)
    desc = ("Six starts on 2026-10-01. 18:46 fixed pool failed at node pool create, $0.0017. "
            "19:00 fixed pool passed, $0.63. About 20:00 IAM apply failed with 403. About 20:05 IAM "
            "check gave a false fail. 20:07 autoscale failed in preflight. 20:12 autoscale passed, $0.53.")
    return svg(max(y, h), "Every attempt on 2026-10-01", desc, b + foot, c)


COMPARE_COST = dict(  # docs/compared-with page list, "Posted list cost" rows
    title="Posted list cost, OKE and GKE",
    sub="OKE, one A10, against GKE, one L4, on one dollar scale. Different hardware and benchmarks.",
    panels=[
        ("Fixed pool", [GREEN, BLUE], [("OKE, one A10", 0.63, "$0.63"), ("GKE, one L4", 0.70, "about $0.70")]),
        ("Autoscale", [GREEN, BLUE], [("OKE, one A10", 0.53, "$0.53"), ("GKE, one L4", 0.50, "about $0.50")]),
        ("Every start", [GREEN, BLUE], [("OKE, one A10", 1.17, "$1.17"), ("GKE, one L4", 1.19, "$1.19")]),
    ],
    notes=["OCI posts cost by the hour, so each OKE figure is one run. Google's report splits by day: "
           "about $0.70 is the day's two fixed-pool runs, and about $0.50 is the autoscale day with "
           "one failed start. Of GKE's $1.19, $0.95 was charged after credits."],
    desc=("Posted list cost on one dollar scale. Fixed pool: $0.63 on OKE; about $0.70 on GKE for the "
          "day's two runs. Autoscale: $0.53 on OKE; about $0.50 on GKE for the day, with one failed "
          "start. Every start: $1.17 on OKE; $1.19 on GKE, of which $0.95 was charged after credits."),
)


# The README shows these as pairs, one per line, at one height (D-262).
PAIRS = [("measured", lambda c, s=0.0, h=0: measured(MEASURED, c, s, h), "attempts", attempts),
         ("deploys", lambda c, s=0.0, h=0: deploys(DEPLOYS, c, s, h), "cost", cost),
         ("autoscale", lambda c, s=0.0, h=0: autoscale(AUTOSCALE, c, s, h),
          "runner-ends", lambda c, s=0.0, h=0: runner_ends(RUNNER, c, s, h)),
         # Docs pages pair these under their own file names, so each file keeps its
         # partner's height: compared-with page, then runs page (D-262, FBOS D-267).
         ("compare-measured", lambda c, s=0.0, h=0: measured(MEASURED, c, s, h),
          "compare-cost", lambda c, s=0.0, h=0: panels(COMPARE_COST, c, s, h)),
         ("runs-attempts", attempts, "runs-cost", cost)]


def main():
    for theme, c in THEMES.items():
        for ln, lf, rn, rf in PAIRS:
            for name, s in zip((ln, rn), pair(lf, rf, c)):
                (HERE / f"{name}-{theme}.svg").write_text(s)
    print("built", ", ".join(f"{ln} | {rn}" for ln, _, rn, _ in PAIRS))


if __name__ == "__main__":
    main()
