#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

main() {
    log_info "Discovering OKE cluster state..."
    
    check_kubectl_context || die "kubectl not configured"
    
    echo ""
    echo "=== Cluster Information ==="
    echo "Kubernetes Version: $(get_cluster_info version)"
    echo "Total Nodes: $(get_cluster_info nodes)"
    echo "GPU Nodes: $(get_cluster_info gpu-nodes)"
    echo "Default StorageClass: $(get_cluster_info storage-class)"
    
    echo ""
    echo "=== Node Details ==="
    kubectl get nodes -o wide 2>/dev/null || echo "Unable to get nodes"
    
    echo ""
    echo "=== GPU Resources ==="
    local gpu_nodes
    gpu_nodes=$(get_gpu_nodes)
    
    if [[ -n "$gpu_nodes" ]]; then
        for node in $gpu_nodes; do
            local gpu_capacity
            gpu_capacity=$(kubectl get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")
            local gpu_allocatable
            gpu_allocatable=$(kubectl get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
            echo "Node: $node"
            echo "  Capacity: $gpu_capacity GPU(s)"
            echo "  Allocatable: $gpu_allocatable GPU(s)"
        done
    else
        echo "No GPU nodes found"
    fi
    
    echo ""
    echo "=== Storage Classes ==="
    kubectl get storageclass 2>/dev/null || echo "Unable to get storage classes"
    
    echo ""
    echo "=== NVIDIA Device Plugin ==="
    if kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds &>/dev/null; then
        kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds
        echo "Status: Installed"
    else
        echo "Status: Not installed"
    fi
    
    echo ""
    echo "=== Existing NIM Deployments ==="
    if kubectl get deployments -A -l app.kubernetes.io/name=nvidia-nim &>/dev/null; then
        kubectl get deployments -A -l app.kubernetes.io/name=nvidia-nim
    else
        echo "No NIM deployments found"
    fi
    
    echo ""
    echo "=== Existing NIM Pods ==="
    if kubectl get pods -A -l app.kubernetes.io/name=nvidia-nim &>/dev/null; then
        kubectl get pods -A -l app.kubernetes.io/name=nvidia-nim -o wide
    else
        echo "No NIM pods found"
    fi
    
    echo ""
    echo "=== Services ==="
    if kubectl get svc -A -l app.kubernetes.io/name=nvidia-nim &>/dev/null; then
        kubectl get svc -A -l app.kubernetes.io/name=nvidia-nim
    else
        echo "No NIM services found"
    fi
    
    echo ""
    echo "=== Cost Estimation ==="
    # get_gpu_count counts GPU NODES. Rates come from _lib.sh for the node
    # shape (read from the node label, else GPU_SHAPE, else VM.GPU.A10.1).
    local node_count shape hourly_cost
    node_count=$(get_gpu_count)
    shape="${GPU_SHAPE:-$NIM_DEFAULT_GPU_SHAPE}"
    if [[ "$node_count" != "0" ]]; then
        local first_node label_shape
        first_node=$(get_gpu_nodes | awk '{print $1}')
        label_shape=$(kubectl get node "$first_node" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || true)
        [[ -n "$label_shape" ]] && shape="$label_shape"
    fi

    local shown_nodes="$node_count"
    [[ "$node_count" == "0" ]] && shown_nodes=1
    if hourly_cost=$(estimate_hourly_cost "$shown_nodes" "$shape" 2>/dev/null); then
        if [[ "$node_count" != "0" ]]; then
            echo "Estimated cluster cost ($node_count x $shape, rates from _lib.sh):"
        else
            echo "No GPU nodes currently provisioned"
            echo "Estimated cost for 1 x $shape (rates from _lib.sh):"
        fi
        echo "  Hourly: \$$(format_cost "$hourly_cost")"
        echo "  5-hour test: \$$(format_cost "$(echo "$hourly_cost * 5" | bc -l)")"
        echo "  Daily (if running 24/7): \$$(format_cost "$(echo "$hourly_cost * 24" | bc -l)")"
        echo "  (GPU and enhanced-cluster rates verified; LB and storage are estimates)"
    else
        echo "Shape $shape: rate not verified (no Oracle rate in _lib.sh)"
    fi
    if [[ "$node_count" != "0" ]]; then
        echo "  GPU nodes bill until 'make teardown'; 'make cleanup' removes only the NIM release."
    fi
    
    echo ""
    echo "=== Pod Count Monitoring ==="
    local pod_count
    pod_count=$(kubectl get pods -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null | wc -l || echo "0")
    echo "Current NIM pods: $pod_count"
    
    if [[ "$pod_count" -gt 1 ]]; then
        echo "⚠️  WARNING: Multiple pods detected (expected: 1)"
        echo "   This may indicate rolling update issues"
    fi
    
    echo ""
    log_success "Discovery complete"
}

main "$@"

