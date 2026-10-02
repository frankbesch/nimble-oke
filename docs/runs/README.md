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

- [2026-10-01, run 1](2026-10-01-run-1-fixed.md): Fixed, one `VM.GPU.A10.1`. PASS: NIM served 5 of 5 requests; teardown clean
- [2026-10-01, run 2](2026-10-01-run-2-autoscale.md): Autoscale, GPU pool 0 to 1 to 0. PASS: scale-up 385 s, scale-down 312 s; teardown clean on the first attempt

## Run summaries

From the two receipts. Costs are posted usage from OCI Cost Analysis, read on 2026-10-02.

### Run 1, fixed pool

| Measure | Value |
|---|---|
| Provision | 15 min 53 s |
| Deploy to NIM Ready | 6 min 56 s |
| Scale-up: pod Pending to GPU node Ready | not applicable |
| Scale-down: zero replicas to no GPU node | not applicable |
| Benchmark, 5 non-streamed requests | 5 of 5; p50 3.85 s; 27.6 tokens/s |
| Teardown | clean, third attempt, 30 min 55 s |
| GPU node pool or node present | 17 min 44 s |
| GPU metered by OCI | 15 min 39 s |
| Posted OCI cost | $0.63 |
| Receipt | [run 1](2026-10-01-run-1-fixed.md) |

### Run 2, autoscale 0→1→0

| Measure | Value |
|---|---|
| Provision | 11 min 58 s, GPU pool at 0 nodes |
| Deploy to NIM Ready | 10 min 43 s from pod Pending, including the new node |
| Scale-up: pod Pending to GPU node Ready | 385 s |
| Scale-down: zero replicas to no GPU node | 312 s |
| Benchmark, 5 non-streamed requests | 5 of 5; p50 3.96 s; 27.3 tokens/s |
| Teardown | clean, first attempt, 6 min 54 s |
| GPU node pool or node present | 10 min 07 s |
| GPU metered by OCI | 13 min 52 s |
| Posted OCI cost | $0.53 |
| Receipt | [run 2](2026-10-01-run-2-autoscale.md) |

## Every attempt, including the failures

<picture><source media="(prefers-color-scheme: dark)" srcset="../diagrams/attempts-dark.svg"/><img width="420" src="../diagrams/attempts-light.svg" alt="Chart: every start, with pass or fail, duration, and cost."/></picture>

<details><summary>Text version of this diagram</summary>

Six starts on 2026-10-01. 18:46 fixed pool failed at node pool create, $0.0017. 19:00 fixed pool passed, $0.63. About 20:00 IAM apply failed with 403. About 20:05 IAM check gave a false fail. 20:07 autoscale failed in preflight. 20:12 autoscale passed, $0.53.

</details>

Six starts on 2026-10-01 produced the two receipts above. Times are UTC, from
each run's phase log. Posted cost is from OCI Cost Analysis, read on
2026-10-02. The day's posted total is $1.17.

- **1. Fixed pool**
  - Start: 18:46
  - Duration: 12 min 40 s
  - Outcome: FAIL at node pool create; trap and teardown left the account clean
  - Cause: The cluster's service load-balancer subnet was the worker subnet. OKE refuses a node pool on that subnet.
  - Fix: `b49ca6d`: assign no service load-balancer subnet
  - Posted cost: $0.0017
- **2. Fixed pool**
  - Start: 19:00
  - Duration: 54 min 12 s
  - Outcome: PASS; teardown clean on the third attempt
  - Cause: Teardown read the pool state once, treated 409 as a failure, and used the default 60-minute drain
  - Fix: `48d766c`: poll state, wait on 409, zero eviction grace
  - Posted cost: $0.63
- **3. IAM setup, apply**
  - Start: about 20:00
  - Duration: seconds
  - Outcome: FAIL, 403
  - Cause: The script sent an IAM write to Phoenix. IAM writes go to the home region.
  - Fix: `9eaab59`: resolve the home region
  - Posted cost: $0
- **4. IAM setup, check**
  - Start: about 20:05
  - Duration: seconds
  - Outcome: False FAIL on a correct rule
  - Cause: The list call returns the dynamic-group rule empty
  - Fix: `ee07cd7`: read the rule with a get call
  - Posted cost: $0
- **5. Autoscale**
  - Start: 20:07
  - Duration: 2 s
  - Outcome: FAIL in preflight; nothing created
  - Cause: The shell had a placeholder compartment ID from a profile file
  - Fix: `3ccc682`: preflight names that cause
  - Posted cost: $0
- **6. Autoscale**
  - Start: 20:12
  - Duration: 35 min 34 s
  - Outcome: PASS; teardown clean on the first attempt
  - Cause: none
  - Fix: none
  - Posted cost: $0.53

Attempts 3 and 4 have no phase log. Their times come from the fix commits.

What the failures changed in the kit:

- Three of them were rules the OCI service enforces and the offline CLI help
  does not show: the subnet rule, the home-region rule, and the default drain.
  Only a live run finds these.
- No failure left a billable resource behind. The failed provision cost one
  minute of cluster fee.
- `tests/live_path_test.sh` now covers the subnet fix, the home-region fix,
  and the zero eviction grace. The 409 wait, the rule read, and the
  placeholder check have no stub test yet.
