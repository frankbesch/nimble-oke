# Project Summary - Nimble OKE

**Status:** First Version - Under Active Development (v0.1.0-dev)  
**Created:** October 9, 2025  
**Purpose:** Rapid smoke testing platform for NVIDIA NIM on OCI OKE with cost guards and idempotent operations

## Overview

Nimble OKE is a platform engineering framework for ultra-fast, cost-efficient smoke testing of NVIDIA NIM deployments on Oracle Cloud Infrastructure's Container Engine for Kubernetes (OKE).

**Key Differentiator:** Purpose-built for rapid validation cycles with minimal cost, not long-running production deployments.

### Design Philosophy

- **Speed** - deploy and validate in minutes
- **Cost-Conscious** - complete smoke test for ~$17.50 (simulated)
- **Idempotent** - every operation safe to re-run
- **Fail-Safe** - automatic cleanup on errors
- **Production Patterns** - enterprise-grade from day one

## Project Architecture

### Runbook-Driven Workflow

```
discover → prereqs → deploy → verify → operate → troubleshoot → cleanup
```

Each phase is:
- independently executable
- idempotent (safe to re-run)
- cost-aware with guards
- logged with [NIM-OKE] prefix
- protected by cleanup hooks

### Cost Guard System

```bash
if cost > threshold OR environment == production:
    require CONFIRM_COST=yes
else:
    proceed
```

Prevents:
- accidental production deployments
- surprise bills from expensive operations
- forgotten resources running indefinitely

### Cleanup Hook Pattern

```bash
trap cleanup_on_failure EXIT ERR INT TERM

# If ANY step fails → cleanup runs automatically
# Resources never leak
# Costs contained
```

## File Structure

### Core Platform Files

```
Makefile                       # Primary orchestration interface
scripts/_lib.sh                # Shared library functions
```

### Runbook Scripts (7 files)

```
scripts/discover.sh            # State discovery and cost estimation
scripts/prereqs.sh             # Prerequisites validation
scripts/deploy.sh              # NIM deployment with guards
scripts/verify.sh              # Health verification
scripts/operate.sh             # Operational commands
scripts/troubleshoot.sh        # Systematic diagnostics
scripts/cleanup-nim.sh         # Idempotent cleanup
```

### Helm Chart (Enhanced)

```
helm/Chart.yaml
helm/values.yaml               # With topology spread, seccomp
helm/templates/
    deployment.yaml            # Config checksums, topology constraints
    service.yaml
    secret.yaml
    pvc.yaml
    serviceaccount.yaml
    _helpers.tpl
```

### Documentation

```
README.md                      # Project overview
QUICKSTART.md                  # 5-minute start guide
PROJECT_SUMMARY.md             # This file
docs/RUNBOOK.md                # Complete operational guide
docs/setup-prerequisites.md    # Prerequisites setup
docs/api-examples.md           # API usage examples
```

## Technical Highlights

### Shared Library (_lib.sh)

**Logging:**
- `log_info()`, `log_warn()`, `log_error()`, `log_success()`
- Consistent [NIM-OKE][LEVEL] format

**Cost Functions:**
- `cost_guard()` - Checks threshold and environment
- `estimate_hourly_cost()` - GPU node cost calculation
- `estimate_deployment_cost()` - Session cost projection
- `format_cost()` - Consistent cost formatting

**Kubernetes Helpers:**
- `get_default_storage_class()` - Extracts (default) StorageClass
- `get_gpu_nodes()` - Finds nodes with nvidia.com/gpu
- `get_gpu_count()` - Counts available GPUs
- `wait_for_pod_ready()` - Smart pod readiness wait
- `helm_install_or_upgrade()` - Idempotent Helm operations

**Guards and Checks:**
- `check_command()` - Tool availability
- `check_env_var()` - Required variables
- `check_oci_credentials()` - OCI auth validation
- `check_kubectl_context()` - Cluster connectivity

### Helm Chart Enhancements

**Security:**
- `seccompProfile: RuntimeDefault` - Syscall filtering
- `readOnlyRootFilesystem: false` - Only where required
- `allowPrivilegeEscalation: false` - No privilege escalation
- `capabilities.drop: ALL` - Minimal capabilities

**High Availability:**
- `topologySpreadConstraints` - Zone distribution
- `nodeAffinity` - Required GPU node placement
- `tolerations` - GPU taint toleration

**Operations:**
- `checksum/config` annotation - Auto-restart on secret changes
- Health probes (readiness, liveness)
- Resource limits (CPU, memory, GPU)

## Cost Analysis

### Smoke Test Scenario (5 hours)

| Component | Cost |
|-----------|------|
| GPU Node (VM.GPU.A10.1) | $8.75 |
| OKE Control Plane | $0.50 |
| ENHANCED Cluster | $0.50 |
| Storage (50GB PVC) | $1.50 |
| LoadBalancer | $6.25 |
| **Total** | **~$17.50** |

### Cost Optimization Features

- pre-deployment cost estimation
- cost guard confirmation workflow
- session cost tracking
- automatic cleanup verification
- model cache preservation option (KEEP_CACHE=yes)

### Alternative Scenarios

- **Multiple smoke tests (3x):** ~$35-45
- **Extended testing (10 hrs):** ~$20-25
- **24/7 running:** ~$1,250-1,500/month ⚠️

## Key Features

### 1. Runbook-Driven Operations

Every operation follows structured pattern:
- prerequisites checked
- costs estimated and guarded
- progress logged
- cleanup on failure
- success verified

### 2. Idempotency Everywhere

```bash
make install   # Run 1: creates
make install   # Run 2: upgrades
make cleanup   # Run 1: deletes
make cleanup   # Run 2: no-op
```

No errors, no duplicate resources, predictable behavior.

### 3. Cost Safety

```bash
# Automatically blocked if cost > $5
make install

# Explicit confirmation required
CONFIRM_COST=yes make install

# Production requires env + confirmation
ENVIRONMENT=production CONFIRM_COST=yes make install
```

### 4. Automatic Cleanup

```bash
make install
  → Step 5 fails
  → trap cleanup_on_failure
  → Helm uninstall
  → PVCs deleted
  → Cost summary
  → Exit 1
```

Resources never leak, even on failures.

### 5. Comprehensive Diagnostics

```bash
make troubleshoot
  → Pod status + events
  → GPU resource check
  → Image pull verification
  → Service connectivity
  → Storage binding
  → Resource allocation
  → Network tests
  → Recent events
```

Systematic troubleshooting, not guesswork.

## Platform Engineering Standards

### Structured Logging

All output follows [NIM-OKE][LEVEL] format:
- parseable by log aggregators
- clear severity levels
- consistent across all scripts

### Error Handling

```bash
set -euo pipefail  # Fail fast
trap cleanup EXIT  # Always cleanup
die() { log_error "$*"; exit 1; }
```

### Input Validation

Every script validates:
- required environment variables
- tool availability
- cluster connectivity
- credential validity

### Timeout Protection

Long operations wrapped:

```bash
timeout 300 kubectl wait ... || { cleanup; exit 1; }
```

Prevents indefinite hangs.

## Comparison to Original

| Aspect | Original | Nimble OKE |
|--------|----------|------------|
| **Interface** | Individual scripts | Makefile + runbooks |
| **Idempotency** | Partial | Complete |
| **Cost Guards** | None | ENVIRONMENT + CONFIRM_COST |
| **Cleanup** | Manual | Automatic on failure |
| **Logging** | Ad-hoc | Structured [NIM-OKE] |
| **Discovery** | Manual | Automated (make discover) |
| **Troubleshooting** | Scattered | Systematic runbook |
| **Session Tracking** | None | Cost + duration tracking |
| **Security** | Basic | Enhanced (seccomp, topology) |

## Success Metrics

**Deployment:**
- cluster discovered and validated
- prerequisites met
- NIM deployed with cost guard
- pods running with GPU
- API responding
- cleanup successful

**Performance:**
- discovery: <30 seconds
- prerequisites: <1 minute
- deployment: 5-10 minutes (cached) or 45-60 minutes (first time)
- verification: <1 minute
- cleanup: 1-2 minutes

**Cost (simulated):**
- smoke test: ~$17.50 (5 hours)
- hourly: ~$3.50
- model cache preservation saves $1.50 per re-deployment

## Next Steps

### To Deploy

1. Review prerequisites: `docs/setup-prerequisites.md`
2. Follow quick start: `QUICKSTART.md`
3. Consult runbook: `docs/RUNBOOK.md`

### To Understand

- study Makefile targets
- review `scripts/_lib.sh` for shared patterns
- explore Helm chart structure

### To Extend

- add custom Makefile targets
- extend `_lib.sh` with new helpers
- customize Helm values for your models
- integrate with CI/CD pipelines

## References

- **NVIDIA NIM:** https://docs.nvidia.com/nim/
- **NVIDIA NGC:** https://catalog.ngc.nvidia.com/
- **Oracle OKE:** https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm
- **Original Implementation:** https://github.com/NVIDIA/nim-deploy/tree/main/cloud-service-providers/oracle/oke
- **Meta Llama:** https://llama.meta.com/

## License & Attribution

Based on NVIDIA nim-deploy Oracle OKE reference implementation.

This project references:
- NVIDIA NIM deployment examples
- Oracle Cloud Infrastructure documentation
- Meta Llama model specifications

Please refer to respective licenses for NVIDIA NIM, Oracle Cloud services, and Meta Llama models.

---

**Ready for smoke testing?** Run `make help` to start.

**Remember:** Always run `make cleanup` after testing.
