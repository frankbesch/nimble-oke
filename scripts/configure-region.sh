#!/bin/bash

# Region Configuration for Nimble OKE
# Simple script to configure OCI region and validate GPU availability

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Default region (closest to Austin, TX)
DEFAULT_REGION="us-phoenix-1"

# Supported regions with GPU availability
declare -A REGION_INFO
REGION_INFO["us-phoenix-1"]="Phoenix, AZ - Closest to Austin, TX"
REGION_INFO["us-ashburn-1"]="Ashburn, VA - East Coast"
REGION_INFO["us-sanjose-1"]="San Jose, CA - West Coast"
REGION_INFO["us-chicago-1"]="Chicago, IL - Central US (No GPU availability)"

log_info "Nimble OKE Region Configuration"

# Function to display available regions
show_available_regions() {
    log_info "Available OCI regions:"
    echo ""
    printf "%-20s %-50s\n" "Region" "Description"
    echo "────────────────────────────────────────────────────────────────"
    
    for region in "${!REGION_INFO[@]}"; do
        local description="${REGION_INFO[$region]}"
        if [[ "$region" == "$DEFAULT_REGION" ]]; then
            printf "%-20s %-50s (RECOMMENDED)\n" "$region" "$description"
        else
            printf "%-20s %-50s\n" "$region" "$description"
        fi
    done
    echo ""
}

# Function to validate region
validate_region() {
    local region="$1"
    
    if [[ -n "${REGION_INFO[$region]:-}" ]]; then
        return 0
    else
        log_error "Unsupported region: $region"
        log_info "Supported regions: ${!REGION_INFO[*]}"
        return 1
    fi
}

# Function to check GPU availability in region
check_gpu_availability() {
    local region="$1"
    
    log_info "Checking GPU availability in region: $region"
    
    # Check if region has GPU support
    case "$region" in
        "us-chicago-1")
            log_warn "⚠️  WARNING: $region does not have GPU availability"
            log_info "This region cannot be used for NVIDIA NIM deployment"
            return 1
            ;;
        *)
            log_success "✅ $region supports GPU instances"
            return 0
            ;;
    esac
}

# Function to set region
set_region() {
    local region="$1"
    
    if ! validate_region "$region"; then
        return 1
    fi
    
    # Set environment variable
    export OCI_REGION="$region"
    
    # Display region information
    local description="${REGION_INFO[$region]}"
    log_success "Region configured: $region"
    log_info "Description: $description"
    
    # Check GPU availability
    if ! check_gpu_availability "$region"; then
        log_error "Cannot use $region for NVIDIA NIM deployment"
        return 1
    fi
    
    # Save to setup-env.sh for persistence
    if [[ -f "${SCRIPT_DIR}/../setup-env.sh" ]]; then
        sed -i.bak "s/export OCI_REGION=.*/export OCI_REGION=\"$region\"/" "${SCRIPT_DIR}/../setup-env.sh"
        log_info "Region saved to setup-env.sh for persistence"
    fi
    
    return 0
}

# Function to get current region
get_current_region() {
    local current_region="${OCI_REGION:-$DEFAULT_REGION}"
    local description="${REGION_INFO[$current_region]:-Unknown region}"
    
    log_info "Current region: $current_region"
    log_info "Description: $description"
    
    if [[ "$current_region" == "us-chicago-1" ]]; then
        log_warn "⚠️  WARNING: Current region does not support GPU instances"
        return 1
    fi
    
    return 0
}

# Function to recommend best region
recommend_region() {
    log_info "Recommended region for Austin, TX location:"
    echo ""
    printf "%-20s %-30s %-20s\n" "Region" "Distance" "GPU Support"
    echo "────────────────────────────────────────────────────────────────"
    printf "%-20s %-30s %-20s\n" "us-phoenix-1" "~1,200 miles (BEST)" "✅ Yes"
    printf "%-20s %-30s %-20s\n" "us-sanjose-1" "~1,800 miles" "✅ Yes"
    printf "%-20s %-30s %-20s\n" "us-ashburn-1" "~1,400 miles" "✅ Yes"
    printf "%-20s %-30s %-20s\n" "us-chicago-1" "~1,100 miles" "❌ No GPU"
    echo ""
    log_info "Recommendation: Use us-phoenix-1 (closest with GPU support)"
}

# Main function
main() {
    local action="${1:-show}"
    
    case "$action" in
        "show")
            show_available_regions
            get_current_region
            ;;
        "set")
            local region="${2:-}"
            if [[ -z "$region" ]]; then
                log_error "Region not specified"
                log_info "Usage: $0 set <region>"
                show_available_regions
                return 1
            fi
            set_region "$region"
            ;;
        "current")
            get_current_region
            ;;
        "recommend")
            recommend_region
            ;;
        "validate")
            local region="${2:-${OCI_REGION:-$DEFAULT_REGION}}"
            validate_region "$region" && check_gpu_availability "$region"
            ;;
        *)
            log_error "Unknown action: $action"
            log_info "Available actions: show, set, current, recommend, validate"
            return 1
            ;;
    esac
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
