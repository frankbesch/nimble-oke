#!/usr/bin/env bash

set -euo pipefail

readonly LOG_PREFIX="[NIM-OKE]"
readonly ENVIRONMENT="${ENVIRONMENT:-dev}"
readonly COST_THRESHOLD_USD="${COST_THRESHOLD_USD:-5}"
readonly CONFIRM_COST="${CONFIRM_COST:-}"

log_info() {
    echo "${LOG_PREFIX}[INFO] $*" >&2
}

log_warn() {
    echo "${LOG_PREFIX}[WARN] $*" >&2
}

log_error() {
    echo "${LOG_PREFIX}[ERROR] $*" >&2
}

log_success() {
    echo "${LOG_PREFIX}[SUCCESS] $*" >&2
}

die() {
    log_error "$*"
    exit 1
}

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command not found: $cmd"
    fi
}

check_env_var() {
    local var="$1"
    if [[ -z "${!var:-}" ]]; then
        die "Required environment variable not set: $var"
    fi
}

cost_guard() {
    local estimated_cost="$1"
    local operation="$2"
    
    if [[ "$ENVIRONMENT" == "production" ]] || (( $(echo "$estimated_cost > $COST_THRESHOLD_USD" | bc -l) )); then
        log_warn "Cost guard triggered for: $operation"
        log_warn "Estimated cost: \$${estimated_cost}"
        log_warn "Environment: $ENVIRONMENT"
        
        if [[ "$CONFIRM_COST" != "yes" ]]; then
            log_error "Cost exceeds threshold (\$${COST_THRESHOLD_USD})"
            log_info "To proceed: export CONFIRM_COST=yes"
            exit 1
        fi
        
        log_info "Cost confirmed, proceeding..."
    fi
}

retry() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local cmd=("$@")
    local attempt=1
    
    until "${cmd[@]}"; do
        if (( attempt >= max_attempts )); then
            log_error "Command failed after $max_attempts attempts: ${cmd[*]}"
            return 1
        fi
        log_warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
        sleep "$delay"
        ((attempt++))
    done
    
    return 0
}

wait_for_condition() {
    local resource="$1"
    local condition="$2"
    local timeout="${3:-300}"
    local namespace="${4:-default}"
    
    log_info "Waiting for $resource to be $condition (timeout: ${timeout}s)..."
    
    if kubectl wait --for="condition=$condition" "$resource" \
        -n "$namespace" \
        --timeout="${timeout}s" 2>/dev/null; then
        log_success "$resource is $condition"
        return 0
    else
        log_error "$resource failed to reach $condition within ${timeout}s"
        return 1
    fi
}

get_default_storage_class() {
    kubectl get storageclass \
        -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
        2>/dev/null || echo "oci-bv"
}

get_gpu_nodes() {
    kubectl get nodes \
        -o jsonpath='{.items[?(@.status.capacity.nvidia\.com/gpu)].metadata.name}' \
        2>/dev/null || echo ""
}

get_gpu_count() {
    local gpu_nodes
    gpu_nodes=$(get_gpu_nodes)
    
    if [[ -z "$gpu_nodes" ]]; then
        echo "0"
        return
    fi
    
    echo "$gpu_nodes" | wc -w | tr -d ' '
}

check_oci_credentials() {
    if ! oci iam region list &>/dev/null; then
        die "OCI CLI not configured or credentials invalid"
    fi
}

check_kubectl_context() {
    if ! kubectl cluster-info &>/dev/null; then
        die "kubectl not configured or cluster unreachable"
    fi
}

check_helm() {
    check_command helm
    
    if ! helm version &>/dev/null; then
        die "Helm not working properly"
    fi
}

get_cluster_info() {
    local key="$1"
    
    case "$key" in
        version)
            kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}'
            ;;
        nodes)
            kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '
            ;;
        gpu-nodes)
            get_gpu_count
            ;;
        storage-class)
            get_default_storage_class
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

estimate_hourly_cost() {
    local gpu_count="${1:-1}"
    local gpu_cost_per_hour=1.75
    local control_plane_cost=0.10
    
    echo "$gpu_count * $gpu_cost_per_hour + $control_plane_cost" | bc -l
}

estimate_deployment_cost() {
    local duration_hours="${1:-5}"
    local gpu_count
    gpu_count=$(get_gpu_count)
    
    if [[ "$gpu_count" == "0" ]]; then
        gpu_count=1
    fi
    
    local hourly_cost
    hourly_cost=$(estimate_hourly_cost "$gpu_count")
    
    echo "$hourly_cost * $duration_hours" | bc -l
}

format_cost() {
    local cost="$1"
    printf "%.2f" "$cost"
}

check_namespace_exists() {
    local namespace="$1"
    kubectl get namespace "$namespace" &>/dev/null
}

create_namespace_if_missing() {
    local namespace="$1"
    
    if ! check_namespace_exists "$namespace"; then
        log_info "Creating namespace: $namespace"
        kubectl create namespace "$namespace"
    fi
}

get_pod_status() {
    local label="$1"
    local namespace="${2:-default}"
    
    kubectl get pods -n "$namespace" -l "$label" \
        -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo ""
}

get_service_external_ip() {
    local service="$1"
    local namespace="${2:-default}"
    
    kubectl get svc "$service" -n "$namespace" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo ""
}

validate_ngc_api_key() {
    local api_key="$1"
    
    if [[ -z "$api_key" ]]; then
        die "NGC_API_KEY is required"
    fi
    
    if [[ ! "$api_key" =~ ^nvapi- ]]; then
        log_warn "NGC_API_KEY doesn't start with 'nvapi-', this might be incorrect"
    fi
}

helm_install_or_upgrade() {
    local release="$1"
    local chart="$2"
    local namespace="$3"
    shift 3
    local extra_args=("$@")
    
    if helm list -n "$namespace" | grep -q "^$release"; then
        log_info "Upgrading Helm release: $release"
        helm upgrade "$release" "$chart" -n "$namespace" "${extra_args[@]}"
    else
        log_info "Installing Helm release: $release"
        helm install "$release" "$chart" -n "$namespace" "${extra_args[@]}"
    fi
}

cleanup_helm_release() {
    local release="$1"
    local namespace="${2:-default}"
    
    if helm list -n "$namespace" | grep -q "^$release"; then
        log_info "Uninstalling Helm release: $release"
        helm uninstall "$release" -n "$namespace" --wait || true
    fi
}

cleanup_namespace() {
    local namespace="$1"
    
    if check_namespace_exists "$namespace"; then
        log_info "Deleting namespace: $namespace"
        kubectl delete namespace "$namespace" --wait=false || true
    fi
}

wait_for_pod_ready() {
    local label="$1"
    local namespace="${2:-default}"
    local timeout="${3:-600}"
    
    log_info "Waiting for pods with label $label to be ready..."
    
    if kubectl wait --for=condition=ready pod \
        -l "$label" \
        -n "$namespace" \
        --timeout="${timeout}s" 2>/dev/null; then
        log_success "Pods are ready"
        return 0
    else
        log_error "Pods failed to become ready within ${timeout}s"
        return 1
    fi
}

get_pod_logs() {
    local label="$1"
    local namespace="${2:-default}"
    local lines="${3:-50}"
    
    kubectl logs -l "$label" -n "$namespace" --tail="$lines" 2>/dev/null || echo "No logs available"
}

describe_pods() {
    local label="$1"
    local namespace="${2:-default}"
    
    kubectl describe pods -l "$label" -n "$namespace" 2>/dev/null || echo "No pods found"
}

check_gpu_available() {
    local gpu_count
    gpu_count=$(get_gpu_count)
    
    if [[ "$gpu_count" == "0" ]]; then
        log_error "No GPU nodes found in cluster"
        return 1
    fi
    
    log_info "Found $gpu_count GPU node(s)"
    return 0
}

export -f log_info log_warn log_error log_success die
export -f check_command check_env_var cost_guard retry
export -f wait_for_condition get_default_storage_class get_gpu_nodes get_gpu_count
export -f check_oci_credentials check_kubectl_context check_helm
export -f get_cluster_info estimate_hourly_cost estimate_deployment_cost format_cost
export -f check_namespace_exists create_namespace_if_missing
export -f get_pod_status get_service_external_ip validate_ngc_api_key
export -f helm_install_or_upgrade cleanup_helm_release cleanup_namespace
export -f wait_for_pod_ready get_pod_logs describe_pods check_gpu_available

