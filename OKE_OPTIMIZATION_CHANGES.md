# OKE Optimization Changes - Critical Fixes Applied

*Historical working note from October 2025; figures corrected 2026-10-01. See README for current status.*

> **Correction (2026-10-01):** This note named a 4-GPU A10 VM shape. Oracle has no such shape. The 4×A10 shape is BM.GPU.A10.4 (bare metal, 64 OCPU, 1024 GB). The conclusion that VM.GPU.A10.1 cannot run NIM on OKE is not supported by any receipt and is withdrawn. The repo default is VM.GPU.A10.1 with 1 GPU per pod.

## Overview
This document details the critical fixes applied to resolve persistent node registration timeout issues in the NVIDIA NIM OKE deployment.

## Root Cause Analysis
After 4 failed deployment attempts with consistent 21-22 minute node registration timeouts, we identified the root cause:

1. **Image Compatibility Issue**: Generic GPU images not optimized for OKE
2. **Incorrect GPU Shape**: suspected at the time; not supported (see correction above)
3. **Missing OKE-Specific Configuration**: Manual KMS instead of OKE built-in
4. **Outdated Kubernetes Version**: v1.28.2 not compatible with current OKE

## Shape Hypothesis (Withdrawn)

The October 2025 note claimed a 4-GPU shape was the smallest that supports NIM on OKE. It named that shape as a VM shape, which does not exist. No receipt supports the claim. It is withdrawn.

## Critical Fixes Applied

### 1. GPU Shape (Reverted)
**At the time**: moved from `VM.GPU.A10.1` to a 4-GPU shape.
**Now**: `VM.GPU.A10.1` (1× A10 24 GB, 15 OCPU, 240 GB) is the repo default.

**Cost**: VM.GPU.A10.1 = $2.00/hour; BM.GPU.A10.4 = $8.00/hour (4 × $2.00 per GPU-hour).

### 2. OKE-Optimized Image (SHAPE-DEPENDENT)
**Before**: Generic GPU image - **INCOMPATIBLE WITH OKE**
**After**: `Oracle-Linux-8.10-Gen2-GPU-2025.08.31-0-OKE-1.34.1-1191`

**Image OCID**: `ocid1.image.oc1.phx.aaaaaaaa2gmabafvnqzelab5ujtlqksdkbgss5w72s3gvf4so34cdic3cwpa`

**Shape restriction (withdrawn)**: the note claimed this image works only on 4-GPU shapes. No receipt supports that claim.

**Rationale**:
- Pre-configured with OKE-specific drivers
- Optimized for Kubernetes GPU workloads
- Proper NVIDIA driver integration
- Recommended for GPU node pools on OKE

### 3. Kubernetes Version Update
**Before**: `v1.28.2`
**After**: `v1.34.1`

**Rationale**:
- Supported OKE version (OKE currently offers v1.34.x–v1.36.x)
- Better GPU device plugin compatibility
- Enhanced stability and performance

### 4. OKE KMS Integration
**Before**: Manual KMS configuration
**After**: OKE built-in KMS

**Changes**:
- Removed manual `--endpoint-config` parameter
- Added `--endpoint-subnet-id` and `--endpoint-public-ip-enabled`
- Uses OKE's native key management

### 5. Enhanced Node Pool Configuration
**Before**: Basic node pool creation
**After**: OKE-optimized configuration with:
- Proper placement configuration
- Availability domain specification
- 200GB boot volume (increased from 100GB)
- Extended timeout (1800 seconds)

## Files Modified

### 1. `scripts/provision-cluster.sh`
- Updated GPU shape (since reverted to VM.GPU.A10.1)
- Updated Kubernetes version to v1.34.1
- Added OKE-optimized image configuration
- Implemented proper placement configuration
- Added validation functions
- Updated cost estimation

### 2. `scripts/_lib.sh`
- Updated cost estimation (now $2.00 per A10 GPU-hour)
- Updated the GPU hourly rate function
- Updated default GPU shape

### 3. `helm/values.yaml`
- Changed GPU resource limits at the time (since reverted to 1 GPU, 24Gi memory, 8 CPU)

### 4. `scripts/oke-optimized-config.sh` (NEW)
- Centralized OKE-optimized configuration
- Validation functions for GPU quota and image
- Cost estimation functions
- Constants for all OKE-specific settings

## Configuration Details

### GPU Resources
Current `helm/values.yaml`:
```yaml
resources:
  limits:
    nvidia.com/gpu: 1
    memory: "24Gi"
    cpu: "8"
  requests:
    nvidia.com/gpu: 1
    memory: "16Gi"
    cpu: "4"
```

### Node Pool Configuration
```bash
--node-shape VM.GPU.A10.1
--kubernetes-version v1.34.1
--placement-configs '[{"availabilityDomain": "yAdn:PHX-AD-1", "subnetId": "subnet-id"}]'
--node-source-details '{"sourceType": "IMAGE", "imageId": "ocid1.image.oc1.phx.aaaaaaaa2gmabafvnqzelab5ujtlqksdkbgss5w72s3gvf4so34cdic3cwpa", "bootVolumeSizeInGBs": 200}'
```

### Cost Structure
- **VM.GPU.A10.1**: $2.00/hour (1× NVIDIA A10 GPU)
- **OKE Enhanced Cluster**: $0.10/hour (counted once; no separate control-plane charge)
- **Load Balancer and Storage**: not verified here
- **Total**: $2.10/hour, plus load balancer and block storage

### Budget Ranges
Each figure is hours × $2.10, plus load balancer and block storage:
- **Fast Test (1 hour)**: $2.10
- **Short Test (2 hours)**: $4.20
- **Extended Test (4 hours)**: $8.40
- **Full Day (24 hours)**: $50.40
- **Weekly (168 hours)**: $352.80

## Validation Process

### 1. Pre-Deployment Validation
- GPU quota verification
- OKE-optimized image accessibility
- Availability domain confirmation
- Cost estimation and approval

### 2. Deployment Monitoring
- Extended timeout (30 minutes)
- Real-time progress tracking
- Automatic failure detection
- Comprehensive logging

### 3. Post-Deployment Verification
- Node registration confirmation
- GPU device plugin status
- Resource allocation verification
- Cost monitoring

## Expected Outcomes

### 1. Resolution of Node Registration Timeouts
- OKE-optimized image eliminates driver issues
- Higher resource allocation prevents timeouts
- Proper placement configuration ensures connectivity

### 2. Improved Performance
- Inference performance is not measured yet
- Optimized for NVIDIA NIM workloads

### 3. Enhanced Reliability
- Latest Kubernetes version
- OKE-native configuration
- Proper validation and monitoring

## Deployment Instructions

1. **Prerequisites**:
   ```bash
   export OCI_COMPARTMENT_ID="your-compartment-id"
   export OCI_REGION="us-phoenix-1"
   export CONFIRM_COST=yes
   ```

2. **Deploy Cluster**:
   ```bash
   ./scripts/provision-cluster.sh
   ```

3. **Deploy NVIDIA NIM**:
   ```bash
   make install NGC_API_KEY=your-api-key
   ```

4. **Monitor Costs**:
   ```bash
   make operate
   ```

## Rollback Plan

If issues persist:
1. Terminate current cluster
2. Use VM.GPU.A10.1 (the current default) with the OKE-optimized image
3. Test with single GPU configuration

## Cost Monitoring

- **Expected Cost**: $2.10/hour, plus load balancer and block storage
- **5-hour Test**: $10.50
- **Daily Cost**: $50.40
- **Weekly Cost**: $352.80

## Success Metrics

1. **Node Registration**: < 5 minutes
2. **GPU Availability**: 1 GPU detected
3. **NIM Deployment**: Successful pod startup
4. **Inference Performance**: < 2s response time

## Lessons Learned

1. **Shape names**: check shape names against Oracle's compute shapes page; there is no 4-GPU A10 VM shape
2. **Image Compatibility**: use OKE images for GPU node pools
3. **Resource Allocation**: Higher resources prevent timeouts, but shape compatibility is more critical
4. **OKE-Specific Configuration**: Use OKE-native features and optimized images
5. **Validation**: Pre-deployment checks prevent failures, especially shape-image compatibility
6. **Cost Management**: Monitor and optimize continuously, but compatibility comes first
7. **Generic Images**: Never use generic GPU images for NIM on OKE - they lack required drivers

## Next Steps

1. Deploy with corrected configuration
2. Monitor node registration closely
3. Verify GPU functionality
4. Test NVIDIA NIM deployment
5. Commit a measured run receipt under `docs/runs/`
