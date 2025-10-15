#!/usr/bin/env bash

# GPU quota checker for Nimble OKE
# Comprehensive GPU availability check across regions and shapes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/_lib_audit.sh"

readonly DEFAULT_SHAPES=(
    "VM.GPU.A10.1"
    "VM.GPU3.1"
    "VM.GPU3.2"
    "VM.GPU3.4"
    "VM.GPU3.8"
)

check_gpu_quota_for_shape() {
    local shape="$1"
    local region="${2:-$OCI_REGION}"
    
    log_info "Checking GPU quota for $shape in $region..."
    
    # Get GPU quota
    local gpu_quota
    gpu_quota=$(get_gpu_service_limit "$shape" 2>/dev/null || echo "0")
    
    if [[ "$gpu_quota" -gt 0 ]]; then
        log_success "✅ $shape: $gpu_quota available in $region"
        echo "  Cost: \$$(get_gpu_hourly_rate "$shape")/hour"
        return 0
    else
        log_warn "⚠️  $shape: 0 quota in $region"
        return 1
    fi
}

check_gpu_quota_across_regions() {
    local shape="$1"
    local regions=("us-phoenix-1" "us-ashburn-1" "us-sanjose-1" "us-chicago-1")
    
    echo ""
    echo "GPU Quota Check: $shape"
    echo "┌─────────────────────────────────────────────────────────────┐"
    printf "│ %-20s │ %-10s │ %-15s │\n" "Region" "Quota" "Cost/Hour"
    echo "├─────────────────────────────────────────────────────────────┤"
    
    local found_available=false
    
    for region in "${regions[@]}"; do
        local gpu_quota
        gpu_quota=$(oci limits value list --compartment-id "$OCI_COMPARTMENT_ID" --service-name compute --region "$region" --all --query "data[?name=='gpu-a10-count'].value | [0]" --raw-output 2>/dev/null || echo "0")
        
        local cost_per_hour
        cost_per_hour=$(get_gpu_hourly_rate "$shape")
        
        if [[ "$gpu_quota" -gt 0 ]]; then
            printf "│ %-20s │ %-10s │ $%-14.2f │\n" "$region" "$gpu_quota" "$cost_per_hour"
            found_available=true
        else
            printf "│ %-20s │ %-10s │ $%-14.2f │\n" "$region" "0" "$cost_per_hour"
        fi
    done
    
    echo "└─────────────────────────────────────────────────────────────┘"
    
    if [[ "$found_available" == "true" ]]; then
        log_success "✅ GPU quota available in at least one region"
        return 0
    else
        log_error "❌ No GPU quota available in any region"
        return 1
    fi
}

check_gpu_image_availability() {
    local shape="$1"
    local region="${2:-$OCI_REGION}"
    
    log_info "Checking GPU image availability for $shape in $region..."
    
    local gpu_image_id
    gpu_image_id=$(get_latest_gpu_image "$shape" 2>/dev/null || echo "")
    
    if [[ -n "$gpu_image_id" ]]; then
        log_success "✅ GPU image available: ${gpu_image_id:0:20}..."
        return 0
    else
        log_warn "⚠️  No GPU image found for $shape in $region"
        return 1
    fi
}

check_oke_quota() {
    local region="${1:-$OCI_REGION}"
    
    log_info "Checking OKE cluster quota in $region..."
    
    local oke_quota
    oke_quota=$(get_oke_cluster_quota 2>/dev/null || echo "0")
    
    if [[ "$oke_quota" -gt 0 ]]; then
        log_success "✅ OKE quota available: $oke_quota"
        return 0
    else
        log_warn "⚠️  OKE quota: $oke_quota"
        return 1
    fi
}

show_quota_request_instructions() {
    echo ""
    echo "==============================================================="
    echo "HOW TO REQUEST GPU QUOTA INCREASE"
    echo "==============================================================="
    echo ""
    echo "1. Go to OCI Console → Governance → Limits, Quotas and Usage"
    echo ""
    echo "2. Select:"
    echo "   • Service: Compute"
    echo "   • Resource: GPUs for GPU.A10 based VM and BM Instances"
    echo "   • Region: Your preferred region"
    echo ""
    echo "3. Click 'Request a service limit increase'"
    echo ""
    echo "4. Fill out the form:"
    echo "   • New Limit: 1 (or more)"
    echo "   • Justification: 'Testing NVIDIA NIM AI inference on OKE'"
    echo ""
    echo "5. Submit and wait for approval (usually 2-24 hours)"
    echo ""
    echo "Alternative: Contact Oracle Support for faster approval"
    echo ""
}

main() {
    local shape="${1:-VM.GPU.A10.1}"
    local region="${2:-$OCI_REGION}"
    
    log_info "Starting GPU quota check..."
    echo ""
    
    local all_passed=true
    
    # Check OKE quota first
    check_oke_quota "$region" || all_passed=false
    echo ""
    
    # Check GPU quota for specific shape
    check_gpu_quota_for_shape "$shape" "$region" || all_passed=false
    echo ""
    
    # Check GPU image availability
    check_gpu_image_availability "$shape" "$region" || all_passed=false
    echo ""
    
    # If specific shape fails, check alternatives
    if [[ "$all_passed" != "true" ]]; then
        echo "Checking alternative GPU shapes..."
        for alt_shape in "${DEFAULT_SHAPES[@]}"; do
            if [[ "$alt_shape" != "$shape" ]]; then
                check_gpu_quota_for_shape "$alt_shape" "$region" && break
            fi
        done
        echo ""
    fi
    
    # Show cross-region analysis
    check_gpu_quota_across_regions "$shape"
    
    if [[ "$all_passed" == "true" ]]; then
        log_success "✅ GPU quota check passed - Ready for deployment"
        return 0
    else
        log_error "❌ GPU quota check failed"
        show_quota_request_instructions
        return 1
    fi
}

# Usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
