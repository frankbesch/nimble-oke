#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_diagnostics.sh"

readonly RELEASE_NAME="nvidia-nim"
readonly NAMESPACE="default"

troubleshoot_pods() {
    log_info "Checking pod status..."
    
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null || echo "")
    
    if [[ -z "$pods" ]]; then
        log_error "No NIM pods found"
        return 1
    fi
    
    echo "$pods" | while read -r line; do
        local pod_name
        pod_name=$(echo "$line" | awk '{print $1}')
        local status
        status=$(echo "$line" | awk '{print $3}')
        
        echo ""
        echo "Pod: $pod_name"
        echo "Status: $status"
        
        if [[ "$status" != "Running" ]]; then
            log_warn "Pod not running, checking events..."
            kubectl describe pod "$pod_name" -n "$NAMESPACE" | grep -A 10 "Events:" || true
            
            log_info "Recent logs:"
            kubectl logs "$pod_name" -n "$NAMESPACE" --tail=50 2>/dev/null || echo "No logs available"
        fi
    done
}

troubleshoot_gpu() {
    log_info "Checking GPU allocation..."
    
    local gpu_count
    gpu_count=$(get_gpu_count)
    
    if [[ "$gpu_count" == "0" ]]; then
        log_error "No GPU nodes found in cluster"
        log_info "Check node labels: kubectl get nodes --show-labels"
        return 1
    fi
    
    log_info "GPU nodes found: $gpu_count"
    
    log_info "Checking NVIDIA device plugin..."
    if ! kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds &>/dev/null; then
        log_error "NVIDIA device plugin not installed"
        log_info "Install: kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml"
        return 1
    fi
    
    log_info "Device plugin status:"
    kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds
    
    log_info "GPU allocatable resources:"
    kubectl get nodes -o json | jq -r '.items[] | select(.status.capacity."nvidia.com/gpu") | "\(.metadata.name): \(.status.allocatable."nvidia.com/gpu") GPU(s)"'
}

troubleshoot_image_pull() {
    log_info "Checking image pull status..."
    
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$pods" ]]; then
        log_warn "No pods to check"
        return 1
    fi
    
    for pod in $pods; do
        local image_pull_status
        image_pull_status=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || echo "")
        
        if echo "$image_pull_status" | grep -q "ImagePullBackOff\|ErrImagePull"; then
            log_error "Pod $pod has image pull issues"
            kubectl describe pod "$pod" -n "$NAMESPACE" | grep -A 5 "Failed to pull image"
            
            log_info "Check NGC credentials:"
            kubectl get secret ngc-secret -n "$NAMESPACE" &>/dev/null || log_error "NGC secret not found"
            
            return 1
        fi
    done
    
    log_success "No image pull issues detected"
}

troubleshoot_service() {
    log_info "Checking service configuration..."
    
    if ! kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_error "Service not found"
        return 1
    fi
    
    echo ""
    kubectl describe svc "$RELEASE_NAME" -n "$NAMESPACE"
    
    local svc_type
    svc_type=$(kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.type}')
    
    if [[ "$svc_type" == "LoadBalancer" ]]; then
        local external_ip
        external_ip=$(get_service_external_ip "$RELEASE_NAME" "$NAMESPACE")
        
        if [[ -z "$external_ip" ]]; then
            log_warn "LoadBalancer IP not assigned yet"
            log_info "Check LoadBalancer events:"
            kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name="$RELEASE_NAME" --sort-by='.lastTimestamp'
        else
            log_info "Testing endpoint connectivity..."
            if timeout 10 curl -sf "http://${external_ip}:8000/v1/health/ready" &>/dev/null; then
                log_success "Endpoint is reachable and healthy"
            else
                log_warn "Endpoint not responding (may still be starting)"
            fi
        fi
    fi
}

troubleshoot_storage() {
    log_info "Checking storage..."
    
    local pvcs
    pvcs=$(kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null || echo "")
    
    if [[ -z "$pvcs" ]]; then
        log_warn "No PVCs found (model caching may not be configured)"
        return 0
    fi
    
    echo "$pvcs" | while read -r line; do
        local pvc_name
        pvc_name=$(echo "$line" | awk '{print $1}')
        local status
        status=$(echo "$line" | awk '{print $2}')
        
        echo ""
        echo "PVC: $pvc_name"
        echo "Status: $status"
        
        if [[ "$status" != "Bound" ]]; then
            log_warn "PVC not bound, checking details..."
            kubectl describe pvc "$pvc_name" -n "$NAMESPACE"
        fi
    done
}

troubleshoot_resources() {
    log_info "Checking resource allocation..."
    
    echo ""
    echo "=== Node Resources ==="
    kubectl top nodes || log_warn "Metrics server not available"
    
    echo ""
    echo "=== Pod Resources ==="
    kubectl top pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim || log_warn "Metrics server not available"
    
    echo ""
    echo "=== Resource Requests/Limits ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{range .items[*]}{.metadata.name}{"\n  CPU Request: "}{.spec.containers[0].resources.requests.cpu}{"\n  CPU Limit: "}{.spec.containers[0].resources.limits.cpu}{"\n  Memory Request: "}{.spec.containers[0].resources.requests.memory}{"\n  Memory Limit: "}{.spec.containers[0].resources.limits.memory}{"\n  GPU Request: "}{.spec.containers[0].resources.requests.nvidia\.com/gpu}{"\n\n"}{end}'
}

troubleshoot_logs() {
    log_info "Collecting recent logs..."
    
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$pods" ]]; then
        log_warn "No pods to collect logs from"
        return 1
    fi
    
    for pod in $pods; do
        echo ""
        echo "=== Logs from $pod (last 100 lines) ==="
        kubectl logs "$pod" -n "$NAMESPACE" --tail=100 || echo "Unable to get logs"
    done
}

troubleshoot_network() {
    log_info "Checking network connectivity..."
    
    local pods
    pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$pods" ]]; then
        log_warn "No pod available for network test"
        return 1
    fi
    
    log_info "Testing DNS resolution from pod..."
    if kubectl exec "$pods" -n "$NAMESPACE" -- nslookup kubernetes.default &>/dev/null; then
        log_success "DNS resolution working"
    else
        log_warn "DNS resolution may have issues"
    fi
}

main() {
    log_info "Running troubleshooting diagnostics..."
    
    # Run enhanced log analysis first
    log_info "Running enhanced log analysis..."
    if "${SCRIPT_DIR}/log-analyzer.sh" "$NAMESPACE"; then
        log_success "Log analysis completed - check /tmp/nim-logs/troubleshooting-report.md"
    else
        log_warn "Log analysis encountered issues, continuing with manual troubleshooting"
    fi
    
    # Quick diagnostic first
    quick_diagnostic
    
    echo ""
    echo "=== PARALLEL DIAGNOSTICS ==="
    
    # Run parallel diagnostics for faster results
    log_info "Running parallel diagnostic checks..."
    
    troubleshoot_pods > "/tmp/nimble-oke-troubleshoot-pods-$$.txt" &
    local pods_pid=$!
    
    troubleshoot_gpu > "/tmp/nimble-oke-troubleshoot-gpu-$$.txt" &
    local gpu_pid=$!
    
    troubleshoot_image_pull > "/tmp/nimble-oke-troubleshoot-image-$$.txt" &
    local image_pid=$!
    
    troubleshoot_service > "/tmp/nimble-oke-troubleshoot-service-$$.txt" &
    local service_pid=$!
    
    troubleshoot_storage > "/tmp/nimble-oke-troubleshoot-storage-$$.txt" &
    local storage_pid=$!
    
    troubleshoot_resources > "/tmp/nimble-oke-troubleshoot-resources-$$.txt" &
    local resources_pid=$!
    
    troubleshoot_network > "/tmp/nimble-oke-troubleshoot-network-$$.txt" &
    local network_pid=$!
    
    # Wait for all diagnostics to complete
    wait $pods_pid $gpu_pid $image_pid $service_pid $storage_pid $resources_pid $network_pid
    
    # Display results
    echo ""
    echo "=== 1. Pod Status ==="
    cat "/tmp/nimble-oke-troubleshoot-pods-$$.txt"
    
    echo ""
    echo "=== 2. GPU Resources ==="
    cat "/tmp/nimble-oke-troubleshoot-gpu-$$.txt"
    
    echo ""
    echo "=== 3. Image Pull ==="
    cat "/tmp/nimble-oke-troubleshoot-image-$$.txt"
    
    echo ""
    echo "=== 4. Service ==="
    cat "/tmp/nimble-oke-troubleshoot-service-$$.txt"
    
    echo ""
    echo "=== 5. Storage ==="
    cat "/tmp/nimble-oke-troubleshoot-storage-$$.txt"
    
    echo ""
    echo "=== 6. Resource Allocation ==="
    cat "/tmp/nimble-oke-troubleshoot-resources-$$.txt"
    
    echo ""
    echo "=== 7. Network ==="
    cat "/tmp/nimble-oke-troubleshoot-network-$$.txt"
    
    echo ""
    echo "=== 8. Recent Events ==="
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -20
    
    # Cleanup temp files
    rm -f "/tmp/nimble-oke-troubleshoot-"*.txt
    
    echo ""
    log_success "Troubleshooting complete (parallel execution)"
    log_info "For detailed logs, run: kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim -f"
}

main "$@"

