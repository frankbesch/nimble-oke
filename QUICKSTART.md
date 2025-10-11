# Quick Start - Nimble OKE

Get NVIDIA NIM running in 5 minutes with automated runbooks.

## Prerequisites

```bash
# Check if you're ready
make prereqs
```

This validates:
- OCI CLI configured
- kubectl connected to OKE cluster
- NGC API key set
- GPU nodes available
- NVIDIA device plugin installed

## Deploy NIM

```bash
# Set your NGC API key
export NGC_API_KEY=nvapi-your-key-here

# Deploy
make install
```

This executes:
1. Discovery (cluster state, costs)
2. Prerequisites check
3. NIM deployment with cost guards
4. Automatic verification

## Verify Deployment

```bash
make verify
```

Checks:
- Pods running and ready
- GPU allocated correctly
- Service endpoints active
- API health responding

## Test Inference

```bash
make operate
```

Shows operational commands including:
- API endpoints
- curl test commands
- Log viewing
- Resource monitoring

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
make prereqs  # See what's missing
export NGC_API_KEY=nvapi-xxx
make prereqs  # Check again
```

**Deployment hangs:**
```bash
make troubleshoot  # Run diagnostics
make logs          # Check pod logs
```

## Next Steps

- **Full documentation:** [docs/RUNBOOK.md](docs/RUNBOOK.md)
- **API examples:** [docs/api-examples.md](docs/api-examples.md)
- **Prerequisites guide:** [docs/setup-prerequisites.md](docs/setup-prerequisites.md)

## All Makefile Targets

```bash
make help          # Show this help
make discover      # Discover cluster state
make prereqs       # Check prerequisites
make install       # Deploy NIM
make verify        # Verify deployment
make operate       # Show operations
make troubleshoot  # Run diagnostics
make cleanup       # Cleanup NIM
make all           # Complete workflow
make status        # Quick status
make logs          # View logs
make validate      # prereqs + verify
```

---

**Let's go!** Run `make help` to start.
