#!/usr/bin/env bash

# Parallel Deployment Pipeline for NVIDIA NIM on OKE
# Optimizes deployment time through parallel execution of independent operations

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly HELM_CHART_DIR="${SCRIPT_DIR}/../helm"
readonly RELEASE_NAME="nvidia-nim"
readonly NAMESPACE="default"
readonly DEPLOY_TIMEOUT=1200

# Track deployment start time for performance measurement
DEPLOY_START_TIME=$(date +%s)
# Set only when THIS run installs a new release; a failure then uninstalls it.
# An existing release is never uninstalled by this script.
DESTRUCTIVE_CLEANUP_ARMED="no"
TEMP_VALUES=""

log_info "Parallel Deployment Pipeline initialized"
log_info "Release: $RELEASE_NAME"
log_info "Namespace: $NAMESPACE"

cleanup_on_failure() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "$TEMP_VALUES" ]]; then rm -f "$TEMP_VALUES"; fi
    if [[ "$rc" -ne 0 && "$DESTRUCTIVE_CLEANUP_ARMED" == "yes" ]]; then
        log_warn "Parallel deployment failed, removing the release this run created..."
        cleanup_helm_release "$RELEASE_NAME" "$NAMESPACE" || true
        kubectl delete pvc -l "app.kubernetes.io/instance=$RELEASE_NAME" -n "$NAMESPACE" --wait=false || true
    elif [[ "$rc" -ne 0 ]]; then
        log_warn "Parallel deployment failed; this run created no release, nothing removed"
    fi
    exit "$rc"
}

# NGC key present (value never printed)
check_ngc_key_present() {
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        log_error "NGC_API_KEY: not set"
        return 1
    fi
    [[ "$NGC_API_KEY" =~ ^nvapi- ]] || log_warn "NGC_API_KEY is set but does not start with 'nvapi-'"
    log_info "NGC_API_KEY: set"
}

# Function to run parallel prerequisites
parallel_prerequisites() {
    log_info "Phase 1: Running parallel prerequisites..."
    
    local failed_checks=0
    
    # Run prerequisite checks in parallel
    (
        log_info "Checking NGC credentials..."
        check_ngc_key_present
    ) &
    local ngc_pid=$!
    
    (
        log_info "Checking GPU nodes..."
        check_gpu_available
    ) &
    local gpu_pid=$!
    
    (
        log_info "Checking cluster connectivity..."
        check_kubectl_context
    ) &
    local k8s_pid=$!
    
    (
        log_info "Validating OCI credentials..."
        check_oci_credentials
    ) &
    local oci_pid=$!
    
    # Wait for all prerequisite checks to complete
    # x=$((x + 1)), not ((x++)): ((0++)) returns 1 and set -e would exit here.
    wait "$ngc_pid" || { log_error "NGC credentials check failed"; failed_checks=$((failed_checks + 1)); }
    wait "$gpu_pid" || { log_error "GPU node check failed"; failed_checks=$((failed_checks + 1)); }
    wait "$k8s_pid" || { log_error "Kubernetes connectivity check failed"; failed_checks=$((failed_checks + 1)); }
    wait "$oci_pid" || { log_error "OCI credentials check failed"; failed_checks=$((failed_checks + 1)); }
    
    if [[ $failed_checks -gt 0 ]]; then
        log_error "Prerequisites failed: $failed_checks checks failed"
        return 1
    fi
    
    log_success "All prerequisites passed"
}

# Resource preparation.
# The chart creates its own secrets (<fullname>-ngc-registry, <fullname>-ngc-api)
# and its own PVC (<fullname>-model-cache) from values. This phase no longer
# creates a separate "ngc" pull secret (key in argv) or an unused 200Gi PVC.
parallel_resource_creation() {
    log_info "Phase 2: Preparing namespace..."

    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        kubectl create namespace "$NAMESPACE" || { log_error "Namespace creation failed"; return 1; }
    fi

    log_success "Namespace ready: $NAMESPACE"
}

# Function to deploy NIM with optimized settings
deploy_nim_optimized() {
    log_info "Phase 3: Deploying NIM with optimized settings..."
    
    # Check if model cache is available for cost optimization
    local cache_available=false
    if "${SCRIPT_DIR}/model-cache-manager.sh" check >/dev/null 2>&1; then
        cache_available=true
        log_info "Model cache available - optimizing deployment"
    else
        log_info "Model cache not available - standard deployment"
    fi
    
    # Values file holds the NGC key: private mktemp file (mode 600), never argv.
    TEMP_VALUES=$(mktemp "${TMPDIR:-/tmp}/nim-parallel-values.XXXXXX") || { log_error "mktemp failed"; return 1; }
    chmod 600 "$TEMP_VALUES"
    printf 'ngc:\n  apiKey: "%s"\n' "$NGC_API_KEY" > "$TEMP_VALUES"

    local existing_release
    existing_release=$(helm list -n "$NAMESPACE" -a -q --filter "^${RELEASE_NAME}\$") \
        || { log_error "Could not list Helm releases in namespace $NAMESPACE"; return 1; }
    if [[ -z "$existing_release" ]]; then
        DESTRUCTIVE_CLEANUP_ARMED="yes"
    else
        log_info "Release $RELEASE_NAME already exists; a failure will NOT uninstall it"
    fi

    # Deploy with Helm (chart defaults for image, resources, PVC, and probes)
    log_info "Deploying NIM with Helm (cache_available=$cache_available)..."
    helm upgrade --install "$RELEASE_NAME" "$HELM_CHART_DIR" \
        --namespace "$NAMESPACE" \
        --values "$TEMP_VALUES" \
        --wait \
        --timeout="${DEPLOY_TIMEOUT}s" \
        --atomic

    log_success "NIM deployment completed"

    rm -f "$TEMP_VALUES"
    TEMP_VALUES=""
}

# Function to verify deployment with parallel checks
verify_deployment_parallel() {
    log_info "Phase 4: Verifying deployment with parallel checks..."
    
    local failed_verifications=0
    
    # Check pod status in parallel
    (
        log_info "Checking pod status..."
        local pod_ready=false
        local attempts=0
        local max_attempts=30
        
        while [[ $attempts -lt $max_attempts ]]; do
            if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
                pod_ready=true
                break
            fi
            sleep 10
            attempts=$((attempts + 1))
        done
        
        if [[ "$pod_ready" == "true" ]]; then
            log_success "Pod is ready"
        else
            log_error "Pod failed to become ready"
            exit 1
        fi
    ) &
    local pod_pid=$!
    
    # Check service endpoints in parallel
    (
        log_info "Checking service endpoints..."
        local service_ready=false
        local attempts=0
        local max_attempts=20
        
        while [[ $attempts -lt $max_attempts ]]; do
            # Ready only when kubectl succeeds AND lists an address; a failed
            # kubectl call is not "ready".
            local ep
            if ep=$(kubectl get endpoints -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null) \
                    && [[ -n "$ep" ]] && ! echo "$ep" | grep -q "<none>"; then
                service_ready=true
                break
            fi
            sleep 5
            attempts=$((attempts + 1))
        done
        
        if [[ "$service_ready" == "true" ]]; then
            log_success "Service endpoints ready"
        else
            log_error "Service endpoints not ready"
            exit 1
        fi
    ) &
    local service_pid=$!
    
    # Check GPU allocation in parallel
    (
        log_info "Checking GPU allocation..."
        local gpu_allocated=false
        local attempts=0
        local max_attempts=15
        
        while [[ $attempts -lt $max_attempts ]]; do
            if kubectl describe pod -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim | grep -qE "nvidia.com/gpu:[[:space:]]+1"; then
                gpu_allocated=true
                break
            fi
            sleep 10
            attempts=$((attempts + 1))
        done
        
        if [[ "$gpu_allocated" == "true" ]]; then
            log_success "GPU allocated successfully"
        else
            log_error "GPU allocation failed"
            exit 1
        fi
    ) &
    local gpu_pid=$!
    
    # Wait for all verification checks to complete
    wait "$pod_pid" || { log_error "Pod verification failed"; failed_verifications=$((failed_verifications + 1)); }
    wait "$service_pid" || { log_error "Service verification failed"; failed_verifications=$((failed_verifications + 1)); }
    wait "$gpu_pid" || { log_error "GPU verification failed"; failed_verifications=$((failed_verifications + 1)); }
    
    if [[ $failed_verifications -gt 0 ]]; then
        log_error "Deployment verification failed: $failed_verifications checks failed"
        return 1
    fi
    
    log_success "All deployment verifications passed"
}

# Function to get deployment performance metrics
get_deployment_metrics() {
    local end_time
    end_time=$(date +%s)
    local total_time=$((end_time - DEPLOY_START_TIME))

    log_info "Deployment Performance Metrics:"
    log_info "  Total deployment time (measured this run): ${total_time} seconds"
    log_info "  Parallel phases: 4"

    # The baseline is a static assumption, not a measured sequential run.
    local baseline_time=2880
    local time_savings=$((baseline_time - total_time))
    local savings_percentage=$((time_savings * 100 / baseline_time))

    log_info "  Baseline (sequential): ${baseline_time} seconds - ESTIMATE (static assumption, not measured)"
    log_info "  Difference vs that baseline: ${time_savings} seconds (${savings_percentage}%) - ESTIMATE (static assumption, not measured)"
}

# Main parallel deployment function
deploy_parallel() {
    log_info "Starting parallel deployment pipeline..."
    
    trap cleanup_on_failure EXIT INT TERM
    
    # Phase 1: Parallel prerequisites
    parallel_prerequisites || die "Prerequisites failed"
    
    # Phase 2: Parallel resource creation
    parallel_resource_creation || die "Resource creation failed"
    
    # Phase 3: Optimized deployment
    deploy_nim_optimized || die "Deployment failed"
    
    # Phase 4: Parallel verification
    verify_deployment_parallel || die "Verification failed"
    
    # Performance metrics
    get_deployment_metrics
    
    # Disable cleanup trap on success
    trap - EXIT INT TERM
    
    log_success "Parallel deployment completed successfully!"
    log_info "Deployment ready for testing"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_parallel "$@"
fi
