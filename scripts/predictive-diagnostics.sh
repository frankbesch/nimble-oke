#!/bin/bash

# Predictive Diagnostics Engine for NVIDIA NIM on OKE
# Proactive pattern detection and prevention recommendations

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Configuration
NAMESPACE="${NAMESPACE:-nim}"
NIM_MODEL="${NIM_MODEL:-meta/llama-3.1-8b-instruct}"
PREDICTION_OUTPUT="/tmp/nim-predictions.json"

log_info "Predictive Diagnostics Engine initialized"
log_info "Namespace: $NAMESPACE"
log_info "Target model: $NIM_MODEL"

# Function to check GPU driver version compatibility
check_gpu_driver_version() {
    log_info "Checking GPU driver version compatibility..."
    
    local driver_version
    driver_version=$(kubectl describe nodes -l nvidia.com/gpu.present=true | grep -o "nvidia-driver-[0-9]*" | head -1 | sed 's/nvidia-driver-//' || echo "unknown")
    
    if [[ "$driver_version" == "unknown" ]]; then
        log_warn "Could not determine GPU driver version"
        return 1
    fi
    
    log_info "GPU driver version: $driver_version"
    
    # Check minimum requirements (NVIDIA recommends 535+)
    if [[ "$driver_version" -lt 535 ]]; then
        log_error "GPU driver version $driver_version is below minimum requirement (535+)"
        log_info "Recommended action: Update GPU driver to version 535 or later"
        return 1
    fi
    
    log_success "GPU driver version compatible"
    return 0
}

# Function to check model compatibility with available resources
check_model_compatibility() {
    log_info "Checking model compatibility with available resources..."
    
    local model="$1"
    local gpu_memory
    local system_memory
    local model_memory_requirement
    
    # Get GPU memory from node capacity
    gpu_memory=$(kubectl get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].status.capacity.nvidia\.com/gpu}' | sed 's/GB//' || echo "0")
    
    # Get system memory from node capacity
    system_memory=$(kubectl get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[0].status.capacity.memory}' | sed 's/Ki//' | head -c -2 || echo "0")
    system_memory=$((system_memory / 1024 / 1024))  # Convert to GB
    
    # Model memory requirements lookup
    case "$model" in
        "meta/llama-3.1-8b-instruct")
            model_memory_requirement=24  # 24GB GPU memory
            ;;
        "meta/llama-3.1-70b-instruct")
            model_memory_requirement=80  # 80GB GPU memory
            ;;
        "meta/codellama-34b-instruct")
            model_memory_requirement=68  # 68GB GPU memory
            ;;
        *)
            log_warn "Unknown model: $model, using default 24GB requirement"
            model_memory_requirement=24
            ;;
    esac
    
    log_info "Resource analysis:"
    log_info "  GPU memory: ${gpu_memory}GB"
    log_info "  System memory: ${system_memory}GB"
    log_info "  Model requirement: ${model_memory_requirement}GB GPU memory"
    
    # Check GPU memory compatibility
    if [[ $gpu_memory -lt $model_memory_requirement ]]; then
        log_error "GPU memory insufficient for model $model"
        log_error "Required: ${model_memory_requirement}GB, Available: ${gpu_memory}GB"
        suggest_model_alternatives "$model" "$gpu_memory"
        return 1
    fi
    
    # Check system memory compatibility (NVIDIA recommends 90GB+)
    if [[ $system_memory -lt 90 ]]; then
        log_warn "System memory may be insufficient for optimal performance"
        log_warn "Available: ${system_memory}GB, Recommended: 90GB+"
        log_info "Model may still work but performance may be degraded"
    fi
    
    log_success "Model compatibility check passed"
    return 0
}

# Function to suggest alternative models based on available resources
suggest_model_alternatives() {
    local requested_model="$1"
    local available_gpu_memory="$2"
    
    log_info "Suggested alternatives for ${available_gpu_memory}GB GPU memory:"
    
    case "$available_gpu_memory" in
        24)
            log_info "  ✅ meta/llama-3.1-8b-instruct (requires 24GB)"
            log_info "  ✅ meta/codellama-7b-instruct (requires 14GB)"
            ;;
        40)
            log_info "  ✅ meta/llama-3.1-8b-instruct (requires 24GB)"
            log_info "  ✅ meta/codellama-34b-instruct (requires 34GB)"
            log_info "  ❌ meta/llama-3.1-70b-instruct (requires 80GB)"
            ;;
        80)
            log_info "  ✅ All models supported:"
            log_info "    - meta/llama-3.1-8b-instruct (requires 24GB)"
            log_info "    - meta/codellama-34b-instruct (requires 34GB)"
            log_info "    - meta/llama-3.1-70b-instruct (requires 80GB)"
            ;;
        *)
            log_info "  ❓ Unknown GPU memory size, checking compatibility..."
            ;;
    esac
}

# Function to check network connectivity for model downloads
check_network_connectivity() {
    log_info "Checking network connectivity for model downloads..."
    
    local connectivity_issues=0
    
    # Check NGC connectivity
    if ! curl -s --connect-timeout 10 "https://nvcr.io" >/dev/null; then
        log_error "NGC registry connectivity failed"
        ((connectivity_issues++))
    else
        log_success "NGC registry connectivity verified"
    fi
    
    # Check OCI Object Storage connectivity (if using)
    if ! curl -s --connect-timeout 10 "https://objectstorage.${OCI_REGION:-us-phoenix-1}.oraclecloud.com" >/dev/null; then
        log_warn "OCI Object Storage connectivity issues detected"
        log_info "This may affect model caching performance"
        ((connectivity_issues++))
    else
        log_success "OCI Object Storage connectivity verified"
    fi
    
    # Check cluster network connectivity
    local cluster_ip
    cluster_ip=$(kubectl get service kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    
    if [[ -n "$cluster_ip" ]]; then
        if ! kubectl run test-connectivity --image=busybox --rm -i --restart=Never -- ping -c 3 "$cluster_ip" >/dev/null 2>&1; then
            log_warn "Cluster network connectivity issues detected"
            ((connectivity_issues++))
        else
            log_success "Cluster network connectivity verified"
        fi
    fi
    
    if [[ $connectivity_issues -gt 0 ]]; then
        log_warn "Network connectivity issues detected: $connectivity_issues problems found"
        return 1
    fi
    
    log_success "All network connectivity checks passed"
    return 0
}

# Function to check storage performance and availability
check_storage_performance() {
    log_info "Checking storage performance and availability..."
    
    local storage_issues=0
    
    # Check default storage class
    local storage_class
    storage_class=$(get_default_storage_class)
    
    if [[ -z "$storage_class" ]]; then
        log_error "No default storage class found"
        log_info "Required for PVC creation"
        ((storage_issues++))
    else
        log_success "Default storage class: $storage_class"
    fi
    
    # Check storage class performance characteristics
    local storage_class_info
    storage_class_info=$(kubectl get storageclass "$storage_class" -o yaml 2>/dev/null || echo "")
    
    if [[ -n "$storage_class_info" ]]; then
        if echo "$storage_class_info" | grep -q "volumeBindingMode: WaitForFirstConsumer"; then
            log_info "Storage class uses WaitForFirstConsumer binding (good for dynamic provisioning)"
        fi
        
        if echo "$storage_class_info" | grep -q "reclaimPolicy: Delete"; then
            log_info "Storage class uses Delete reclaim policy (good for cost optimization)"
        fi
    fi
    
    # Check available storage capacity
    local available_capacity
    available_capacity=$(kubectl top nodes 2>/dev/null | tail -n +2 | awk '{sum += $5} END {print sum}' || echo "0")
    
    if [[ $available_capacity -lt 200 ]]; then
        log_warn "Available storage capacity may be insufficient for model cache (200GB recommended)"
        log_info "Available: ${available_capacity}GB"
        ((storage_issues++))
    else
        log_success "Storage capacity sufficient for model cache"
    fi
    
    if [[ $storage_issues -gt 0 ]]; then
        log_warn "Storage issues detected: $storage_issues problems found"
        return 1
    fi
    
    log_success "All storage checks passed"
    return 0
}

# Function to check NGC authentication and model access
check_ngc_authentication() {
    log_info "Checking NGC authentication and model access..."
    
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        log_error "NGC_API_KEY not set"
        log_info "Set with: export NGC_API_KEY=nvapi-your-key-here"
        return 1
    fi
    
    # Test NGC API authentication
    local auth_response
    auth_response=$(curl -s -w "%{http_code}" -o /dev/null \
        -H "Authorization: Bearer $NGC_API_KEY" \
        "https://api.ngc.nvidia.com/v2/auth/verify" 2>/dev/null || echo "000")
    
    case "$auth_response" in
        "200")
            log_success "NGC API authentication successful"
            ;;
        "401")
            log_error "NGC API key authentication failed"
            log_info "Verify your key at: https://ngc.nvidia.com/setup/api-key"
            return 1
            ;;
        "403")
            log_error "NGC API key lacks required permissions"
            log_info "Check your NGC account permissions"
            return 1
            ;;
        *)
            log_warn "NGC API connectivity test inconclusive (HTTP $auth_response)"
            log_info "Proceeding anyway - will fail at deployment if access denied"
            ;;
    esac
    
    # Check specific model access
    local model_access_response
    model_access_response=$(curl -s -w "%{http_code}" -o /dev/null \
        -H "Authorization: Bearer $NGC_API_KEY" \
        "https://api.ngc.nvidia.com/v2/models/nvidia/$NIM_MODEL" 2>/dev/null || echo "000")
    
    case "$model_access_response" in
        "200")
            log_success "Model access verified: $NIM_MODEL"
            ;;
        "401"|"403")
            log_error "NGC API key lacks access to model: $NIM_MODEL"
            log_info "Request access at: https://catalog.ngc.nvidia.com/"
            return 1
            ;;
        *)
            log_warn "Model access test inconclusive (HTTP $model_access_response)"
            log_info "Proceeding anyway - will fail at deployment if access denied"
            ;;
    esac
    
    return 0
}

# Function to check cluster resource availability
check_cluster_resources() {
    log_info "Checking cluster resource availability..."
    
    local resource_issues=0
    
    # Check GPU node availability
    local gpu_nodes
    gpu_nodes=$(get_gpu_nodes | wc -l)
    
    if [[ $gpu_nodes -eq 0 ]]; then
        log_error "No GPU nodes available"
        log_info "Required for NIM deployment"
        ((resource_issues++))
    else
        log_success "GPU nodes available: $gpu_nodes"
    fi
    
    # Check GPU allocation
    local total_gpus
    total_gpus=$(kubectl get nodes -l nvidia.com/gpu.present=true -o jsonpath='{.items[*].status.capacity.nvidia\.com/gpu}' | tr ' ' '\n' | wc -l)
    
    if [[ $total_gpus -eq 0 ]]; then
        log_error "No GPUs available for allocation"
        ((resource_issues++))
    else
        log_success "Total GPUs available: $total_gpus"
    fi
    
    # Check CPU and memory availability
    local cpu_requests
    local memory_requests
    
    cpu_requests=$(kubectl describe nodes | grep -o "cpu:[0-9]*" | head -1 | sed 's/cpu://' || echo "0")
    memory_requests=$(kubectl describe nodes | grep -o "memory:[0-9]*Gi" | head -1 | sed 's/memory://' | sed 's/Gi//' || echo "0")
    
    if [[ $cpu_requests -lt 4 ]]; then
        log_warn "Low CPU availability: ${cpu_requests} cores (4+ recommended)"
        ((resource_issues++))
    fi
    
    if [[ $memory_requests -lt 32 ]]; then
        log_warn "Low memory availability: ${memory_requests}GB (32GB+ recommended)"
        ((resource_issues++))
    fi
    
    if [[ $resource_issues -gt 0 ]]; then
        log_warn "Resource availability issues: $resource_issues problems found"
        return 1
    fi
    
    log_success "All resource availability checks passed"
    return 0
}

# Function to generate prevention recommendations
generate_prevention_recommendations() {
    log_info "Generating prevention recommendations..."
    
    local recommendations_file="/tmp/nim-prevention-recommendations.md"
    
    cat > "$recommendations_file" << EOF
# NVIDIA NIM Prevention Recommendations

**Generated:** $(date)
**Model:** $NIM_MODEL
**Namespace:** $NAMESPACE

## Proactive Recommendations

### 1. Resource Optimization
- **GPU Memory**: Ensure sufficient GPU memory for model requirements
- **System Memory**: Use 90GB+ system memory for optimal performance
- **Storage**: Allocate 200GB+ for model cache and temporary files

### 2. Network Optimization
- **NGC Connectivity**: Ensure stable internet connection for model downloads
- **Bandwidth**: Allocate sufficient bandwidth for model downloads (50GB+)
- **Firewall**: Allow outbound HTTPS connections to nvcr.io

### 3. Authentication Setup
- **NGC API Key**: Generate and configure NGC API key before deployment
- **Model Access**: Request access to specific models in NGC catalog
- **Credentials**: Store credentials securely using OCI Vault or Kubernetes secrets

### 4. Cluster Configuration
- **GPU Nodes**: Ensure GPU nodes are running and accessible
- **Storage Class**: Verify default storage class is available
- **Resource Limits**: Set appropriate resource requests and limits

### 5. Monitoring Setup
- **Health Probes**: Configure appropriate readiness and liveness probes
- **Logging**: Enable structured logging for troubleshooting
- **Metrics**: Set up monitoring for resource usage and performance

## Risk Mitigation

### High-Risk Scenarios
1. **Insufficient GPU Memory**: Model will fail to load
   - **Mitigation**: Use smaller model or larger GPU instance
   
2. **Network Connectivity Issues**: Model download will fail
   - **Mitigation**: Pre-download models or use local cache
   
3. **Storage Space**: Model cache will fail
   - **Mitigation**: Increase PVC size or clean up old caches

### Medium-Risk Scenarios
1. **Slow Network**: Extended download times
   - **Mitigation**: Use model caching and pre-warming
   
2. **Resource Contention**: Performance degradation
   - **Mitigation**: Resource isolation and proper scheduling

## Best Practices

1. **Always run predictive diagnostics before deployment**
2. **Use model caching to reduce download costs and time**
3. **Monitor resource usage during deployment**
4. **Have fallback plans for common failure scenarios**
5. **Document successful configurations for reuse**

EOF
    
    log_success "Prevention recommendations generated: $recommendations_file"
}

# Function to set up predictive monitoring
setup_predictive_monitoring() {
    log_info "Setting up predictive monitoring..."
    
    # Create monitoring namespace if it doesn't exist
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - || true
    
    # Set up basic monitoring for NIM deployment
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: nim-monitoring-config
  namespace: $NAMESPACE
data:
  monitoring.sh: |
    #!/bin/bash
    # Basic monitoring script for NIM deployment
    while true; do
      # Check pod status
      kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim
      
      # Check resource usage
      kubectl top pods -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim
      
      sleep 60
    done
EOF
    
    log_success "Predictive monitoring setup completed"
}

# Main predictive diagnostics function
predictive_diagnostics() {
    log_info "Starting predictive diagnostics for NVIDIA NIM deployment..."
    
    local failed_checks=0
    local total_checks=6
    
    # Run all predictive checks
    check_gpu_driver_version || ((failed_checks++))
    check_model_compatibility "$NIM_MODEL" || ((failed_checks++))
    check_network_connectivity || ((failed_checks++))
    check_storage_performance || ((failed_checks++))
    check_ngc_authentication || ((failed_checks++))
    check_cluster_resources || ((failed_checks++))
    
    # Generate recommendations
    generate_prevention_recommendations
    
    # Set up monitoring
    setup_predictive_monitoring
    
    # Summary
    local passed_checks=$((total_checks - failed_checks))
    local success_rate=$((passed_checks * 100 / total_checks))
    
    log_info "Predictive diagnostics summary:"
    log_info "  Total checks: $total_checks"
    log_info "  Passed: $passed_checks"
    log_info "  Failed: $failed_checks"
    log_info "  Success rate: ${success_rate}%"
    
    if [[ $failed_checks -eq 0 ]]; then
        log_success "All predictive checks passed - deployment should succeed"
        return 0
    elif [[ $failed_checks -le 2 ]]; then
        log_warn "Some predictive checks failed - deployment may succeed with warnings"
        log_info "Review recommendations: /tmp/nim-prevention-recommendations.md"
        return 0
    else
        log_error "Multiple predictive checks failed - deployment likely to fail"
        log_info "Review recommendations: /tmp/nim-prevention-recommendations.md"
        return 1
    fi
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    predictive_diagnostics "$@"
fi
