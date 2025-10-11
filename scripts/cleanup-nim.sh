#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly RELEASE_NAME="nvidia-nim"
readonly NAMESPACE="default"

cleanup_helm_release() {
    log_info "Cleaning up Helm release..."
    
    if helm list -n "$NAMESPACE" | grep -q "^$RELEASE_NAME"; then
        log_info "Uninstalling $RELEASE_NAME..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 300s || {
            log_warn "Helm uninstall failed, forcing cleanup"
            helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --no-hooks || true
        }
        log_success "Helm release uninstalled"
    else
        log_info "Helm release not found (already cleaned up)"
    fi
}

cleanup_kubernetes_resources() {
    log_info "Cleaning up Kubernetes resources..."
    
    log_info "Deleting deployments..."
    kubectl delete deployment -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --wait=true --timeout=180s 2>/dev/null || true
    
    log_info "Deleting services..."
    kubectl delete svc -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --wait=false 2>/dev/null || true
    
    log_info "Deleting pods..."
    kubectl delete pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --wait=false --grace-period=0 --force 2>/dev/null || true
    
    log_info "Deleting secrets..."
    kubectl delete secret ngc-secret -n "$NAMESPACE" 2>/dev/null || true
    kubectl delete secret "${RELEASE_NAME}-ngc-api" -n "$NAMESPACE" 2>/dev/null || true
    
    log_info "Deleting configmaps..."
    kubectl delete configmap -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim 2>/dev/null || true
    
    log_info "Deleting service accounts..."
    kubectl delete serviceaccount -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim 2>/dev/null || true
}

cleanup_storage() {
    log_info "Cleaning up storage..."
    
    local pvc_count
    pvc_count=$(kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$pvc_count" != "0" ]]; then
        log_warn "Found $pvc_count PVC(s) - these contain cached models"
        
        if [[ "${KEEP_CACHE:-no}" == "yes" ]]; then
            log_info "KEEP_CACHE=yes, preserving PVCs for faster re-deployment"
        else
            log_info "Deleting PVCs (set KEEP_CACHE=yes to preserve model cache)..."
            kubectl delete pvc -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --wait=false 2>/dev/null || true
        fi
    else
        log_info "No PVCs found"
    fi
}

verify_cleanup() {
    log_info "Verifying cleanup..."
    
    local remaining_resources=0
    
    if kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim &>/dev/null; then
        log_warn "Deployments still exist"
        ((remaining_resources++))
    fi
    
    if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim &>/dev/null; then
        local pod_count
        pod_count=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --no-headers | wc -l | tr -d ' ')
        if [[ "$pod_count" != "0" ]]; then
            log_warn "Pods still exist: $pod_count (may be terminating)"
            ((remaining_resources++))
        fi
    fi
    
    if [[ $remaining_resources -eq 0 ]]; then
        log_success "Cleanup complete - no NIM resources remain"
        return 0
    else
        log_warn "Some resources still terminating (this is normal)"
        log_info "Wait a minute and check: kubectl get all -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim"
        return 0
    fi
}

calculate_session_cost() {
    if [[ -f "${SCRIPT_DIR}/.nim-deployed-at" ]]; then
        local deploy_time
        deploy_time=$(cat "${SCRIPT_DIR}/.nim-deployed-at")
        local current_time
        current_time=$(date +%s)
        local elapsed_hours
        elapsed_hours=$(echo "scale=2; ($current_time - $deploy_time) / 3600" | bc -l)
        
        local gpu_count
        gpu_count=$(get_gpu_count)
        local hourly_cost
        hourly_cost=$(estimate_hourly_cost "$gpu_count")
        local total_cost
        total_cost=$(echo "scale=2; $elapsed_hours * $hourly_cost" | bc -l)
        
        echo ""
        log_info "Session duration: $(format_cost "$elapsed_hours") hours"
        log_info "Estimated cost: \$$(format_cost "$total_cost")"
        
        rm -f "${SCRIPT_DIR}/.nim-deployed-at"
    fi
}

main() {
    log_info "Starting NIM cleanup..."
    
    local force="${FORCE:-no}"
    
    if [[ "$force" != "yes" ]]; then
        echo ""
        log_warn "This will delete the NIM deployment and associated resources"
        log_info "Set FORCE=yes to skip this prompt"
        echo ""
        read -p "Continue with cleanup? (yes/no) " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            log_info "Cleanup cancelled"
            exit 0
        fi
    fi
    
    cleanup_helm_release
    cleanup_kubernetes_resources
    cleanup_storage
    verify_cleanup
    calculate_session_cost
    
    rm -f "${SCRIPT_DIR}/.nim-endpoint"
    
    echo ""
    log_success "NIM cleanup complete"
    log_info "Note: GPU nodes and cluster remain (use scripts/cleanup.sh for full cluster teardown)"
}

main "$@"

