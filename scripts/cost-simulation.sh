#!/usr/bin/env bash

# Cost simulation and budget validation for Nimble OKE
# Provides detailed cost breakdown and budget analysis

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly DEFAULT_DURATION=5
readonly DEFAULT_GPU_COUNT=1
readonly DEFAULT_GPU_SHAPE="VM.GPU.A10.1"

show_cost_breakdown() {
    local duration="${1:-$DEFAULT_DURATION}"
    local gpu_count="${2:-$DEFAULT_GPU_COUNT}"
    local gpu_shape="${3:-$DEFAULT_GPU_SHAPE}"
    
    echo ""
    echo "==============================================================="
    echo "COST SIMULATION - NIMBLE OKE DEPLOYMENT"
    echo "==============================================================="
    echo ""
    echo "Configuration:"
    echo "  Duration: ${duration} hours"
    echo "  GPU Count: ${gpu_count}"
    echo "  GPU Shape: ${gpu_shape}"
    echo "  Environment: ${ENVIRONMENT:-dev}"
    echo ""
    
    # Calculate individual costs
    local gpu_hourly_rate
    gpu_hourly_rate=$(get_gpu_hourly_rate "$gpu_shape")
    local gpu_cost
    gpu_cost=$(echo "scale=2; $gpu_hourly_rate * $gpu_count * $duration" | bc -l)
    
    local oke_control_plane_cost
    oke_control_plane_cost=$(echo "scale=2; 0.10 * $duration" | bc -l)
    
    local enhanced_cluster_cost
    enhanced_cluster_cost=$(echo "scale=2; 0.10 * $duration" | bc -l)
    
    local storage_cost=1.50  # Fixed 50GB PVC cost
    
    local loadbalancer_cost
    loadbalancer_cost=$(echo "scale=2; 1.25 * $duration" | bc -l)
    
    local total_cost
    total_cost=$(echo "scale=2; $gpu_cost + $oke_control_plane_cost + $enhanced_cluster_cost + $storage_cost + $loadbalancer_cost" | bc -l)
    
    # Display cost breakdown
    echo "Cost Breakdown:"
    echo "┌─────────────────────────────────────────────────────────────┐"
    printf "│ %-35s │ $%8.2f │\n" "GPU Nodes (${gpu_count}x $gpu_shape)" "$gpu_cost"
    printf "│ %-35s │ $%8.2f │\n" "OKE Control Plane" "$oke_control_plane_cost"
    printf "│ %-35s │ $%8.2f │\n" "ENHANCED Cluster" "$enhanced_cluster_cost"
    printf "│ %-35s │ $%8.2f │\n" "Storage (50GB PVC)" "$storage_cost"
    printf "│ %-35s │ $%8.2f │\n" "Load Balancer" "$loadbalancer_cost"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│ %-35s │ $%8.2f │\n" "TOTAL" "$total_cost"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo ""
    
    # Cost per hour analysis
    local cost_per_hour
    cost_per_hour=$(echo "scale=2; $total_cost / $duration" | bc -l)
    echo "Cost Analysis:"
    echo "  Cost per hour: \$$(format_cost "$cost_per_hour")"
    echo "  Cost per GPU-hour: \$$(echo "scale=2; $total_cost / ($duration * $gpu_count)" | bc -l)"
    echo ""
    
    # Budget comparison
    local daily_budget="${DAILY_BUDGET_USD:-50}"
    local budget_percentage
    budget_percentage=$(echo "scale=1; ($total_cost / $daily_budget) * 100" | bc -l)
    
    echo "Budget Analysis:"
    echo "  Daily Budget: \$$daily_budget"
    echo "  This deployment: \$$(format_cost "$total_cost") ($(printf "%.1f" "$budget_percentage")%)"
    
    if (( $(echo "$budget_percentage > 100" | bc -l) )); then
        log_error "⚠️  Deployment exceeds daily budget!"
    elif (( $(echo "$budget_percentage > 80" | bc -l) )); then
        log_warn "⚠️  Deployment uses $(printf "%.1f" "$budget_percentage")% of daily budget"
    else
        log_success "✅ Deployment within budget limits"
    fi
    echo ""
    
    return 0
}

show_cost_scenarios() {
    echo "==============================================================="
    echo "COST SCENARIOS - NIMBLE OKE"
    echo "==============================================================="
    echo ""
    
    local scenarios=(
        "5:1:Quick smoke test"
        "10:1:Extended testing"
        "24:1:Full day testing"
        "5:3:Multi-GPU smoke test"
        "168:1:Weekly development"
        "720:1:Monthly development"
    )
    
    echo "Scenario Analysis:"
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    printf "│ %-12s │ %-8s │ %-20s │ %-12s │\n" "Duration" "GPUs" "Description" "Total Cost"
    echo "├─────────────────────────────────────────────────────────────────────────┤"
    
    for scenario in "${scenarios[@]}"; do
        IFS=':' read -r duration gpu_count description <<< "$scenario"
        
        local gpu_cost
        gpu_cost=$(echo "scale=2; 1.75 * $gpu_count * $duration" | bc -l)
        local other_costs
        other_costs=$(echo "scale=2; 0.20 * $duration + 1.50 + 1.25 * $duration" | bc -l)
        local total_cost
        total_cost=$(echo "scale=2; $gpu_cost + $other_costs" | bc -l)
        
        printf "│ %-12s │ %-8s │ %-20s │ $%-11.2f │\n" "${duration}h" "$gpu_count" "$description" "$total_cost"
    done
    
    echo "└─────────────────────────────────────────────────────────────────────────┘"
    echo ""
}

show_cost_optimization_tips() {
    echo "==============================================================="
    echo "COST OPTIMIZATION TIPS"
    echo "==============================================================="
    echo ""
    echo "1. SHORT SMOKE TESTS (Recommended):"
    echo "   • Use 5-hour deployments for quick validation"
    echo "   • Cost: ~\$11 per test"
    echo "   • Perfect for rapid iteration"
    echo ""
    echo "2. MODEL CACHE PRESERVATION:"
    echo "   • Use KEEP_CACHE=yes during cleanup"
    echo "   • Saves \$2-3 per redeployment"
    echo "   • Reduces image pull time"
    echo ""
    echo "3. BUDGET GUARDS:"
    echo "   • Set DAILY_BUDGET_USD environment variable"
    echo "   • Automatic cost validation before deployment"
    echo "   • Prevents runaway costs"
    echo ""
    echo "4. AUTOMATIC CLEANUP:"
    echo "   • Always run 'make cleanup' after testing"
    echo "   • Set up automated teardown timers"
    echo "   • Use TTL annotations for self-destruction"
    echo ""
    echo "5. ENVIRONMENT VARIABLES:"
    echo "   • ENVIRONMENT=dev (lower cost threshold)"
    echo "   • CONFIRM_COST=yes (bypass cost guards when needed)"
    echo "   • COST_THRESHOLD_USD=5 (custom threshold)"
    echo ""
    echo "6. MONITORING:"
    echo "   • Use 'make session-summary' to track costs"
    echo "   • Monitor OCI console for real-time costs"
    echo "   • Set up billing alerts in OCI"
    echo ""
}

validate_budget() {
    local estimated_cost="${1:-}"
    local daily_budget="${DAILY_BUDGET_USD:-50}"
    
    if [[ -z "$estimated_cost" ]]; then
        log_error "Estimated cost not provided"
        return 1
    fi
    
    local budget_percentage
    budget_percentage=$(echo "scale=1; ($estimated_cost / $daily_budget) * 100" | bc -l)
    
    echo ""
    echo "Budget Validation:"
    echo "  Estimated Cost: \$$(format_cost "$estimated_cost")"
    echo "  Daily Budget: \$$daily_budget"
    echo "  Usage: $(printf "%.1f" "$budget_percentage")%"
    echo ""
    
    if (( $(echo "$budget_percentage > 125" | bc -l) )); then
        log_error "❌ HARD FAIL: Deployment exceeds budget by $(echo "scale=1; $budget_percentage - 100" | bc -l)%"
        log_error "   Estimated cost: \$$(format_cost "$estimated_cost")"
        log_error "   Daily budget: \$$daily_budget"
        log_error "   Excess: \$$(echo "scale=2; $estimated_cost - $daily_budget" | bc -l)"
        return 1
    elif (( $(echo "$budget_percentage > 100" | bc -l) )); then
        log_warn "⚠️  WARNING: Deployment exceeds daily budget"
        log_warn "   Consider reducing duration or GPU count"
        return 2
    elif (( $(echo "$budget_percentage > 80" | bc -l) )); then
        log_warn "⚠️  CAUTION: Deployment uses $(printf "%.1f" "$budget_percentage")% of daily budget"
        return 0
    else
        log_success "✅ Budget validation passed"
        return 0
    fi
}

main() {
    local duration="${1:-$DEFAULT_DURATION}"
    local gpu_count="${2:-$DEFAULT_GPU_COUNT}"
    local gpu_shape="${3:-$DEFAULT_GPU_SHAPE}"
    local mode="${4:-breakdown}"
    
    case "$mode" in
        "breakdown")
            show_cost_breakdown "$duration" "$gpu_count" "$gpu_shape"
            ;;
        "scenarios")
            show_cost_scenarios
            ;;
        "optimization")
            show_cost_optimization_tips
            ;;
        "validate")
            local estimated_cost
            estimated_cost=$(estimate_deployment_cost "$duration")
            validate_budget "$estimated_cost"
            ;;
        "all")
            show_cost_breakdown "$duration" "$gpu_count" "$gpu_shape"
            echo ""
            show_cost_scenarios
            echo ""
            show_cost_optimization_tips
            ;;
        *)
            echo "Usage: $0 [duration] [gpu_count] [gpu_shape] [mode]"
            echo ""
            echo "Modes:"
            echo "  breakdown    - Show detailed cost breakdown (default)"
            echo "  scenarios    - Show cost scenarios table"
            echo "  optimization - Show cost optimization tips"
            echo "  validate     - Validate against budget"
            echo "  all          - Show all information"
            echo ""
            echo "Examples:"
            echo "  $0 5 1 VM.GPU.A10.1 breakdown"
            echo "  $0 0 0 0 scenarios"
            echo "  $0 0 0 0 optimization"
            echo "  $0 10 2 VM.GPU3.1 validate"
            return 1
            ;;
    esac
}

# Usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
