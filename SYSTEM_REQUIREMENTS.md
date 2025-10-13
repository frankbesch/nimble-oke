# System Requirements - NVIDIA NIM on OCI OKE

**Version:** v0.1.0-20251013-dev  
**Last Updated:** October 13, 2025  
**Pricing Source:** [Oracle IaaS and PaaS Services Highlights](https://www.oracle.com/cloud/iaas-paas/) (December 2024)

## Executive Summary

The **VM.GPU.A10.1** OCI shape **exceeds all NVIDIA NIM requirements** for deploying Llama 3.1 8B Instruct:
- **240GB RAM** (2.6× NVIDIA's 90GB recommendation)
- **24GB GPU VRAM** (meets A10 minimum for 8B models)
- **15 OCPUs** (exceeds compute requirements)
- **$2.62/hour** (cost-effective for testing and development)

## NVIDIA NIM Official Requirements

Based on [NVIDIA NIM Documentation](https://docs.nvidia.com/nim/cosmos/latest/prerequisites.html).

### Hardware Requirements

| Component | Minimum | Recommended | Notes |
|-----------|---------|-------------|-------|
| **GPU** | NVIDIA A10 (Ampere) | A100 (Ampere/Hopper) | 24GB VRAM minimum for Llama 3.1 8B |
| **GPU Memory** | 24GB VRAM | 40GB+ VRAM | Larger models require more VRAM |
| **CPU** | x86_64 architecture | x86_64 | ARM not supported |
| **System Memory** | 40GB RAM | **90GB+ RAM** | **Critical: NVIDIA official recommendation** |
| **Disk Space** | 100GB | 200GB+ | Model cache (50-100GB) + containers |

### Software Requirements

| Component | Minimum Version | Recommended | Auto-Provisioned by OKE |
|-----------|----------------|-------------|-------------------------|
| **OS** | Linux with glibc 2.35+ | Oracle Linux 8 | ✅ Yes |
| **GPU Driver** | NVIDIA 535+ | Latest stable | ✅ Yes |
| **NVIDIA Container Toolkit** | 1.16.2+ | Latest | ✅ Yes |
| **Docker/containerd** | 23.0.1+ | Latest | ✅ Yes (containerd) |
| **Kubernetes** | 1.28+ | 1.28+ | ✅ Yes (OKE managed) |

## OCI VM.GPU.A10.1 Shape Specifications

### Resource Allocation

| Resource | Specification | NVIDIA Requirement | Compliance |
|----------|---------------|-------------------|------------|
| **GPU** | 1× NVIDIA A10 (Ampere) | A10 minimum | ✅ **Meets** |
| **GPU Memory** | 24GB GDDR6 VRAM | 24GB minimum | ✅ **Meets** |
| **vCPUs (OCPUs)** | 15 cores | 8+ cores recommended | ✅ **Exceeds (1.9×)** |
| **System Memory** | **240GB RAM** | 90GB recommended | ✅ **Exceeds (2.6×)** |
| **Memory per vCPU** | 16GB per OCPU | N/A | ✅ Excellent ratio |
| **Network Bandwidth** | 24.6 Gbps | 10Gbps+ recommended | ✅ **Exceeds** |
| **Block Storage** | 100GB+ configurable | 100GB minimum | ✅ **Configurable** |
| **Local NVMe** | Not included | Optional | ⚠️ Use block storage |
| **Architecture** | x86_64 (AMD EPYC) | x86_64 required | ✅ **Compatible** |

### Cost Structure

> **Note:** All prices are as of December 2024 and are subject to change. Volume discounts may be applicable for Oracle Universal Credits subscriptions. Please contact an Oracle sales representative for an official quote.

| Component | Rate | 5-Hour Test | 24/7 Month | Notes |
|-----------|------|-------------|------------|-------|
| **GPU Compute** | $2.62/hour | $13.10 | $1,890 | Primary cost |
| **OKE Cluster** | $0.10/hour | $0.50 | $72 | Managed K8s |
| **Block Storage (200GB)** | $0.03/GB/month | ~$0.25 | $5 | Model cache |
| **Load Balancer** | ~$1.25/hour | $6.25 | $900 | External access |
| **Network Egress** | Variable | Minimal | Variable | Model downloads |
| **Total** | **~$4.02/hr** | **~$20.10** | **~$2,885** | **Time-box for testing!** |

### GPU Specifications (NVIDIA A10)

| Specification | Value | Use Case Suitability |
|---------------|-------|---------------------|
| **Architecture** | NVIDIA Ampere | ✅ Latest supported by NIM |
| **CUDA Cores** | 9,216 | ✅ Sufficient for inference |
| **Tensor Cores** | 288 (3rd Gen) | ✅ Accelerated FP16/BF16 inference |
| **RT Cores** | 72 (2nd Gen) | N/A for NIM |
| **GPU Memory** | 24GB GDDR6 | ✅ Meets Llama 3.1 8B minimum |
| **Memory Bandwidth** | 600 GB/s | ✅ Fast inference |
| **TDP** | 150W | ✅ Efficient |
| **FP32 Performance** | 31.2 TFLOPS | ✅ Good baseline |
| **FP16/BF16 Performance** | 125 TFLOPS (with Tensor Cores) | ✅ **Excellent for NIM** |

## Model-Specific Requirements

### Meta Llama 3.1 8B Instruct

| Requirement | Specification | VM.GPU.A10.1 | Status |
|-------------|---------------|--------------|--------|
| **Model Size** | ~8 billion parameters | N/A | ✅ |
| **FP16 Model Size** | ~16GB | 24GB VRAM | ✅ Fits in VRAM |
| **Quantized (INT8)** | ~8GB | 24GB VRAM | ✅ Ample headroom |
| **Context Length** | 8,192 tokens (default) | Memory dependent | ✅ |
| **Batch Size** | 1-32 (configurable) | Memory dependent | ✅ |
| **System Memory** | 40GB minimum | 240GB available | ✅ **6× minimum** |

### Larger Models (Future)

| Model | Parameters | VRAM Required | VM.GPU.A10.1 | Alternative Shape |
|-------|------------|---------------|--------------|-------------------|
| Llama 3.1 8B | 8B | 24GB (FP16) | ✅ **Supported** | VM.GPU.A10.1 |
| Llama 3.1 70B | 70B | 140GB (FP16) | ❌ Insufficient VRAM | VM.GPU.A100.2 (80GB × 2) |
| Llama 3.1 405B | 405B | 810GB (FP16) | ❌ Insufficient VRAM | BM.GPU.A100-v2.8 (640GB) |

**Note:** For models >24GB VRAM, use VM.GPU.A100 shapes with 40GB or 80GB VRAM per GPU.

## Local Workstation Requirements

### Minimum Specifications

| Component | Minimum | Recommended | Purpose |
|-----------|---------|-------------|---------|
| **RAM** | 8GB | 16GB+ | OCI CLI, kubectl, Helm operations |
| **CPU** | 2 cores | 4+ cores | Concurrent tool operations |
| **Disk Space** | 10GB free | 20GB+ free | Container images, logs, configs |
| **Network** | Stable broadband | 50+ Mbps | OCI API calls, kubectl operations |
| **OS** | macOS 10.15+ / Linux | macOS 12+ / Ubuntu 22.04+ | Tested platforms |

### Required Tools

| Tool | Minimum Version | Recommended | Installation |
|------|----------------|-------------|--------------|
| **OCI CLI** | Latest | Latest | [Install Guide](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) |
| **kubectl** | 1.28+ | 1.30+ | [Install Guide](https://kubernetes.io/docs/tasks/tools/) |
| **Helm** | 3.12+ | 3.15+ | [Install Guide](https://helm.sh/docs/intro/install/) |
| **jq** | 1.6+ | Latest | `brew install jq` / `apt install jq` |
| **bc** | Any | Pre-installed | macOS/Linux built-in |
| **git** | 2.0+ | Latest | Version control |

## OCI Account Requirements

### Account Configuration

| Requirement | Specification | Notes |
|-------------|---------------|-------|
| **Account Type** | **Paid account required** | ❌ **Free tier NOT supported** |
| **Payment Method** | Credit card on file | Required for GPU quota |
| **Identity Verification** | Completed | May be required for GPU access |
| **Compartment** | OCID required | For resource organization |
| **IAM Policies** | Admin or custom | Permissions for OKE, compute, networking |

### GPU Quota Requirements

| Resource | Minimum Quota | Recommended | Request Method |
|----------|---------------|-------------|----------------|
| **VM.GPU.A10.1 count** | 1 GPU | 2-4 GPUs | OCI Console → Limits, Quotas and Usage |
| **GPUs for VM instances** | 1 GPU | 2-4 GPUs | Same request |
| **Cores for GPU shapes** | 15 OCPUs | 30-60 OCPUs | Auto-calculated with GPU quota |
| **Block Volume storage** | 100GB | 500GB+ | Usually sufficient by default |

**Processing Time:** GPU quota requests typically take 24-48 hours for approval.

### Cost Optimization Options

#### Oracle Universal Credits
- **Volume Discounts:** Available for Oracle Universal Credits subscriptions
- **Flexible Billing:** Pay-as-you-go or committed use discounts
- **Contact Sales:** For official quotes and enterprise pricing

#### Cost Management Tools
- **OCI Cost Estimator:** [https://www.oracle.com/cloud/cost-estimator/](https://www.oracle.com/cloud/cost-estimator/)
- **Budget Alerts:** Set up automated cost monitoring
- **Cost Analysis:** Detailed usage and billing reports

### Regional Availability

| Region | VM.GPU.A10.1 Available | Recommended | Notes |
|--------|----------------------|-------------|-------|
| **us-ashburn-1** | ✅ Yes | ✅ Recommended | Primary US region |
| **us-phoenix-1** | ✅ Yes | ✅ Recommended | Western US |
| **us-chicago-1** | ✅ Yes | ✅ Recommended | Central US |
| **ca-toronto-1** | ✅ Yes | ✅ Recommended | Canada |
| **eu-frankfurt-1** | ✅ Yes | ✅ Recommended | Europe |
| **uk-london-1** | ✅ Yes | ✅ Recommended | UK |
| **ap-tokyo-1** | ✅ Yes | ✅ Recommended | Asia Pacific |
| **ap-sydney-1** | ✅ Yes | ✅ Recommended | Australia |

**Check current availability:** [OCI GPU Regions](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm)

## NVIDIA NGC Requirements

### Account Setup

| Requirement | Specification | Cost | Notes |
|-------------|---------------|------|-------|
| **NGC Account** | Required | **Free** | [Register here](https://catalog.ngc.nvidia.com/) |
| **NGC API Key** | Required | **Free** | [Generate here](https://ngc.nvidia.com/setup/api-key) |
| **Model Access** | Llama 3.1 8B | **Free** | May require accepting terms |
| **Container Access** | NIM containers | **Free** | Requires NGC authentication |

### API Key Management

```bash
# Set NGC API key (starts with 'nvapi-')
export NGC_API_KEY="nvapi-xxxxxxxxxxxxxxxxxxxx"

# Validate NGC access
docker login nvcr.io
Username: $oauthtoken
Password: <paste-NGC-API-KEY>

# Test model access
curl -H "Authorization: Bearer $NGC_API_KEY" \
  https://api.ngc.nvidia.com/v2/models
```

## Deployment Validation Checklist

### Pre-Deployment

- [ ] **OCI Account:** Paid account with payment method
- [ ] **GPU Quota:** VM.GPU.A10.1 quota approved (1+ GPU)
- [ ] **Compartment:** OCID identified and accessible
- [ ] **Region:** Selected region with A10 availability
- [ ] **NGC Account:** Registered and API key generated
- [ ] **NGC Access:** Docker login to nvcr.io successful
- [ ] **OCI CLI:** Installed and configured (`oci iam region list`)
- [ ] **kubectl:** Installed (`kubectl version --client`)
- [ ] **Helm:** Installed (`helm version`)
- [ ] **Budget Alert:** $50 budget configured (recommended)

### Post-Deployment Validation

- [ ] **Node Memory:** 240GB RAM available (`kubectl describe node`)
- [ ] **GPU Allocation:** 1× A10 GPU allocated to pod
- [ ] **VRAM Usage:** <24GB VRAM used (check with nvidia-smi)
- [ ] **System Memory:** <40GB RAM used by NIM container
- [ ] **Disk Space:** <100GB used for model cache
- [ ] **Health Check:** NIM /v1/health/ready endpoint responding
- [ ] **Inference Test:** Successful completion request
- [ ] **Cost Tracking:** Session cost tracking enabled

## Troubleshooting

### Insufficient Memory Errors

**Symptom:** OOMKilled or out-of-memory errors

**Cause:** Container memory limits too low or node memory exhausted

**Solution:**
- Verify node has 240GB RAM: `kubectl describe node | grep -i memory`
- Check container limits in `helm/values.yaml`:
  ```yaml
  resources:
    limits:
      memory: "32Gi"  # Increase if needed
  ```
- The VM.GPU.A10.1 node provides 240GB, so this should not occur

### GPU VRAM Exhausted

**Symptom:** CUDA out of memory errors

**Cause:** Model + context exceeds 24GB VRAM

**Solution:**
- Reduce batch size
- Reduce context length
- Use quantized models (INT8: ~8GB vs FP16: ~16GB)
- For larger models, upgrade to VM.GPU.A100 shapes

### Storage Exhaustion

**Symptom:** Pod evicted due to disk pressure

**Cause:** Model cache + container images exceed 100GB

**Solution:**
- Increase block volume size in Helm chart:
  ```yaml
  persistence:
    size: 200Gi  # Increase from 50Gi
  ```
- Clean up old container images on nodes
- Use separate PVC for model cache

## References

### Official Documentation

- **NVIDIA NIM Prerequisites:** https://docs.nvidia.com/nim/cosmos/latest/prerequisites.html
- **NVIDIA NGC Catalog:** https://catalog.ngc.nvidia.com/
- **NVIDIA NGC Setup:** https://docs.nvidia.com/ngc/ngc-catalog-user-guide/
- **OCI GPU Compute Shapes:** https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm
- **OCI OKE Documentation:** https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm
- **OCI Service Limits:** https://docs.oracle.com/en-us/iaas/Content/General/Concepts/servicelimits.htm
- **Oracle IaaS and PaaS Services:** https://www.oracle.com/cloud/iaas-paas/
- **OCI Cost Estimator:** https://www.oracle.com/cloud/cost-estimator/

### Shape Specifications

- **VM.GPU.A10 Family:** [OCI Compute Shapes](https://docs.oracle.com/en-us/iaas/Content/Compute/References/computeshapes.htm#vm-gpu)
- **NVIDIA A10 Datasheet:** [NVIDIA Website](https://www.nvidia.com/en-us/data-center/products/a10-gpu/)

---

**✅ The VM.GPU.A10.1 shape meets and exceeds all NVIDIA NIM requirements for deploying Llama 3.1 8B Instruct.**

## OCI Deployment Models

Oracle Cloud Infrastructure offers multiple deployment models as referenced in the [Oracle IaaS and PaaS Services Highlights](https://www.oracle.com/cloud/iaas-paas/):

### 1. Oracle-Managed Services (OKE)
- **Fully Managed:** Oracle manages the Kubernetes control plane
- **Our Choice:** Nimble OKE uses this model for simplified operations
- **Benefits:** No infrastructure management, automatic updates, high availability

### 2. Customer-Managed Virtual Machines
- **Full Control:** Complete control over the compute environment
- **Use Case:** Custom configurations, specific security requirements
- **Trade-off:** More operational overhead

### 3. Oracle-Managed Serverless Instances
- **Serverless:** Pay-per-execution model
- **Use Case:** Event-driven workloads, batch processing
- **Limitation:** Not suitable for persistent NIM deployments

**Nimble OKE Strategy:** We use Oracle-managed OKE services combined with customer-managed VM.GPU.A10.1 instances for optimal balance of simplicity and control.

**Next Steps:** See [Setup Prerequisites](docs/setup-prerequisites.md) for detailed deployment instructions.

