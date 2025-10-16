#!/usr/bin/env bash

# OKE-Optimized Configuration for NVIDIA NIM Deployment
# Based on lessons learned from deployment failures

set -euo pipefail

# OKE-Optimized Settings
readonly OKE_GPU_SHAPE="VM.GPU.A10.4"
readonly OKE_K8S_VERSION="v1.34.1"
readonly OKE_GPU_IMAGE_ID="ocid1.image.oc1.phx.aaaaaaaa2gmabafvnqzelab5ujtlqksdkbgss5w72s3gvf4so34cdic3cwpa"
readonly OKE_GPU_IMAGE_NAME="Oracle-Linux-8.10-Gen2-GPU-2025.08.31-0-OKE-1.34.1-1191"
readonly OKE_BOOT_VOLUME_SIZE_GB=200

# Cost Configuration (VM.GPU.A10.4 pricing)
readonly OKE_GPU_HOURLY_RATE="12.24"  # VM.GPU.A10.4 (4x NVIDIA A10 GPUs)
readonly OKE_CONTROL_PLANE_RATE="0.10"
readonly OKE_ENHANCED_RATE="0.10"
readonly OKE_TOTAL_HOURLY_RATE="12.44"  # Total hourly cost

# Budget Ranges for Different Test Durations
readonly BUDGET_FAST="${BUDGET_FAST:-15}"      # 1 hour test (~$12.44)
readonly BUDGET_SHORT="${BUDGET_SHORT:-25}"     # 2 hour test (~$24.88)
readonly BUDGET_EXTENDED="${BUDGET_EXTENDED:-50}" # 4 hour test (~$49.76)
readonly BUDGET_FULL_DAY="${BUDGET_FULL_DAY:-300}" # 24 hour test (~$298.56)

# Resource Configuration
readonly OKE_GPU_COUNT=4
readonly OKE_CPU_REQUEST="16"
readonly OKE_CPU_LIMIT="32"
readonly OKE_MEMORY_REQUEST="96Gi"
readonly OKE_MEMORY_LIMIT="128Gi"

# Validation Functions
validate_oke_gpu_quota() {
    local required_count="${1:-1}"
    local shape="${2:-$OKE_GPU_SHAPE}"
    
    echo "[NIM-OKE][VALIDATE] Checking GPU quota for $shape (required: $required_count)"
    
    # Check if we have sufficient GPU quota
    local available_quota
    available_quota=$(oci limits resource-availability get \
        --service-name compute \
        --limit-name gpu-a10-count \
        --compartment-id "${OCI_COMPARTMENT_ID}" \
        --region "${OCI_REGION:-us-phoenix-1}" \
        --query 'data.available' \
        --raw-output 2>/dev/null || echo "0")
    
    if [[ "$available_quota" -ge "$required_count" ]]; then
        echo "[NIM-OKE][SUCCESS] GPU quota available: $available_quota $shape"
        return 0
    else
        echo "[NIM-OKE][ERROR] GPU quota insufficient: $available_quota available, $required_count required"
        return 1
    fi
}

validate_oke_image() {
    local image_id="${1:-$OKE_GPU_IMAGE_ID}"
    
    echo "[NIM-OKE][VALIDATE] Validating OKE-optimized image: $image_id"
    
    # Check if image exists and is accessible
    if oci compute image get --image-id "$image_id" --region "${OCI_REGION:-us-phoenix-1}" &>/dev/null; then
        echo "[NIM-OKE][SUCCESS] OKE-optimized image accessible: $OKE_GPU_IMAGE_NAME"
        return 0
    else
        echo "[NIM-OKE][ERROR] OKE-optimized image not accessible: $image_id"
        return 1
    fi
}

get_oke_availability_domain() {
    local compartment_id="${1:-$OCI_COMPARTMENT_ID}"
    local region="${2:-${OCI_REGION:-us-phoenix-1}}"
    
    echo "[NIM-OKE][INFO] Getting availability domain for $region"
    
    local ad
    ad=$(oci iam availability-domain list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --query 'data[0].name' \
        --raw-output)
    
    if [[ -n "$ad" ]]; then
        echo "[NIM-OKE][SUCCESS] Availability domain: $ad"
        echo "$ad"
        return 0
    else
        echo "[NIM-OKE][ERROR] Failed to get availability domain"
        return 1
    fi
}

estimate_oke_cost() {
    local duration_hours="${1:-5}"
    local gpu_count="${2:-1}"
    
    local gpu_cost
    gpu_cost=$(echo "$OKE_GPU_HOURLY_RATE * $gpu_count" | bc -l)
    
    local total_hourly
    total_hourly=$(echo "$gpu_cost + $OKE_CONTROL_PLANE_RATE + $OKE_ENHANCED_RATE" | bc -l)
    
    local total_cost
    total_cost=$(echo "$total_hourly * $duration_hours" | bc -l)
    
    echo "[NIM-OKE][COST] VM.GPU.A10.4 Cost Estimation:"
    echo "  GPU Cost: \$$(printf "%.2f" "$gpu_cost")/hour × $gpu_count nodes (4x NVIDIA A10)"
    echo "  Control Plane: \$$(printf "%.2f" "$OKE_CONTROL_PLANE_RATE")/hour"
    echo "  Enhanced: \$$(printf "%.2f" "$OKE_ENHANCED_RATE")/hour"
    echo "  Total Hourly: \$$(printf "%.2f" "$total_hourly")/hour"
    echo "  $duration_hours-hour cost: \$$(printf "%.2f" "$total_cost")"
    echo ""
    echo "Budget Ranges:"
    echo "  Fast Test (1h): \$$(printf "%.2f" "$total_hourly")"
    echo "  Short Test (2h): \$$(printf "%.2f" "$(echo "$total_hourly * 2" | bc -l)")"
    echo "  Extended Test (4h): \$$(printf "%.2f" "$(echo "$total_hourly * 4" | bc -l)")"
    echo "  Full Day (24h): \$$(printf "%.2f" "$(echo "$total_hourly * 24" | bc -l)")"
    
    echo "$total_cost"
}

# Export functions for use in other scripts
export -f validate_oke_gpu_quota
export -f validate_oke_image
export -f get_oke_availability_domain
export -f estimate_oke_cost

# Export constants
export OKE_GPU_SHAPE
export OKE_K8S_VERSION
export OKE_GPU_IMAGE_ID
export OKE_GPU_IMAGE_NAME
export OKE_BOOT_VOLUME_SIZE_GB
export OKE_GPU_HOURLY_RATE
export OKE_CONTROL_PLANE_RATE
export OKE_ENHANCED_RATE
export OKE_GPU_COUNT
export OKE_CPU_REQUEST
export OKE_CPU_LIMIT
export OKE_MEMORY_REQUEST
export OKE_MEMORY_LIMIT
