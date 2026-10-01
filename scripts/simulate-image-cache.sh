#!/usr/bin/env bash

# Image pre-caching simulation for Nimble OKE
# Estimates time and costs for image pre-caching strategies.
# NOTHING HERE IS MEASURED: sizes, bandwidths, times, and the OCIR storage
# cost are static assumptions and are printed as ESTIMATE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly EST="ESTIMATE (static assumption, not measured)"
# Deployed image (helm/values.yaml): Llama 3 8B Instruct.
readonly NIM_IMAGE="nvcr.io/nim/meta/llama3-8b-instruct:1.0.3"
readonly NIM_IMAGE_SIZE_GB=15  # assumption, not measured
readonly DEVICE_PLUGIN_IMAGE="nvcr.io/nvidia/k8s-device-plugin:v0.14.1"
readonly DEVICE_PLUGIN_SIZE_GB=0.5

simulate_image_pull_time() {
    # $1 = image reference (kept for callers; the estimate uses only size)
    local image_size_gb="$2"
    local bandwidth_mbps="${3:-100}"  # Default 100 Mbps
    
    # Convert Mbps to MB/s
    local bandwidth_mbs
    bandwidth_mbs=$(echo "scale=2; $bandwidth_mbps / 8" | bc -l)
    
    # Calculate pull time (with 20% overhead for network inefficiency)
    local pull_time_seconds
    pull_time_seconds=$(echo "scale=0; ($image_size_gb * 1024) / $bandwidth_mbs * 1.2" | bc -l)
    
    echo "$pull_time_seconds"
}

simulate_image_caching_strategies() {
    echo ""
    echo "==============================================================="
    echo "IMAGE PRE-CACHING SIMULATION - $EST"
    echo "==============================================================="
    echo ""
    
    local bandwidth_scenarios=(
        "50:Slow connection"
        "100:Standard connection"
        "200:Fast connection"
        "500:Very fast connection"
    )
    
    echo "Image Pull Time - $EST (sizes ${NIM_IMAGE_SIZE_GB}GB / ${DEVICE_PLUGIN_SIZE_GB}GB, 20% overhead):"
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    printf "│ %-20s │ %-15s │ %-15s │ %-15s │\n" "Connection Speed" "NIM Image (15GB)" "Device Plugin (0.5GB)" "Total Time"
    echo "├─────────────────────────────────────────────────────────────────────────┤"
    
    for scenario in "${bandwidth_scenarios[@]}"; do
        IFS=':' read -r bandwidth_mbps description <<< "$scenario"
        
        local nim_pull_time
        nim_pull_time=$(simulate_image_pull_time "$NIM_IMAGE" "$NIM_IMAGE_SIZE_GB" "$bandwidth_mbps")
        local device_plugin_pull_time
        device_plugin_pull_time=$(simulate_image_pull_time "$DEVICE_PLUGIN_IMAGE" "$DEVICE_PLUGIN_SIZE_GB" "$bandwidth_mbps")
        local total_time
        total_time=$(echo "scale=0; $nim_pull_time + $device_plugin_pull_time" | bc -l)
        
        # Convert to minutes
        local nim_minutes
        nim_minutes=$(echo "scale=1; $nim_pull_time / 60" | bc -l)
        local device_plugin_minutes
        device_plugin_minutes=$(echo "scale=1; $device_plugin_pull_time / 60" | bc -l)
        local total_minutes
        total_minutes=$(echo "scale=1; $total_time / 60" | bc -l)
        
        printf "│ %-20s │ %-15s │ %-15s │ %-15s │\n" "$description" "${nim_minutes}min" "${device_plugin_minutes}min" "${total_minutes}min"
    done
    
    echo "└─────────────────────────────────────────────────────────────────────────┘"
    echo ""
}

simulate_node_warmup_strategies() {
    echo "Node Warmup Strategies (times and costs are $EST):"
    echo ""
    
    echo "1. PRE-PULL STRATEGY (Recommended):"
    echo "   • Pull images during node initialization"
    echo "   • Time: +2-5 minutes to node startup"
    echo "   • Cost: No additional cost"
    echo "   • Benefit: Faster pod startup"
    echo ""
    
    echo "2. IMAGE CACHE STRATEGY:"
    echo "   • Use OCI Container Registry (OCIR)"
    echo "   • Pre-pull to OCIR during setup"
    echo "   • Time: +10-15 minutes setup"
    echo "   • Cost: ~\$0.50 for storage (unverified)"
    echo "   • Benefit: Consistent pull times"
    echo ""
    
    echo "3. NO PRE-CACHING:"
    echo "   • Pull images on first pod start"
    echo "   • Time: +3-8 minutes to first pod ready"
    echo "   • Cost: No additional cost"
    echo "   • Risk: Network-dependent startup time"
    echo ""
}

simulate_deployment_time_impact() {
    echo "Deployment Time Impact Analysis - $EST:"
    echo ""
    
    local scenarios=(
        "no_cache:No pre-caching:3-8:0"
        "pre_pull:Pre-pull on nodes:1-2:0"
        "ocir_cache:OCIR pre-cache:0.5-1:0.50"
    )
    
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    printf "│ %-15s │ %-20s │ %-15s │ %-10s │\n" "Strategy" "Description" "Extra Time" "Extra Cost"
    echo "├─────────────────────────────────────────────────────────────────────────┤"
    
    for scenario in "${scenarios[@]}"; do
        IFS=':' read -r strategy description extra_time extra_cost <<< "$scenario"
        
        printf "│ %-15s │ %-20s │ %-15s │ $%-9s │\n" "$strategy" "$description" "${extra_time}min" "$extra_cost"
    done
    
    echo "└─────────────────────────────────────────────────────────────────────────┘"
    echo ""
}

recommend_optimization_strategy() {
    echo "Recommended Optimization Strategy (times and costs are $EST):"
    echo ""
    echo "🎯 HYBRID APPROACH:"
    echo ""
    echo "1. IMMEDIATE (No additional time/cost):"
    echo "   • Enable pre-pull in node initialization"
    echo "   • Use image pull policy IfNotPresent (Always re-pulls and defeats pre-pulling)"
    echo "   • Add readiness probes with longer initial delay"
    echo ""
    echo "2. SHORT-TERM (+2-3 minutes setup):"
    echo "   • Pre-pull critical images during cluster setup"
    echo "   • Cache NVIDIA device plugin image"
    echo "   • Use image pull secrets for faster authentication"
    echo ""
    echo "3. LONG-TERM (+10 minutes, +\$0.50 unverified):"
    echo "   • Set up OCIR mirror for NIM images"
    echo "   • Implement image warming scripts"
    echo "   • Use image pre-caching in CI/CD"
    echo ""
    
    echo "Expected Results - $EST:"
    echo "  • Pod startup time: 8min → 2min"
    echo "  • Fewer network-dependent pulls at pod start (not quantified)"
    echo ""
}

main() {
    log_info "Starting image caching simulation..."
    
    simulate_image_caching_strategies
    simulate_node_warmup_strategies
    simulate_deployment_time_impact
    recommend_optimization_strategy
    
    log_info "Image caching simulation complete (estimates only, nothing measured)"
}

# Usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
