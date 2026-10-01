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
| First deployment | October 2025, on a cluster made with the Console's Quick Create. NIM served inference. No run receipt was kept. |
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
| GPU node | `VM.GPU.A10.1` by default: one NVIDIA A10 (24 GB), 15 OCPU, 240 GB RAM |
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
| **Default shape, `VM.GPU.A10.1`** | **$2.10 per hour** |
| `VM.GPU.A10.2` (two GPUs) | $4.10 per hour |
| `BM.GPU.A10.4` (four GPUs, bare metal) | $8.10 per hour |

The load balancer and block storage add a small amount. This repository does
not verify those two rates, so the scripts label them as estimates.

One table in [scripts/_lib.sh](scripts/_lib.sh) holds every rate. An unknown
shape is an error, not a default price.

GPU billing stops only when the node pool is deleted. `make cleanup` removes
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
export NGC_API_KEY=nvapi-xxxxxxxxxxxxxxxxxxxx
export OCI_REGION=us-phoenix-1
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
OCI_COMPARTMENT_ID=... NGC_API_KEY=... scripts/run_measured.sh docs/runs/out
```

A free check of access, quota, and configuration, with nothing created:

```bash
OCI_COMPARTMENT_ID=... scripts/run_measured.sh --preflight-only /tmp/preflight
```

The runner is built to end with the cluster deleted:

- A trap runs teardown once on success, failure, Ctrl-C, `TERM`, and `HUP`.
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
| A failed install uninstalled the release before anyone could see why | Deploy captures pod state, events, and logs before it cleans up. |
| Prices and shapes disagreed across files, and `VM.GPU.A10.4` is not an Oracle shape | One rate table. Three valid shapes. |

## Repository layout

```
Makefile            Entry point for every step
scripts/            Provision, deploy, verify, cleanup, teardown, and the measured-run runner
scripts/_lib.sh     Logging, cost guards, rate table, confirmed-delete helpers
helm/               Chart for the NIM deployment
tests/              Stubbed tests for the runner
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
- The watchdog runs on the machine that starts the run. If that machine loses power, nothing tears the cluster down.

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
