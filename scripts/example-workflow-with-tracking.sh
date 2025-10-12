#!/usr/bin/env bash

# Example workflow with comprehensive session tracking
# Demonstrates obstacle detection, cost tracking, and performance measurement

set -euo pipefail

# Source shared library
source scripts/_lib.sh

# Initialize session tracking
init_session "example-workflow"

# Example workflow phases
run_discover_phase() {
    start_phase "discover"
    
    log_info "Discovering cluster state..."
    
    # Simulate discovery with potential obstacle
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_obstacle "discover" "network-timeout" \
            "kubectl cluster-info failed" \
            "Network connectivity issue" \
            "Check firewall and kubectl configuration" \
            30 0.02
    else
        log_success "Cluster discovery successful"
    fi
    
    end_phase "discover"
}

run_prereqs_phase() {
    start_phase "prereqs"
    
    log_info "Checking prerequisites..."
    
    # Simulate prerequisite checks
    local missing_tools=()
    
    for tool in kubectl helm oci; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_obstacle "prereqs" "missing-tools" \
            "Required tools missing: ${missing_tools[*]}" \
            "Development environment not properly configured" \
            "Install missing tools: ${missing_tools[*]}" \
            60 0.05
    else
        log_success "All prerequisites met"
    fi
    
    end_phase "prereqs"
}

run_install_phase() {
    start_phase "install"
    
    log_info "Installing NIM..."
    
    # Simulate installation with potential delays
    local install_start=$(date +%s)
    
    # Simulate image pull delay
    log_info "Pulling NVIDIA NIM image..."
    sleep 2
    
    # Simulate GPU allocation delay
    if [[ $(kubectl get nodes -o json | jq -r '.items[] | select(.status.allocatable."nvidia.com/gpu" != null) | .metadata.name' | wc -l) -eq 0 ]]; then
        local delay=120
        log_obstacle "install" "gpu-allocation" \
            "No GPU nodes available for scheduling" \
            "GPU node pool not configured or nodes not ready" \
            "Provision GPU node pool or check node status" \
            "$delay" 0.10
    else
        log_success "GPU nodes available"
    fi
    
    end_phase "install"
}

run_verify_phase() {
    start_phase "verify"
    
    log_info "Verifying deployment..."
    
    # Simulate verification with potential issues
    local pods_ready=0
    local max_wait=180
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        pods_ready=$(kubectl get pods -l app=nvidia-nim --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        
        if [[ $pods_ready -gt 0 ]]; then
            log_success "NIM pods are running"
            break
        fi
        
        sleep 5
        waited=$((waited + 5))
    done
    
    if [[ $pods_ready -eq 0 ]]; then
        log_obstacle "verify" "pod-startup-timeout" \
            "NIM pods failed to start within ${max_wait}s" \
            "Pod startup timeout - likely image pull or resource issues" \
            "Check pod events and logs for startup issues" \
            "$max_wait" 0.15
    fi
    
    end_phase "verify"
}

# Main workflow execution
main() {
    log_info "Starting example workflow with session tracking..."
    
    # Run phases with automatic tracking
    run_discover_phase
    run_prereqs_phase
    run_install_phase
    run_verify_phase
    
    # Calculate final performance metrics
    local efficiency_score=$(scripts/session-tracker.sh calculate-performance 2>/dev/null || echo "0")
    
    log_success "Workflow completed with efficiency score: ${efficiency_score}%"
    
    # Generate session summary
    scripts/session-tracker.sh summary 2>/dev/null || true
    
    # Compare with previous sessions
    scripts/session-tracker.sh compare ~/.nimble-oke/sessions/current.json 2>/dev/null || true
}

# Execute main function
main "$@"
