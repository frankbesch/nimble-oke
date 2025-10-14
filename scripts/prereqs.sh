#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

check_tool() {
    local tool="$1"
    local min_version="${2:-}"
    
    if command -v "$tool" &>/dev/null; then
        local version
        version=$("$tool" version --short 2>/dev/null || "$tool" --version 2>/dev/null | head -n1 || echo "unknown")
        log_success "$tool: installed ($version)"
        return 0
    else
        log_error "$tool: NOT INSTALLED"
        return 1
    fi
}

check_oci_config() {
    if [[ ! -f "$HOME/.oci/config" ]]; then
        log_error "OCI CLI config not found at ~/.oci/config"
        return 1
    fi
    
    if ! oci iam region list &>/dev/null; then
        log_error "OCI CLI not properly configured or credentials invalid"
        return 1
    fi
    
    log_success "OCI CLI: configured and authenticated"
    return 0
}

check_kubectl_config() {
    if [[ ! -f "$HOME/.kube/config" ]]; then
        log_error "kubectl config not found at ~/.kube/config"
        return 1
    fi
    
    if ! kubectl cluster-info &>/dev/null; then
        log_error "kubectl cannot connect to cluster"
        return 1
    fi
    
    local context
    context=$(kubectl config current-context 2>/dev/null || echo "none")
    log_success "kubectl: connected to cluster (context: $context)"
    return 0
}

check_helm_repos() {
    if ! helm repo list &>/dev/null; then
        log_warn "No Helm repositories configured"
        return 1
    fi
    
    log_success "Helm repositories: configured"
    return 0
}

check_ngc_credentials() {
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        log_error "NGC_API_KEY environment variable not set"
        log_info "Get your key from: https://ngc.nvidia.com/setup/api-key"
        log_info "Set it with: export NGC_API_KEY=nvapi-..."
        return 1
    fi
    
    validate_ngc_api_key "$NGC_API_KEY"
    log_success "NGC_API_KEY: set (${NGC_API_KEY:0:10}...)"
    return 0
}

check_ngc_model_access() {
    local model="${NIM_MODEL:-meta/llama-3.1-8b-instruct}"
    
    log_info "Verifying NGC model access: $model"
    
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        log_warn "NGC_API_KEY not set, skipping model access check"
        return 1
    fi
    
    # Test NGC API authentication and model access
    local ngc_response
    ngc_response=$(curl -s -w "%{http_code}" -o /dev/null \
        -H "Authorization: Bearer $NGC_API_KEY" \
        "https://api.ngc.nvidia.com/v2/models/nvidia/$model" 2>/dev/null || echo "000")
    
    if [[ "$ngc_response" == "200" ]]; then
        log_success "NGC model access verified: $model"
        return 0
    elif [[ "$ngc_response" == "401" ]]; then
        log_error "NGC API key authentication failed"
        log_info "Verify your key at: https://ngc.nvidia.com/setup/api-key"
        return 1
    elif [[ "$ngc_response" == "403" ]]; then
        log_error "NGC API key lacks access to model: $model"
        log_info "Request access at: https://catalog.ngc.nvidia.com/"
        return 1
    else
        log_warn "NGC API connectivity test inconclusive (HTTP $ngc_response)"
        log_info "Proceeding anyway - will fail at deployment if access denied"
        return 0
    fi
}

check_oci_compartment() {
    if [[ -z "${OCI_COMPARTMENT_ID:-}" ]]; then
        log_error "OCI_COMPARTMENT_ID environment variable not set"
        log_info "Find your compartment ID with: oci iam compartment list"
        log_info "Set it with: export OCI_COMPARTMENT_ID=ocid1.compartment..."
        return 1
    fi
    
    log_success "OCI_COMPARTMENT_ID: set"
    return 0
}

check_service_limits() {
    if ! check_oci_credentials; then
        log_warn "Cannot check service limits (OCI not configured)"
        return 1
    fi
    
    log_info "Verifying OCI service limits..."
    
    local gpu_limit
    gpu_limit=$(get_gpu_service_limit "${GPU_SHAPE:-VM.GPU.A10.1}")
    
    if [[ "$gpu_limit" == "0" ]]; then
        log_error "GPU service limit is 0 for ${GPU_SHAPE:-VM.GPU.A10.1}"
        log_info "Request limit increase: OCI Console > Governance > Limits, Quotas and Usage"
        return 1
    fi
    
    log_success "GPU service limit: $gpu_limit"
    
    local oke_limit
    oke_limit=$(get_oke_cluster_quota)
    
    if [[ "$oke_limit" == "0" ]]; then
        log_error "OKE cluster limit is 0"
        log_info "Request OKE cluster limit increase in OCI Console"
        return 1
    fi
    
    log_success "OKE cluster limit: $oke_limit"
    
    log_info "Checking GPU capacity in availability domains..."
    local ads
    ads=$(list_availability_domains)
    local capacity_found=false
    
    for ad in $ads; do
        if check_gpu_shape_capacity "${GPU_SHAPE:-VM.GPU.A10.1}" "$ad" 2>/dev/null; then
            log_success "GPU capacity available in: $ad"
            capacity_found=true
            break
        fi
    done
    
    if [[ "$capacity_found" == "false" ]]; then
        log_warn "No GPU capacity found in checked ADs - provisioning may fail"
        log_info "Try different region or wait for capacity"
    fi
    
    return 0
}

check_cluster_gpu_nodes() {
    local gpu_count
    gpu_count=$(get_gpu_count)
    
    if [[ "$gpu_count" == "0" ]]; then
        log_error "No GPU nodes found in cluster"
        log_info "Provision GPU nodes with: make provision"
        return 1
    fi
    
    log_success "GPU nodes available: $gpu_count"
    return 0
}

check_nvidia_device_plugin() {
    if kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds &>/dev/null; then
        local ready
        ready=$(kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")
        local desired
        desired=$(kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        
        if [[ "$ready" == "$desired" ]] && [[ "$ready" != "0" ]]; then
            log_success "NVIDIA device plugin: installed and ready ($ready/$desired)"
            return 0
        else
            log_warn "NVIDIA device plugin: installed but not fully ready ($ready/$desired)"
            return 1
        fi
    else
        log_error "NVIDIA device plugin: not installed"
        log_info "Install with: kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml"
        return 1
    fi
}

main() {
    log_info "Checking prerequisites..."
    
    # Enhanced validation if available
    if [[ -x "${SCRIPT_DIR}/pre-execution-validation.sh" ]]; then
        log_info "Running enhanced validation..."
        if "${SCRIPT_DIR}/pre-execution-validation.sh" 5 1; then
            log_success "Enhanced validation passed"
            return 0
        else
            log_warn "Enhanced validation failed, falling back to basic checks"
        fi
    fi
    
    local failed=0
    
    echo ""
    echo "=== Required Tools ==="
    check_tool kubectl || ((failed++))
    check_tool helm || ((failed++))
    check_tool oci || ((failed++))
    check_tool jq || ((failed++))
    check_tool bc || ((failed++))
    
    echo ""
    echo "=== Configuration ==="
    check_oci_config || ((failed++))
    check_kubectl_config || ((failed++))
    check_oci_compartment || ((failed++))
    check_ngc_credentials || ((failed++))
    check_ngc_model_access || log_warn "NGC model access check inconclusive (non-fatal)"
    
    echo ""
    echo "=== Optional Checks ==="
    check_helm_repos || log_warn "Helm repos not configured (optional)"
    
    echo ""
    echo "=== Cluster Requirements ==="
    check_cluster_gpu_nodes || ((failed++))
    check_nvidia_device_plugin || ((failed++))
    
    echo ""
    echo "=== OCI Service Limits ==="
    check_service_limits || log_warn "Service limits check inconclusive (non-fatal)"
    
    echo ""
    if [[ $failed -eq 0 ]]; then
        log_success "All critical prerequisites met"
        return 0
    else
        log_error "Prerequisites check failed ($failed critical checks failed)"
        log_info "Fix the errors above and run again"
        return 1
    fi
}

main "$@"

