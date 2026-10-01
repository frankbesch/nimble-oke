#!/usr/bin/env bash

# Model Cache Manager for NVIDIA NIM on OKE
# Provides intelligent model caching with TTL and pre-warming capabilities

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Cache configuration
CACHE_BASE_DIR="${MODEL_CACHE_DIR:-/shared/model-cache}"
CACHE_TTL_HOURS="${MODEL_CACHE_TTL:-72}"
PREWARM_ENABLED="${PREWARM_CACHE:-no}"

# Model information
# Deployed image: nvcr.io/nim/meta/llama3-8b-instruct:1.0.3 (Llama 3 8B Instruct)
NIM_MODEL="${NIM_MODEL:-meta/llama3-8b-instruct}"
MODEL_SIZE_GB="${MODEL_SIZE_GB:-50}"

log_info "Model Cache Manager initialized"
log_info "Cache directory: $CACHE_BASE_DIR"
log_info "Cache TTL: $CACHE_TTL_HOURS hours"
log_info "Target model: $NIM_MODEL"

# Function to check if model cache exists and is fresh
check_cache_freshness() {
    local model="$1"
    local cache_dir="${CACHE_BASE_DIR}/${model}"
    
    if [[ ! -d "$cache_dir" ]]; then
        log_info "Cache directory does not exist: $cache_dir"
        return 1
    fi
    
    # A cache written by SIMULATE_DOWNLOAD=yes holds empty placeholder files.
    if [[ -f "$cache_dir/.simulated" ]]; then
        log_warn "Cache at $cache_dir is SIMULATED (empty placeholder files), not a real model cache"
        return 1
    fi

    # Check if cache is within TTL (-mmin: find's -mtime counts days, not hours)
    if find "$cache_dir" -type f -mmin -"$((CACHE_TTL_HOURS * 60))" | grep -q .; then
        log_success "Cache is fresh (within $CACHE_TTL_HOURS hours): $cache_dir"
        return 0
    else
        log_warn "Cache is stale (older than $CACHE_TTL_HOURS hours): $cache_dir"
        return 1
    fi
}

# Function to estimate cache savings
estimate_cache_savings() {
    local model="$1"
    local model_size_gb="$2"
    
    # ~2 min per GB is a static assumption; cost = that time x the hourly
    # rate from _lib.sh for GPU_SHAPE.
    local download_time_minutes=$((model_size_gb * 2))
    local hourly cost_savings
    if hourly=$(estimate_hourly_cost 1 "${GPU_SHAPE:-$NIM_DEFAULT_GPU_SHAPE}"); then
        cost_savings=$(format_cost "$(echo "$hourly * $download_time_minutes / 60" | bc -l)")
        cost_savings="\$${cost_savings}"
    else
        cost_savings="rate not verified"
    fi

    log_info "Cache hit would save (ESTIMATE (static assumption, not measured)):"
    log_info "  - Download time: ${download_time_minutes} minutes (assumes ~2 min/GB for ${model_size_gb} GB)"
    log_info "  - Cost: ${cost_savings} per re-deployment"
}

# Function to download model to cache
download_model_to_cache() {
    local model="$1"
    local cache_dir="${CACHE_BASE_DIR}/${model}"
    
    log_info "Downloading model to cache: $model"
    log_info "Cache directory: $cache_dir"
    
    # Create cache directory
    mkdir -p "$cache_dir"
    
    # Set up NGC credentials for download
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        log_error "NGC_API_KEY not set for model download"
        return 1
    fi
    
    # A real NGC download is NOT implemented. Without SIMULATE_DOWNLOAD=yes
    # this fails instead of reporting a download that did not happen.
    if [[ "${SIMULATE_DOWNLOAD:-no}" != "yes" ]]; then
        log_error "NGC model download is not implemented in this script; no files were downloaded"
        log_info "The NIM container downloads the model into its PVC on first start."
        log_info "Set SIMULATE_DOWNLOAD=yes to create placeholder files for testing only."
        return 1
    fi

    log_info "SIMULATED download: creating empty placeholder files (no model data)"
    local start_time end_time
    start_time=$(date +%s)
    sleep 10
    touch "$cache_dir/model.bin" "$cache_dir/tokenizer.json" "$cache_dir/config.json"
    touch "$cache_dir/.simulated"
    end_time=$(date +%s)

    log_warn "SIMULATED cache created in $((end_time - start_time)) seconds: $cache_dir (placeholders only)"
    
    # Set cache timestamp
    touch "$cache_dir/.cache_timestamp"
}

# Function to pre-warm cache during low-cost hours
prewarm_cache() {
    local model="$1"
    
    if [[ "$PREWARM_ENABLED" != "yes" ]]; then
        log_info "Cache pre-warming disabled"
        return 0
    fi
    
    log_info "Checking if cache pre-warming is needed for: $model"
    
    if check_cache_freshness "$model"; then
        log_info "Cache is already fresh, no pre-warming needed"
        return 0
    fi
    
    log_info "Pre-warming cache for model: $model"
    download_model_to_cache "$model"
}

# Function to clean up expired cache
cleanup_expired_cache() {
    local max_age_hours="${1:-168}"  # 7 days default
    
    log_info "Cleaning up cache older than $max_age_hours hours"
    
    if [[ -d "$CACHE_BASE_DIR" ]]; then
        # -mindepth 1 keeps the base directory; -mmin because -mtime counts days.
        find "$CACHE_BASE_DIR" -mindepth 1 -type d -mmin +"$((max_age_hours * 60))" -exec rm -rf {} + 2>/dev/null || true
        log_success "Expired cache cleanup completed"
    else
        log_info "Cache directory does not exist: $CACHE_BASE_DIR"
    fi
}

# Function to get cache statistics
get_cache_stats() {
    local cache_dir="$CACHE_BASE_DIR"
    
    if [[ ! -d "$cache_dir" ]]; then
        log_info "Cache directory does not exist: $cache_dir"
        return 0
    fi
    
    local total_size model_count oldest_cache
    total_size=$(du -sh "$cache_dir" 2>/dev/null | cut -f1 || echo "0")
    model_count=$(find "$cache_dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    oldest_cache=$(find "$cache_dir" -type f -name ".cache_timestamp" -exec ls -tr {} + 2>/dev/null | head -1 || true)
    oldest_cache="${oldest_cache:-none}"
    
    log_info "Cache Statistics:"
    log_info "  Total size: $total_size"
    log_info "  Model count: $model_count"
    log_info "  Oldest cache: $oldest_cache"
}

# Function to manage model cache (main entry point)
manage_model_cache() {
    local model="$NIM_MODEL"
    local action="${1:-check}"
    
    case "$action" in
        "check")
            log_info "Checking model cache status for: $model"
            if check_cache_freshness "$model"; then
                estimate_cache_savings "$model" "$MODEL_SIZE_GB"
                log_success "Cache hit - model ready for deployment"
                return 0
            else
                log_warn "Cache miss - model download required"
                return 1
            fi
            ;;
        "download")
            log_info "Downloading model to cache: $model"
            download_model_to_cache "$model"
            ;;
        "prewarm")
            log_info "Pre-warming cache for: $model"
            prewarm_cache "$model"
            ;;
        "cleanup")
            log_info "Cleaning up expired cache"
            cleanup_expired_cache "${2:-168}"
            ;;
        "stats")
            log_info "Getting cache statistics"
            get_cache_stats
            ;;
        *)
            log_error "Unknown action: $action"
            log_info "Available actions: check, download, prewarm, cleanup, stats"
            return 1
            ;;
    esac
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_model_cache "$@"
fi
