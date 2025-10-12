#!/usr/bin/env bash

# Diagnostic helper library for Nimble OKE
# Provides enhanced error context capture and quick diagnostics

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Capture full error context
capture_error_context() {
    local phase="$1"
    local error_msg="$2"
    
    local context_file="/tmp/nimble-oke-error-context-$$.json"
    
    debug "Capturing error context for phase: $phase"
    
    # Gather context
    local pod_status=$(kubectl get pods -o json 2>/dev/null || echo "{}")
    local events=$(kubectl get events --sort-by='.lastTimestamp' -o json 2>/dev/null || echo "{}")
    local node_status=$(kubectl get nodes -o json 2>/dev/null || echo "{}")
    local service_status=$(kubectl get services -o json 2>/dev/null || echo "{}")
    local pvc_status=$(kubectl get pvc -o json 2>/dev/null || echo "{}")
    
    # Store as JSON
    jq -n \
        --arg phase "$phase" \
        --arg error "$error_msg" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson pods "$pod_status" \
        --argjson events "$events" \
        --argjson nodes "$node_status" \
        --argjson services "$service_status" \
        --argjson pvcs "$pvc_status" \
        '{
            phase: $phase,
            error: $error,
            timestamp: $timestamp,
            context: {
                pods: $pods,
                events: $events,
                nodes: $nodes,
                services: $services,
                pvcs: $pvcs
            }
        }' > "$context_file"
    
    log_info "Error context saved: $context_file"
    echo "$context_file"
}

# Quick diagnostic summary
quick_diagnostic() {
    echo ""
    echo "=== QUICK DIAGNOSTIC ==="
    
    # Pod status
    local total_pods=$(kubectl get pods --no-headers 2>/dev/null | wc -l || echo "0")
    local running_pods=$(kubectl get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    local pending_pods=$(kubectl get pods --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l || echo "0")
    local failed_pods=$(kubectl get pods --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l || echo "0")
    
    echo "Pods: $total_pods total ($running_pods running, $pending_pods pending, $failed_pods failed)"
    
    # GPU nodes
    local gpu_nodes=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l || echo "0")
    echo "GPU Nodes: $gpu_nodes"
    
    # Recent events
    echo "Recent Events:"
    kubectl get events --sort-by='.lastTimestamp' --field-selector type=Warning 2>/dev/null | tail -3 || echo "  No warning events"
    
    # Storage classes
    local default_sc=$(get_default_storage_class)
    echo "Default StorageClass: $default_sc"
    
    # NIM specific resources
    local nim_pods=$(kubectl get pods -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null | wc -l || echo "0")
    local nim_services=$(kubectl get services -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null | wc -l || echo "0")
    echo "NIM Resources: $nim_pods pods, $nim_services services"
    
    echo "======================="
    echo ""
}

# Detailed pod diagnostics
diagnose_pods() {
    local namespace="${1:-default}"
    
    echo "=== POD DIAGNOSTICS ==="
    
    # Get all pods in namespace
    kubectl get pods -n "$namespace" -o wide
    
    echo ""
    echo "--- Pod Conditions ---"
    for pod in $(kubectl get pods -n "$namespace" --no-headers -o custom-columns=":metadata.name"); do
        echo "Pod: $pod"
        kubectl describe pod "$pod" -n "$namespace" | grep -A 10 "Conditions:" || echo "  No conditions available"
        echo ""
    done
    
    echo "--- Recent Events ---"
    kubectl get events -n "$namespace" --sort-by='.lastTimestamp' | tail -10
    
    echo "===================="
}

# GPU resource diagnostics
diagnose_gpu() {
    echo "=== GPU DIAGNOSTICS ==="
    
    # Check for GPU nodes
    local gpu_nodes=$(get_gpu_nodes)
    if [[ -n "$gpu_nodes" ]]; then
        echo "GPU Nodes found:"
        for node in $gpu_nodes; do
            local capacity=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
            local allocatable=$(kubectl get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
            echo "  $node: $capacity capacity, $allocatable allocatable"
        done
    else
        echo "No GPU nodes found"
    fi
    
    echo ""
    echo "--- NVIDIA Device Plugin ---"
    kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds 2>/dev/null || echo "NVIDIA device plugin not found"
    
    echo ""
    echo "--- GPU Resource Requests ---"
    kubectl describe nodes | grep -A 5 -B 5 "nvidia.com/gpu" || echo "No GPU resource requests found"
    
    echo "===================="
}

# Storage diagnostics
diagnose_storage() {
    echo "=== STORAGE DIAGNOSTICS ==="
    
    echo "--- Storage Classes ---"
    kubectl get storageclass
    
    echo ""
    echo "--- PVC Status ---"
    kubectl get pvc -o wide
    
    echo ""
    echo "--- PV Status ---"
    kubectl get pv -o wide
    
    echo ""
    echo "--- Storage Events ---"
    kubectl get events --field-selector involvedObject.kind=PersistentVolumeClaim --sort-by='.lastTimestamp' | tail -5
    
    echo "===================="
}

# Network diagnostics
diagnose_network() {
    echo "=== NETWORK DIAGNOSTICS ==="
    
    echo "--- Services ---"
    kubectl get services -o wide
    
    echo ""
    echo "--- Endpoints ---"
    kubectl get endpoints
    
    echo ""
    echo "--- Ingress (if any) ---"
    kubectl get ingress 2>/dev/null || echo "No ingress found"
    
    echo ""
    echo "--- Network Events ---"
    kubectl get events --field-selector involvedObject.kind=Service --sort-by='.lastTimestamp' | tail -5
    
    echo "===================="
}

# Comprehensive diagnostics (parallel execution)
run_parallel_diagnostics() {
    local namespace="${1:-default}"
    
    echo "Running parallel diagnostics..."
    
    # Run diagnostics in parallel
    diagnose_pods "$namespace" > "/tmp/nimble-oke-diagnostics-pods-$$.txt" &
    local pods_pid=$!
    
    diagnose_gpu > "/tmp/nimble-oke-diagnostics-gpu-$$.txt" &
    local gpu_pid=$!
    
    diagnose_storage > "/tmp/nimble-oke-diagnostics-storage-$$.txt" &
    local storage_pid=$!
    
    diagnose_network > "/tmp/nimble-oke-diagnostics-network-$$.txt" &
    local network_pid=$!
    
    # Wait for all diagnostics to complete
    wait $pods_pid $gpu_pid $storage_pid $network_pid
    
    # Display results
    echo ""
    echo "=== DIAGNOSTIC RESULTS ==="
    
    echo ""
    cat "/tmp/nimble-oke-diagnostics-pods-$$.txt"
    echo ""
    cat "/tmp/nimble-oke-diagnostics-gpu-$$.txt"
    echo ""
    cat "/tmp/nimble-oke-diagnostics-storage-$$.txt"
    echo ""
    cat "/tmp/nimble-oke-diagnostics-network-$$.txt"
    
    # Cleanup temp files
    rm -f "/tmp/nimble-oke-diagnostics-"*.txt
    
    echo "========================="
}

# Enhanced error context with diagnostics
capture_full_context() {
    local phase="$1"
    local error_msg="$2"
    local namespace="${3:-default}"
    
    # Capture basic context
    local context_file=$(capture_error_context "$phase" "$error_msg")
    
    # Run quick diagnostic
    quick_diagnostic
    
    # Run parallel diagnostics
    run_parallel_diagnostics "$namespace"
    
    # Save diagnostics to context file
    local diagnostic_file="/tmp/nimble-oke-diagnostics-$$.txt"
    {
        echo "=== FULL DIAGNOSTIC REPORT ==="
        echo "Phase: $phase"
        echo "Error: $error_msg"
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        
        quick_diagnostic
        run_parallel_diagnostics "$namespace"
    } > "$diagnostic_file"
    
    log_info "Full diagnostic report saved: $diagnostic_file"
    echo "$diagnostic_file"
}

# Usage examples
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        "quick")
            quick_diagnostic
            ;;
        "pods")
            diagnose_pods "${2:-default}"
            ;;
        "gpu")
            diagnose_gpu
            ;;
        "storage")
            diagnose_storage
            ;;
        "network")
            diagnose_network
            ;;
        "parallel")
            run_parallel_diagnostics "${2:-default}"
            ;;
        "context")
            capture_full_context "${2:-unknown}" "${3:-unknown error}" "${4:-default}"
            ;;
        *)
            echo "Usage: $0 {quick|pods|gpu|storage|network|parallel|context}"
            echo ""
            echo "Commands:"
            echo "  quick              - Quick diagnostic summary"
            echo "  pods [namespace]   - Detailed pod diagnostics"
            echo "  gpu                - GPU resource diagnostics"
            echo "  storage            - Storage diagnostics"
            echo "  network            - Network diagnostics"
            echo "  parallel [ns]      - Run all diagnostics in parallel"
            echo "  context phase msg ns - Capture full error context"
            exit 1
            ;;
    esac
fi
