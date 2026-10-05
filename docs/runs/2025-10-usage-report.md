# October 2025, OCI usage report

The first deployment ran in October 2025, before `scripts/run_measured.sh`
existed. No run receipt was kept. This page records what OCI's usage report
shows for that month, so the first deployment has a cost on record. The
month covers the October 2025 runs including build time: the hours spent
building the kit against live clusters, not only the hours NIM served.

Source: the OCI usage report for the account, downloaded 2026-10-05. It
groups usage by service and region for the whole month, so it covers every
OCI use in October 2025, not one run. Amounts are the report's "amount used"
at its net unit prices, such as $2.00 per A10 GPU-hour. Lines are rounded;
totals are summed from the unrounded amounts. Account name, user, and
subscription ID are left out.

## Total

| Measure | Value |
|---|---|
| October 2025, runs and build time | $59.26 |
| Phoenix, with the A10 GPU | $39.46 |
| Chicago, no GPU | $19.79 |
| Overage | $0 on every line |

Chicago was the account's home region and the kit's default until
2025-10-12, when the default moved to Phoenix (`d11004f`). Chicago has no
GPU line; every GPU-hour is in Phoenix, where NIM served inference.

Overage $0 most likely means the usage was drawn from account credits rather
than billed. The report does not say so directly; the invoice for the month
would.

## Cost per run

No record counts the runs in October 2025, so the cost per run is the
month's total divided by the number of runs. The A10 GPU is 64% of it.

| Runs | Cost per run | GPU-hours per run |
|---|---|---|
| 1 | $59.26 | 18.95 |
| 2 | $29.63 | 9.48 |
| 3 | $19.75 | 6.32 |
| 4 | $14.81 | 4.74 |

Each figure includes build time. For comparison, the two scripted runs on
2026-10-01 posted $0.63 and $0.53, with the GPU metered for about 15 minutes
each and teardown confirmed clean: see the [measured runs](README.md).

## Phoenix

| Line | Amount |
|---|---|
| A10 GPU, 18.95 GPU-hours | $37.90 |
| OKE enhanced cluster fee, 11.20 hours | $1.12 |
| Block volume storage, 10.30 GB-months | $0.26 |
| Block volume performance, 103.03 units | $0.18 |
| Load balancer base and bandwidth, 5.91 hours | $0 |

## Chicago

| Line | Amount |
|---|---|
| E5 compute, 343.42 OCPU-hours | $10.30 |
| E5 memory, 1,749.23 GB-hours | $3.50 |
| OKE enhanced cluster fee, 45.54 hours | $4.55 |
| Load balancer, 100 Mbps, 67.56 hours | $1.44 |
| Block volume, free tier, 12.89 GB-months | $0 |

Monitoring, object storage, and outbound data transfer in both regions came
to $0. Object storage also shows a $0 line for November 2025.

## What the report cannot say

- How many runs there were, or how much of each was build time against
  serving time.
- Why the hours differ. The A10 GPU ran 18.95 hours against 11.20 hours of
  Phoenix cluster fee, and the Chicago load balancer ran 67.56 hours against
  45.54 hours of cluster fee. A resource left running after its cluster, or
  time on a basic cluster, which has no hourly fee, would each explain it.
  No record shows which.
