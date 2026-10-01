#!/usr/bin/env bash

# Budget Configuration for NVIDIA NIM OKE Deployment
# All rates come from _lib.sh (single source of truth for shape and price).

set -euo pipefail

BUDGET_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F estimate_hourly_cost >/dev/null; then
    # shellcheck source=_lib.sh
    source "${BUDGET_SCRIPT_DIR}/_lib.sh"
fi

readonly BUDGET_GPU_SHAPE="${BUDGET_GPU_SHAPE:-${GPU_SHAPE:-$NIM_DEFAULT_GPU_SHAPE}}"
BUDGET_GPU_RATE=$(get_gpu_hourly_rate "$BUDGET_GPU_SHAPE")
BUDGET_GPUS_PER_NODE=$(get_shape_gpu_count "$BUDGET_GPU_SHAPE")
BUDGET_HOURLY_TOTAL=$(printf "%.4f" "$(estimate_hourly_cost 1 "$BUDGET_GPU_SHAPE")")
readonly BUDGET_GPU_RATE BUDGET_GPUS_PER_NODE BUDGET_HOURLY_TOTAL

# Budget Ranges for Different Test Scenarios
readonly BUDGET_CONFIGS=(
    "FAST:15:1:Fast test - 1 hour deployment and basic validation"
    "SHORT:25:2:Short test - 2 hours for development and testing"
    "EXTENDED:50:4:Extended test - 4 hours for comprehensive testing"
    "FULL_DAY:300:24:Full day - 24 hours for production-like testing"
    "WEEKLY:2000:168:Weekly - 7 days for extended development"
)

# Cost Breakdown (one node of $BUDGET_GPU_SHAPE)
readonly COST_BREAKDOWN=(
    "GPU_NODES:${BUDGET_GPU_RATE}:${BUDGET_GPU_SHAPE} (${BUDGET_GPUS_PER_NODE}x NVIDIA A10 GPU)"
    "ENHANCED:${NIM_ENHANCED_CLUSTER_HOURLY_USD}:OKE Enhanced Cluster (covers the control plane)"
    "LOAD_BALANCER:${NIM_LB_HOURLY_ESTIMATE_USD}:Flexible Load Balancer (estimate, unverified)"
    "STORAGE:${NIM_STORAGE_HOURLY_ESTIMATE_USD}:Block Volume (estimate, unverified)"
    "TOTAL:${BUDGET_HOURLY_TOTAL}:Total Hourly Cost"
)

display_budget_options() {
    echo "[NIM-OKE][BUDGET] Available Budget Options:"
    echo ""
    
    for config in "${BUDGET_CONFIGS[@]}"; do
        IFS=':' read -r name budget hours description <<< "$config"
        local cost
        cost=$(echo "$BUDGET_HOURLY_TOTAL * $hours" | bc -l)
        printf "  %-12s: \$%-6s (%2sh) - %s\n" "$name" "$budget" "$hours" "$description"
        printf "    Actual cost: \$%.2f\n" "$cost"
        echo ""
    done
}

display_cost_breakdown() {
    echo "[NIM-OKE][COST] ${BUDGET_GPU_SHAPE} Cost Breakdown:"
    echo ""
    
    for cost in "${COST_BREAKDOWN[@]}"; do
        IFS=':' read -r component rate description <<< "$cost"
        printf "  %-15s: \$%6s/hour - %s\n" "$component" "$rate" "$description"
    done
    echo ""
}

calculate_budget_for_duration() {
    local hours="${1:-1}"
    local cost
    cost=$(echo "$BUDGET_HOURLY_TOTAL * $hours" | bc -l)
    
    echo "[NIM-OKE][CALCULATE] Budget for $hours hour(s):"
    echo "  Estimated cost: \$$(printf "%.2f" "$cost")"
    echo "  Recommended budget: \$$(printf "%.0f" "$(echo "$cost * 1.2" | bc -l)") (20% buffer)"
    echo ""
}

get_budget_recommendation() {
    local test_type="${1:-EXTENDED}"
    
    case "$test_type" in
        "FAST")
            echo "15"
            ;;
        "SHORT")
            echo "25"
            ;;
        "EXTENDED")
            echo "50"
            ;;
        "FULL_DAY")
            echo "300"
            ;;
        "WEEKLY")
            echo "2000"
            ;;
        *)
            echo "50"  # Default to EXTENDED
            ;;
    esac
}

# Export functions
export -f display_budget_options
export -f display_cost_breakdown
export -f calculate_budget_for_duration
export -f get_budget_recommendation

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== NVIDIA NIM OKE Budget Configuration ==="
    echo ""
    display_cost_breakdown
    display_budget_options
    
    echo "Usage Examples:"
    echo "  ./budget-config.sh                    # Show all options"
    echo "  calculate_budget_for_duration 2      # Calculate for 2 hours"
    echo "  get_budget_recommendation EXTENDED    # Get recommended budget"
    echo ""
fi

