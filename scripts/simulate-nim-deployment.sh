#!/usr/bin/env bash

# NIM-specific deployment simulation for Nimble OKE
# Walks through the NIM deployment phases with failure point analysis.
#
# NOTHING HERE IS MEASURED. Every timing, size, and duration below is a
# static assumption hardcoded in this script and is labelled ESTIMATE.
# Costs are computed from the rates in scripts/_lib.sh. For measured numbers,
# use scripts/run_measured.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly EST="ESTIMATE (static assumption, not measured)"
# Deployed image (helm/values.yaml): Llama 3 8B Instruct.
readonly NIM_IMAGE="nvcr.io/nim/meta/llama3-8b-instruct:1.0.3"
readonly NIM_MODEL_ID="meta/llama3-8b-instruct"
readonly NIM_IMAGE_SIZE_GB=15  # assumption, not measured
readonly MODEL_SIZE_GB=16      # Llama 3 8B weights, assumption, not measured
readonly SIM_GPU_SHAPE="${GPU_SHAPE:-$NIM_DEFAULT_GPU_SHAPE}"

simulate_nim_image_pull() {
    log_info "=== Simulating NIM Image Pull ==="

    local bandwidth_mbps="${1:-100}"
    local region="${2:-${OCI_REGION:-us-phoenix-1}}"

    # Assumed latency from Austin, TX (not measured)
    local latency_ms
    case "$region" in
        "us-phoenix-1") latency_ms=30 ;;
        "us-ashburn-1") latency_ms=45 ;;
        "us-sanjose-1") latency_ms=35 ;;
        "us-chicago-1") latency_ms=25 ;;
        *) latency_ms=50 ;;
    esac

    # Network throughput calculation (Mbps to MB/s, assumed 80% efficiency)
    local effective_bandwidth
    effective_bandwidth=$(echo "scale=2; $bandwidth_mbps / 8 * 0.8" | bc -l)

    local image_pull_time
    image_pull_time=$(echo "scale=0; ($NIM_IMAGE_SIZE_GB * 1024) / $effective_bandwidth" | bc -l)

    # Authentication time (NGC API calls), assumed
    local auth_time=30

    local total_time
    total_time=$(echo "scale=0; $image_pull_time + $auth_time" | bc -l)

    echo "NIM Image Pull Simulation:"
    echo "  Image: $NIM_IMAGE"
    echo "  Size: ${NIM_IMAGE_SIZE_GB}GB ($EST)"
    echo "  Region: $region (${latency_ms}ms latency, $EST)"
    echo "  Bandwidth: ${bandwidth_mbps}Mbps (input)"
    echo "  Pull time: $(echo "scale=1; $total_time / 60" | bc -l) minutes - $EST"

    if [[ $total_time -gt 1800 ]]; then
        log_warn "⚠️  ESTIMATE: pull may exceed 30 min and time out"
        echo "  Mitigation: Pre-pull images or use OCIR mirror"
    elif [[ $total_time -gt 900 ]]; then
        log_warn "⚠️  ESTIMATE: pull may take 15-30 min"
        echo "  Mitigation: Consider image caching strategy"
    else
        log_info "ESTIMATE: pull under 15 min at the assumed bandwidth"
    fi

    return 0
}

simulate_model_download() {
    log_info "=== Simulating Model Download ==="

    local model_size_gb="$MODEL_SIZE_GB"
    local cache_enabled="${1:-true}"

    echo "Model Download Simulation ($EST):"
    echo "  Model: $NIM_MODEL_ID (Llama 3 8B Instruct)"
    echo "  Size: ${model_size_gb}GB ($EST)"
    if [[ "$cache_enabled" == "true" ]]; then
        echo "  Cache: Enabled (chart PVC, 100Gi)"
        echo "  First run: 5-10 minutes (download + cache) - $EST"
        echo "  Subsequent runs: 30-60 seconds (from cache) - $EST"
        log_info "Model caching is recommended (benefit not measured here)"
    else
        echo "  Cache: Disabled"
        echo "  Every run: 5-10 minutes - $EST"
        log_warn "⚠️  No caching: every run re-downloads the model"
    fi

    return 0
}

simulate_gpu_initialization() {
    log_info "=== Simulating GPU Initialization ==="

    local gpu_shape="${1:-$SIM_GPU_SHAPE}"
    local node_count="${2:-1}"

    echo "GPU Initialization Simulation:"
    echo "  Shape: $gpu_shape"
    echo "  Count: $node_count"

    local driver_load_time=120
    local cuda_init_time=60
    local plugin_startup_time=30
    local total_init_time=$((driver_load_time + cuda_init_time + plugin_startup_time))

    echo "  Driver loading: $(echo "scale=1; $driver_load_time / 60" | bc -l) minutes - $EST"
    echo "  CUDA initialization: $(echo "scale=1; $cuda_init_time / 60" | bc -l) minutes - $EST"
    echo "  Device plugin: $(echo "scale=1; $plugin_startup_time / 60" | bc -l) minutes - $EST"
    echo "  Total GPU init: $(echo "scale=1; $total_init_time / 60" | bc -l) minutes - $EST"

    # Node memory per Oracle's shape page (VM.GPU.A10.1 = 240 GB, VM.GPU.A10.2 = 480 GB)
    local required_memory=32  # GB, assumption
    local available_memory
    case "$gpu_shape" in
        "VM.GPU.A10.1") available_memory=240 ;;
        "VM.GPU.A10.2") available_memory=480 ;;
        *)
            log_warn "Node memory for $gpu_shape not known to this script; skipping memory check"
            return 0
            ;;
    esac

    if [[ $available_memory -lt $required_memory ]]; then
        log_error "❌ Insufficient memory: ${available_memory}GB < ${required_memory}GB assumed requirement"
        return 1
    fi
    log_info "Node memory ${available_memory}GB covers the assumed ${required_memory}GB requirement"

    return 0
}

simulate_loadbalancer_provisioning() {
    log_info "=== Simulating LoadBalancer Provisioning ==="

    local region="${1:-${OCI_REGION:-us-phoenix-1}}"
    local shape="flexible"

    echo "LoadBalancer Provisioning Simulation:"
    echo "  Region: $region"
    echo "  Shape: $shape (10-10 Mbps)"

    local lb_provision_time=180
    local ip_assignment_time=60
    local health_check_time=120
    local total_lb_time=$((lb_provision_time + ip_assignment_time + health_check_time))

    echo "  LB provisioning: $(echo "scale=1; $lb_provision_time / 60" | bc -l) minutes - $EST"
    echo "  IP assignment: $(echo "scale=1; $ip_assignment_time / 60" | bc -l) minutes - $EST"
    echo "  Health checks: $(echo "scale=1; $health_check_time / 60" | bc -l) minutes - $EST"
    echo "  Total LB time: $(echo "scale=1; $total_lb_time / 60" | bc -l) minutes - $EST"

    echo ""
    echo "Common LoadBalancer Issues:"
    echo "  • Missing OCI annotations → LB creation fails"
    echo "  • Insufficient quota → IP assignment fails"
    echo "  • Security list restrictions → Health check fails"
    echo "  • External traffic policy → Connection issues"

    return 0
}

simulate_nim_startup_sequence() {
    log_info "=== Simulating NIM Startup Sequence ==="

    echo "NIM Pod Startup Simulation ($EST):"
    echo ""

    local phases=(
        "Container start:30:Low"
        "NGC authentication:60:Medium"
        "Model validation:120:High"
        "GPU memory allocation:90:High"
        "NIM server startup:180:High"
        "Health check ready:60:Medium"
    )

    local total_startup_time=0

    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    printf "│ %-25s │ %-8s │ %-15s │ %-10s │\n" "Phase" "Est. time" "Risk Level" "Cumulative"
    echo "├─────────────────────────────────────────────────────────────────────────┤"

    local phase name time_seconds risk_level cumulative_minutes
    for phase in "${phases[@]}"; do
        IFS=':' read -r name time_seconds risk_level <<< "$phase"
        total_startup_time=$((total_startup_time + time_seconds))
        cumulative_minutes=$(echo "scale=1; $total_startup_time / 60" | bc -l)
        printf "│ %-25s │ %-8s │ %-15s │ %-10s │\n" "$name" "${time_seconds}s" "$risk_level" "${cumulative_minutes}min"
    done

    echo "└─────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "Total startup time: $(echo "scale=1; $total_startup_time / 60" | bc -l) minutes - $EST"

    echo ""
    echo "Startup probe sizing for that estimate:"
    echo "  initialDelaySeconds: 10"
    echo "  periodSeconds: 10"
    echo "  timeoutSeconds: 5"
    echo "  failureThreshold: $(( (total_startup_time + 9) / 10 ))  # covers ${total_startup_time}s at 10s per probe"
    echo "  (helm/values.yaml sets the probes actually deployed)"

    if [[ $total_startup_time -gt 1800 ]]; then
        log_warn "⚠️  ESTIMATE: startup over 30 min - consider optimizations"
    else
        log_info "ESTIMATE: startup under 30 min"
    fi

    return 0
}

generate_nim_deployment_timeline() {
    echo ""
    echo "==============================================================="
    echo "NIM DEPLOYMENT TIMELINE - $EST"
    echo "==============================================================="
    echo ""

    echo "Phase-by-Phase Timeline ($EST):"
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    printf "│ %-30s │ %-15s │ %-15s │\n" "Phase" "Est. min" "Est. cumulative"
    echo "├─────────────────────────────────────────────────────────────────────────┤"

    local phases=(
        "Image Pull:900"
        "GPU Node Ready:600"
        "Model Download:600"
        "NIM Startup:540"
        "LoadBalancer Ready:180"
        "Health Check Pass:60"
    )

    local phase name time_seconds total=0
    for phase in "${phases[@]}"; do
        IFS=':' read -r name time_seconds <<< "$phase"
        total=$((total + time_seconds))
        printf "│ %-30s │ %-15s │ %-15s │\n" "$name" "$(echo "scale=1; $time_seconds / 60" | bc -l)" "$(echo "scale=1; $total / 60" | bc -l)"
    done

    echo "└─────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "Total deployment time: $(echo "scale=1; $total / 60" | bc -l) minutes - $EST"

    # Cost of that estimated duration, from the _lib.sh rates.
    local hourly
    if hourly=$(estimate_hourly_cost 1 "$SIM_GPU_SHAPE"); then
        echo "Hourly cost, 1 x $SIM_GPU_SHAPE: \$$(format_cost "$hourly") (rates from _lib.sh; LB and storage are estimates)"
        echo "Cost of the estimated $(echo "scale=1; $total / 60" | bc -l) min: \$$(format_cost "$(echo "$hourly * $total / 3600" | bc -l)") - $EST duration"
    else
        echo "Hourly cost for $SIM_GPU_SHAPE: rate not verified"
    fi
    echo ""

    echo "Optimization Strategies (savings are $EST):"
    echo "  • Image pre-pulling: -15 minutes"
    echo "  • Model caching: -10 minutes (subsequent runs)"
    echo "  • OCIR mirror: -5 minutes"
    echo "  • Optimized startup probes: -2 minutes"
    echo ""
    echo "Optimized timeline: ~16 minutes with caching - $EST"
    echo ""
}

main() {
    local bandwidth="${1:-100}"
    local region="${2:-${OCI_REGION:-us-phoenix-1}}"
    local cache_enabled="${3:-true}"

    log_info "Starting NIM deployment simulation (no cloud calls; all timings are estimates)..."
    echo ""

    simulate_nim_image_pull "$bandwidth" "$region"
    echo ""
    simulate_model_download "$cache_enabled"
    echo ""
    simulate_gpu_initialization "$SIM_GPU_SHAPE" 1
    echo ""
    simulate_loadbalancer_provisioning "$region"
    echo ""
    simulate_nim_startup_sequence
    generate_nim_deployment_timeline

    log_info "NIM deployment simulation complete (estimates only, nothing measured)"
}

# Usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
