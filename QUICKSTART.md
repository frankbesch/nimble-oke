# Quick Start - Nimble OKE

> **📖 Reading time:** 2 minutes

Deploy NVIDIA NIM on OKE with runbook automation. Deployment time is not measured yet; see [docs/runs/](docs/runs/).

## System Requirements

### Minimum Requirements

| Component | Specification | Notes |
|-----------|---------------|-------|
| **OCI Account** | Paid account | Free tier not supported |
| **GPU Quota** | VM.GPU.A10.1 (1× A10 24 GB) | Default limit is 0; request a `gpu-a10-count` increase in the OCI Console |
| **Node Memory** | 240 GB | VM.GPU.A10.1: 15 OCPU, 240 GB RAM |
| **Disk Space** | 100GB | For model cache + containers |
| **NGC API Key** | Required | [Generate here](https://ngc.nvidia.com/setup/api-key) |

**Cost:** $2.00/hr GPU + $0.10/hr enhanced cluster = $2.10/hr, plus load balancer and block storage, not verified here.

## Prerequisites

```bash
# Check if you're ready
make prereqs
```

**Validates:**
- ✅ OCI CLI configured
- ✅ kubectl connected to OKE cluster  
- ✅ NGC API key set
- ✅ GPU nodes available
- ✅ NVIDIA device plugin installed

## Deploy NIM

```bash
# Set your NGC API key
export NGC_API_KEY=nvapi-your-key-here

# Deploy
make install
```

**Executes:**
1. 🔍 Discovery (cluster state, costs)
2. ✅ Prerequisites check
3. 🚀 NIM deployment with cost guards
4. ✅ Automatic verification

## Verify Deployment

```bash
make verify
```

**Checks:**
- ✅ Pods running and ready
- ✅ GPU allocated correctly
- ✅ Service endpoints active
- ✅ API health responding

## Test Inference

```bash
make operate
```

**Shows operational commands:**
- 🌐 API endpoints
- 🔗 curl test commands
- 📋 Log viewing
- 📊 Resource monitoring

Copy and run the curl commands to test inference.

## View Status

```bash
# Quick status
make status

# View logs
make logs

# Full diagnostics
make troubleshoot
```

## Cleanup

```bash
# Remove NIM deployment
make cleanup

# Keep model cache for faster re-deployment
KEEP_CACHE=yes make cleanup

# Force cleanup without confirmation
FORCE=yes make cleanup
```

`make cleanup` removes the NIM release only. GPU billing continues until you run `make teardown`, which deletes the node pool and cluster.

## Complete Workflow

```bash
# Everything in one command
make all  # discover → install → verify
```

## Environment Variables

| Variable | Purpose | Example |
|----------|---------|---------|
| `NGC_API_KEY` | NVIDIA NGC API key (required) | `nvapi-...` |
| `OCI_COMPARTMENT_ID` | OCI compartment (required) | `ocid1...` |
| `CONFIRM_COST` | Bypass cost guard | `yes` |
| `KEEP_CACHE` | Preserve PVCs during cleanup | `yes` |

**📖 Complete reference:** [README.md - Environment Variables](README.md#makefile-targets)

## Troubleshooting

`make troubleshoot` - Run diagnostics  
`CONFIRM_COST=yes make install` - Bypass cost guard  
`export NGC_API_KEY=nvapi-xxx` - Set NGC credentials

**📚 Full guide:** [docs/RUNBOOK.md - Phase 6: Troubleshoot](docs/RUNBOOK.md#phase-6-troubleshoot)

## Next Steps

- **Full documentation:** [docs/RUNBOOK.md](docs/RUNBOOK.md)
- **API examples:** [docs/api-examples.md](docs/api-examples.md)
- **Prerequisites guide:** [docs/setup-prerequisites.md](docs/setup-prerequisites.md)

**📖 All Makefile targets:** [README.md - Makefile Targets](README.md#makefile-targets)
