#!/usr/bin/env bash

# Pod Cleanup Script for Nimble OKE
# Prevents accumulation of failed pods

set -euo pipefail

# Configuration
readonly MAX_FAILED_PODS="${MAX_FAILED_PODS:-3}"
readonly MAX_PENDING_PODS="${MAX_PENDING_PODS:-2}"
readonly CLEANUP_INTERVAL="${CLEANUP_INTERVAL:-300}" # 5 minutes
readonly NAMESPACE="${NAMESPACE:-default}"
# Only NIM pods are counted and deleted; other workloads are never touched.
readonly POD_SELECTOR="${POD_SELECTOR:-app.kubernetes.io/name=nvidia-nim}"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POD-CLEANUP] $*" >&2
}

# Cleanup failed pods
cleanup_failed_pods() {
    local failed_count
    failed_count=$(kubectl get pods -l "$POD_SELECTOR" --field-selector=status.phase=Failed -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    
    if [[ "$failed_count" -gt "$MAX_FAILED_PODS" ]]; then
        log "WARNING: $failed_count failed pods exceed limit ($MAX_FAILED_PODS)"
        log "Cleaning up failed pods..."
        kubectl delete pods -l "$POD_SELECTOR" --field-selector=status.phase=Failed -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        log "Failed pods cleaned up"
    else
        log "Failed pods within limit: $failed_count/$MAX_FAILED_PODS"
    fi
}

# Cleanup pending pods
cleanup_pending_pods() {
    local pending_count
    pending_count=$(kubectl get pods -l "$POD_SELECTOR" --field-selector=status.phase=Pending -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    
    if [[ "$pending_count" -gt "$MAX_PENDING_PODS" ]]; then
        log "WARNING: $pending_count pending pods exceed limit ($MAX_PENDING_PODS)"
        log "Cleaning up pending pods..."
        kubectl delete pods -l "$POD_SELECTOR" --field-selector=status.phase=Pending -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
        log "Pending pods cleaned up"
    else
        log "Pending pods within limit: $pending_count/$MAX_PENDING_PODS"
    fi
}

# Main cleanup function
main() {
    log "Starting pod cleanup process..."
    log "Max failed pods: $MAX_FAILED_PODS"
    log "Max pending pods: $MAX_PENDING_PODS"
    log "Pod selector: $POD_SELECTOR"
    log "Cleanup interval: ${CLEANUP_INTERVAL}s"
    
    cleanup_failed_pods
    cleanup_pending_pods
    
    log "Pod cleanup completed"
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
