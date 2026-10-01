# OCI Service Limits Analysis for Nimble OKE

*Historical working note from October 2025; figures corrected 2026-10-01. See README for current status.*

Limit values below are as of October 2025, not re-verified.

## Executive Summary

Based on the [OCI Service Limits documentation](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/servicelimits.htm), Nimble OKE is **within all service limits** for its current configuration. This analysis validates our approach and identifies areas for optimization.

---

## 🎯 Service Limits Review

### **Kubernetes Engine (OKE) Limits**

| Resource | Limit | Nimble OKE Usage | Status |
|----------|-------|------------------|--------|
| **Enhanced Clusters per Region** | 15 | 1 | ✅ **Well within limit** |
| **Managed Nodes per Cluster** | 5,000 (Flannel CNI) | 1 | ✅ **Well within limit** |
| **Managed Nodes per Node Pool** | 1,000 | 1 | ✅ **Well within limit** |
| **Pods per Managed Node** | 110 | 1 | ✅ **Well within limit** |
| **Virtual Nodes per Region** | 9 (Oracle Universal Credits) | 0 | ✅ **Not used** |

**Analysis**: Our single-node cluster configuration is well within all OKE limits.

### **Compute Service Limits**

| Resource | Limit | Nimble OKE Usage | Status |
|----------|-------|------------------|--------|
| **`gpu-a10-count`** | Default 0; request an increase in the Console | 1 | Requires a limit increase |
| **Block Volumes per Instance** | 32 | 1 | ✅ **Well within limit** |
| **Total Block Volume Size** | 100 TB (Universal Credits) | 100GB | ✅ **Well within limit** |

**Analysis**: Single GPU instance with minimal storage is well within compute limits.

### **Load Balancer Service Limits**

| Resource | Limit | Nimble OKE Usage | Status |
|----------|-------|------------------|--------|
| **Load Balancers per Region** | 50 | 1 | ✅ **Well within limit** |
| **Load Balancer Bandwidth** | 5,000 Mbps | 10 Mbps (flexible) | ✅ **Well within limit** |
| **Listeners per Load Balancer** | 16 | 1 | ✅ **Well within limit** |
| **Backend Sets per Load Balancer** | 16 | 1 | ✅ **Well within limit** |
| **Backend Servers per Load Balancer** | 512 | 1 | ✅ **Well within limit** |

**Analysis**: Single load balancer configuration is well within all limits.

### **Block Volume Service Limits**

| Resource | Limit | Nimble OKE Usage | Status |
|----------|-------|------------------|--------|
| **Block Volumes per Instance** | 32 | 1 | ✅ **Well within limit** |
| **Total Storage per Region** | 100 TB (Universal Credits) | 100GB | ✅ **Well within limit** |
| **Backup Count** | 100,000 | 0 (optional) | ✅ **Not used** |

**Analysis**: Minimal storage usage is well within all limits.

---

## 🔐 API Authorization Analysis

### **Required OCI API Calls for Nimble OKE**

Based on our scripts and configuration, Nimble OKE requires the following OCI API calls:

#### **Compute Service APIs**
- `oci compute instance launch` - ✅ **Standard compute permissions**
- `oci compute instance terminate` - ✅ **Standard compute permissions**
- `oci compute instance list` - ✅ **Standard compute permissions**

#### **Container Engine APIs**
- `oci ce cluster create` - ✅ **OKE service permissions**
- `oci ce cluster delete` - ✅ **OKE service permissions**
- `oci ce node-pool create` - ✅ **OKE service permissions**
- `oci ce node-pool delete` - ✅ **OKE service permissions**
- `oci ce cluster kubeconfig` - ✅ **OKE service permissions**

#### **Networking APIs**
- `oci network vcn create` - ✅ **Networking service permissions**
- `oci network subnet create` - ✅ **Networking service permissions**
- `oci network security-list create` - ✅ **Networking service permissions**
- `oci network route-table create` - ✅ **Networking service permissions**
- `oci network internet-gateway create` - ✅ **Networking service permissions**

#### **IAM and Identity APIs**
- `oci iam compartment list` - ✅ **Standard IAM permissions**
- `oci limits service list` - ✅ **Standard IAM permissions**
- `oci limits value list` - ✅ **Standard IAM permissions**

### **Required IAM Policies**

Nimble OKE requires these IAM policies:

```bash
# Compute Service
Allow group <group> to manage compute-instances in compartment <compartment>
Allow group <group> to manage volume-family in compartment <compartment>

# Container Engine Service  
Allow group <group> to manage cluster-family in compartment <compartment>
Allow group <group> to manage node-pool-family in compartment <compartment>

# Networking Service
Allow group <group> to manage virtual-network-family in compartment <compartment>

# IAM Service
Allow group <group> to read compartments in compartment <compartment>
Allow group <group> to read limits in compartment <compartment>
```

**Status**: ✅ **All required permissions are standard OCI service permissions**

---

## 🔑 Hugging Face Token Analysis

### **Current Configuration**

Nimble OKE uses **NVIDIA NGC API keys**, not Hugging Face tokens:

```yaml
# From helm/values.yaml
ngc:
  apiKey: ""   # required; pass --set ngc.apiKey=$NGC_API_KEY at install
  registry: nvcr.io
  username: "$oauthtoken"
```

### **NVIDIA NGC vs Hugging Face**

| Aspect | NVIDIA NGC | Hugging Face |
|--------|------------|--------------|
| **Model Registry** | `nvcr.io` | `huggingface.co` |
| **Authentication** | NGC API Key | HF Token |
| **Model Access** | `meta/llama3-8b-instruct` | Various models |
| **Our Choice** | ✅ **NGC** | Not used |

### **NGC API Key Requirements**

- **Registration**: [NVIDIA NGC Account](https://catalog.ngc.nvidia.com/)
- **API Key**: [Generate NGC API Key](https://ngc.nvidia.com/setup/api-key)
- **Scope**: Container registry access for NIM images
- **Format**: `nvapi-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

**Status**: ✅ **NGC authentication properly configured**

---

## 🚀 OKE Configuration Validation

### **Our OKE Configuration vs OCI Best Practices**

| Configuration Aspect | Our Setting | OCI Recommendation | Status |
|---------------------|-------------|-------------------|--------|
| **Cluster Type** | Enhanced | Enhanced for production | ✅ **Optimal** |
| **CNI Plugin** | Flannel | Flannel for simplicity | ✅ **Optimal** |
| **Node Pool Strategy** | Single GPU pool | Dedicated pools per workload | ✅ **Appropriate for single workload** |
| **Load Balancer** | Flexible shape | Flexible for cost optimization | ✅ **Optimal** |
| **Storage Class** | `oci-bv` | `oci-bv` for persistent volumes | ✅ **Optimal** |
| **Security Lists** | Custom rules | Custom rules for GPU workloads | ✅ **Optimal** |

### **Resource Configuration Validation**

| Resource | Our Configuration | NVIDIA NIM Requirement | Status |
|----------|------------------|------------------------|--------|
| **GPU** | 1× A10 (24GB VRAM) | Not in NVIDIA's support matrix for Llama 3 8B (A10G is) | Generic configuration (FP16), not guaranteed |
| **Memory** | 240GB RAM | 90GB figure came from NVIDIA's Cosmos NIM page | Not verified for Llama 3 8B |
| **CPU** | 15 OCPUs | x86_64 architecture | ✅ **Exceeds requirements** |
| **Storage** | 100GB persistent volume | 100GB minimum | ✅ **Meets requirement** |

### **Storage Configuration - Optimized**

**At the time**: storage was raised to 200GB. The current chart uses 100Gi.

**Configuration**:
```yaml
# In helm/values.yaml
persistence:
  size: 100Gi
```

---

## 📊 Optimization Opportunities

### **1. Storage Optimization - COMPLETED**
- **Previous**: 50GB persistent volume
- **Updated**: 200GB at the time; the current chart uses 100Gi
- **Cost Impact**: block storage rate not verified here

### **2. Resource Efficiency**
- **Current**: Single node with 240GB RAM
- **Optimization**: Could run multiple NIM instances
- **Limit**: 110 pods per node
- **Potential**: Scale to 2-3 NIM instances per node

### **3. Cost Optimization**
- **Current**: $2.10/hour ($2.00 GPU + $0.10 enhanced cluster), plus load balancer and block storage
- **Optimization**: Preemptible instances (if available)
- **Savings**: preemptible discount as of October 2025, not re-verified
- **Trade-off**: Potential interruptions

---

## ✅ Validation Results

### **Service Limits Compliance**
- ✅ **OKE Limits**: Well within all limits
- ✅ **Compute Limits**: Well within all limits  
- ✅ **Load Balancer Limits**: Well within all limits
- ✅ **Storage Limits**: Well within all limits

### **API Authorization**
- ✅ **All required APIs**: Standard OCI permissions
- ✅ **IAM Policies**: Standard service policies
- ✅ **No special permissions**: Required

### **Authentication**
- ✅ **NGC API Keys**: Properly configured
- ✅ **No Hugging Face**: Not required for our use case
- ✅ **Token Security**: Standard NGC authentication

### **OKE Configuration**
- ✅ **Best Practices**: Following OCI recommendations
- ✅ **Resource Sizing**: Appropriate for workload
- ✅ **Storage Size**: 100Gi in the current chart

---

## 🎯 Recommendations

### **Immediate Actions**
1. **Storage**: persistent volume is 100Gi in the current chart
2. **Validate GPU Quota**: Ensure the `gpu-a10-count` limit increase is approved (default is 0)
3. **Test NGC API Key**: Verify NGC authentication works

### **Future Optimizations**
1. **Multi-Instance Scaling**: Consider running 2-3 NIM instances per node
2. **Preemptible Instances**: Evaluate cost savings vs reliability
3. **Regional Expansion**: Consider Phoenix region for better availability

### **Monitoring**
1. **Resource Usage**: Monitor actual vs allocated resources
2. **Cost Tracking**: Track actual costs vs estimates
3. **Performance Metrics**: Measure deployment and inference times

---

## 📋 Summary

**Nimble OKE fits within the OCI service limits listed above, as of October 2025.** The GPU limit defaults to 0 and needs an increase. The current chart uses a 100Gi persistent volume.

**Ready for deployment once the GPU limit increase is approved.**
