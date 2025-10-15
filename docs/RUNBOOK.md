# Nimble OKE Platform Engineering Runbook

> **📖 Reading time:** 15 minutes  
> **📚 Reference guide** - Bookmark for operational tasks

Complete operational guide for NVIDIA NIM smoke testing on OCI OKE.

## Runbook Philosophy

**discover → prereqs → deploy → verify → operate → troubleshoot → cleanup**

Every operation follows this structured pattern with:
- idempotent execution (safe to re-run)
- cost guards before expensive ops
- automatic cleanup on failure
- structured logging with [NIM-OKE] prefix
- session cost tracking

## Phase 1: Discover

### Purpose

Understand current cluster state before making changes.

### Command

```bash
make discover
```

### What It Does

1. **Cluster Information**
   - Kubernetes version
   - total nodes and GPU nodes
   - default StorageClass detection

2. **GPU Resources**
   - GPU node inventory
   - capacity and allocatable GPUs
   - GPU product type (NVIDIA-A10)

3. **Existing Deployments**
   - current NIM deployments
   - running pods and services
   - resource allocation

4. **Cost Estimation**
   - current hourly cost
   - daily/monthly projections
   - smoke test cost estimate

### Expected Output

```
[NIM-OKE][INFO] Discovering OKE cluster state...

=== Cluster Information ===
Kubernetes Version: v1.28.2
Total Nodes: 1
GPU Nodes: 1
Default StorageClass: oci-bv

=== GPU Resources ===
Node: oke-cxxxxxxx-xxxxx
  Capacity: 1 GPU(s)
  Allocatable: 1 GPU(s)

=== Cost Estimation ===
Current cluster cost (with 1 GPU node(s)):
  Hourly: $1.85
  Daily: $44.40
  Monthly (if running 24/7): $1,332.00

[NIM-OKE][SUCCESS] Discovery complete
```

### When to Run

- before any deployment
- after cluster changes
- when troubleshooting resource issues
- to check current costs

## Phase 2: Prerequisites

### Purpose

Validate all requirements before attempting deployment.

### Command

```bash
make prereqs
```

### What It Checks

**Required Tools:**
- kubectl (Kubernetes CLI)
- helm (Kubernetes package manager)
- oci (Oracle Cloud CLI)
- jq (JSON processor)
- bc (Calculator for cost math)

**Configuration:**
- OCI CLI configured (~/.oci/config)
- kubectl connected to cluster
- OCI_COMPARTMENT_ID set
- NGC_API_KEY set and valid format

**Cluster Requirements:**
- GPU nodes available
- NVIDIA device plugin installed
- Device plugin pods ready

**Optional:**
- GPU quota available
- Helm repositories configured

### Expected Output

```
[NIM-OKE][INFO] Checking prerequisites...

=== Required Tools ===
[NIM-OKE][SUCCESS] kubectl: installed (v1.28.2)
[NIM-OKE][SUCCESS] helm: installed (v3.12.0)
[NIM-OKE][SUCCESS] oci: installed (3.30.0)
[NIM-OKE][SUCCESS] jq: installed (1.6)
[NIM-OKE][SUCCESS] bc: installed (1.07.1)

=== Configuration ===
[NIM-OKE][SUCCESS] OCI CLI: configured and authenticated
[NIM-OKE][SUCCESS] kubectl: connected to cluster (context: oke-cluster)
[NIM-OKE][SUCCESS] OCI_COMPARTMENT_ID: set
[NIM-OKE][SUCCESS] NGC_API_KEY: set (nvapi-xxx...)

=== Cluster Requirements ===
[NIM-OKE][SUCCESS] GPU nodes available: 1
[NIM-OKE][SUCCESS] NVIDIA device plugin: installed and ready (1/1)

[NIM-OKE][SUCCESS] All critical prerequisites met
```

### Failure Handling

If prerequisites fail:

```bash
[NIM-OKE][ERROR] Prerequisites check failed (3 critical checks failed)
[NIM-OKE][INFO] Fix the errors above and run again
```

Fix issues and re-run `make prereqs` until all checks pass.

## Phase 3: Deploy

### Purpose

Deploy NVIDIA NIM to OKE with cost guards and cleanup hooks.

### Command

```bash
NGC_API_KEY=nvapi-xxx make install
```

### Cost Guards

Before deployment, cost guard evaluates:

```bash
ENVIRONMENT=dev
COST_THRESHOLD_USD=5
Estimated cost: $12 for 5 hours

# If cost > threshold OR environment == production:
[NIM-OKE][WARN] Cost guard triggered for: NIM deployment
[NIM-OKE][WARN] Estimated cost: $12.00
[NIM-OKE][WARN] Environment: dev
[NIM-OKE][ERROR] Cost exceeds threshold ($5)
[NIM-OKE][INFO] To proceed: export CONFIRM_COST=yes
```

Bypass with:

```bash
CONFIRM_COST=yes make install
```

### What It Does

1. **Runs prerequisites check**
2. **Estimates and guards cost**
3. **Validates NGC credentials**
4. **Checks GPU availability**
5. **Creates namespace** (if needed)
6. **Generates values** with NGC key
7. **Deploys via Helm** (install or upgrade)
8. **Waits for pods** to be ready (timeout: 1200s)
9. **Checks service** and external IP
10. **Saves endpoint** to .nim-endpoint file

### Cleanup on Failure

If any step fails, automatic cleanup:

```bash
trap cleanup_on_failure EXIT ERR INT TERM

cleanup_on_failure() {
    [NIM-OKE][WARN] Deployment failed, running cleanup...
    # Uninstall Helm release
    # Delete PVCs (unless KEEP_CACHE=yes)
    # Display session cost
}
```

### Expected Output

```
[NIM-OKE][INFO] Starting NIM deployment...
[NIM-OKE][INFO] Running prerequisites check...
[NIM-OKE][SUCCESS] All critical prerequisites met
[NIM-OKE][INFO] Estimating deployment cost...
[NIM-OKE][INFO] Estimated cost for 5-hour deployment: $12.00
[NIM-OKE][INFO] Cost confirmed, proceeding...
[NIM-OKE][INFO] Deploying NIM with Helm...
[NIM-OKE][INFO] Waiting for pods to be ready...
[NIM-OKE][SUCCESS] Pods are ready
[NIM-OKE][INFO] Checking service...
[NIM-OKE][SUCCESS] External IP assigned: xxx.xxx.xxx.xxx
[NIM-OKE][SUCCESS] Deployment complete!
[NIM-OKE][INFO] Run 'make verify' to check health
```

### Idempotency

Running `make install` multiple times:
- First run: Creates resources
- Subsequent runs: Upgrades existing deployment
- No errors or duplicate resources

## Phase 4: Verify

### Purpose

Comprehensive health check of NIM deployment.

### Command

```bash
make verify
```

### Verification Checks

**Critical (must pass):**
1. Deployment exists
2. Pods running
3. Pods ready
4. GPU allocated
5. Service exists

**Optional (warnings OK):**
6. Service endpoint available
7. PVC bound
8. API health responding
9. Model loaded

### Expected Output

```
[NIM-OKE][INFO] Verifying NIM deployment...

=== Deployment Verification ===
[NIM-OKE][SUCCESS] Deployment exists
[NIM-OKE][SUCCESS] Pods running: 1
[NIM-OKE][SUCCESS] Pods ready: 1
[NIM-OKE][SUCCESS] GPUs allocated: 1

=== Service Verification ===
[NIM-OKE][SUCCESS] Service exists (type: LoadBalancer)
[NIM-OKE][SUCCESS] External endpoint: http://xxx.xxx.xxx.xxx:8000

=== Storage Verification ===
[NIM-OKE][SUCCESS] PVCs bound: 1

=== API Verification ===
[NIM-OKE][SUCCESS] API health check: PASSED
[NIM-OKE][WARN] Model still loading (this can take 30-45 minutes)

[NIM-OKE][SUCCESS] Critical checks passed (2 warnings)
[NIM-OKE][WARN] Some optional checks failed (service may still be initializing)

Next steps:
  - Test inference: make test-inference
  - View operations: make operate
```

### Failure Scenarios

If critical checks fail:

```
[NIM-OKE][ERROR] Verification failed (2 critical checks failed)

[NIM-OKE][INFO] Troubleshoot with: make troubleshoot
```

Run diagnostics to identify root cause.

## Phase 5: Operate

### Purpose

Display operational commands and current system state.

### Command

```bash
make operate
```

### Output

Provides ready-to-copy commands for:

- **Quick Status** - Current deployment state
- **View Pods** - Pod listing and details
- **View Logs** - Log retrieval commands
- **Describe Resources** - Detailed resource inspection
- **GPU Usage** - nvidia-smi in containers
- **Port Forwarding** - Local access setup
- **API Testing** - curl commands for inference
- **Resource Usage** - CPU/memory/GPU metrics
- **Helm Operations** - Upgrade, rollback, values
- **Scaling** - Replica management
- **Events** - Recent cluster events
- **Cost Monitoring** - Current hourly/daily costs

### Example Commands

```bash
# View logs
kubectl logs -n default -l app.kubernetes.io/name=nvidia-nim --tail=100

# Test API
curl http://xxx.xxx.xxx.xxx:8000/v1/health/ready

# Check GPU usage
kubectl exec -n default -it <pod-name> -- nvidia-smi

# Scale deployment
kubectl scale deployment nvidia-nim -n default --replicas=2
```

## Phase 6: Troubleshoot

### Purpose

Systematic diagnostics when things go wrong.

### Command

```bash
make troubleshoot
```

### Diagnostic Steps

1. **Pod Status** - Check pod phase and events
2. **GPU Resources** - Verify GPU nodes and device plugin
3. **Image Pull** - Check for ImagePullBackOff errors
4. **Service** - LoadBalancer and endpoint status
5. **Storage** - PVC binding status
6. **Resource Allocation** - CPU/memory/GPU requests
7. **Network** - DNS resolution and connectivity
8. **Recent Events** - Last 20 cluster events

### Common Issues Detected

**No GPU nodes:**
```
[NIM-OKE][ERROR] No GPU nodes found in cluster
[NIM-OKE][INFO] Check node labels: kubectl get nodes --show-labels
```

**Device plugin not installed:**
```
[NIM-OKE][ERROR] NVIDIA device plugin not installed
[NIM-OKE][INFO] Install: kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml
```

**Image pull errors:**
```
[NIM-OKE][ERROR] Pod nvidia-nim-xxx has image pull issues
[NIM-OKE][INFO] Check NGC credentials:
```

**LoadBalancer pending:**
```
[NIM-OKE][WARN] LoadBalancer IP not assigned yet
[NIM-OKE][INFO] Check LoadBalancer events:
```

## Phase 7: Cleanup

### Purpose

Remove NIM deployment and stop billable resources.

### Command

```bash
make cleanup
```

### What It Removes

1. Helm release (nvidia-nim)
2. Kubernetes resources (deployments, pods, services)
3. Secrets (NGC credentials)
4. ConfigMaps
5. Service accounts
6. PVCs (unless KEEP_CACHE=yes)

### Cleanup Options

```bash
# Standard cleanup
make cleanup

# Keep model cache (faster re-deployment)
KEEP_CACHE=yes make cleanup

# Force cleanup without confirmation
FORCE=yes make cleanup

# Cleanup + full cluster teardown
make cleanup-cluster
```

### Verification

After cleanup:

```
[NIM-OKE][INFO] Verifying cleanup...
[NIM-OKE][SUCCESS] Cleanup complete - no NIM resources remain

[NIM-OKE][INFO] Session duration: 4.50 hours
[NIM-OKE][INFO] Estimated cost: $8.33

[NIM-OKE][SUCCESS] NIM cleanup complete
```

### Idempotency

Running `make cleanup` when already clean:

```bash
make cleanup
# → No errors, just reports "already clean"
```

## Cost Guard Examples

### Scenario 1: Dev Deployment Under Threshold

```bash
$ make install
[NIM-OKE][INFO] Estimated cost for 5-hour deployment: $4.50
# Proceeds without prompt (under $5 threshold)
```

### Scenario 2: Dev Deployment Over Threshold

```bash
$ make install
[NIM-OKE][WARN] Cost guard triggered
[NIM-OKE][ERROR] Cost exceeds threshold ($5)
[NIM-OKE][INFO] To proceed: export CONFIRM_COST=yes

$ CONFIRM_COST=yes make install
[NIM-OKE][INFO] Cost confirmed, proceeding...
# Deployment continues
```

### Scenario 3: Production Environment

```bash
$ ENVIRONMENT=production make install
[NIM-OKE][WARN] Cost guard triggered (production environment)
[NIM-OKE][ERROR] Cost exceeds threshold
[NIM-OKE][INFO] To proceed: export CONFIRM_COST=yes

$ ENVIRONMENT=production CONFIRM_COST=yes make install
# Deployment proceeds with extra confirmation
```

### Scenario 4: Custom Threshold

```bash
$ COST_THRESHOLD_USD=20 make install
# Higher threshold, deployment proceeds if under $20
```

## Idempotency Patterns

### Deploy Script

First run:
```bash
make install
→ Creates namespace
→ Installs Helm release
→ Creates PVCs
→ Pods start
```

Second run:
```bash
make install
→ Namespace exists (skipped)
→ Upgrades Helm release
→ PVCs exist (reused)
→ Pods rolling update
```

### Cleanup Script

First run:
```bash
make cleanup
→ Uninstalls Helm release
→ Deletes resources
→ Removes PVCs
```

Second run:
```bash
make cleanup
→ Helm release not found (no-op)
→ Resources already gone (no-op)
→ Reports "already clean"
```

## Cleanup Hook Behavior

### Successful Deployment

```bash
make install
→ trap set for cleanup_on_failure
→ All steps succeed
→ trap disabled
→ Resources remain
```

### Failed Deployment

```bash
make install
→ trap set for cleanup_on_failure
→ Step 5 fails (pod timeout)
→ trap triggered
→ cleanup_on_failure runs
→ Helm release uninstalled
→ PVCs deleted
→ Exit with error
```

Resources cleaned automatically, no manual intervention needed.

## Structured Logging

### Log Levels

```bash
[NIM-OKE][INFO]     # Informational messages
[NIM-OKE][WARN]     # Warnings (non-fatal)
[NIM-OKE][ERROR]    # Errors (fatal)
[NIM-OKE][SUCCESS]  # Success confirmations
```

### Example Log Flow

```
[NIM-OKE][INFO] Starting NIM deployment...
[NIM-OKE][INFO] Running prerequisites check...
[NIM-OKE][SUCCESS] All critical prerequisites met
[NIM-OKE][INFO] Estimating deployment cost...
[NIM-OKE][WARN] Cost guard triggered for: NIM deployment
[NIM-OKE][INFO] Cost confirmed, proceeding...
[NIM-OKE][INFO] Deploying NIM with Helm...
[NIM-OKE][SUCCESS] Deployment complete!
```

All logs go to stderr, allowing for:

```bash
make install 2>&1 | tee deployment.log  # Capture all output
make install 2>/dev/null                # Suppress logs
```

## Session Cost Tracking

### How It Works

1. **deploy.sh** saves timestamp on successful deployment:
   ```bash
   date +%s > .nim-deployed-at
   ```

2. **cleanup-nim.sh** calculates session cost:
   ```bash
   deploy_time=$(cat .nim-deployed-at)
   current_time=$(date +%s)
   elapsed_hours=$(( (current_time - deploy_time) / 3600 ))
   cost=$(echo "$elapsed_hours * $hourly_cost" | bc)
   
   [NIM-OKE][INFO] Session duration: 4.50 hours
   [NIM-OKE][INFO] Estimated cost: $8.33
   ```

3. Timestamp removed after cost display

### Manual Cost Check

```bash
make operate  # Shows current hourly/daily cost
make discover # Shows projected costs
```

## Troubleshooting Decision Tree

### Issue: Deployment Fails

```
make install fails
    │
    ├─→ Prerequisites fail?
    │   └─→ make prereqs (fix missing tools/config)
    │
    ├─→ Cost guard blocks?
    │   └─→ CONFIRM_COST=yes make install
    │
    ├─→ Helm fails?
    │   └─→ make troubleshoot (check chart syntax)
    │
    └─→ Pods not ready?
        └─→ make troubleshoot (check GPU, image pull, resources)
```

### Issue: Verification Fails

```
make verify fails
    │
    ├─→ Pods not running?
    │   └─→ make logs (check for errors)
    │
    ├─→ GPU not allocated?
    │   └─→ make troubleshoot (check GPU nodes and device plugin)
    │
    ├─→ Service no external IP?
    │   └─→ Wait 5 minutes (LoadBalancer provisioning)
    │
    └─→ API not healthy?
        └─→ Check logs (model may still be loading)
```

### Issue: Inference Slow/Fails

```
API slow or failing
    │
    ├─→ Model still loading?
    │   └─→ make logs (check for "model loaded")
    │
    ├─→ Out of memory?
    │   └─→ kubectl top pods (check resource usage)
    │
    ├─→ GPU not utilized?
    │   └─→ kubectl exec nvidia-smi (verify GPU is active)
    │
    └─→ Network issues?
        └─→ make troubleshoot (check service and endpoints)
```

## Complete Workflow Example

### Scenario: First-Time Smoke Test

```bash
# 1. Set credentials
export NGC_API_KEY=nvapi-xxxxxxxxxxxxxxx
export OCI_COMPARTMENT_ID=ocid1.compartment.oc1...
export OCI_REGION=us-phoenix-1

# 2. Discover current state
make discover
# Output: Cluster ready, 1 GPU node, cost: $1.85/hr

# 3. Check prerequisites
make prereqs
# Output: All checks passed

# 4. Deploy NIM
CONFIRM_COST=yes make install
# Output: Deployment complete after ~10 minutes

# 5. Verify health
make verify
# Output: All critical checks passed, model loading

# 6. Wait for model (30-45 min), then verify again
sleep 1800  # Wait 30 minutes
make verify
# Output: All checks passed, API healthy

# 7. Test inference
make operate
# Copy curl commands and test API

# 8. Cleanup
make cleanup
# Output: Cleanup complete, session cost: $8.33
```

Total time: ~5 hours including model download
Total cost: ~$9-12

### Scenario: Re-deployment with Cached Model

```bash
# First deployment
make install
# ... wait for complete deployment ...
KEEP_CACHE=yes make cleanup  # Preserve PVC

# Second deployment (faster)
make install
# Model already cached in PVC
# Deployment ready in ~5 minutes instead of 45
```

Cost savings: ~$1.50 per re-deployment (no model download time)

## Advanced Operations

### Multi-Environment Setup

```bash
# Dev environment
ENVIRONMENT=dev make install

# Staging (if cluster supports)
ENVIRONMENT=staging CONFIRM_COST=yes make install

# Production (requires explicit confirmation)
ENVIRONMENT=production CONFIRM_COST=yes make install
```

### Custom Resource Allocation

Edit `helm/values.yaml`:

```yaml
resources:
  limits:
    nvidia.com/gpu: 2  # Use 2 GPUs
    memory: 64Gi
    cpu: 16
  requests:
    nvidia.com/gpu: 2
    memory: 48Gi
    cpu: 8
```

Then upgrade:

```bash
make install  # Helm upgrade with new values
```

### Debugging Failed Deployments

```bash
# 1. Check what happened
make status

# 2. View recent logs
make logs

# 3. Full diagnostics
make troubleshoot

# 4. Describe specific pod
kubectl describe pod <pod-name> -n default

# 5. Get events
kubectl get events -n default --sort-by='.lastTimestamp'

# 6. Check Helm status
helm list -n default
helm status nvidia-nim -n default
```

### Manual Helm Operations

```bash
# Get current values
helm get values nvidia-nim -n default

# Get all resources
helm get manifest nvidia-nim -n default

# Rollback to previous version
helm rollback nvidia-nim -n default

# Upgrade with custom values
helm upgrade nvidia-nim ./helm -n default -f custom-values.yaml
```

## Cost Optimization Strategies

### 1. Time-Boxed Testing

```bash
# Set a timer
sleep 18000 && make cleanup &  # Cleanup after 5 hours

# Run tests
make install
# ... perform smoke tests ...
# Automatic cleanup after 5 hours
```

### 2. Model Cache Preservation

```bash
# First deployment
make install
# ... complete testing ...
KEEP_CACHE=yes make cleanup

# Subsequent deployments (faster)
make install  # Model loads from cache in ~5 minutes
```

### 3. Cost Monitoring

```bash
# Check costs frequently
make operate  # Shows current hourly rate

# Set budget alerts in OCI Console
# Governance → Cost Management → Budgets
```

### 4. Scheduled Cleanup

```bash
# Add to crontab for automatic cleanup
0 23 * * * cd /path/to/nimble-oke && FORCE=yes make cleanup
```

## Reference: Makefile Targets

| Target | Description | Prerequisites |
|--------|-------------|---------------|
| `help` | Show all targets | None |
| `discover` | Discover cluster state | kubectl configured |
| `prereqs` | Validate prerequisites | Tools installed |
| `install` | Deploy NIM | prereqs pass |
| `verify` | Verify deployment | install complete |
| `operate` | Show operations | deployment exists |
| `troubleshoot` | Run diagnostics | kubectl configured |
| `cleanup` | Remove NIM | None (idempotent) |
| `all` | Complete workflow | prereqs pass |
| `status` | Quick status | kubectl configured |
| `logs` | View logs | deployment exists |
| `validate` | prereqs + verify | Both must pass |

## Reference: Environment Variables

| Variable | Values | Default | Purpose |
|----------|--------|---------|---------|
| `NGC_API_KEY` | nvapi-... | (required) | NVIDIA NGC credentials |
| `OCI_COMPARTMENT_ID` | ocid1... | (required) | OCI compartment |
| `ENVIRONMENT` | dev, production | dev | Triggers cost guards |
| `CONFIRM_COST` | yes, no | no | Bypass cost guard |
| `COST_THRESHOLD_USD` | number | 5 | Cost guard threshold |
| `KEEP_CACHE` | yes, no | no | Preserve PVCs in cleanup |
| `FORCE` | yes, no | no | Skip confirmations |

## Best Practices

### Before Deployment

1. Run `make discover` to understand current state
2. Run `make prereqs` to validate readiness
3. Estimate costs and set `CONFIRM_COST` if needed
4. Have cleanup plan ready

### During Operations

1. Monitor costs with `make operate`
2. Check logs regularly with `make logs`
3. Verify health periodically with `make verify`
4. Keep session time-boxed

### After Testing

1. **Always run `make cleanup`**
2. Verify cleanup completed successfully
3. Check OCI console for no remaining resources
4. Review session cost in cleanup output

### Production Deployments

1. Set `ENVIRONMENT=production`
2. Always use `CONFIRM_COST=yes` explicitly
3. Document deployment in change log
4. Have rollback plan ready
5. Monitor for at least 30 minutes post-deployment

## Troubleshooting Reference

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| Cost guard blocks | Cost > $5 or prod env | `CONFIRM_COST=yes make install` |
| No GPU nodes | Cluster not provisioned | Provision OKE with GPU nodes first |
| ImagePullBackOff | Invalid NGC key | Check NGC_API_KEY is correct |
| Pods pending | Insufficient GPU | Check node capacity with `make discover` |
| Model loading slow | Normal behavior | Wait 30-45 min for 15GB download |
| LoadBalancer pending | OCI provisioning | Wait 2-5 minutes |
| API 503 errors | Model not ready | Check logs for "model loaded" |
| Out of memory | Insufficient resources | Increase node size or reduce limits |

## Getting Help

- **Run diagnostics:** `make troubleshoot`
- **Check logs:** `make logs`
- **View operations:** `make operate`
- **NVIDIA NIM Docs:** https://docs.nvidia.com/nim/
- **OCI Support:** https://cloud.oracle.com/support

---

**This runbook provides everything needed for rapid, cost-effective smoke testing of NVIDIA NIM on OCI OKE.**

