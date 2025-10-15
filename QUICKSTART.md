# Quick Start - Nimble OKE

> **📖 Reading time:** 3 minutes

Get NVIDIA NIM running in 12-48 minutes with runbook automation.

## System Requirements

### Minimum Requirements

| Component | Specification | Notes |
|-----------|---------------|-------|
| **OCI Account** | Paid account | Free tier not supported |
| **GPU Quota** | VM.GPU.A10.1 (1 GPU) | Request via OCI Console |
| **System Memory** | 40GB RAM minimum | VM.GPU.A10.1 has 240GB ✅ |
| **Disk Space** | 100GB | For model cache + containers |
| **NGC API Key** | Required | [Generate here](https://ngc.nvidia.com/setup/api-key) |

**NVIDIA recommends 90GB RAM** - VM.GPU.A10.1 provides 240GB (2.6× recommendation). **Cost: $2.62/hour.**

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

**📖 Complete reference:** [README.md - Environment Variables](README.md#environment-variables)

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
