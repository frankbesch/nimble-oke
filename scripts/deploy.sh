#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly HELM_CHART_DIR="${SCRIPT_DIR}/../helm"
readonly RELEASE_NAME="nvidia-nim"
readonly NAMESPACE="default"
readonly DEPLOY_TIMEOUT=1200
readonly NIM_SELECTOR="app.kubernetes.io/instance=${RELEASE_NAME}"

# Kube context pin: provision-cluster.sh records KUBE_CONTEXT=<name> in
# cluster-info.txt. When present, every kubectl/helm call made by this script
# (including the _lib.sh helpers it calls) targets that context. The user's
# current-context is never changed. No KUBE_CONTEXT line: behaviour unchanged.
# NIMBLE_CLUSTER_INFO overrides the file path (tests only).
NIMBLE_CLUSTER_INFO="${NIMBLE_CLUSTER_INFO:-${SCRIPT_DIR}/cluster-info.txt}"
KUBE_CONTEXT_PIN=""
if [[ -f "$NIMBLE_CLUSTER_INFO" ]]; then
    KUBE_CONTEXT_PIN="$(sed -n 's/^KUBE_CONTEXT=//p' "$NIMBLE_CLUSTER_INFO" | tail -1)"
fi
if [[ -n "$KUBE_CONTEXT_PIN" ]]; then
    export HELM_KUBECONTEXT="$KUBE_CONTEXT_PIN"
    kubectl() { command kubectl --context "$KUBE_CONTEXT_PIN" "$@"; }
fi

# The NGC key never touches disk and never appears in argv: ngc_values_yaml
# prints it with the printf builtin into a pipe, and helm reads that pipe as
# a values file (-f -). All non-secret settings come from helm/values.yaml.
#
# Exit-time state. Destructive cleanup runs only when ARMED (this run is
# installing a release that did not exist before); an existing release is
# never uninstalled. INSTALL_ATTEMPTED gates the failure diagnostics.
DESTRUCTIVE_CLEANUP_ARMED="no"
INSTALL_ATTEMPTED="no"

ngc_values_yaml() {
    local k="$NGC_API_KEY"
    k="${k//\\/\\\\}"
    k="${k//\"/\\\"}"
    printf 'ngc:\n  apiKey: "%s"\n' "$k"
}

# Failure evidence, printed to stdout (the runner logs it) BEFORE any
# uninstall or PVC delete. Never reads Secrets: no describe/get secret, and
# pod descriptions show only the secretKeyRef, not its value.
capture_failure_diagnostics() {
    echo "===== NIM FAILURE DIAGNOSTICS $(date -u +%FT%TZ) (captured before cleanup) ====="
    echo "--- kubectl get pods -o wide ---"
    kubectl get pods -n "$NAMESPACE" -o wide 2>&1 || true
    echo "--- kubectl describe pod -l ${NIM_SELECTOR} ---"
    kubectl describe pod -n "$NAMESPACE" -l "$NIM_SELECTOR" 2>&1 || true
    echo "--- kubectl get events (last 50 by lastTimestamp) ---"
    kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp 2>&1 | tail -50 || true
    echo "--- kubectl logs --tail=200 ---"
    kubectl logs -n "$NAMESPACE" -l "$NIM_SELECTOR" --all-containers --tail=200 2>&1 \
        || echo "(no current logs)"
    echo "--- kubectl logs --previous --tail=200 ---"
    kubectl logs -n "$NAMESPACE" -l "$NIM_SELECTOR" --all-containers --previous --tail=200 2>&1 \
        || echo "(no previous container logs)"
    echo "--- node allocatable / taints ---"
    kubectl get nodes -o 'custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory,EPHEMERAL:.status.allocatable.ephemeral-storage,TAINTS:.spec.taints[*].key' 2>&1 || true
    echo "--- kubectl describe nodes (GPU nodes: taints, allocatable, allocated) ---"
    local n
    for n in $(get_gpu_nodes); do
        kubectl describe node "$n" 2>&1 \
            | sed -n '/^Name:/p;/^Taints:/,/^Unschedulable:/p;/^Allocatable:/,/^System Info:/p;/^Allocated resources:/,/^Events:/p' \
            || true
    done
    echo "--- kubectl get pvc ---"
    kubectl get pvc -n "$NAMESPACE" 2>&1 || true
    echo "===== END NIM FAILURE DIAGNOSTICS ====="
}

cleanup_on_failure() {
    log_warn "Deployment failed, removing the release this run created..."
    cleanup_helm_release "$RELEASE_NAME" "$NAMESPACE" || true
    kubectl delete pvc -l "$NIM_SELECTOR" -n "$NAMESPACE" --wait=false || true
}

on_exit() {
    local rc=$?
    set +e
    trap '' INT TERM
    if [[ $rc -ne 0 && "$INSTALL_ATTEMPTED" == "yes" ]]; then
        INSTALL_ATTEMPTED="no"
        capture_failure_diagnostics
    fi
    if [[ $rc -ne 0 && "$DESTRUCTIVE_CLEANUP_ARMED" == "yes" ]]; then
        DESTRUCTIVE_CLEANUP_ARMED="no"
        cleanup_on_failure
    fi
    exit "$rc"
}

main() {
    log_info "Starting NIM deployment..."
    
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    
    log_info "Running prerequisites check..."
    if ! "${SCRIPT_DIR}/prereqs.sh"; then
        die "Prerequisites not met, aborting deployment"
    fi
    
    # Check model cache for cost optimization
    log_info "Checking model cache for cost optimization..."
    if "${SCRIPT_DIR}/model-cache-manager.sh" check; then
        log_success "Model cache hit - model download skipped"
    else
        log_info "Model cache miss - model download required (adds startup time on billed GPU hours)"
    fi
    
    log_info "Estimating deployment cost..."
    local estimated_cost
    estimated_cost=$(estimate_deployment_cost 5)
    log_info "Estimated cost for 5-hour deployment: \$$(format_cost "$estimated_cost")"
    
    cost_guard "$(format_cost "$estimated_cost")" "NIM deployment"
    
    log_info "Validating NGC credentials..."
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        die "NGC_API_KEY not set"
    fi
    validate_ngc_api_key "$NGC_API_KEY"
    
    # CRITICAL: OCI CLI validation based on 2025-10-19 learnings
    log_info "Validating OCI CLI configuration..."
    check_oci_credentials
    log_success "OCI CLI authentication verified"
    
    # CRITICAL: Check for active OKE cluster in the project compartment
    log_info "Checking for active OKE cluster..."
    check_env_var OCI_COMPARTMENT_ID
    local active_json active_count
    active_json=$(oci ce cluster list \
        --compartment-id "$OCI_COMPARTMENT_ID" \
        --lifecycle-state ACTIVE \
        --query 'data[].id') || die "Failed to list OKE clusters in compartment $OCI_COMPARTMENT_ID"
    active_count=$(printf '%s' "${active_json:-[]}" | jq 'length') || die "Unparseable cluster list output"
    if [[ "$active_count" == "0" ]]; then
        log_warn "⚠️  No active OKE cluster found"
        log_warn "   Create cluster first using: scripts/provision-cluster.sh"
        log_warn "   Or use OCI Console: Container Engine → Clusters"
        die "No active OKE cluster available"
    fi
    log_success "Active OKE cluster found"
    
    log_info "Checking GPU availability..."
    check_gpu_available || die "No GPU nodes available"
    
    log_info "Creating namespace if needed..."
    create_namespace_if_missing "$NAMESPACE"
    
    log_info "Validating Helm chart..."
    if [[ ! -f "${HELM_CHART_DIR}/Chart.yaml" ]]; then
        die "Helm chart not found at ${HELM_CHART_DIR}"
    fi
    
    if [[ ! -f "${HELM_CHART_DIR}/values.yaml" ]]; then
        die "Helm values.yaml not found at ${HELM_CHART_DIR}"
    fi
    
    log_info "Running pre-deployment safety checks..."
    
    # CRITICAL: Disk usage check to prevent disk pressure
    log_info "Checking node disk usage..."
    local disk_usage
    disk_usage=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="DiskPressure")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$disk_usage" == "True" ]]; then
        log_error "🚨 DISK PRESSURE DETECTED - Deployment blocked"
        log_error "   Node has disk pressure, will cause pod evictions"
        die "Disk pressure detected on node"
    fi
    log_success "Disk usage check passed"
    
    # CRITICAL: Dry run validation to prevent catastrophic failures
    log_info "Validating deployment with dry-run..."
    # stdout discarded: the rendered Secrets hold the NGC key.
    if ! ngc_values_yaml | helm upgrade --install "$RELEASE_NAME" "$HELM_CHART_DIR" \
        -n "$NAMESPACE" \
        -f "${HELM_CHART_DIR}/values.yaml" \
        -f - \
        --dry-run \
        --timeout 60s >/dev/null; then
        log_error "🚨 DRY RUN FAILED - Deployment blocked for safety"
        log_error "   Fix configuration issues before proceeding"
        die "Dry run validation failed"
    fi
    log_success "Dry run validation passed"
    
    local existing_release
    existing_release=$(helm list -n "$NAMESPACE" -a -q --filter "^${RELEASE_NAME}\$") \
        || die "Could not list Helm releases in namespace $NAMESPACE"
    if [[ -z "$existing_release" ]]; then
        # New release: on failure from here on, remove what this run created.
        DESTRUCTIVE_CLEANUP_ARMED="yes"
    else
        log_info "Release $RELEASE_NAME already exists; a failure will NOT uninstall it"
    fi
    
    log_info "Deploying NIM with Helm (waits up to ${DEPLOY_TIMEOUT}s)..."
    INSTALL_ATTEMPTED="yes"
    ngc_values_yaml | helm upgrade --install "$RELEASE_NAME" "$HELM_CHART_DIR" \
        -n "$NAMESPACE" \
        -f "${HELM_CHART_DIR}/values.yaml" \
        -f - \
        --wait \
        --timeout "${DEPLOY_TIMEOUT}s"
    
    log_info "Waiting for pods to be ready..."
    
    # CRITICAL: Monitor pod count to detect rolling update issues
    local pod_count
    pod_count=$(kubectl get pods -n "$NAMESPACE" -l "$NIM_SELECTOR" --no-headers | wc -l)
    log_info "Initial pod count: $pod_count"
    
    if [[ "$pod_count" -gt 1 ]]; then
        log_warn "⚠️  Multiple pods detected (expected: 1)"
        log_warn "   This may indicate rolling update issues"
        log_warn "   Previous session: 2,582+ pods created"
        
        # Emergency stop if too many pods
        if [[ "$pod_count" -gt 5 ]]; then
            log_error "🚨 EMERGENCY: Too many pods created ($pod_count)"
            if [[ "$DESTRUCTIVE_CLEANUP_ARMED" == "yes" ]]; then
                log_error "   Removing the release this run created to prevent cost escalation"
                die "Emergency cleanup initiated - too many pods created"
            fi
            log_error "   Release existed before this run; not uninstalling it automatically"
            die "Too many pods - inspect and run 'make cleanup' if needed"
        fi
    fi
    
    if ! wait_for_pod_ready "$NIM_SELECTOR" "$NAMESPACE" "$DEPLOY_TIMEOUT"; then
        log_error "Pods failed to become ready"
        log_info "Checking pod status..."
        kubectl get pods -n "$NAMESPACE" -l "$NIM_SELECTOR"
        
        # Check for pod eviction issues
        local evicted_pods
        evicted_pods=$(kubectl get pods -n "$NAMESPACE" -l "$NIM_SELECTOR" --no-headers | grep -c "Evicted" || true)
        if [[ "$evicted_pods" -gt 0 ]]; then
            log_error "🚨 Pod eviction detected ($evicted_pods pods)"
            log_error "   This may indicate disk pressure issues"
            log_error "   Check node disk usage and boot volume size"
        fi
        
        log_info "Recent logs:"
        get_pod_logs "$NIM_SELECTOR" "$NAMESPACE" 50
        die "Deployment failed - pods not ready"
    fi
    
    log_info "Checking service..."
    if kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
        local svc_type
        svc_type=$(kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.type}')
        log_info "Service type: $svc_type"
        
        if [[ "$svc_type" == "LoadBalancer" ]]; then
            log_info "Waiting for LoadBalancer IP..."
            local retries=0
            local max_retries=30
            local external_ip=""
            
            while [[ $retries -lt $max_retries ]]; do
                external_ip=$(get_service_external_ip "$RELEASE_NAME" "$NAMESPACE")
                if [[ -n "$external_ip" ]]; then
                    break
                fi
                sleep 10
                retries=$((retries + 1))
            done
            
            if [[ -n "$external_ip" ]]; then
                log_success "External IP assigned: $external_ip"
                echo "export NIM_ENDPOINT=http://${external_ip}:8000" > "${SCRIPT_DIR}/.nim-endpoint"
            else
                log_warn "LoadBalancer IP not assigned yet (may take a few more minutes)"
            fi
        fi
    fi
    
    DESTRUCTIVE_CLEANUP_ARMED="no"
    INSTALL_ATTEMPTED="no"
    
    log_info "Recording deployment timestamp for cost tracking..."
    date +%s > "${SCRIPT_DIR}/.nim-deployed-at"
    
    echo ""
    log_success "Deployment complete!"
    log_info "Run 'make verify' to check health"
    log_info "Run 'make operate' for operational commands"
    log_info "IMPORTANT: Only 'make teardown' stops GPU billing (it deletes the node pool and cluster)."
    log_info "           'make cleanup' removes the NIM deployment only; GPU nodes keep billing."
}

main "$@"

