#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly HELM_CHART_DIR="${SCRIPT_DIR}/../helm"
readonly RELEASE_NAME="nvidia-nim"
readonly NAMESPACE="default"
readonly DEPLOY_TIMEOUT=1200
readonly NIM_SELECTOR="app.kubernetes.io/instance=${RELEASE_NAME}"

# Exit-time state. TEMP_VALUES holds the NGC key and is always removed.
# Destructive cleanup runs only when ARMED (this run is installing a release
# that did not exist before); an existing release is never uninstalled.
TEMP_VALUES=""
DESTRUCTIVE_CLEANUP_ARMED="no"

cleanup_on_failure() {
    log_warn "Deployment failed, removing the release this run created..."
    cleanup_helm_release "$RELEASE_NAME" "$NAMESPACE" || true
    kubectl delete pvc -l "$NIM_SELECTOR" -n "$NAMESPACE" --wait=false || true
}

on_exit() {
    local rc=$?
    set +e
    if [[ -n "$TEMP_VALUES" ]]; then
        rm -f "$TEMP_VALUES"
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
        log_success "Model cache hit - saving \$1.50 in download costs"
    else
        log_info "Model cache miss - download required (\$1.50 cost)"
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
    
    log_info "Creating temporary values file with NGC credentials..."
    TEMP_VALUES=$(mktemp "${TMPDIR:-/tmp}/nim-values.XXXXXX") || die "mktemp failed"
    chmod 600 "$TEMP_VALUES"
    local temp_values="$TEMP_VALUES"
    
    cat > "$temp_values" <<EOF
# NIM Deployment Configuration - Updated based on 2025-10-19 learnings
ngc:
  apiKey: "${NGC_API_KEY}"

image:
  pullPolicy: IfNotPresent

# CRITICAL: Single pod strategy prevents rolling update issues
replicaCount: 1

# CRITICAL: Enable persistence with 100Gi PVC for model caching
persistence:
  enabled: true
  size: 100Gi
  storageClass: oci-bv

# CRITICAL: NIM-specific resource configuration (VM.GPU.A10.2 with 2 GPUs)
resources:
  limits:
    nvidia.com/gpu: 1  # Single GPU per pod for cost optimization
    memory: 24Gi
    cpu: 8
    ephemeral-storage: 200Gi  # Updated based on 2025-10-19 learnings
  requests:
    nvidia.com/gpu: 1
    memory: 16Gi
    cpu: 4
    ephemeral-storage: 100Gi  # Updated based on 2025-10-19 learnings

# podSecurityContext and podLimiter are intentionally not overridden here;
# the chart defaults apply.

nodeSelector:
  nvidia.com/gpu.present: "true"

tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: node.kubernetes.io/disk-pressure
    operator: Exists
    effect: NoSchedule
EOF
    
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
    if ! helm upgrade --install "$RELEASE_NAME" "$HELM_CHART_DIR" \
        -n "$NAMESPACE" \
        -f "${HELM_CHART_DIR}/values.yaml" \
        -f "$temp_values" \
        --dry-run \
        --timeout 60s >/dev/null; then  # the rendered Secrets hold the NGC key
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
    
    log_info "Deploying NIM with Helm..."
    helm_install_or_upgrade \
        "$RELEASE_NAME" \
        "$HELM_CHART_DIR" \
        "$NAMESPACE" \
        -f "${HELM_CHART_DIR}/values.yaml" \
        -f "$temp_values" \
        --wait \
        --timeout "${DEPLOY_TIMEOUT}s"
    
    rm -f "$TEMP_VALUES"
    
    log_info "Waiting for pods to be ready..."
    
    # CRITICAL: Monitor pod count to detect rolling update issues
    local pod_count
    pod_count=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --no-headers | wc -l)
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
    
    if ! wait_for_pod_ready "app.kubernetes.io/name=nvidia-nim" "$NAMESPACE" "$DEPLOY_TIMEOUT"; then
        log_error "Pods failed to become ready"
        log_info "Checking pod status..."
        kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim
        
        # Check for pod eviction issues
        local evicted_pods
        evicted_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --no-headers | grep -c "Evicted" || true)
        if [[ "$evicted_pods" -gt 0 ]]; then
            log_error "🚨 Pod eviction detected ($evicted_pods pods)"
            log_error "   This may indicate disk pressure issues"
            log_error "   Check node disk usage and boot volume size"
        fi
        
        log_info "Recent logs:"
        get_pod_logs "app.kubernetes.io/name=nvidia-nim" "$NAMESPACE" 50
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

