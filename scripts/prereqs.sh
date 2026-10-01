#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
# GPU service-limit helpers (get_gpu_service_limit, get_oke_cluster_quota,
# list_availability_domains, check_gpu_shape_capacity) live here.
source "${SCRIPT_DIR}/_lib_audit.sh"

# Kube context pin: provision-cluster.sh records KUBE_CONTEXT=<name> in
# cluster-info.txt. When present, every kubectl/helm call made by this script
# (including the _lib.sh helpers it calls) targets that context. The user's
# current-context is never changed. No KUBE_CONTEXT line: behaviour unchanged.
# NIMBLE_CLUSTER_INFO overrides the file path (tests only).
NIMBLE_CLUSTER_INFO="${NIMBLE_CLUSTER_INFO:-${SCRIPT_DIR}/cluster-info.txt}"
KUBE_CONTEXT_PIN=""
if [[ -f "$NIMBLE_CLUSTER_INFO" ]]; then
    KUBE_CONTEXT_PIN="$(sed -n 's/^KUBE_CONTEXT=//p' "$NIMBLE_CLUSTER_INFO" | tail -1)"
fi
if [[ -n "$KUBE_CONTEXT_PIN" ]]; then
    export HELM_KUBECONTEXT="$KUBE_CONTEXT_PIN"
    kubectl() { command kubectl --context "$KUBE_CONTEXT_PIN" "$@"; }
fi

check_tool() {
    local tool="$1"

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
    if [[ -n "$KUBE_CONTEXT_PIN" ]]; then
        context="$KUBE_CONTEXT_PIN (pinned from cluster-info.txt)"
    else
        context=$(kubectl config current-context 2>/dev/null || echo "none")
    fi
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
    log_success "NGC_API_KEY: set"
    return 0
}

check_ngc_model_access() {
    local model="${NIM_MODEL:-meta/llama3-8b-instruct}"
    
    log_info "Verifying NGC model access: $model"
    
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        log_warn "NGC_API_KEY not set, skipping model access check"
        return 1
    fi
    
    # Test NGC API authentication and model access
    local ngc_response
    # The key reaches curl on stdin (--config -), never in argv.
    ngc_response=$(printf 'header = "Authorization: Bearer %s"\n' "$NGC_API_KEY" \
        | curl -s -w "%{http_code}" -o /dev/null --config - \
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
    
    local gpu_limit=""
    if ! gpu_limit=$(get_gpu_service_limit "${GPU_SHAPE:-VM.GPU.A10.1}") \
        || ! [[ "$gpu_limit" =~ ^[0-9]+$ ]]; then
        log_warn "GPU service limit: unknown (query failed or returned '${gpu_limit}')"
        return 1
    fi
    
    if [[ "$gpu_limit" == "0" ]]; then
        log_error "GPU service limit is 0 for ${GPU_SHAPE:-VM.GPU.A10.1}"
        log_info "Request limit increase: OCI Console > Governance > Limits, Quotas and Usage"
        return 1
    fi
    
    log_success "GPU service limit: $gpu_limit"
    
    local oke_limit=""
    if ! oke_limit=$(get_oke_cluster_quota) || ! [[ "$oke_limit" =~ ^[0-9]+$ ]]; then
        log_warn "OKE cluster limit: unknown (query failed or returned '${oke_limit}')"
        return 1
    fi
    
    if [[ "$oke_limit" == "0" ]]; then
        log_error "OKE cluster limit is 0"
        log_info "Request OKE cluster limit increase in OCI Console"
        return 1
    fi
    
    log_success "OKE cluster limit: $oke_limit"
    
    log_info "Checking GPU capacity in availability domains..."
    local ads
    ads=$(list_availability_domains)
    if [[ -z "$ads" ]]; then
        log_warn "Availability domains: none listed (query failed); GPU capacity not checked"
        return 1
    fi
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

# The real requirement: the device plugin (whatever installed it) has made at
# least one node advertise allocatable nvidia.com/gpu >= 1. A DaemonSet label
# query is not used: the upstream DaemonSet object carries no labels (only its
# pod template does), so a label selector never matches.
# Needs kubectl and python3 (python3 parses the node list JSON).
check_nvidia_device_plugin() {
    local nodes_json summary
    if ! nodes_json=$(kubectl get nodes -o json 2>/dev/null); then
        log_error "NVIDIA GPU allocatable: cannot list nodes (kubectl failed)"
        return 1
    fi
    if ! summary=$(printf '%s' "$nodes_json" | python3 -c '
import json, sys
try:
    items = json.load(sys.stdin).get("items", [])
except ValueError:
    sys.exit(2)
ok = []
for n in items:
    v = n.get("status", {}).get("allocatable", {}).get("nvidia.com/gpu", "0")
    try:
        g = int(str(v))
    except ValueError:
        g = 0
    if g >= 1:
        ok.append("%s=%d" % (n["metadata"]["name"], g))
print(" ".join(ok))
sys.exit(0 if ok else 1)
'); then
        log_error "NVIDIA GPU allocatable: no node reports allocatable nvidia.com/gpu >= 1"
        log_info "The NVIDIA device plugin is missing or not ready on the GPU nodes."
        log_info "Check: kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu"
        log_info "       kubectl get pods -A | grep -i nvidia"
        return 1
    fi
    log_success "NVIDIA GPU allocatable: $summary"
    return 0
}

main() {
    log_info "Checking prerequisites..."
    
    # Enhanced validation is advisory. It treats missing GPU nodes as INFO,
    # so a pass must not skip the critical checks below (GPU allocatable).
    if [[ -x "${SCRIPT_DIR}/pre-execution-validation.sh" ]]; then
        log_info "Running enhanced validation (advisory)..."
        if "${SCRIPT_DIR}/pre-execution-validation.sh" 5 1; then
            log_success "Enhanced validation passed"
        else
            log_warn "Enhanced validation reported failures (advisory); running critical checks"
        fi
    fi
    
    local failed=0
    
    echo ""
    echo "=== Required Tools ==="
    check_tool kubectl || failed=$((failed + 1))
    check_tool helm || failed=$((failed + 1))
    check_tool oci || failed=$((failed + 1))
    check_tool jq || failed=$((failed + 1))
    check_tool bc || failed=$((failed + 1))
    check_tool python3 || failed=$((failed + 1))
    
    echo ""
    echo "=== Configuration ==="
    check_oci_config || failed=$((failed + 1))
    check_kubectl_config || failed=$((failed + 1))
    check_oci_compartment || failed=$((failed + 1))
    check_ngc_credentials || failed=$((failed + 1))
    check_ngc_model_access || log_warn "NGC model access check inconclusive (non-fatal)"
    
    echo ""
    echo "=== Optional Checks ==="
    check_helm_repos || log_warn "Helm repos not configured (optional)"
    
    echo ""
    echo "=== Cluster Requirements ==="
    check_cluster_gpu_nodes || failed=$((failed + 1))
    check_nvidia_device_plugin || failed=$((failed + 1))
    
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

