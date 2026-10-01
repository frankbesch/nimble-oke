# Nimble OKE — NVIDIA NIM on Oracle Kubernetes Engine

Shell scripts and a Helm chart that take an NVIDIA NIM LLM microservice from
nothing to a served request on Oracle Kubernetes Engine (OKE), then tear
everything down. The project is a smoke-test harness, not a production
platform. Its focus is the part that costs money when it goes wrong:
provisioning a GPU node pool and proving it was deleted.

**Based on:** [NVIDIA nim-deploy, Oracle OKE reference](https://github.com/NVIDIA/nim-deploy/tree/main/cloud-service-providers/oracle/oke)

## Status

| Item | State |
|------|-------|
| First deployment | October 2025, on a cluster built with the Console's Quick Create plus `oci` CLI steps for what the Console could not do. NIM served inference. No run receipt was kept. |
| Measured rerun | Pending. `scripts/run_measured.sh` writes a timed receipt to [docs/runs/](docs/runs/). None is committed yet. It will be the first proof of the scripted provisioning path. |
| Review pass | October 2026. Teardown, provisioning, and secret handling were reworked. See [What changed in October 2026](#what-changed-in-october-2026). |
| CI | Shellcheck, stubbed tests of the runner and of the provision and teardown scripts, Helm lint and render, secret scan. |

Timing and cost figures elsewhere in this repository that come from the
simulation scripts are estimates from static assumptions. They are labelled
as estimates. Only a file in `docs/runs/` is a measurement.

## What it deploys

| Component | Value |
|-----------|-------|
| Cluster | OKE enhanced cluster, Kubernetes v1.34.1 |
| GPU node pool | `VM.GPU.A10.1` by default: one NVIDIA A10 (24 GB), 15 OCPU, 240 GB RAM |
| System node pool | One `VM.Standard.E4.Flex` node, 2 OCPU and 16 GB. It runs cluster DNS and the autoscaler. |
| Model | `nvcr.io/nim/meta/llama3-8b-instruct:1.0.3` (Llama 3 8B Instruct) |
| Storage | 100 Gi block volume for the model cache |
| Endpoint | OpenAI-compatible API on port 8000 |

Two limits you should know before you rely on this stack:

- **The image is past NVIDIA's end of support.** The NGC catalog marks
  `llama3-8b-instruct` 1.x as no longer supported. The current NIM LLM line
  is 2.x (`llama-3.1-8b-instruct`). This repository keeps the image that was
  deployed here. An upgrade is a separate, unmeasured change.
- **The A10 is not on NVIDIA's optimized list for this model.** NVIDIA's
  support matrix lists the A10G. OCI's A10 runs under the generic
  configuration, which NVIDIA describes as not guaranteed.

## Cost

Rates are Oracle list prices, read from Oracle's price list on 2026-10-01.

| Line | Rate |
|------|------|
| A10 GPU | $2.00 per GPU-hour |
| OKE enhanced cluster | $0.10 per cluster-hour |
| System node, E4 Flex | $0.025 per OCPU-hour and $0.0015 per GB-hour: $0.074 per hour |
| **Default shape, `VM.GPU.A10.1`** | **$2.17 per hour** |
| `VM.GPU.A10.2` (two GPUs) | $4.17 per hour |
| `BM.GPU.A10.4` (four GPUs, bare metal) | $8.17 per hour |

The scripts print about $2.24 per hour for the default shape. That figure
adds estimates for block storage and a load balancer, which this repository
does not verify and labels as estimates. The chart's Service is ClusterIP, so
no load balancer is created.

One table in [scripts/_lib.sh](scripts/_lib.sh) holds every rate. An unknown
shape is an error, not a default price.

With autoscaling, the GPU line bills only while the GPU node exists. The
cluster and the system node bill for the whole run.

GPU billing stops only when the GPU node is gone or the node pool is deleted. `make cleanup` removes
the NIM release and leaves the cluster running. `make teardown` deletes the
node pool and the cluster.

## Prerequisites

- An OCI paid account and a compartment. The default GPU limit is 0. Request
  an increase for `gpu-a10-count` in the Console under Limits, Quotas and Usage.
- An NGC API key with access to `nvcr.io`.
- `oci`, `kubectl`, `helm`, `jq`, `python3`, `curl`, and `bc` on the path.

Details: [docs/setup-prerequisites.md](docs/setup-prerequisites.md).

## Quick start

```bash
export OCI_COMPARTMENT_ID=ocid1.compartment.oc1..your-compartment
export OCI_REGION=us-phoenix-1
```

Keep the NGC key in a file that only you can read, and export it from there.
Typing the key on a command line puts it in shell history.

```bash
chmod 600 ~/.ngc-key
export NGC_API_KEY="$(cat ~/.ngc-key)"
```

| Step | Command | Bills |
|------|---------|-------|
| Check access, quota, and configuration | `scripts/run_measured.sh --preflight-only /tmp/preflight` | No |
| Create the cluster and GPU node pool | `make provision CONFIRM_COST=yes` | Yes, from here |
| Check the cluster, the GPU, and registry access | `make prereqs` | Yes |
| Deploy NIM | `make install CONFIRM_COST=yes` | Yes |
| Check health and send one inference request | `make verify` | Yes |
| Remove NIM, keep the cluster | `make cleanup` | Yes |
| Delete the node pool and cluster | `make teardown` | Stops here |

The NGC key is passed to Helm on standard input at install time. It is not
written to disk. The chart has no default key and refuses to render without one.

## Measured run

`scripts/run_measured.sh` runs the whole path once and records it:
preflight, provision, deploy, wait for ready, benchmark, teardown, and a
check that nothing is left.

```bash
export OCI_COMPARTMENT_ID=ocid1.compartment.oc1..your-compartment
scripts/run_measured.sh --key-file ~/.ngc-key docs/runs/2026-10-01-fixed
```

The key file must have mode 600 or 400. The output directory must be new or
empty.

A free check of access, quota, and configuration, with nothing created:

```bash
scripts/run_measured.sh --preflight-only /tmp/preflight
```

### GPU node autoscaling, 0 to 1 to 0

`--autoscale` creates the GPU node pool with no nodes and installs Oracle's
Cluster Autoscaler add-on on the system node. The pending NIM pod triggers
one GPU node. After the benchmark, the runner scales NIM to zero replicas and
waits for the autoscaler to remove the node.

The autoscaler needs a dynamic group and a policy in your tenancy. Oracle
documents the six statements. The setup script prints them, checks for them,
or creates them after a typed confirmation:

```bash
scripts/setup-autoscaler-iam.sh --print
scripts/setup-autoscaler-iam.sh --check
scripts/setup-autoscaler-iam.sh --apply
```

```bash
scripts/run_measured.sh --autoscale --preflight-only /tmp/preflight
scripts/run_measured.sh --autoscale --key-file ~/.ngc-key docs/runs/2026-10-01-autoscale
```

The receipt records the seconds from pod Pending to GPU node Ready, the
seconds from zero replicas to no GPU node, the autoscaler timers, GPU-node
minutes, and a line `autoscale result: 0→1→0 PASS` or `FAIL` with the reason.

Scope: one GPU node. `MAX_GPU_NODES` above 1 is refused. Oracle's
documentation does not state that a node pool can scale up from zero nodes;
the upstream autoscaler code supports it. The measured run is the test.

### How the runner ends

The runner is built to end with the cluster deleted:

- A trap runs teardown on success, failure, Ctrl-C, `TERM`, and `HUP`, and retries it until the deletes are confirmed.
- Each step has a hard timeout. Preflight refuses to start if the watchdog limit is shorter than the step timeouts combined.
- A watchdog runs in its own session, outside the terminal's process tree.
  It starts before anything billable exists. It takes over teardown if the
  runner dies, and at a time limit.
- If teardown cannot be confirmed, the runner exits non-zero, leaves the
  watchdog armed, and prints the `oci` commands to delete by hand.
- The NGC key never appears in the logs or in process arguments.

The runner's behaviour is tested with stubs in [tests/](tests/). Those tests
make no cloud call.

## What changed in October 2026

A review found defects that could leave a GPU billing or damage unrelated
resources. Each is fixed. The provision, teardown, and runner fixes have
stubbed tests in [tests/](tests/). No stub proves behaviour against the real
OCI API; the measured run does that.

| Defect | Fix |
|--------|-----|
| An NGC API key was committed in `helm/values.yaml` | Removed. The chart now requires the key at install. CI scans for key-shaped strings. |
| A failed provision left the cluster running with no local record | Each OCID is recorded when it is created. The failure trap deletes what the run started. |
| Teardown printed "charges stopped" when deletes failed | Each delete is confirmed. On failure, teardown keeps its state file and exits non-zero. |
| Teardown waited on a state the OCI CLI does not accept, so cluster deletes failed silently | It now waits on the work request, then checks the resource is deleted. |
| Teardown deleted the user's whole `~/.kube/config` | It removes only this cluster's entries. |
| Emergency cleanup force-deleted every instance, volume, and load balancer in the first compartment it found | It is scoped to `OCI_COMPARTMENT_ID` and to OKE resources, and asks for a typed confirmation. |
| An early exit from deploy uninstalled a healthy release and deleted its model cache | Destructive cleanup is armed only for a release that this run created. |
| Deploy left the NGC key in a temp file, and setup printed it | The key goes to Helm on standard input and is never written to disk. Scripts print only "set" or "not set". |
| The scripted subnets had no OKE security rules, so nodes could not register | Provisioning creates security lists that mirror the rules Oracle's Quick Create generates. |
| The root filesystem stayed near 35 GB whatever the boot volume size | The GPU node pool runs `oci-growfs` in cloud-init, as Oracle documents. |
| A cluster of only tainted GPU nodes had nowhere to run DNS | A small system node pool is created first, and provisioning waits for DNS. |
| A failed install uninstalled the release before anyone could see why | Deploy captures pod state, events, and logs before it cleans up. |
| Prices and shapes disagreed across files, and `VM.GPU.A10.4` is not an Oracle shape | One rate table. Three valid shapes. |

## OKE compared with GKE

This kit has a companion, [nim-gke](https://github.com/frankbesch/nim-gke),
that does the same job on Google Kubernetes Engine: deploy NIM with Helm,
track cost, clean up, and measure GPU node autoscaling. The two platforms
reach the same result. OKE needs more explicit setup. The table lists what
each kit has to do itself.

| Task | OKE, nimble-oke | GKE, nim-gke |
|------|-----------------|--------------|
| Hardware and image | `VM.GPU.A10.1`, one NVIDIA A10 (24 GB). Own Helm chart. `llama3-8b-instruct:1.0.3`. | `g2-standard-4`, one NVIDIA L4 (24 GB). NVIDIA's `nim-llm` chart 1.3.0. `llama3-8b-instruct:1.0.0`. |
| Network rules for node registration | The kit creates two security lists: workers to the API endpoint on 6443 and 12250, the control plane to workers, and node to node. | GKE creates the ingress firewall rules when it creates the cluster. The kit sets none. |
| Subnets | The kit creates an API endpoint subnet and a worker subnet. A node pool cannot use the cluster's service load-balancer subnet. | The kit passes no network flags and uses the project's default network. |
| Root filesystem | The GPU node pool runs `oci-growfs` in cloud-init. Without it the root filesystem stays near 35 GB whatever the boot volume size. | The kit uses the default boot disk and has no resize step. |
| GPU drivers and device plugin | The GPU node image carries the drivers. The kit checks for an allocatable GPU and applies the NVIDIA device plugin if none is reported. | The node pool sets `gpu-driver-version`, and GKE installs the drivers. The kit applies no device plugin. |
| GPU taint and toleration | The autoscaler treats GPU nodes as tainted `nvidia.com/gpu:NoSchedule`. The chart carries the toleration. | GKE adds the taint `nvidia.com/gpu=present:NoSchedule` and adds the toleration to pods that request a GPU. |
| System node | One CPU node pool that the autoscaler does not manage. Oracle requires it to run the autoscaler and cluster add-ons. | The default CPU node pool runs system pods. Google states that a Standard cluster keeps at least one node for them. |
| Cluster autoscaler | The kit installs the Cluster Autoscaler add-on with `min:max:pool` and its scale-down timers. | Three flags on the node pool: `--enable-autoscaling`, `--min-nodes`, `--max-nodes`. The kit deploys no autoscaler. |
| Autoscaler permissions | A dynamic group and a six-statement policy, created once by the account owner. | The kit creates none. |
| GPU pool from zero nodes | Supported by the autoscaler's code. Oracle's documentation does not state it. The pool carries a tag that tells the autoscaler the node's storage. | Measured once: 0 to 1 to 0 on one L4, in nim-gke run 3. |
| GPU quota | A service limit per availability domain, `gpu-a10-count`. The default is 0. | A project quota, `GPUS_ALL_REGIONS`, plus the regional GPU quota. |
| Confirming a delete | A delete returns a work request. The kit waits for it, then reads the resource state. | `gcloud` waits for the delete. The kit then checks for a leftover model-store disk. |
| Cluster fee | $0.10 per hour for an enhanced cluster. Basic clusters are free and cannot run the add-on. | The zonal cluster fee applies on both paths. |

None of these is a defect in either platform. They are the steps a script
must own on OKE and can leave to the platform on GKE. The same table appears
in both repositories.

Sources: each kit's own scripts for what the kit does. For platform
behaviour, Google's GKE documentation on GPUs, firewall rules, and the
cluster autoscaler, and Oracle's OKE documentation on the Cluster Autoscaler
add-on, custom cloud-init, and GPU workloads, read on 2026-10-01. The measured
runs in each repository's `docs/runs/` show which rows are proven against the
real API.

## Repository layout

```
Makefile            Entry point for every step
scripts/            Provision, deploy, verify, cleanup, teardown, IAM setup, and the measured-run runner
scripts/_lib.sh     Logging, cost guards, rate table, confirmed-delete helpers
helm/               Chart for the NIM deployment
tests/              Stubbed tests for the runner, autoscaling, and the provision and teardown scripts
docs/               Runbook, prerequisites, API examples, and historical working notes
docs/runs/          Receipts from measured runs
```

Several documents at the repository root and in `docs/` are working notes
from October 2025. The session summaries and reports carry a note saying so.
Their figures were corrected in October 2026.

## Makefile targets

| Target | Purpose | Cost guard |
|--------|---------|------------|
| `make provision` | Create the cluster and GPU node pool | Yes |
| `make prereqs` | Check the cluster, the GPU, and registry access | No |
| `make install` | Deploy NIM with Helm | Yes |
| `make verify` | Check health and send one inference request | No |
| `make status` / `make logs` | Show pod state and recent logs | No |
| `make troubleshoot` | Run diagnostics | No |
| `make cleanup` | Remove the NIM release; the cluster keeps billing | No |
| `make teardown` | Delete the node pool and cluster | Typed confirmation |
| `make lint` | Shellcheck and Helm lint | No |
| `make test` | Run the stubbed tests | No |
| `make help` | List every target | No |

| Variable | Default | Purpose |
|----------|---------|---------|
| `OCI_COMPARTMENT_ID` | required | Compartment that owns every resource |
| `NGC_API_KEY` | required | NGC key, passed to Helm at install |
| `OCI_REGION` | `us-phoenix-1` | Region for every `oci` call. The pinned node image is Phoenix-only. |
| `API_ALLOWED_CIDR` | `0.0.0.0/0` | Source range allowed to reach the Kubernetes API on 6443 |
| `OKE_GPU_SHAPE` | `VM.GPU.A10.1` | GPU node shape |
| `AUTOSCALE` | `0` | Set `1` for `make provision` to create the GPU pool at zero nodes with the autoscaler |
| `CONFIRM_COST` | `no` | Set `yes` to pass the cost guard. Otherwise a billable step exits. |
| `KEEP_CACHE` | `no` | Keep the model-cache volume during `make cleanup` |
| `FORCE` | `no` | Skip confirmation prompts |

## Known gaps

- No measured receipt is committed yet. Until one is, the scripted provisioning path is untested against the real OCI API.
- The Kubernetes API endpoint is public and open on 6443 by default. Set `API_ALLOWED_CIDR` to narrow it.
- The node image OCID is pinned to Phoenix. Other regions need a different image.
- The pod runs as uid 1000 with no further hardening. The chart says so.
- The NVIDIA device plugin is pinned at v0.14.0 and has not been re-tested against newer releases.
- The scripts are tested on bash 3.2. Bash 5 is exercised only in CI.
- Autoscaling is limited to one GPU node and is unproven until a receipt is committed.
- The watchdog runs on the machine that starts the run. If that machine loses power or sleeps with the lid closed, nothing tears the cluster down until it wakes.

## References

- [NVIDIA NIM documentation](https://docs.nvidia.com/nim/)
- [NVIDIA NIM for LLMs support matrix](https://docs.nvidia.com/nim/large-language-models/latest/reference/support-matrix.html)
- [Oracle OKE documentation](https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm)
- [OCI compute shapes](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm)
- [Oracle Cloud price list](https://www.oracle.com/cloud/price-list/)
- [Runbook](docs/RUNBOOK.md)

## License

MIT. See [LICENSE](LICENSE). NVIDIA NIM and Oracle Cloud services are subject
to their own terms.
