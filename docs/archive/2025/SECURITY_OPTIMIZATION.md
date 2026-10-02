# Security Configuration Optimization for NIM Deployment

> **Archived.** A planning or analysis note from October 2025. It is not a measurement. For current status and measured results, see the [README](../../../README.md).

*Historical working note from October 2025; figures corrected 2026-10-01. See README for current status.*

> **Current state (2026-10-01):** the chart applies no pod hardening. `podSecurityContext` is empty, so the container runs as the image's default user with no fsGroup and no seccomp profile. The container context sets only `readOnlyRootFilesystem: false`. Privilege escalation is allowed and no capabilities are dropped. Hardening is untested with NIM.

## Overview

This document outlines the security optimizations made to minimize deployment time, costs, and troubleshooting complexity while maintaining appropriate security for NIM deployments.

## Security Settings Analysis

### 1. seccompProfile Configuration

**Issue**: `RuntimeDefault` seccomp profile may block syscalls required by NIM for GPU operations.

**NIM Requirements**:
- GPU memory management (`mmap`, `munmap`, `ioctl`)
- CUDA driver communication
- Model file operations
- Network API serving

**Solution**: Disabled seccompProfile for initial deployment
```yaml
# DISABLED for NIM compatibility
# seccompProfile: RuntimeDefault
```

**Future Enhancement**: Create custom seccomp profile after validating NIM requirements.

### 2. Topology Spread Constraints

**Issue**: `DoNotSchedule` policy prevents deployment in single-zone clusters.

**Solution**: Disabled for development/testing environments
```yaml
topologySpreadConstraints:
  enabled: false  # DISABLED for single-zone development/testing
  whenUnsatisfiable: ScheduleAnyway  # Allow scheduling even if constraints can't be met
```

**Production Recommendation**: Enable for multi-zone production deployments.

### 3. Health Check Optimization

**Optimization**: Reduced probe intervals for faster deployment detection.

**Changes**:
- Readiness probe: 30s → 15s initial delay
- Liveness probe: 60s → 45s initial delay  
- Startup probe: 10s → 5s initial delay
- Reduced timeout values for faster failure detection

**Trade-off**: Faster deployment vs slightly more probe traffic.

## Security Settings in the Current Chart

### Applied

1. **GPU node selection**: `nvidia.com/gpu.present: "true"` (any NVIDIA GPU node)
2. **Resource limits**: CPU, memory, and GPU limits
3. **Service account**: dedicated service account

### Not Applied (Untested with NIM)

1. **Non-root execution**: `runAsNonRoot` is not set; the image's default user runs
2. **Privilege escalation prevention**: `allowPrivilegeEscalation: false` is not set
3. **Capability dropping**: no capabilities are dropped
4. **Seccomp**: no profile is set

### Trade-offs

1. **Writable root filesystem**: Required for NIM temp files and cache
2. **No seccomp profile**: chosen to avoid blocking GPU syscalls (untested)
3. **Disabled topology spread**: Required for single-zone testing

## Deployment Optimization Impact

### Time Savings
- **Readiness detection**: 15s faster (30s → 15s)
- **Startup detection**: 5s faster (10s → 5s)
- **Topology constraints**: Eliminates scheduling delays in single-zone

### Cost Optimization
- Faster deployment = reduced compute time
- Eliminates topology-related scheduling failures
- Reduces troubleshooting time

### Troubleshooting Benefits
- Simpler configuration = fewer failure points
- Faster probe responses = quicker issue detection
- Disabled complex constraints = easier debugging

## Future Security Enhancements

### Phase 1: Post-Deployment Validation
1. Monitor NIM container for required syscalls
2. Create custom seccomp profile based on actual usage
3. Test with seccomp enabled

### Phase 2: Production Hardening
1. Enable topology spread constraints for multi-zone
2. Implement read-only root filesystem with tmpfs volumes
3. Add network policies for micro-segmentation

### Phase 3: Advanced Security
1. Implement Pod Security Standards
2. Add admission controllers
3. Enable audit logging

## Testing Recommendations

### Pre-Deployment
```bash
# Validate configuration
make dry-run
make validate
```

### Post-Deployment
```bash
# Test NIM functionality
make verify
make test-inference

# Monitor for security-related issues
kubectl logs -f deployment/nvidia-nim
kubectl describe pod <nim-pod>
```

### Security Validation
```bash
# Check applied security context
kubectl get pod <nim-pod> -o jsonpath='{.spec.securityContext}'

# Show the runtime user (the chart does not force non-root)
kubectl exec <nim-pod> -- id
```

## Conclusion

These settings prioritize deployment success and troubleshooting ease. The pod is not hardened. The configuration can be progressively hardened as the deployment matures and requirements become clearer.

**Key Principle**: Start with working deployment, then incrementally enhance security based on actual requirements and constraints.
