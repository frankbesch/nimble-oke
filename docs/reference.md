# Reference

## Rates and shapes

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

One table in [scripts/_lib.sh](../scripts/_lib.sh) holds every rate. An unknown
shape is an error, not a default price.

With autoscaling, the GPU line bills only while the GPU node exists. The
cluster and the system node bill for the whole run.

GPU billing stops only when the GPU node is gone or the node pool is deleted. `make cleanup` removes
the NIM release and leaves the cluster running. `make teardown` deletes the
node pool and the cluster.

## Repository layout

```text
Makefile            Entry point for every step
scripts/            Provision, deploy, verify, cleanup, teardown, IAM setup, and the measured-run runner
scripts/_lib.sh     Logging, cost guards, rate table, confirmed-delete helpers
helm/               Chart for the NIM deployment
tests/              Stubbed tests for the runner, autoscaling, and the provision and teardown scripts
docs/               Quick start, runbook, prerequisites, and API examples
docs/runs/          Receipts from measured runs, the attempt log, and posted cost
docs/archive/2025/  Working notes from October 2025; not measurements
```

The working notes from October 2025 are in
[docs/archive/2025/](archive/2025/README.md). Each carries a note saying
it is not a measurement. Their prices and shapes were corrected in October
2026.

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

- `OCI_COMPARTMENT_ID` (required): Compartment that owns every resource
- `NGC_API_KEY` (required): NGC key, passed to Helm at install
- `OCI_REGION` (default `us-phoenix-1`): Region for every `oci` call. The pinned node image is Phoenix-only.
- `API_ALLOWED_CIDR` (default `0.0.0.0/0`): Source range allowed to reach the Kubernetes API on 6443
- `OKE_GPU_SHAPE` (default `VM.GPU.A10.1`): GPU node shape
- `AUTOSCALE` (default `0`): Set `1` for `make provision` to create the GPU pool at zero nodes with the autoscaler
- `CONFIRM_COST` (default `no`): Set `yes` to pass the cost guard. Otherwise a billable step exits.
- `KEEP_CACHE` (default `no`): Keep the model-cache volume during `make cleanup`
- `FORCE` (default `no`): Skip confirmation prompts

## References

- [NVIDIA NIM documentation](https://docs.nvidia.com/nim/)
- [NVIDIA NIM for LLMs support matrix](https://docs.nvidia.com/nim/large-language-models/latest/reference/support-matrix.html)
- [Oracle OKE documentation](https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm)
- [OCI compute shapes](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm)
- [Oracle Cloud price list](https://www.oracle.com/cloud/price-list/)
- [Quick start](QUICKSTART.md), [runbook](RUNBOOK.md), and [API examples](api-examples.md)
