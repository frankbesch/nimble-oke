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
| GPU node present | 607 s, about 10.1 minutes |

Evidence from the cluster's events:

```
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

| Operation | Accepted | Finished | Duration |
|---|---|---|---|
| GPU node pool delete (0 nodes) | 20:41:18 | 20:41:41 | 23 s |
| System node pool delete | 20:41:52 | 20:42:57 | 1 min 05 s |
| Cluster delete | 20:43:26 | 20:47:49 | 4 min 23 s |

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

No bill is available yet. These are estimates at Oracle list prices read on
2026-10-01, from the runner's receipt.

| Line | Window | Rate | Estimate |
|---|---|---|---|
| GPU node | 607 s, while the node existed | $2.00 per hour | $0.34 |
| System node pool | 2,128 s, provision start to verified teardown | $0.074 per hour | $0.04 |
| Enhanced cluster | 2,128 s | $0.10 per hour | $0.06 |
| **Total** | | | **about $0.44** |

Not included: block storage for the GPU node's boot volume and the 100 Gi
model cache. This kit does not verify that rate.

Run 1 held a GPU node for about 18 minutes and cost about $0.73 by the same
method. Here the GPU billed for about 10 minutes.

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
- The actual bill.
- Regions other than Phoenix.
