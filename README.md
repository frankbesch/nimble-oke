# Nimble OKE - Rapid Smoke Testing for NVIDIA NIM on OCI

GPU-accelerated, cost-efficient smoke testing platform for validating AI inference microservices on Oracle Cloud Infrastructure.

**Based on:** [NVIDIA nim-deploy Oracle OKE Reference](https://github.com/NVIDIA/nim-deploy/tree/main/cloud-service-providers/oracle/oke)

## 💡 Nimble OKE vs. OCI Marketplace NIM

While Oracle Cloud Infrastructure offers a managed NVIDIA NIM solution via its Marketplace, the `nimble-oke` project focuses on a **custom, optimized deployment on OCI Container Engine for Kubernetes (OKE)**. This approach provides:

- **Granular Control**: Full control over Kubernetes cluster configuration, networking, and resource allocation
- **Deep Technical Insight**: Demonstrates proficiency in Kubernetes, Helm, OCI CLI, and GPU-accelerated AI inference deployment
- **Optimization Validation**: Allows for direct measurement and refinement of performance and cost optimizations at the infrastructure level
- **Region Flexibility**: Our solution supports multiple regions (user's choice), whereas the Marketplace offering is currently restricted to `us-ashburn-1`
- **Learning & Competence**: Showcases advanced technical competence in building and optimizing AI inference platforms

**Key Differences:**
| Aspect | Nimble OKE | Marketplace NIM |
|--------|------------|-----------------|
| Platform | OKE (Kubernetes) | OCI Data Science |
| Deployment | Custom Helm charts | Terraform stack |
| Region | Dealer's choice (flexible) | us-ashburn-1 only |
| Control | Full infrastructure control | Managed service |
| Cost | $3.50-$17.50 (simulated) | $1/hr per GPU |
| Purpose | Optimizing & practicing NIM on OKE deployment | Quick deployment |

## Purpose

Validates NVIDIA NIM deployments with comprehensive testing framework. Purpose-built for rapid smoke testing:

- **12-48 minute deployment** (simulated, depending on optimization level)
- **$3.50-$17.50 complete smoke test** (simulated, depending on duration and optimization)
- **Idempotent operations** - safe to re-run
- **Cost guards** - prevent surprise bills
- **Automatic cleanup** on failure
- **Production-grade patterns** from first deployment

## Platform Features

- **Runbook-Driven Workflow** - discover → prereqs → deploy → verify → operate → troubleshoot → cleanup
- **Cost Guards** - ENVIRONMENT and CONFIRM_COST checks before expensive operations
- **Idempotent Operations** - every script safe to re-run
- **Cleanup Hooks** - automatic resource cleanup on failure
- **Structured Logging** - consistent [NIM-OKE][LEVEL] output
- **Smart Discovery** - automatic StorageClass and GPU node detection
- **Session Cost Tracking** - deployment duration and cost estimation
- **Enhanced Security** - seccompProfile RuntimeDefault, topology spread constraints
- **Comprehensive Diagnostics** - systematic troubleshooting runbook

## Quick Start

### Prerequisites

```bash
# Set credentials
export NGC_API_KEY=nvapi-your-key-here
export OCI_COMPARTMENT_ID=ocid1.compartment.oc1...
export OCI_REGION=us-phoenix-1
```

### Option 1: Complete Smoke Test (Cluster + NIM)

```bash
# Provision OKE cluster with GPU nodes
make provision CONFIRM_COST=yes

# Deploy, verify, test NIM
make all

# Cleanup everything
make cleanup
make teardown
```

**Time:** 5 hours | **Cost:** ~$17.50 (simulated)

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

**Time:** 1-2 hours | **Cost:** ~$3.50-$5.00 (simulated)

## Prerequisites

### Required

- **OCI Account** - [Sign up](https://www.oracle.com/cloud/free/)
- **GPU Quota** - VM.GPU.A10.1 (minimum 1 GPU)
- **NVIDIA NGC Account** - [Register](https://catalog.ngc.nvidia.com/)
- **NGC API Key** - [Generate key](https://ngc.nvidia.com/setup/api-key)

### Tools

- OCI CLI ([install](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm))
- kubectl ([install](https://kubernetes.io/docs/tasks/tools/))
- Helm 3+ ([install](https://helm.sh/docs/intro/install/))
- jq ([install](https://stedolan.github.io/jq/download/))
- bc (pre-installed on macOS/Linux)

## Cost Breakdown

### Smoke Test Run (5 hours)

| Component | Rate | Duration | Total |
|-----------|------|----------|-------|
| VM.GPU.A10.1 (1 GPU) | $1.75/hr | 5 hours | $8.75 |
| OKE Control Plane | $0.10/hr | 5 hours | $0.50 |
| ENHANCED Cluster | $0.10/hr | 5 hours | $0.50 |
| Block Storage (50GB) | ~$0.03/GB | 50GB | $1.50 |
| Load Balancer | ~$1.25/hr | 5 hours | $6.25 |
| **Total** | | | **~$17.50** |

### Cost Optimization

- **Time-boxed testing** - provision only when validating
- **Automatic cleanup** - `make cleanup` removes billable resources
- **Model caching** - PVC preserves models between tests (KEEP_CACHE=yes)
- **Cost guards** - prevent accidental production deployments

**WARNING:** 24/7 operation costs ~$1,250-1,500/month. Always run `make cleanup` after testing.

## Runbook Architecture

### Workflow Phases

```
discover → prereqs → deploy → verify → operate → troubleshoot → cleanup
```

**discover** - cluster state, GPU availability, costs
**prereqs** - validate tools, credentials, GPU quota, NGC access
**deploy** - install NIM with cost guards and cleanup hooks
**verify** - deployment health, pod status, GPU allocation, API endpoints
**operate** - operational commands and current costs
**troubleshoot** - systematic diagnostics for common issues
**cleanup** - idempotent resource deletion with cost summary

### Cost Guards

Expensive operations require confirmation:

```bash
# Dev environment - prompts if cost > $5
make install

# Production environment - requires explicit confirmation
ENVIRONMENT=production CONFIRM_COST=yes make install

# Override threshold
COST_THRESHOLD_USD=10 make install
```

### Idempotency

Operations are safe to re-run:

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
# → Cleanup hook triggered
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

- **seccompProfile: RuntimeDefault** - mandatory syscall filtering
- **readOnlyRootFilesystem** - false only where NIM requires write access
- **runAsNonRoot** - all containers run as UID 1000
- **Dropped capabilities** - ALL capabilities dropped by default

### High Availability

- **Topology Spread Constraints** - distributes pods across zones
- **Pod Disruption Budgets** - ensures minimum availability during updates
- **Multi-replica support** - horizontal scaling with GPU scheduling

### Configuration Management

- **Config checksums** - automatic pod restarts on config changes
- **External secrets** - OCI Vault integration ready
- **Environment-based values** - different settings for dev/staging/prod

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
make troubleshoot  # runs comprehensive diagnostics
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
