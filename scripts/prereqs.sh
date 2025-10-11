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

check_gpu_quota() {
    if ! check_oci_credentials; then
        log_warn "Cannot check GPU quota (OCI not configured)"
        return 1
    fi
    
    log_info "Checking GPU quota..."
    
    local limits
    if limits=$(oci limits value list --service-name compute 2>/dev/null); then
        local gpu_limit
        gpu_limit=$(echo "$limits" | jq -r '.data[] | select(.name | contains("gpu-a10-count")) | .value' 2>/dev/null || echo "0")
        
        if [[ "$gpu_limit" != "0" ]] && [[ "$gpu_limit" != "" ]]; then
            log_success "GPU quota available: $gpu_limit GPU(s)"
            return 0
        else
            log_warn "GPU quota may not be available or limit is 0"
            log_info "Request quota at: OCI Console → Governance → Limits, Quotas & Usage"
            return 1
        fi
    else
        log_warn "Unable to check GPU quota"
        return 1
    fi
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
    
    echo ""
    echo "=== Optional Checks ==="
    check_helm_repos || log_warn "Helm repos not configured (optional)"
    
    echo ""
    echo "=== Cluster Requirements ==="
    check_cluster_gpu_nodes || ((failed++))
    check_nvidia_device_plugin || ((failed++))
    
    echo ""
    echo "=== Quota Checks ==="
    check_gpu_quota || log_warn "GPU quota check inconclusive (non-fatal)"
    
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

