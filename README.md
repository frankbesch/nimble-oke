# Nimble OKE - Rapid Smoke Testing for NVIDIA NIM on OCI

> **⚠️ Development Status:** First version (v0.1.0-20251013-dev) - Under active development  
> **🚧 Testing Required:** All configurations need validation with actual GPU quota

GPU-accelerated, cost-efficient smoke testing platform for validating AI inference microservices on Oracle Cloud Infrastructure.

**Based on:** [NVIDIA nim-deploy Oracle OKE Reference](https://github.com/NVIDIA/nim-deploy/tree/main/cloud-service-providers/oracle/oke)

## 🚧 Development Status

**Current Version:** v0.1.0-20251013-dev (First version under active development)

### What's Ready:
- ✅ **Complete testing framework** - All simulation and optimization scripts
- ✅ **Environment configuration** - Chicago region, compartment, budget controls  
- ✅ **NGC API key validation** - Set and validated
- ✅ **Cost simulation** - $17.50 deployment within $50 budget
- ✅ **Security optimization** - NIM-compatible security settings
- ✅ **Documentation** - Comprehensive technical analysis and guides

### What Needs Testing:
- ⏳ **GPU quota approval** - CAM-247648 (Oracle reviewing)
- ⏳ **Cluster provisioning** - Cannot provision without GPU quota
- ⏳ **NIM deployment** - 48min baseline, 12min optimized (simulated)
- ⏳ **Performance validation** - All timing estimates are simulated
- ⏳ **Cost validation** - All cost estimates are simulated

### Development Philosophy:
This is the **first version** of Nimble OKE. All configurations, timing estimates, and cost projections are based on mathematical modeling and simulation. Real-world performance will be validated after GPU quota approval and actual deployment testing.

## Purpose

Validates NVIDIA NIM deployments with comprehensive testing framework. Purpose-built for rapid smoke testing:

- **12-48 minute deployment** (simulated, depending on optimization level)
- **$3.50-$17.50 complete smoke test** (simulated, depending on duration and optimization)
- **Idempotent operations** - safe to re-run
- **Cost guards** - prevent surprise bills
- **Automatic cleanup** on failure
- **Production-grade patterns** from first deployment

## Platform Features

### Enhanced Over Reference Implementation

**Beyond the [NVIDIA nim-deploy Oracle OKE reference](https://github.com/NVIDIA/nim-deploy/tree/main/cloud-service-providers/oracle/oke), Nimble OKE adds:**

- **Mathematical Performance Modeling** - 48min baseline → 12min optimized deployment (70% improvement)
- **Comprehensive Testing Framework** - Complete simulation without infrastructure costs
- **Cost Engineering** - $17.50 → $3.50 per iteration optimization (80% cost reduction)
- **Failure Pattern Detection** - Proactive troubleshooting for common NIM issues
- **Rapid Iteration Optimization** - Caching strategies and performance tuning
- **Security Optimization** - NIM-compatible security settings (seccompProfile disabled for GPU compatibility)
- **Cost Guards & Budget Controls** - $50 daily limit with automatic validation
- **Session Cost Tracking** - Real-time deployment cost monitoring

### Core Platform Features

- **Runbook-Driven Workflow** - discover → prereqs → deploy → verify → operate → troubleshoot → cleanup
- **Cost Guards** - ENVIRONMENT and CONFIRM_COST checks before expensive operations
- **Idempotent Operations** - every script safe to re-run
- **Cleanup Hooks** - automatic resource cleanup on failure
- **Structured Logging** - consistent [NIM-OKE][LEVEL] output
- **Smart Discovery** - automatic StorageClass and GPU node detection
- **Enhanced Security** - NIM-optimized security (non-root, capability dropping, topology constraints disabled for development)
- **Comprehensive Diagnostics** - systematic troubleshooting runbook with failure pattern recognition

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

### Required Accounts & Resources

| Component | Requirement | Notes |
|-----------|-------------|-------|
| **OCI Account** | [Sign up](https://www.oracle.com/cloud/free/) | **Does NOT work on OCI Free tier** - requires paid account |
| **GPU Quota** | VM.GPU.A10.1 (minimum 1 GPU) | Request via OCI Console → Service Limits → Compute |
| **NVIDIA NGC Account** | [Register](https://catalog.ngc.nvidia.com/) | Free account required for NIM container access |
| **NGC API Key** | [Generate key](https://ngc.nvidia.com/setup/api-key) | Required for pulling NVIDIA container images |
| **Memory** | Minimum 8GB RAM | For OCI CLI, kubectl, and local operations |
| **Storage** | 10GB free space | For container images and temporary files |

### Required Tools

| Tool | Version | Install Command | Purpose |
|------|---------|-----------------|---------|
| **OCI CLI** | Latest | [Install guide](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) | OCI resource management |
| **kubectl** | 1.28+ | [Install guide](https://kubernetes.io/docs/tasks/tools/) | Kubernetes cluster interaction |
| **Helm** | 3.12+ | [Install guide](https://helm.sh/docs/intro/install/) | Kubernetes package management |
| **jq** | 1.6+ | `brew install jq` (macOS) / `apt install jq` (Ubuntu) | JSON processing |
| **bc** | Any | Pre-installed on macOS/Linux | Mathematical calculations |

## Cost Breakdown

### Smoke Test Run (5 hours)

| Component | Rate | Duration | Total | Notes |
|-----------|------|----------|-------|-------|
| VM.GPU.A10.1 (1 GPU) | $1.75/hr | 5 hours | $8.75 | Primary compute cost |
| OKE Control Plane | $0.10/hr | 5 hours | $0.50 | Kubernetes management |
| ENHANCED Cluster | $0.10/hr | 5 hours | $0.50 | Additional cluster features |
| Block Storage (50GB) | ~$0.03/GB | 50GB | $1.50 | Model storage and cache |
| Load Balancer | ~$1.25/hr | 5 hours | $6.25 | External access |
| **Total** | | | **~$17.50** | **Simulated estimate** |

### Cost Optimization Strategies

| Strategy | Impact | Implementation |
|----------|--------|----------------|
| **Time-boxed testing** | 80% cost reduction | Provision only when validating |
| **Automatic cleanup** | Prevents surprise bills | `make cleanup` removes billable resources |
| **Model caching** | Preserves expensive downloads | PVC preserves models (KEEP_CACHE=yes) |
| **Cost guards** | Prevents accidental deployments | Confirmation prompts for >$5 operations |

**⚠️ WARNING:** 24/7 operation costs ~$1,250-1,500/month. Always run `make cleanup` after testing.

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

### Primary Operations

| Command | Purpose | Cost Guard | Duration |
|---------|---------|------------|----------|
| `make provision` | Provision OKE cluster with GPU nodes | ✅ Yes | ~15min |
| `make teardown` | Teardown entire OKE cluster | ✅ Yes | ~10min |
| `make discover` | Discover cluster state and costs | ❌ No | ~30sec |
| `make prereqs` | Validate prerequisites | ❌ No | ~1min |
| `make install` | Deploy NIM (discover → prereqs → deploy) | ✅ Yes | ~12-48min |
| `make verify` | Verify deployment health | ❌ No | ~2min |
| `make operate` | Show operational commands | ❌ No | ~30sec |
| `make troubleshoot` | Run diagnostics | ❌ No | ~3min |
| `make cleanup` | Remove NIM deployment | ❌ No | ~2min |

### Shortcuts & Utilities

| Command | Purpose | Includes |
|---------|---------|----------|
| `make all` | Complete workflow | discover → install → verify |
| `make clean` | Alias for cleanup | Same as make cleanup |
| `make help` | Show all targets | Complete command reference |
| `make status` | Quick deployment status | Pod health, costs, GPU usage |
| `make logs` | Fetch recent logs | Last 100 lines from all pods |

### Environment Variables

| Variable | Values | Default | Purpose |
|----------|--------|---------|---------|
| `ENVIRONMENT` | `dev` \| `production` | `dev` | Triggers cost guards |
| `CONFIRM_COST` | `yes` \| `no` | `no` | Bypass cost guard prompt |
| `COST_THRESHOLD_USD` | Number | `5` | Cost threshold for guards |
| `NGC_API_KEY` | `nvapi-...` | **Required** | NVIDIA NGC API key |
| `OCI_COMPARTMENT_ID` | `ocid1...` | **Required** | OCI compartment |
| `KEEP_CACHE` | `yes` \| `no` | `no` | Preserve PVCs during cleanup |
| `FORCE` | `yes` \| `no` | `no` | Skip cleanup confirmation |

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

### Security Hardening (NIM-Optimized)

| Feature | Implementation | NIM Compatibility |
|---------|----------------|-------------------|
| **Non-root execution** | UID 1000 | ✅ Compatible |
| **Dropped capabilities** | ALL capabilities dropped | ✅ Compatible |
| **Privilege escalation prevention** | `allowPrivilegeEscalation: false` | ✅ Compatible |
| **Writable root filesystem** | `readOnlyRootFilesystem: false` | ✅ Required for NIM temp files |
| **seccompProfile** | Disabled for GPU syscall compatibility | ⚠️ Trade-off for GPU access |
| **Security optimization** | Balanced for deployment success | 🎯 Practical security |

### High Availability (Development-Optimized)

| Feature | Status | Purpose |
|---------|--------|---------|
| **Topology Spread Constraints** | Disabled | Single-zone development/testing |
| **Node affinity** | GPU node placement required | NVIDIA A10 scheduling |
| **Tolerations** | GPU taint toleration | GPU node access |
| **Multi-replica support** | Enabled | Horizontal scaling with GPU scheduling |
| **Health probes** | Optimized timing | Faster deployment detection (15s readiness, 45s liveness) |

### Configuration Management

| Feature | Implementation | Benefit |
|---------|----------------|---------|
| **Config checksums** | Automatic pod restarts | Config change detection |
| **External secrets** | OCI Vault integration ready | Production secret management |
| **Environment-based values** | Dev/staging/prod settings | Environment-specific configuration |

## Troubleshooting

### Common Issues & Solutions

| Issue | Error Message | Solution | Prevention |
|-------|---------------|----------|------------|
| **Cost guard triggered** | `[NIM-OKE][ERROR] Cost guard: Estimated $12.00 exceeds threshold` | `CONFIRM_COST=yes make install` | Set higher `COST_THRESHOLD_USD` |
| **No GPU nodes found** | `[NIM-OKE][ERROR] No GPU nodes available` | `make provision` first | Always provision cluster before install |
| **NGC credentials invalid** | `[NIM-OKE][ERROR] NGC_API_KEY not set` | `export NGC_API_KEY=nvapi-your-key-here` | Run `make prereqs` to validate |
| **Pods stuck pending** | Pods in `Pending` state | `make troubleshoot` for diagnostics | Check GPU quota and node capacity |
| **Image pull failures** | `Failed to pull image` | Verify NGC API key and network access | Run `make prereqs` to validate NGC access |

**🔍 Comprehensive Diagnostics:** Run `make troubleshoot` for systematic issue detection and resolution guidance.

**📚 Complete Guide:** See [docs/RUNBOOK.md](docs/RUNBOOK.md) for detailed troubleshooting procedures.

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
