#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly HELM_CHART_DIR="${SCRIPT_DIR}/../helm"
readonly RELEASE_NAME="nvidia-nim"
readonly NAMESPACE="default"
readonly DEPLOY_TIMEOUT=1200

cleanup_on_failure() {
    log_warn "Deployment failed, running cleanup..."
    cleanup_helm_release "$RELEASE_NAME" "$NAMESPACE" || true
    kubectl delete pvc -l app.kubernetes.io/name=nvidia-nim -n "$NAMESPACE" --wait=false || true
}

main() {
    log_info "Starting NIM deployment..."
    
    trap cleanup_on_failure EXIT ERR INT TERM
    
    log_info "Running prerequisites check..."
    if ! "${SCRIPT_DIR}/prereqs.sh"; then
        die "Prerequisites not met, aborting deployment"
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
    local temp_values
    temp_values=$(mktemp)
    trap "rm -f $temp_values" EXIT
    
    cat > "$temp_values" <<EOF
ngc:
  apiKey: "${NGC_API_KEY}"

image:
  pullPolicy: IfNotPresent

persistence:
  enabled: true
  size: 50Gi
  storageClass: $(get_default_storage_class)

resources:
  limits:
    nvidia.com/gpu: 1
    memory: 32Gi
    cpu: 8
  requests:
    nvidia.com/gpu: 1
    memory: 24Gi
    cpu: 4

nodeSelector:
  nvidia.com/gpu.present: "true"

tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
EOF
    
    log_info "Deploying NIM with Helm..."
    helm_install_or_upgrade \
        "$RELEASE_NAME" \
        "$HELM_CHART_DIR" \
        "$NAMESPACE" \
        -f "${HELM_CHART_DIR}/values.yaml" \
        -f "$temp_values" \
        --wait \
        --timeout "${DEPLOY_TIMEOUT}s"
    
    log_info "Waiting for pods to be ready..."
    if ! wait_for_pod_ready "app.kubernetes.io/name=nvidia-nim" "$NAMESPACE" "$DEPLOY_TIMEOUT"; then
        log_error "Pods failed to become ready"
        log_info "Checking pod status..."
        kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim
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
                ((retries++))
            done
            
            if [[ -n "$external_ip" ]]; then
                log_success "External IP assigned: $external_ip"
                echo "export NIM_ENDPOINT=http://${external_ip}:8000" > "${SCRIPT_DIR}/.nim-endpoint"
            else
                log_warn "LoadBalancer IP not assigned yet (may take a few more minutes)"
            fi
        fi
    fi
    
    trap - EXIT ERR INT TERM
    
    log_info "Recording deployment timestamp for cost tracking..."
    date +%s > "${SCRIPT_DIR}/.nim-deployed-at"
    
    echo ""
    log_success "Deployment complete!"
    log_info "Run 'make verify' to check health"
    log_info "Run 'make operate' for operational commands"
    log_info "IMPORTANT: Run 'make cleanup' when finished to stop charges"
}

main "$@"

