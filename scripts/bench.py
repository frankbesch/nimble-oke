#!/usr/bin/env python3
"""Small inference benchmark against a port-forwarded NVIDIA NIM (default localhost:8000).

Ported in method from the GKE runner's bench.py (sibling nim-gke repo): GET
/v1/models, then a few sequential non-streamed /v1/chat/completions requests.

Per request it records:
  ttfr_s     time to first response: request sent -> response status and headers received
  latency_s  request sent -> full JSON body read
  tokens_per_s  usage.completion_tokens / latency_s (server-reported token count)

Concurrency 1, n small: a smoke receipt, not a load test. Standard library only.
It never reads, logs, or sends the NGC key (the local NIM endpoint needs none).
Exit 0 only if every request returned 200 with non-empty content and a usage block.
"""
import argparse
import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request

# The key is never needed here; drop it so no code path can echo it.
os.environ.pop("NGC_API_KEY", None)
os.environ.pop("NGC_CLI_API_KEY", None)

PROMPTS = [
    "Summarize the benefits of running LLM inference on Kubernetes in three sentences.",
    "Explain what a GPU node pool is to a finance manager in two sentences.",
    "List four risks of deploying an LLM in production and one control for each.",
    "Write a short checklist for smoke-testing an inference endpoint.",
]


def pct(xs, p):
    xs = sorted(xs)
    k = (len(xs) - 1) * p
    f = int(k)
    c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def chat(base, model, prompt, max_tokens, timeout):
    body = json.dumps({
        "model": model, "max_tokens": max_tokens, "temperature": 0,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(base + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        t_first = time.monotonic()
        status = r.status
        raw = r.read()
    t_end = time.monotonic()
    return status, json.loads(raw), t_first - t0, t_end - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1:8000",
                    help="Base URL of the port-forwarded NIM (default: %(default)s)")
    ap.add_argument("--model", default=None,
                    help="Model id; default: the first id from /v1/models")
    ap.add_argument("--n", type=int, default=5,
                    help="Number of sequential chat completions (default: %(default)s)")
    ap.add_argument("--max-tokens", type=int, default=128, dest="max_tokens",
                    help="max_tokens per request (default: %(default)s)")
    ap.add_argument("--timeout", type=float, default=300.0,
                    help="Per-request timeout in seconds (default: %(default)s)")
    ap.add_argument("--out", default=None, help="Path for the JSON result")
    args = ap.parse_args()
    if args.n < 1:
        ap.error("--n must be >= 1")

    base = args.url.rstrip("/")
    out = {"url": base, "n_requested": args.n, "max_tokens": args.max_tokens,
           "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    ok = True
    try:
        with urllib.request.urlopen(base + "/v1/models", timeout=30) as r:
            models = json.load(r)
        ids = [m.get("id") for m in models.get("data", []) if m.get("id")]
    except (urllib.error.URLError, OSError, ValueError) as e:
        print("ERROR: could not read %s/v1/models: %s" % (base, e), file=sys.stderr)
        ids = []
    out["models"] = ids
    model = args.model or (ids[0] if ids else None)
    out["model"] = model
    if not model or (args.model and args.model not in ids):
        out["error"] = "model not listed by /v1/models"
        ok = False

    reqs = []
    if ok:
        for i in range(args.n):
            rec = {"i": i}
            try:
                status, d, ttfr, lat = chat(base, model, PROMPTS[i % len(PROMPTS)],
                                            args.max_tokens, args.timeout)
                text = (d.get("choices") or [{}])[0].get("message", {}).get("content") or ""
                usage = d.get("usage") or {}
                ctoks = usage.get("completion_tokens")
                rec.update(status=status, ttfr_s=round(ttfr, 3), latency_s=round(lat, 3),
                           prompt_tokens=usage.get("prompt_tokens"), completion_tokens=ctoks,
                           tokens_per_s=round(ctoks / lat, 1) if (ctoks and lat > 0) else None,
                           excerpt=text.strip()[:80])
                if status != 200 or not text.strip() or ctoks is None:
                    rec["error"] = "non-200, empty content, or no usage.completion_tokens"
                    ok = False
            except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError, AttributeError) as e:
                rec["error"] = "%s: %s" % (type(e).__name__, e)
                ok = False
            reqs.append(rec)
            print("request %d: %s" % (i, json.dumps(rec)), file=sys.stderr)

    good = [r for r in reqs if "error" not in r]
    out["requests"] = reqs
    out["n_ok"] = len(good)
    if good:
        ttfr = [r["ttfr_s"] for r in good]
        lat = [r["latency_s"] for r in good]
        tps = [r["tokens_per_s"] for r in good if r["tokens_per_s"] is not None]
        out["ttfr_s"] = {"p50": round(pct(ttfr, .5), 3), "max": round(max(ttfr), 3)}
        out["latency_s"] = {"p50": round(pct(lat, .5), 3), "max": round(max(lat), 3)}
        out["completion_tokens_mean"] = round(statistics.mean(r["completion_tokens"] for r in good), 1)
        if tps:
            out["tokens_per_s"] = {"p50": round(pct(tps, .5), 1), "min": round(min(tps), 1)}
    out["ok"] = ok

    text_out = json.dumps(out, indent=2)
    print(text_out)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text_out + "\n")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
