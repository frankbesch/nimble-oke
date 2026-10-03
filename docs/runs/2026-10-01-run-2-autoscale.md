# Measured run 2: GPU node autoscaling 0→1→0 (2026-10-01)

First measured GPU node-autoscaling run of this kit. Same region, shape,
chart, image, and Kubernetes version as [run 1](2026-10-01-run-1-fixed.md):
`us-phoenix-1`, `VM.GPU.A10.1` with one NVIDIA A10,
`nvcr.io/nim/meta/llama3-8b-instruct:1.0.3`, v1.34.1, plus one
`VM.Standard.E4.Flex` system node. The difference: the GPU node pool is
created with **0 nodes**, and Oracle's Cluster Autoscaler add-on (1.34.3)
manages it with `nodes=0:1`. The GPU node exists only while a pod needs it.
Run by the owner from a local terminal:

```bash
scripts/run_measured.sh --autoscale --key-file ~/.ngc-key docs/runs/2026-10-01-autoscale-2
```

Scope: node autoscaling 0→1→0 on one GPU node, once. `MAX_GPU_NODES` above 1
is refused by the kit, so 1→2 was not run. Pod autoscaling on request rate is
out of scope.

## Result

| Gate | Result |
|---|---|
| Preflight: tools, auth, A10 limit, no existing cluster, image, Kubernetes version, autoscaler IAM | PASS |
| System node pool Ready; cluster DNS Ready on it | PASS |
| GPU node pool created at 0 nodes with label, cloud-init, and the autoscaler's storage tag | PASS |
| Cluster Autoscaler add-on `ACTIVE` with `nodes=0:1`; its pod Running on the system node | PASS |
| 0→1: pod Pending → `TriggeredScaleUp` → A10 node Ready → pod Ready | PASS |
| Inference: readiness check, 5 of 5 benchmark requests | PASS |
| 1→0: replicas 0 → autoscaler removes the A10 node; pool size reads 0 | PASS |
| Teardown confirmed clean by the runner and by a separate read of the account | PASS, first attempt |

Runner exit code: 0. Receipt line: `autoscale result: 0→1→0 PASS`.

## Autoscaling

| Measure | Value |
|---|---|
| Scale-up: NIM pod Pending to GPU node Ready | 385 s |
| GPU node Ready to NIM pod Ready (image pull, volume attach, model download) | 258 s |
| NIM pod Pending to NIM pod Ready | 643 s |
| Scale-down: replicas 0 to no GPU node | 312 s |
| Autoscaler timers | scale-down-unneeded 3 m, scale-down-delay-after-add 3 m |
| GPU node present in the cluster | 607 s, about 10.1 minutes |
| GPU metered by OCI | 832 s, about 13.9 minutes |

Evidence from the cluster's events:

```text
Normal  TriggeredScaleUp  pod/nvidia-nim-…  pod triggered scale-up: [{<GPU node pool> 0->1 (max: 1)}]
Normal  ScaleDown         node/<GPU node>   marked the node as toBeDeleted/unschedulable
Normal  ScaleDownEmpty    configmap/cluster-autoscaler-status  Scale-down: empty node <GPU node> removed
```

After scale-down, `oci ce node-pool get` reported the GPU pool size as 0.

Oracle's documentation does not state that a managed node pool can scale up
from zero nodes. This run shows that it does, with add-on 1.34.3, for a pod
that requests `nvidia.com/gpu`. The node the autoscaler created reported one
allocatable GPU and 440 Gi of ephemeral storage, so the cloud-init
`oci-growfs` step and the device plugin both worked on a node that no one
could fix by hand.

The 3-minute timers are shorter than the add-on's 10-minute defaults. They
were set to keep the run short.

## Timings

Runner phases, in seconds:

| Phase | Seconds |
|---|---|
| preflight | 6 |
| provision | 718 |
| deploy | 17 |
| scale-up | 386 |
| ready | 257 |
| bench | 21 |
| scale-down | 314 |
| teardown | 414 |
| verify-clean | 1 |

Teardown work requests (UTC):

Listed by operation:

- **GPU node pool delete (0 nodes)**
  - Accepted: 20:41:18
  - Finished: 20:41:41
  - Duration: 23 s
- **System node pool delete**
  - Accepted: 20:41:52
  - Finished: 20:42:57
  - Duration: 1 min 05 s
- **Cluster delete**
  - Accepted: 20:43:26
  - Finished: 20:47:49
  - Duration: 4 min 23 s

The system node pool delete took 65 s here against 21 minutes in run 1. The
difference is the zero eviction grace period the kit now passes at teardown.
Teardown finished on its first attempt.

## Benchmark

Five sequential, non-streamed `/v1/chat/completions` requests, `max_tokens`
128, temperature 0, one stream, over a local port-forward.

| Measure | Value |
|---|---|
| Requests succeeded | 5 of 5 |
| Latency to full response | p50 3.96 s, max 4.65 s |
| Output throughput | p50 27.3 tokens/s, min 26.7 |

These match run 1 within a few percent. Five requests on one stream is a
smoke test, not a performance result.

## Cost

Posted cost: **$0.53**. Source: OCI Cost Analysis, hourly by SKU, read on
2026-10-02. It is metered usage at list rates, not an invoice.

Listed by line:

- **GPU, A10**
  - Metered quantity: 0.2311 GPU-hours, 13 min 52 s
  - Rate: $2.00 per GPU-hour
  - Posted cost: $0.4622
- **System node, `VM.Standard.E4.Flex`**
  - Metered quantity: 0.6808 OCPU-hours and 5.45 GB-hours
  - Rate: $0.025 per OCPU-hour, $0.0015 per GB-hour
  - Posted cost: $0.0252
- **Enhanced cluster**
  - Metered quantity: 0.3817 cluster-hours, 22 min 54 s
  - Rate: $0.10 per hour
  - Posted cost: $0.0382
- **Block volume, storage and performance**
  - Metered quantity: boot volumes and the model cache
  - Rate: as metered
  - Posted cost: $0.0091
- **Total**
  - Posted cost: **$0.5346**

The lines are the 20:00 UTC hour of the account's usage. This run was the
only activity in that hour, so the split by run is an inference from time,
not a tag.

Before the usage posted, this receipt estimated $0.44. The estimate was low by
$0.09, and the GPU line is the reason. The estimate counted the 607 s the GPU
node was present in the cluster. OCI metered the instance for 13 min 52 s.
An instance bills from launch to termination, and that is longer than the
time its node is registered.

[Run 1](2026-10-01-run-1-fixed.md) posted $0.63, with the GPU metered for
15 min 39 s. Autoscaling saved about 2 minutes of GPU time in this run. The
saving grows with idle time: a fixed pool bills the GPU while it waits, and
this pool does not.

## Before this run

Three things failed on the way, none of them billable:

- The IAM setup script sent its first write to Phoenix. OCI answered 403,
  "Please go to your home region." IAM writes go to the tenancy's home
  region, whatever region the cluster is in. The script now resolves it.
- The IAM check then reported a correct dynamic-group rule as wrong. The list
  call returns the rule empty; the check now reads it with a get call.
- The first start of this run stopped in preflight. The shell had a
  placeholder compartment ID from a profile file. Preflight now names that
  cause.

## What this run does not show

- More than one GPU node, or scaling from 1 to 2.
- Repeatability. This is one run.
- The add-on's default 10-minute timers.
- Scale-down with other workloads on the GPU node.
- Performance under load or with streaming.
- An invoice. The cost above is posted usage, not a billing document.
- Regions other than Phoenix.
