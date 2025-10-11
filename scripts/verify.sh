#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly RELEASE_NAME="nvidia-nim"
readonly NAMESPACE="default"

verify_deployment_exists() {
    if ! kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim &>/dev/null; then
        log_error "NIM deployment not found"
        return 1
    fi
    log_success "Deployment exists"
    return 0
}

verify_pods_running() {
    local pod_count
    pod_count=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$pod_count" == "0" ]]; then
        log_error "No NIM pods running"
        return 1
    fi
    
    log_success "Pods running: $pod_count"
    return 0
}

verify_pods_ready() {
    local ready_count
    ready_count=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status=="True")].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    
    if [[ "$ready_count" == "0" ]]; then
        log_error "No NIM pods ready"
        return 1
    fi
    
    log_success "Pods ready: $ready_count"
    return 0
}

verify_gpu_allocation() {
    local gpu_allocated
    gpu_allocated=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[*].spec.containers[*].resources.requests.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '+' | bc 2>/dev/null || echo "0")
    
    if [[ "$gpu_allocated" == "0" ]] || [[ -z "$gpu_allocated" ]]; then
        log_error "No GPUs allocated to NIM pods"
        return 1
    fi
    
    log_success "GPUs allocated: $gpu_allocated"
    return 0
}

verify_service_exists() {
    if ! kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_error "NIM service not found"
        return 1
    fi
    
    local svc_type
    svc_type=$(kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.type}')
    log_success "Service exists (type: $svc_type)"
    return 0
}

verify_service_endpoint() {
    local external_ip
    external_ip=$(get_service_external_ip "$RELEASE_NAME" "$NAMESPACE")
    
    if [[ -z "$external_ip" ]]; then
        local svc_type
        svc_type=$(kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.type}')
        
        if [[ "$svc_type" == "LoadBalancer" ]]; then
            log_warn "LoadBalancer IP not yet assigned (may still be provisioning)"
            return 1
        else
            log_success "Service endpoint: ClusterIP (use port-forward for access)"
            return 0
        fi
    fi
    
    log_success "External endpoint: http://${external_ip}:8000"
    return 0
}

verify_pvc_bound() {
    local pvc_count
    pvc_count=$(kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --field-selector=status.phase=Bound --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$pvc_count" == "0" ]]; then
        log_warn "No PVCs bound (model caching may not be persistent)"
        return 1
    fi
    
    log_success "PVCs bound: $pvc_count"
    return 0
}

verify_api_health() {
    local external_ip
    external_ip=$(get_service_external_ip "$RELEASE_NAME" "$NAMESPACE")
    
    if [[ -z "$external_ip" ]]; then
        log_warn "No external IP, skipping API health check"
        return 1
    fi
    
    log_info "Testing API health endpoint..."
    
    if curl -sf "http://${external_ip}:8000/v1/health/ready" --max-time 10 &>/dev/null; then
        log_success "API health check: PASSED"
        return 0
    else
        log_warn "API health check: FAILED (service may still be starting)"
        return 1
    fi
}

verify_model_loading() {
    local pod_name
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$pod_name" ]]; then
        log_warn "No pod found to check model loading"
        return 1
    fi
    
    log_info "Checking model loading status..."
    local logs
    logs=$(kubectl logs "$pod_name" -n "$NAMESPACE" --tail=100 2>/dev/null || echo "")
    
    if echo "$logs" | grep -qi "model.*loaded\|ready.*accept.*request"; then
        log_success "Model appears to be loaded"
        return 0
    elif echo "$logs" | grep -qi "loading.*model\|downloading"; then
        log_warn "Model still loading (this can take 30-45 minutes)"
        return 1
    else
        log_warn "Unable to determine model loading status from logs"
        return 1
    fi
}

main() {
    log_info "Verifying NIM deployment..."
    
    local failed=0
    local warnings=0
    
    echo ""
    echo "=== Deployment Verification ==="
    verify_deployment_exists || ((failed++))
    verify_pods_running || ((failed++))
    verify_pods_ready || ((failed++))
    verify_gpu_allocation || ((failed++))
    
    echo ""
    echo "=== Service Verification ==="
    verify_service_exists || ((failed++))
    verify_service_endpoint || ((warnings++))
    
    echo ""
    echo "=== Storage Verification ==="
    verify_pvc_bound || ((warnings++))
    
    echo ""
    echo "=== API Verification ==="
    verify_api_health || ((warnings++))
    verify_model_loading || ((warnings++))
    
    echo ""
    echo "=== Pod Details ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o wide 2>/dev/null || echo "Unable to get pods"
    
    echo ""
    echo "=== Service Details ==="
    kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "Service not found"
    
    echo ""
    if [[ $failed -eq 0 ]]; then
        if [[ $warnings -eq 0 ]]; then
            log_success "All verification checks passed"
            echo ""
            log_info "Next steps:"
            log_info "  - Test inference: make test-inference"
            log_info "  - View operations: make operate"
            return 0
        else
            log_success "Critical checks passed ($warnings warnings)"
            log_warn "Some optional checks failed (service may still be initializing)"
            echo ""
            log_info "Wait a few minutes and run 'make verify' again"
            return 0
        fi
    else
        log_error "Verification failed ($failed critical checks failed)"
        echo ""
        log_info "Troubleshoot with: make troubleshoot"
        return 1
    fi
}

main "$@"

