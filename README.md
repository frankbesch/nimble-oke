# Nimble OKE - Rapid Smoke Testing for NVIDIA NIM on OCI

Ultra-fast, cost-efficient smoke testing platform for validating GPU-accelerated AI inference microservices on Oracle Cloud Infrastructure.

**Based on:** [NVIDIA nim-deploy Oracle OKE Reference](https://github.com/NVIDIA/nim-deploy/tree/main/cloud-service-providers/oracle/oke)

## Why Nimble OKE?

Validates NVIDIA NIM deployments in minutes, not hours. Purpose-built for rapid smoke testing with minimal cost:

- **5-minute deployment** with automated runbook workflow
- **$12 complete smoke test** (provision to teardown)
- **Idempotent operations** safe to re-run without side effects
- **Cost guards** prevent surprise bills with ENVIRONMENT and CONFIRM_COST checks
- **Automatic cleanup** on failure via trap hooks
- **Production-grade patterns** from first deployment

## Platform Engineering Enhancements

- **Runbook-Driven Workflow** - Structured discover → prereqs → deploy → verify → operate → troubleshoot → cleanup
- **Cost Guards** - ENVIRONMENT and CONFIRM_COST checks before expensive operations
- **Idempotent Operations** - Every script safe to re-run with proper state checking
- **Cleanup Hooks** - Automatic resource cleanup on failure via trap handlers
- **Structured Logging** - Consistent [NIM-OKE][LEVEL] prefixed output
- **Smart Discovery** - Automatic detection of default StorageClass and GPU nodes
- **Session Cost Tracking** - Tracks deployment duration and estimated costs
- **Enhanced Security** - seccompProfile RuntimeDefault, topology spread constraints
- **Comprehensive Diagnostics** - Dedicated troubleshooting runbook with systematic checks

## Quick Start

### Prerequisites

```bash
# Set credentials
export NGC_API_KEY=nvapi-your-key-here
export OCI_COMPARTMENT_ID=ocid1.compartment.oc1...
export OCI_REGION=us-ashburn-1
```

### Option 1: Complete Smoke Test (Cluster + NIM)

```bash
# Provision OKE cluster with GPU nodes
make provision CONFIRM_COST=yes

# Deploy, verify, and test NIM
make all

# Cleanup everything
make cleanup
make teardown
```

**Total Time:** 5 hours | **Cost:** ~$12

### Option 2: Use Existing Cluster

```bash
# Discover existing cluster
make discover

# Deploy NIM
make install CONFIRM_COST=yes

# Verify and test
make verify

# Cleanup
make cleanup
```

**Time:** 1-2 hours (NIM deployment only) | **Cost:** ~$3-5

## Prerequisites

### Required

- **OCI Account** - [Sign up](https://www.oracle.com/cloud/free/)
- **GPU Quota** - VM.GPU.A10.1 (at least 1 GPU)
- **NVIDIA NGC Account** - [Register](https://catalog.ngc.nvidia.com/)
- **NGC API Key** - [Generate key](https://ngc.nvidia.com/setup/api-key)

### Tools

- OCI CLI ([install](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm))
- kubectl ([install](https://kubernetes.io/docs/tasks/tools/))
- Helm 3+ ([install](https://helm.sh/docs/intro/install/))
- jq ([install](https://stedolan.github.io/jq/download/))
- bc (usually pre-installed on macOS/Linux)

## Cost Breakdown

### Smoke Test Run (5 hours)

| Component | Rate | Duration | Total |
|-----------|------|----------|-------|
| VM.GPU.A10.1 (1 GPU) | $1.75/hr | 5 hours | $8.75 |
| OKE Control Plane | $0.10/hr | 5 hours | $0.50 |
| Block Storage (50GB) | ~$0.03/GB | 50GB | $1.50 |
| Load Balancer | ~$0.20/hr | 5 hours | $1.00 |
| **Total** | | | **~$12** |

### Cost Optimization

- **Time-boxed testing** - Provision only when actively validating
- **Automatic cleanup** - `make cleanup` removes all billable resources
- **Model caching** - PVC preserves model between tests (set KEEP_CACHE=yes)
- **Cost guards** - Prevents accidental production deployments

**WARNING:** Running 24/7 costs ~$1,250-1,500/month. Always run `make cleanup` after testing.

## Runbook Architecture

### Workflow Phases

```
discover → prereqs → deploy → verify → operate → troubleshoot → cleanup
```

**discover** - Understand current cluster state, GPU availability, costs
**prereqs** - Validate tools, credentials, GPU quota, NGC access
**deploy** - Install NIM with cost guards and cleanup hooks
**verify** - Check deployment health, pod status, GPU allocation, API endpoints
**operate** - Display operational commands and current costs
**troubleshoot** - Systematic diagnostics for common issues
**cleanup** - Idempotent resource deletion with cost summary

### Cost Guards

All expensive operations require confirmation:

```bash
# Dev environment - prompts if cost > $5
make install

# Production environment - requires explicit confirmation
ENVIRONMENT=production CONFIRM_COST=yes make install

# Override threshold
COST_THRESHOLD_USD=10 make install
```

### Idempotency

Every operation is safe to re-run:

```bash
make install  # First run: creates resources
make install  # Second run: upgrades existing resources (no errors)
make cleanup  # First run: deletes resources
make cleanup  # Second run: no-op (already clean)
```

### Cleanup Hooks

Automatic cleanup on failures:

```bash
# If deployment fails at any point
make install
# → Cleanup hook automatically triggered
# → Helm release uninstalled
# → PVCs deleted (unless KEEP_CACHE=yes)
# → Cost summary displayed
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Makefile Orchestration                │
│  discover | prereqs | deploy | verify | cleanup          │
└──────────────────────┬──────────────────────────────────┘
                       │
       ┌───────────────┼───────────────┐
       │               │               │
       ▼               ▼               ▼
┌──────────┐    ┌──────────┐    ┌──────────┐
│ _lib.sh  │    │ OCI CLI  │    │ kubectl  │
│  Logging │    │  APIs    │    │  + Helm  │
│  Costs   │    │          │    │          │
│  Guards  │    │          │    │          │
└──────────┘    └──────────┘    └──────────┘
       │               │               │
       └───────────────┼───────────────┘
                       │
                       ▼
       ┌───────────────────────────────┐
       │    OCI OKE Cluster            │
       │  ┌─────────────────────────┐  │
       │  │  GPU Node Pool          │  │
       │  │  (VM.GPU.A10.1 × 1)     │  │
       │  │                         │  │
       │  │  ┌───────────────────┐  │  │
       │  │  │  NIM Pod          │  │  │
       │  │  │  Llama 3.1 8B     │  │  │
       │  │  │  GPU: NVIDIA A10  │  │  │
       │  │  └───────────────────┘  │  │
       │  └─────────────────────────┘  │
       │                               │
       │  LoadBalancer (External IP)   │
       └───────────────────────────────┘
```

## Project Structure

```
nimble-oke/
├── Makefile                    # Primary interface (all operations)
├── scripts/
│   ├── _lib.sh                # Shared functions (logging, costs, guards)
│   ├── discover.sh            # Cluster state discovery
│   ├── prereqs.sh             # Prerequisites validation
│   ├── deploy.sh              # NIM deployment with guards
│   ├── verify.sh              # Health verification
│   ├── operate.sh             # Operational commands
│   ├── troubleshoot.sh        # Diagnostic runbook
│   └── cleanup-nim.sh         # Resource cleanup
├── helm/                       # Kubernetes manifests
│   ├── Chart.yaml
│   ├── values.yaml            # Configuration
│   └── templates/
│       ├── deployment.yaml    # Enhanced with checksums, topology spread
│       ├── service.yaml
│       ├── secret.yaml
│       ├── pvc.yaml
│       └── ...
└── docs/
    ├── RUNBOOK.md             # Complete operational guide
    ├── setup-prerequisites.md
    └── api-examples.md
```

## Makefile Targets

### Cluster Lifecycle

```bash
make provision     # Provision OKE cluster with GPU nodes
make teardown      # Teardown entire OKE cluster
```

### NIM Deployment Runbook

```bash
make discover      # Discover cluster state and costs
make prereqs       # Validate prerequisites
make install       # Deploy NIM (discover → prereqs → deploy)
make verify        # Verify deployment health
make operate       # Show operational commands
make troubleshoot  # Run diagnostics
make cleanup       # Remove NIM deployment
```

### Shortcuts

```bash
make all           # Complete workflow (discover → install → verify)
make clean         # Alias for cleanup
make help          # Show all targets
make status        # Quick deployment status
make logs          # Fetch recent logs
```

### Environment Variables

```bash
ENVIRONMENT=dev|production     # Triggers cost guards (default: dev)
CONFIRM_COST=yes              # Bypass cost guard prompt
COST_THRESHOLD_USD=5          # Cost threshold for guards (default: 5)
NGC_API_KEY=nvapi-...         # NVIDIA NGC API key (required)
OCI_COMPARTMENT_ID=ocid1...   # OCI compartment (required)
KEEP_CACHE=yes                # Preserve PVCs during cleanup
FORCE=yes                     # Skip cleanup confirmation
```

### Examples

```bash
# Discovery
make discover

# Deploy with cost guard
NGC_API_KEY=nvapi-xxx make install

# Production deployment (requires confirmation)
ENVIRONMENT=production CONFIRM_COST=yes NGC_API_KEY=nvapi-xxx make install

# Cleanup preserving model cache
KEEP_CACHE=yes make cleanup

# Force cleanup without prompt
FORCE=yes make cleanup

# Check deployment status
make status

# View logs
make logs

# Troubleshoot issues
make troubleshoot
```

## Helm Chart Features

### Security Hardening

- **seccompProfile: RuntimeDefault** - Mandatory syscall filtering
- **readOnlyRootFilesystem** - False only where NIM requires write access
- **runAsNonRoot** - All containers run as UID 1000
- **Dropped capabilities** - ALL capabilities dropped by default

### High Availability

- **Topology Spread Constraints** - Distributes pods across zones
- **Pod Disruption Budgets** - Ensures minimum availability during updates
- **Multi-replica support** - Horizontal scaling with GPU scheduling

### Configuration Management

- **Config checksums** - Automatic pod restarts on config changes
- **External secrets** - OCI Vault integration ready
- **Environment-based values** - Different settings for dev/staging/prod

## Troubleshooting

### Common Issues

**Cost guard triggered:**
```bash
[NIM-OKE][ERROR] Cost guard: Estimated $12.00 exceeds threshold
[NIM-OKE][INFO] Set CONFIRM_COST=yes to proceed
```
Solution: `CONFIRM_COST=yes make install`

**No GPU nodes found:**
```bash
[NIM-OKE][ERROR] No GPU nodes available
```
Solution: Provision OKE cluster with GPU node pool first

**NGC credentials invalid:**
```bash
[NIM-OKE][ERROR] NGC_API_KEY not set
```
Solution: `export NGC_API_KEY=nvapi-your-key-here`

**Pods stuck pending:**
```bash
make troubleshoot  # Runs comprehensive diagnostics
```

See [docs/RUNBOOK.md](docs/RUNBOOK.md) for complete troubleshooting guide.

## Additional Resources

- **NVIDIA NIM Documentation:** https://docs.nvidia.com/nim/
- **NVIDIA NGC Catalog:** https://catalog.ngc.nvidia.com/
- **Oracle OKE Documentation:** https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm
- **Reference Implementation:** https://github.com/NVIDIA/nim-deploy/tree/main/cloud-service-providers/oracle/oke
- **Complete Runbook:** [docs/RUNBOOK.md](docs/RUNBOOK.md)

## License

This project references NVIDIA NIM deployment examples and Oracle Cloud documentation. 
Please refer to respective licenses for NVIDIA NIM and Oracle Cloud services.

## Contributing

For issues or improvements, please refer to the upstream repositories:
- https://github.com/NVIDIA/nim-deploy

---

**Ready for rapid smoke testing?** Run `make help` to get started.

**Remember:** Always run `make cleanup` after testing to stop charges.

---

**Note:** GitHub repository URL is https://github.com/frankbesch/nimble-oke
