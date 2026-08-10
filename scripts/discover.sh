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
    local gpu_count
    gpu_count=$(get_gpu_count)
    
    if [[ "$gpu_count" != "0" ]]; then
        local hourly_cost
        hourly_cost=$(estimate_hourly_cost "$gpu_count")
        local daily_cost
        daily_cost=$(echo "$hourly_cost * 24" | bc -l)
        local monthly_cost
        monthly_cost=$(echo "$hourly_cost * 24 * 30" | bc -l)
        
        echo "Current cluster cost (with $gpu_count GPU node(s)):"
        echo "  Hourly: \$$(format_cost "$hourly_cost")"
        echo "  Daily: \$$(format_cost "$daily_cost")"
        echo "  Monthly (if running 24/7): \$$(format_cost "$monthly_cost")"
        
        # Cost warning based on today's learnings
        if (( $(echo "$hourly_cost > 5" | bc -l) )); then
            echo ""
            echo "⚠️  COST WARNING: High hourly cost detected"
            echo "   Consider emergency cleanup if deployment fails"
            echo "   Previous session: 2,582+ pods created, \$20+ cost"
        fi
    else
        echo "No GPU nodes currently provisioned"
        echo "Estimated cost for VM.GPU.A10.2 (2 GPUs):"
        echo "  Hourly: \$6.62 (VM.GPU.A10.2 + 5TB boot volume)"
        echo "  5-hour test: ~\$33.10"
        echo ""
        echo "⚠️  LESSONS LEARNED:"
        echo "   - NIM requires 5TB+ boot volume for model caching"
        echo "   - Single pod strategy prevents rolling update issues"
        echo "   - Persistence disabled eliminates volume conflicts"
    fi
    
    echo ""
    echo "=== Pod Count Monitoring ==="
    local pod_count
    pod_count=$(kubectl get pods -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null | wc -l || echo "0")
    echo "Current NIM pods: $pod_count"
    
    if [[ "$pod_count" -gt 1 ]]; then
        echo "⚠️  WARNING: Multiple pods detected (expected: 1)"
        echo "   This may indicate rolling update issues"
        echo "   Previous session: 2,582+ pods created"
    fi
    
    echo ""
    log_success "Discovery complete"
}

main "$@"

