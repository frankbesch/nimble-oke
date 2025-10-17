#!/usr/bin/env bash

# Budget Configuration for NVIDIA NIM OKE Deployment
# VM.GPU.A10.4 pricing: ~$12.44/hour

set -euo pipefail

# Budget Ranges for Different Test Scenarios
readonly BUDGET_CONFIGS=(
    "FAST:15:1:Fast test - 1 hour deployment and basic validation"
    "SHORT:25:2:Short test - 2 hours for development and testing"
    "EXTENDED:50:4:Extended test - 4 hours for comprehensive testing"
    "FULL_DAY:300:24:Full day - 24 hours for production-like testing"
    "WEEKLY:2000:168:Weekly - 7 days for extended development"
)

# Cost Breakdown (VM.GPU.A10.4)
readonly COST_BREAKDOWN=(
    "GPU_NODES:12.24:VM.GPU.A10.4 (4x NVIDIA A10 GPUs)"
    "CONTROL_PLANE:0.10:OKE Control Plane"
    "ENHANCED:0.10:Enhanced Cluster Type"
    "LOAD_BALANCER:0.01:Flexible Load Balancer (10 Mbps)"
    "STORAGE:0.05:200GB Block Volume"
    "TOTAL:12.44:Total Hourly Cost"
)

display_budget_options() {
    echo "[NIM-OKE][BUDGET] Available Budget Options:"
    echo ""
    
    for config in "${BUDGET_CONFIGS[@]}"; do
        IFS=':' read -r name budget hours description <<< "$config"
        local cost
        cost=$(echo "12.44 * $hours" | bc -l)
        printf "  %-12s: \$%-6s (%2sh) - %s\n" "$name" "$budget" "$hours" "$description"
        printf "    Actual cost: \$%.2f\n" "$cost"
        echo ""
    done
}

display_cost_breakdown() {
    echo "[NIM-OKE][COST] VM.GPU.A10.4 Cost Breakdown:"
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
    cost=$(echo "12.44 * $hours" | bc -l)
    
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

