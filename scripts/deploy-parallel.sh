#!/bin/bash

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

log_info "Parallel Deployment Pipeline initialized"
log_info "Release: $RELEASE_NAME"
log_info "Namespace: $NAMESPACE"

cleanup_on_failure() {
    log_warn "Parallel deployment failed, running cleanup..."
    cleanup_helm_release "$RELEASE_NAME" "$NAMESPACE" || true
    kubectl delete pvc -l app.kubernetes.io/name=nvidia-nim -n "$NAMESPACE" --wait=false || true
}

# Function to run parallel prerequisites
parallel_prerequisites() {
    log_info "Phase 1: Running parallel prerequisites..."
    
    local failed_checks=0
    
    # Run prerequisite checks in parallel
    (
        log_info "Checking NGC credentials..."
        check_ngc_credentials
    ) &
    local ngc_pid=$!
    
    (
        log_info "Checking GPU quota..."
        check_gpu_quota
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
    wait $ngc_pid || { log_error "NGC credentials check failed"; ((failed_checks++)); }
    wait $gpu_pid || { log_error "GPU quota check failed"; ((failed_checks++)); }
    wait $k8s_pid || { log_error "Kubernetes connectivity check failed"; ((failed_checks++)); }
    wait $oci_pid || { log_error "OCI credentials check failed"; ((failed_checks++)); }
    
    if [[ $failed_checks -gt 0 ]]; then
        log_error "Prerequisites failed: $failed_checks checks failed"
        return 1
    fi
    
    log_success "All prerequisites passed"
}

# Function to run parallel resource creation
parallel_resource_creation() {
    log_info "Phase 2: Running parallel resource creation..."
    
    # Create namespace if it doesn't exist
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - || true
    
    local failed_creations=0
    
    # Create secrets in parallel
    (
        log_info "Creating NGC secrets..."
        create_ngc_secrets
    ) &
    local secrets_pid=$!
    
    # Create PVC in parallel
    (
        log_info "Creating PVC..."
        create_pvc_if_missing
    ) &
    local pvc_pid=$!
    
    # Validate GPU nodes in parallel
    (
        log_info "Validating GPU node availability..."
        validate_gpu_nodes
    ) &
    local gpu_validation_pid=$!
    
    # Wait for all resource creation to complete
    wait $secrets_pid || { log_error "Secrets creation failed"; ((failed_creations++)); }
    wait $pvc_pid || { log_error "PVC creation failed"; ((failed_creations++)); }
    wait $gpu_validation_pid || { log_error "GPU validation failed"; ((failed_creations++)); }
    
    if [[ $failed_creations -gt 0 ]]; then
        log_error "Resource creation failed: $failed_creations operations failed"
        return 1
    fi
    
    log_success "All resources created successfully"
}

# Function to create NGC secrets
create_ngc_secrets() {
    local secret_name="ngc-secret"
    
    if kubectl get secret "$secret_name" -n "$NAMESPACE" >/dev/null 2>&1; then
        log_info "NGC secret already exists"
        return 0
    fi
    
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        log_error "NGC_API_KEY not set"
        return 1
    fi
    
    kubectl create secret docker-registry "$secret_name" \
        --docker-server=nvcr.io \
        --docker-username='$oauthtoken' \
        --docker-password="$NGC_API_KEY" \
        --docker-email=none \
        -n "$NAMESPACE"
    
    log_success "NGC secret created"
}

# Function to create PVC if missing
create_pvc_if_missing() {
    local pvc_name="nim-model-cache"
    
    if kubectl get pvc "$pvc_name" -n "$NAMESPACE" >/dev/null 2>&1; then
        log_info "PVC already exists"
        return 0
    fi
    
    # Get default storage class
    local storage_class
    storage_class=$(get_default_storage_class)
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc_name
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 200Gi
  storageClassName: $storage_class
EOF
    
    log_success "PVC created"
}

# Function to validate GPU nodes
validate_gpu_nodes() {
    local gpu_nodes
    gpu_nodes=$(get_gpu_nodes | wc -l)
    
    if [[ $gpu_nodes -eq 0 ]]; then
        log_error "No GPU nodes available"
        return 1
    fi
    
    log_success "GPU nodes validated: $gpu_nodes nodes available"
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
    
    # Prepare Helm values with optimizations
    local helm_values_file="/tmp/nim-optimized-values.yaml"
    cat > "$helm_values_file" << EOF
model:
  name: "${NIM_MODEL:-meta/llama-3.1-8b-instruct}"
  cpuRequirement: "4"
  memoryRequirement: "24Gi"
  cpuLimit: "8"
  memoryLimit: "32Gi"
  sizeGB: 50

persistence:
  enabled: true
  storageClass: "$(get_default_storage_class)"
  accessMode: ReadWriteOnce
  size: 200Gi
  mountPath: /model-cache

resources:
  requests:
    cpu: "4"
    memory: "24Gi"
    nvidia.com/gpu: 1
  limits:
    cpu: "8"
    memory: "32Gi"
    nvidia.com/gpu: 1

# Optimized health probes for faster startup
readinessProbe:
  initialDelaySeconds: 15
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3

livenessProbe:
  initialDelaySeconds: 45
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
EOF
    
    # Deploy with Helm
    log_info "Deploying NIM with Helm..."
    helm upgrade --install "$RELEASE_NAME" "$HELM_CHART_DIR" \
        --namespace "$NAMESPACE" \
        --values "$helm_values_file" \
        --wait \
        --timeout="${DEPLOY_TIMEOUT}s" \
        --atomic
    
    log_success "NIM deployment completed"
    
    # Clean up temporary values file
    rm -f "$helm_values_file"
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
            if kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
                pod_ready=true
                break
            fi
            sleep 10
            ((attempts++))
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
            if kubectl get endpoints -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --no-headers | grep -q "<none>"; then
                sleep 5
                ((attempts++))
            else
                service_ready=true
                break
            fi
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
            if kubectl describe pod -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim | grep -q "nvidia.com/gpu: 1"; then
                gpu_allocated=true
                break
            fi
            sleep 10
            ((attempts++))
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
    wait $pod_pid || { log_error "Pod verification failed"; ((failed_verifications++)); }
    wait $service_pid || { log_error "Service verification failed"; ((failed_verifications++)); }
    wait $gpu_pid || { log_error "GPU verification failed"; ((failed_verifications++)); }
    
    if [[ $failed_verifications -gt 0 ]]; then
        log_error "Deployment verification failed: $failed_verifications checks failed"
        return 1
    fi
    
    log_success "All deployment verifications passed"
}

# Function to get deployment performance metrics
get_deployment_metrics() {
    local end_time=$(date +%s)
    local total_time=$((end_time - DEPLOY_START_TIME))
    
    log_info "Deployment Performance Metrics:"
    log_info "  Total deployment time: ${total_time} seconds"
    log_info "  Parallel phases: 4"
    log_info "  Estimated time savings: ~50% vs sequential deployment"
    
    # Compare with baseline (48 minutes = 2880 seconds)
    local baseline_time=2880
    local time_savings=$((baseline_time - total_time))
    local savings_percentage=$((time_savings * 100 / baseline_time))
    
    log_info "  Baseline (sequential): ${baseline_time} seconds"
    log_info "  Time savings: ${time_savings} seconds (${savings_percentage}%)"
}

# Main parallel deployment function
deploy_parallel() {
    log_info "Starting parallel deployment pipeline..."
    
    trap cleanup_on_failure EXIT ERR INT TERM
    
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
    trap - EXIT ERR INT TERM
    
    log_success "Parallel deployment completed successfully!"
    log_info "Deployment ready for testing"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    deploy_parallel "$@"
fi
