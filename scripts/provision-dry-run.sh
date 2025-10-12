#!/usr/bin/env bash

# Cluster provisioning dry-run for Nimble OKE
# Simulates the entire provisioning process without creating resources

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_audit.sh"

readonly DRY_RUN=true

simulate_vcn_creation() {
    log_info "=== Simulating VCN Creation ==="
    
    local vcn_name="nimble-oke-vcn"
    local cidr_block="10.0.0.0/16"
    
    log_info "Would create VCN:"
    echo "  Name: $vcn_name"
    echo "  CIDR: $cidr_block"
    echo "  Compartment: ${OCI_COMPARTMENT_ID:0:20}..."
    echo "  Region: $OCI_REGION"
    echo "  Estimated time: 30-60 seconds"
    
    # Check if VCN with same name exists
    if oci network vcn list --compartment-id "$OCI_COMPARTMENT_ID" --region "$OCI_REGION" --query "data[?display-name=='$vcn_name']" --raw-output | grep -q "id"; then
        log_warn "⚠️  VCN with name '$vcn_name' already exists"
        echo "  Would fail: VCN name conflict"
        return 1
    else
        log_success "✅ VCN name available"
    fi
    
    return 0
}

simulate_subnet_creation() {
    log_info "=== Simulating Subnet Creation ==="
    
    local api_subnet_name="nimble-oke-api-subnet"
    local worker_subnet_name="nimble-oke-worker-subnet"
    local api_cidr="10.0.1.0/24"
    local worker_cidr="10.0.2.0/24"
    
    log_info "Would create subnets:"
    echo "  API Subnet: $api_subnet_name ($api_cidr)"
    echo "  Worker Subnet: $worker_subnet_name ($worker_cidr)"
    echo "  Estimated time: 60-90 seconds each"
    
    # Check subnet CIDR conflicts
    local existing_subnets
    existing_subnets=$(oci network subnet list --compartment-id "$OCI_COMPARTMENT_ID" --region "$OCI_REGION" --query "data[].cidr-block" --raw-output 2>/dev/null || echo "[]")
    
    if echo "$existing_subnets" | grep -q "$api_cidr\|$worker_cidr"; then
        log_warn "⚠️  CIDR conflicts detected"
        echo "  Would fail: Subnet CIDR conflict"
        return 1
    else
        log_success "✅ Subnet CIDRs available"
    fi
    
    return 0
}

simulate_oke_cluster_creation() {
    log_info "=== Simulating OKE Cluster Creation ==="
    
    local cluster_name="nimble-oke-cluster"
    local k8s_version="${K8S_VERSION:-1.29.1}"
    local cluster_type="ENHANCED"
    
    log_info "Would create OKE cluster:"
    echo "  Name: $cluster_name"
    echo "  Type: $cluster_type"
    echo "  Kubernetes Version: $k8s_version"
    echo "  Estimated time: 10-15 minutes"
    
    # Check OKE quota
    local oke_quota
    oke_quota=$(get_oke_cluster_quota 2>/dev/null || echo "0")
    
    if [[ "$oke_quota" -eq 0 ]]; then
        log_warn "⚠️  OKE cluster quota is 0"
        echo "  Would fail: Insufficient OKE quota"
        return 1
    else
        log_success "✅ OKE quota available: $oke_quota"
    fi
    
    return 0
}

simulate_gpu_node_pool_creation() {
    log_info "=== Simulating GPU Node Pool Creation ==="
    
    local node_pool_name="nimble-oke-gpu-pool"
    local gpu_shape="${GPU_SHAPE:-VM.GPU.A10.1}"
    local node_count="${NODE_COUNT:-1}"
    
    log_info "Would create GPU node pool:"
    echo "  Name: $node_pool_name"
    echo "  Shape: $gpu_shape"
    echo "  Count: $node_count"
    echo "  Estimated time: 5-10 minutes"
    
    # Check GPU quota
    local gpu_quota
    gpu_quota=$(get_gpu_service_limit "$gpu_shape" 2>/dev/null || echo "0")
    
    if [[ "$gpu_quota" -eq 0 ]]; then
        log_error "❌ GPU quota is 0 for shape $gpu_shape"
        echo "  Would fail: Insufficient GPU quota"
        echo "  Solution: Request quota increase in OCI Console"
        return 1
    else
        log_success "✅ GPU quota available: $gpu_quota"
    fi
    
    # Check GPU image availability
    local gpu_image_id
    gpu_image_id=$(get_latest_gpu_image "$gpu_shape" 2>/dev/null || echo "")
    
    if [[ -z "$gpu_image_id" ]]; then
        log_warn "⚠️  No GPU-enabled image found for $gpu_shape"
        echo "  Would fail: No compatible GPU image"
        return 1
    else
        log_success "✅ GPU image available: ${gpu_image_id:0:20}..."
    fi
    
    return 0
}

simulate_cost_estimation() {
    log_info "=== Simulating Cost Estimation ==="
    
    local duration="${DURATION:-5}"
    local gpu_count="${NODE_COUNT:-1}"
    
    local estimated_cost
    estimated_cost=$(estimate_deployment_cost "$duration")
    
    log_info "Estimated costs:"
    echo "  Duration: ${duration} hours"
    echo "  GPU Count: $gpu_count"
    echo "  Total Cost: \$$(format_cost "$estimated_cost")"
    
    # Check budget
    local daily_budget="${DAILY_BUDGET_USD:-50}"
    local budget_percentage
    budget_percentage=$(echo "scale=1; ($estimated_cost / $daily_budget) * 100" | bc -l)
    
    if (( $(echo "$budget_percentage > 125" | bc -l) )); then
        log_error "❌ Would fail: Exceeds budget by $(echo "scale=1; $budget_percentage - 100" | bc -l)%"
        return 1
    elif (( $(echo "$budget_percentage > 100" | bc -l) )); then
        log_warn "⚠️  Would exceed budget by $(echo "scale=1; $budget_percentage - 100" | bc -l)%"
    else
        log_success "✅ Within budget: $(printf "%.1f" "$budget_percentage")%"
    fi
    
    return 0
}

generate_provisioning_report() {
    echo ""
    echo "==============================================================="
    echo "CLUSTER PROVISIONING DRY-RUN REPORT"
    echo "==============================================================="
    echo ""
    echo "Configuration:"
    echo "  Region: $OCI_REGION"
    echo "  Compartment: ${OCI_COMPARTMENT_ID:0:20}..."
    echo "  GPU Shape: ${GPU_SHAPE:-VM.GPU.A10.1}"
    echo "  Node Count: ${NODE_COUNT:-1}"
    echo "  Duration: ${DURATION:-5} hours"
    echo ""
    echo "Estimated Timeline:"
    echo "  VCN Creation: 1-2 minutes"
    echo "  Subnet Creation: 2-3 minutes"
    echo "  OKE Cluster: 10-15 minutes"
    echo "  GPU Node Pool: 5-10 minutes"
    echo "  Total: 18-30 minutes"
    echo ""
    echo "Estimated Cost: \$$(format_cost "$(estimate_deployment_cost "${DURATION:-5}")")"
    echo ""
}

main() {
    log_info "Starting cluster provisioning dry-run..."
    echo ""
    
    local all_passed=true
    
    # Run all simulations
    simulate_vcn_creation || all_passed=false
    echo ""
    simulate_subnet_creation || all_passed=false
    echo ""
    simulate_oke_cluster_creation || all_passed=false
    echo ""
    simulate_gpu_node_pool_creation || all_passed=false
    echo ""
    simulate_cost_estimation || all_passed=false
    
    # Generate final report
    generate_provisioning_report
    
    if [[ "$all_passed" == "true" ]]; then
        log_success "✅ DRY-RUN PASSED - Ready for actual provisioning"
        echo ""
        echo "To proceed with actual provisioning:"
        echo "  make provision CONFIRM_COST=yes"
        return 0
    else
        log_error "❌ DRY-RUN FAILED - Fix issues before provisioning"
        echo ""
        echo "Common fixes:"
        echo "  1. Request GPU quota increase in OCI Console"
        echo "  2. Check for resource name conflicts"
        echo "  3. Verify budget limits"
        echo "  4. Ensure OCI permissions are sufficient"
        return 1
    fi
}

# Usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
