# Measured runs

Each Markdown file here is the receipt of one run of `scripts/run_measured.sh`
against a real OCI account. A receipt records the date, region, shape, image,
Kubernetes version, time per phase, OCI work-request times, benchmark
numbers, an itemised cost with its rate basis, and the teardown result. The
cost is an estimate until OCI posts the usage; both receipts below now carry
posted cost.

A receipt holds no OCIDs, no IP addresses, and no key. The runner writes its
raw output, including `receipt.md`, `summary.json`, and step logs, to the
directory you name. Those directories stay out of git.

| Run | Mode | Result |
|---|---|---|
| [2026-10-01, run 1](2026-10-01-run-1-fixed.md) | Fixed, one `VM.GPU.A10.1` | PASS: NIM served 5 of 5 requests; teardown clean |
| [2026-10-01, run 2](2026-10-01-run-2-autoscale.md) | Autoscale, GPU pool 0 to 1 to 0 | PASS: scale-up 385 s, scale-down 312 s; teardown clean on the first attempt |
