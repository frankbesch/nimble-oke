# Quick Start - Nimble OKE

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

```bash
NGC_API_KEY=nvapi-...          # Required: NVIDIA NGC API key
OCI_COMPARTMENT_ID=ocid1...    # Required: OCI compartment
ENVIRONMENT=dev                # Optional: dev or production
CONFIRM_COST=yes               # Optional: bypass cost guard
KEEP_CACHE=yes                 # Optional: preserve PVCs
FORCE=yes                      # Optional: skip confirmations
```

## Cost Examples

```bash
# Dev deployment (prompts if cost > $5)
make install

# Production deployment (requires confirmation)
ENVIRONMENT=production CONFIRM_COST=yes make install

# Higher cost threshold
COST_THRESHOLD_USD=20 make install
```

## Troubleshooting

**Cost guard blocks deployment:**
```bash
CONFIRM_COST=yes make install
```

**Prerequisites fail:**
```bash
make prereqs  # see what's missing
export NGC_API_KEY=nvapi-xxx
make prereqs  # check again
```

**Deployment hangs:**
```bash
make troubleshoot  # run diagnostics
make logs          # check pod logs
```

## Next Steps

- **Full documentation:** [docs/RUNBOOK.md](docs/RUNBOOK.md)
- **API examples:** [docs/api-examples.md](docs/api-examples.md)
- **Prerequisites guide:** [docs/setup-prerequisites.md](docs/setup-prerequisites.md)

## All Makefile Targets

```bash
make help          # show this help
make discover      # discover cluster state
make prereqs       # check prerequisites
make install       # deploy NIM
make verify        # verify deployment
make operate       # show operations
make troubleshoot  # run diagnostics
make cleanup       # cleanup NIM
make all           # complete workflow
make status        # quick status
make logs          # view logs
make validate      # prereqs + verify
```

---

**Let's go!** Run `make help` to start.
