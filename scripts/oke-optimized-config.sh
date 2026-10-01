#!/usr/bin/env bash
#
# OKE-Optimized Configuration for NVIDIA NIM Deployment.
#
# This file is a SOURCED LIBRARY, not a command: provision-cluster.sh and
# scripts/run_measured.sh `source` it. It is intentionally not executable.
# It sources scripts/_lib.sh (the single source of pricing and shape facts)
# unless the caller already did, then derives every rate, budget, and
# resource size below from OKE_GPU_SHAPE (default VM.GPU.A10.1).

set -euo pipefail

# OKE-Optimized Settings
readonly OKE_GPU_SHAPE="${OKE_GPU_SHAPE:-VM.GPU.A10.1}"
readonly OKE_K8S_VERSION="v1.34.1"
readonly OKE_GPU_IMAGE_ID="ocid1.image.oc1.phx.aaaaaaaa2gmabafvnqzelab5ujtlqksdkbgss5w72s3gvf4so34cdic3cwpa"
readonly OKE_GPU_IMAGE_NAME="Oracle-Linux-8.10-Gen2-GPU-2025.08.31-0-OKE-1.34.1-1191"
readonly OKE_BOOT_VOLUME_SIZE_GB=500

# Pricing comes from _lib.sh. Guard on a lib variable, not a function:
# exported functions reach child processes, readonly variables do not.
# Look next to this file first, then in the caller's SCRIPT_DIR (a copy of
# this file elsewhere, e.g. a test fixture, still finds the repo's _lib.sh).
if [[ -z "${NIM_A10_GPU_HOURLY_USD:-}" ]]; then
    _oke_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"
    if [[ ! -f "$_oke_lib" && -n "${SCRIPT_DIR:-}" ]]; then
        _oke_lib="${SCRIPT_DIR}/_lib.sh"
    fi
    # shellcheck source=./_lib.sh
    source "$_oke_lib"
fi

_oke_cfg_fail() {
    echo "[NIM-OKE][ERROR] oke-optimized-config.sh: $1" >&2
    return 1
}

# Cost Configuration (derived from _lib.sh for OKE_GPU_SHAPE)
_oke_gpu_count=$(get_shape_gpu_count "$OKE_GPU_SHAPE") \
    || _oke_cfg_fail "unsupported OKE_GPU_SHAPE '$OKE_GPU_SHAPE'" || return 1 2>/dev/null || exit 1
_oke_gpu_rate=$(get_gpu_hourly_rate "$OKE_GPU_SHAPE") \
    || _oke_cfg_fail "no verified rate for '$OKE_GPU_SHAPE'" || return 1 2>/dev/null || exit 1
_oke_total_rate=$(estimate_hourly_cost 1 "$OKE_GPU_SHAPE") \
    || _oke_cfg_fail "cannot estimate hourly cost for '$OKE_GPU_SHAPE'" || return 1 2>/dev/null || exit 1
readonly OKE_GPU_HOURLY_RATE="$_oke_gpu_rate"            # one node of OKE_GPU_SHAPE (A10.1 = $2.00/hr)
# The enhanced-cluster fee IS the control-plane fee ($0.10/cluster-hour, counted once).
readonly OKE_CONTROL_PLANE_RATE="$NIM_ENHANCED_CLUSTER_HOURLY_USD"
# One node + cluster fee + LB/storage ESTIMATES (see estimate_hourly_cost in _lib.sh).
OKE_TOTAL_HOURLY_RATE=$(printf "%.2f" "$_oke_total_rate")
readonly OKE_TOTAL_HOURLY_RATE

# Budget Ranges for Different Test Durations: estimated cost x 1.25 headroom,
# rounded up to whole dollars. Override any of them from the environment.
_oke_budget() {
    echo "$_oke_total_rate * $1 * 1.25" | bc -l | awk '{ c = int($1); if ($1 > c) c++; print c }'
}
readonly BUDGET_FAST="${BUDGET_FAST:-$(_oke_budget 1)}"          # 1 hour test
readonly BUDGET_SHORT="${BUDGET_SHORT:-$(_oke_budget 2)}"        # 2 hour test
readonly BUDGET_EXTENDED="${BUDGET_EXTENDED:-$(_oke_budget 4)}"  # 4 hour test
readonly BUDGET_FULL_DAY="${BUDGET_FULL_DAY:-$(_oke_budget 24)}" # 24 hour test

# Resource Configuration, sized per GPU so a pod fits its node.
# VM.GPU.A10.1 node = 15 OCPU (30 vCPU) / 240 GB; requests stay under 15 CPU
# and well under 240 GB even if CPU is read as OCPUs. Note: helm/values.yaml
# sets its own pod resources; nothing in this repo reads these four values yet.
readonly OKE_GPU_COUNT="$_oke_gpu_count"
readonly OKE_CPU_REQUEST="$((6 * _oke_gpu_count))"
readonly OKE_CPU_LIMIT="$((12 * _oke_gpu_count))"
readonly OKE_MEMORY_REQUEST="$((48 * _oke_gpu_count))Gi"
readonly OKE_MEMORY_LIMIT="$((96 * _oke_gpu_count))Gi"

# Validation Functions
validate_oke_gpu_quota() {
    local required_count="${1:-1}"
    local shape="${2:-$OKE_GPU_SHAPE}"
    
    echo "[NIM-OKE][VALIDATE] Checking GPU quota for $shape (required: $required_count)"
    
    # Get availability domain for quota check
    local ad
    ad=$(oci iam availability-domain list \
        --compartment-id "${OCI_COMPARTMENT_ID}" \
        --region "${OCI_REGION:-us-phoenix-1}" \
        --query 'data[0].name' \
        --raw-output 2>/dev/null)
    
    if [[ -z "$ad" ]]; then
        echo "[NIM-OKE][ERROR] Failed to get availability domain"
        return 1
    fi
    
    # Check if we have sufficient GPU quota
    local available_quota
    available_quota=$(oci limits resource-availability get \
        --service-name compute \
        --limit-name gpu-a10-count \
        --compartment-id "${OCI_COMPARTMENT_ID}" \
        --region "${OCI_REGION:-us-phoenix-1}" \
        --availability-domain "$ad" \
        --query 'data.available' \
        --raw-output 2>/dev/null) || {
        echo "[NIM-OKE][ERROR] GPU quota query failed (oci limits resource-availability get)"
        return 1
    }

    if ! [[ "$available_quota" =~ ^[0-9]+$ ]]; then
        echo "[NIM-OKE][ERROR] GPU quota query returned a non-numeric value: '$available_quota'"
        return 1
    fi

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
    
    # Log lines go to stderr: callers capture stdout as the AD name.
    echo "[NIM-OKE][INFO] Getting availability domain for $region" >&2
    
    local ad
    ad=$(oci iam availability-domain list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --query 'data[0].name' \
        --raw-output)
    
    if [[ -n "$ad" ]]; then
        echo "[NIM-OKE][SUCCESS] Availability domain: $ad" >&2
        echo "$ad"
        return 0
    else
        echo "[NIM-OKE][ERROR] Failed to get availability domain" >&2
        return 1
    fi
}

estimate_oke_cost() {
    local duration_hours="${1:-5}"
    local node_count="${2:-1}"

    local node_cost
    node_cost=$(echo "$OKE_GPU_HOURLY_RATE * $node_count" | bc -l)

    local total_hourly
    total_hourly=$(estimate_hourly_cost "$node_count" "$OKE_GPU_SHAPE") || return 1

    local total_cost
    total_cost=$(echo "$total_hourly * $duration_hours" | bc -l)

    # Output cost estimation to stderr (for display)
    echo "[NIM-OKE][COST] $OKE_GPU_SHAPE Cost Estimation (rates from _lib.sh):" >&2
    echo "  GPU Cost: \$$(printf "%.2f" "$OKE_GPU_HOURLY_RATE")/hour × $node_count node(s) ($OKE_GPU_COUNT x NVIDIA A10 each) = \$$(printf "%.2f" "$node_cost")/hour" >&2
    echo "  Enhanced cluster (control plane): \$$(printf "%.2f" "$OKE_CONTROL_PLANE_RATE")/hour" >&2
    echo "  System node pool (VM.Standard.E4.Flex): \$$(get_system_pool_hourly_rate)/hour" >&2
    echo "  LB + storage: ESTIMATE (unverified), included in the total" >&2
    echo "  Total Hourly: \$$(printf "%.2f" "$total_hourly")/hour" >&2
    echo "  $duration_hours-hour cost: \$$(printf "%.2f" "$total_cost")" >&2
    echo "" >&2
    echo "Budget Ranges:" >&2
    echo "  Fast Test (1h): \$$(printf "%.2f" "$total_hourly")" >&2
    echo "  Short Test (2h): \$$(printf "%.2f" "$(echo "$total_hourly * 2" | bc -l)")" >&2
    echo "  Extended Test (4h): \$$(printf "%.2f" "$(echo "$total_hourly * 4" | bc -l)")" >&2
    echo "  Full Day (24h): \$$(printf "%.2f" "$(echo "$total_hourly * 24" | bc -l)")" >&2

    # Return only the numeric cost value
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
export OKE_TOTAL_HOURLY_RATE
export BUDGET_FAST BUDGET_SHORT BUDGET_EXTENDED BUDGET_FULL_DAY
export OKE_GPU_COUNT
export OKE_CPU_REQUEST
export OKE_CPU_LIMIT
export OKE_MEMORY_REQUEST
export OKE_MEMORY_LIMIT
