#!/usr/bin/env bash

set -euo pipefail

readonly LOG_PREFIX="[NIM-OKE]"
readonly ENVIRONMENT="${ENVIRONMENT:-dev}"
readonly COST_THRESHOLD_USD="${COST_THRESHOLD_USD:-5}"
readonly CONFIRM_COST="${CONFIRM_COST:-}"
readonly DEBUG="${DEBUG:-false}"
readonly DRY_RUN="${DRY_RUN:-false}"

# Session tracking
readonly SESSION_DIR="${HOME}/.nimble-oke/sessions"
readonly CURRENT_SESSION="${SESSION_DIR}/current.json"

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

# Smart retry logic with exponential backoff and circuit breaker pattern
smart_retry() {
    local max_attempts="${1:-3}"
    local base_delay="${2:-5}"
    local command="${@:3}"
    local attempt=1
    local circuit_breaker_threshold=5
    local circuit_breaker_reset_time=300  # 5 minutes
    
    # Check circuit breaker
    local circuit_breaker_file="/tmp/nim-circuit-breaker-$(echo "$command" | md5sum | cut -d' ' -f1)"
    local current_time=$(date +%s)
    
    if [[ -f "$circuit_breaker_file" ]]; then
        local last_failure_time=$(cat "$circuit_breaker_file")
        local time_since_failure=$((current_time - last_failure_time))
        
        if [[ $time_since_failure -lt $circuit_breaker_reset_time ]]; then
            log_warn "Circuit breaker active - command failed recently, skipping retry"
            return 1
        else
            # Reset circuit breaker
            rm -f "$circuit_breaker_file"
        fi
    fi
    
    while [[ $attempt -le $max_attempts ]]; do
        log_info "Attempt $attempt/$max_attempts: $command"
        
        if eval "$command"; then
            log_success "Command succeeded on attempt $attempt"
            # Clear circuit breaker on success
            rm -f "$circuit_breaker_file"
            return 0
        fi
        
        local exit_code=$?
        log_warn "Attempt $attempt failed with exit code $exit_code"
        
        # Exponential backoff with jitter
        if [[ $attempt -lt $max_attempts ]]; then
            local delay=$((base_delay * (2 ** (attempt - 1)) + RANDOM % 5))
            log_info "Retrying in ${delay} seconds..."
            sleep $delay
        fi
        
        ((attempt++))
    done
    
    # Record failure for circuit breaker
    echo "$current_time" > "$circuit_breaker_file"
    
    log_error "Command failed after $max_attempts attempts"
    return 1
}

# Enhanced timeout protection with smart retry
timeout_with_retry() {
    local timeout_seconds="${1:-300}"
    local max_retries="${2:-2}"
    local command="${@:3}"
    
    log_info "Running command with timeout protection and smart retry"
    log_info "Timeout: ${timeout_seconds}s, Max retries: $max_retries"
    
    smart_retry "$max_retries" 10 "timeout $timeout_seconds $command"
}

debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "${LOG_PREFIX}[DEBUG] $*" >&2
    fi
}

dry_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would execute: $*"
        return 0
    else
        eval "$@"
        return $?
    fi
}

die() {
    log_error "$*"
    exit 1
}

# Session tracking functions
init_session() {
    local operation="$1"
    local session_id="session-$(date +%Y%m%d-%H%M%S)"
    
    if [[ -x "scripts/session-tracker.sh" ]]; then
        local session_file=$(scripts/session-tracker.sh init "$session_id" "$operation" 2>/dev/null)
        if [[ -n "$session_file" ]]; then
            log_info "Session tracking initialized: $session_file"
        fi
    fi
}

log_obstacle() {
    local phase="$1"
    local obstacle_type="$2"
    local description="$3"
    local root_cause="$4"
    local fix="$5"
    local time_delay="${6:-0}"
    local cost_impact="${7:-0}"
    
    log_warn "OBSTACLE: $phase - $description"
    
    if [[ -x "scripts/session-tracker.sh" ]]; then
        scripts/session-tracker.sh log-obstacle "$phase" "$obstacle_type" "$description" "$root_cause" "$fix" "$time_delay" "$cost_impact" 2>/dev/null || true
    fi
}

end_session() {
    if [[ -x "scripts/session-tracker.sh" ]]; then
        scripts/session-tracker.sh calculate-performance 2>/dev/null || true
        scripts/session-tracker.sh summary 2>/dev/null || true
    fi
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
    local phase="${3:-unknown}"
    shift 3
    local cmd=("$@")
    local attempt=1
    local start_time=$(date +%s)
    
    debug "Retrying command: ${cmd[*]} (max attempts: $max_attempts, delay: ${delay}s)"
    
    until "${cmd[@]}"; do
        if (( attempt >= max_attempts )); then
            local end_time=$(date +%s)
            local total_delay=$((end_time - start_time))
            
            log_error "Command failed after $max_attempts attempts: ${cmd[*]}"
            
            # Auto-log obstacle
            log_obstacle "$phase" "retry-exhausted" \
                "Command failed after $max_attempts attempts: ${cmd[*]}" \
                "Persistent failure - likely configuration or resource issue" \
                "Check logs and resource availability" \
                "$total_delay" "$(echo "scale=2; $total_delay * 0.001" | bc -l)"
            
            return 1
        fi
        log_warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
        sleep "$delay"
        ((attempt++))
    done
    
    debug "Command succeeded after $((attempt - 1)) attempts"
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

start_phase() {
    local phase="$1"
    echo "$(date +%s)" > "/tmp/nimble-oke-${phase}-start"
    log_info "=== PHASE: $phase STARTED at $(date '+%H:%M:%S') ==="
    
    # Session tracking
    if [[ -x "scripts/session-tracker.sh" ]]; then
        scripts/session-tracker.sh start-phase "$phase" 2>/dev/null || true
    fi
}

end_phase() {
    local phase="$1"
    local start_file="/tmp/nimble-oke-${phase}-start"
    if [[ -f "$start_file" ]]; then
        local duration=$(($(date +%s) - $(cat "$start_file")))
        log_success "=== PHASE: $phase COMPLETED in $((duration/60))m $((duration%60))s ==="
        
        # Session tracking
        if [[ -x "scripts/session-tracker.sh" ]]; then
            scripts/session-tracker.sh end-phase "$phase" 2>/dev/null || true
        fi
        
        rm -f "$start_file"
    fi
}

start_step() {
    local step="$1"
    echo "$(date +%s)" > "/tmp/nimble-oke-step"
    log_info "→ $step"
}

end_step() {
    local step="$1"
    if [[ -f "/tmp/nimble-oke-step" ]]; then
        local duration=$(($(date +%s) - $(cat "/tmp/nimble-oke-step")))
        log_success "✓ $step (${duration}s)"
        rm -f "/tmp/nimble-oke-step"
    fi
}

with_timeout() {
    local timeout="$1"
    local desc="$2"
    local phase="${3:-unknown}"
    shift 3
    
    log_info "Running: $desc (timeout: ${timeout}s)"
    
    # Background progress indicator
    (
        local elapsed=0
        while kill -0 $$ 2>/dev/null; do
            echo -n "." >&2
            sleep 5
            elapsed=$((elapsed + 5))
            if [[ $((elapsed % 30)) -eq 0 ]]; then
                echo " ${elapsed}s" >&2
            fi
        done
    ) &
    local progress_pid=$!
    
    # Run actual command
    if timeout "$timeout" bash -c "$*"; then
        kill $progress_pid 2>/dev/null || true
        log_success "$desc completed"
        return 0
    else
        kill $progress_pid 2>/dev/null || true
        local exit_code=$?
        
        if [[ $exit_code -eq 124 ]]; then
            log_error "$desc STALLED (timeout: ${timeout}s)"
            # Auto-log obstacle for timeouts
            log_obstacle "$phase" "timeout" \
                "$desc stalled after ${timeout}s" \
                "Operation exceeded timeout threshold" \
                "Increase timeout or optimize operation" \
                "$timeout" "$(echo "scale=2; $timeout * 0.001" | bc -l)"
        else
            log_error "$desc FAILED (exit: $exit_code)"
            # Auto-log obstacle for failures
            log_obstacle "$phase" "execution-error" \
                "$desc failed with exit code $exit_code" \
                "Command execution error" \
                "Check command syntax and dependencies" \
                "0" "0"
        fi
        
        return $exit_code
    fi
}

wait_for_state() {
    local check_cmd="$1"
    local desc="$2"
    local timeout="${3:-300}"
    local phase="${4:-unknown}"
    local elapsed=0
    
    log_info "Waiting: $desc (timeout: ${timeout}s)"
    
    # Background progress indicator
    (
        local elapsed=0
        while kill -0 $$ 2>/dev/null; do
            echo -n "." >&2
            sleep 5
            elapsed=$((elapsed + 5))
            if [[ $((elapsed % 30)) -eq 0 ]]; then
                echo " ${elapsed}s" >&2
            fi
        done
    ) &
    local progress_pid=$!
    
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$check_cmd" 2>/dev/null; then
            kill $progress_pid 2>/dev/null || true
            log_success "$desc (after ${elapsed}s)"
            return 0
        fi
        
        if [[ $((elapsed % 15)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            log_info "Still waiting... (${elapsed}s elapsed)"
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    kill $progress_pid 2>/dev/null || true
    log_error "$desc TIMEOUT after ${timeout}s"
    
    # Auto-log obstacle for timeouts
    log_obstacle "$phase" "state-timeout" \
        "$desc timeout after ${timeout}s" \
        "Resource failed to reach expected state within timeout" \
        "Check resource status and increase timeout if needed" \
        "$timeout" "$(echo "scale=2; $timeout * 0.001" | bc -l)"
    
    return 1
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
    debug "Checking OCI credentials..."
    if ! oci iam region list &>/dev/null; then
        die "OCI CLI not configured or credentials invalid"
    fi
    debug "OCI credentials valid"
}

check_kubectl_context() {
    debug "Checking kubectl context..."
    local context=$(kubectl config current-context 2>/dev/null || echo "none")
    debug "Current context: $context"
    
    if ! kubectl cluster-info &>/dev/null; then
        die "kubectl not configured or cluster unreachable"
    fi
    debug "kubectl context valid"
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
    local gpu_hourly="12.24"       # VM.GPU.A10.4 (4x NVIDIA A10 GPUs)
    local control_plane="0.10"     # OKE control plane
    local enhanced="0.10"          # ENHANCED cluster type
    local lb_cost="0.0144"         # 10 Mbps flexible LB (corrected from $0.25)
    local storage_cost="0.05"      # 200GB at ~$0.03/GB/month
    echo "($gpu_hourly * $gpu_count) + $control_plane + $enhanced + $lb_cost + $storage_cost" | bc -l
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

get_oci_tags_file() {
    local type="$1"
    local tags_file="/tmp/oci-tags-$$.json"
    
    cat > "$tags_file" <<EOF
{
  "project": "nimble-oke",
  "managed-by": "automation",
  "resource-type": "$type",
  "created-at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environment": "${ENVIRONMENT:-dev}"
}
EOF
    
    echo "$tags_file"
}

# Enhanced resource validation functions
validate_gpu_quota() {
    local shape="${1:-VM.GPU.A10.1}"
    local required_count="${2:-1}"
    
    debug "Validating GPU quota for $shape (required: $required_count)"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would check GPU quota for $shape"
        return 0
    fi
    
    local available_quota
    available_quota=$(get_gpu_service_limit "$shape")
    
    if [[ "$available_quota" -ge "$required_count" ]]; then
        log_success "GPU quota available: $available_quota $shape"
        return 0
    else
        log_error "GPU quota insufficient: $available_quota available, $required_count required"
        return 1
    fi
}

validate_storage_class() {
    local storage_class="${1:-oci-bv}"
    
    debug "Validating storage class: $storage_class"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would validate storage class: $storage_class"
        return 0
    fi
    
    if kubectl get storageclass "$storage_class" &>/dev/null; then
        log_success "Storage class available: $storage_class"
        return 0
    else
        log_error "Storage class not found: $storage_class"
        log_info "Available storage classes:"
        kubectl get storageclass 2>/dev/null || log_warn "Unable to list storage classes"
        return 1
    fi
}

validate_network_connectivity() {
    local target="${1:-kubernetes.default.svc.cluster.local}"
    local port="${2:-443}"
    
    debug "Validating network connectivity to $target:$port"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would test connectivity to $target:$port"
        return 0
    fi
    
    # Test from a pod if available, otherwise skip
    local test_pod
    test_pod=$(kubectl get pods --field-selector=status.phase=Running --no-headers -o custom-columns=":metadata.name" | head -1 2>/dev/null || echo "")
    
    if [[ -n "$test_pod" ]]; then
        if kubectl exec "$test_pod" -- nc -z "$target" "$port" &>/dev/null; then
            log_success "Network connectivity verified: $target:$port"
            return 0
        else
            log_warn "Network connectivity test failed: $target:$port"
            return 1
        fi
    else
        log_warn "No running pods available for network connectivity test"
        return 0
    fi
}

validate_ngc_api_connectivity() {
    debug "Validating NGC API connectivity"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would test NGC API connectivity"
        return 0
    fi
    
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        log_error "NGC_API_KEY not set for connectivity test"
        return 1
    fi
    
    # Test NGC API connectivity
    local ngc_test_url="https://api.ngc.nvidia.com/v2/auth/status"
    if curl -s -H "Authorization: Bearer $NGC_API_KEY" "$ngc_test_url" &>/dev/null; then
        log_success "NGC API connectivity verified"
        return 0
    else
        log_warn "NGC API connectivity test failed"
        return 1
    fi
}

validate_oci_service_limits() {
    local service="${1:-compute}"
    
    debug "Validating OCI service limits for $service"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would check OCI service limits for $service"
        return 0
    fi
    
    if ! check_oci_credentials; then
        log_warn "Cannot validate service limits (OCI not configured)"
        return 1
    fi
    
    local limits
    limits=$(oci limits value list --service-name "$service" --compartment-id "${OCI_COMPARTMENT_ID:-}" --all 2>/dev/null || echo "")
    
    if [[ -n "$limits" ]]; then
        log_success "OCI service limits accessible for $service"
        return 0
    else
        log_warn "Unable to retrieve OCI service limits for $service"
        return 1
    fi
}

get_gpu_hourly_rate() {
    local shape="${1:-VM.GPU.A10.4}"
    
    # GPU hourly rates (USD per hour)
    case "$shape" in
        VM.GPU.A10.1|BM.GPU.A10.1)
            echo "3.06"
            ;;
        VM.GPU.A10.2|BM.GPU.A10.2)
            echo "6.12"
            ;;
        VM.GPU.A10.4|BM.GPU.A10.4)
            echo "12.24"
            ;;
        VM.GPU3.1|BM.GPU3.1)
            echo "3.06"
            ;;
        VM.GPU3.2|BM.GPU3.2)
            echo "6.12"
            ;;
        VM.GPU3.4|BM.GPU3.4)
            echo "12.24"
            ;;
        VM.GPU3.8|BM.GPU3.8)
            echo "24.48"
            ;;
        *H100*)
            echo "21.33"
            ;;
        *)
            echo "12.24"  # Default to A10.4 rate
            ;;
    esac
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
export -f wait_for_condition wait_for_state
export -f start_phase end_phase start_step end_step with_timeout
export -f get_default_storage_class get_gpu_nodes get_gpu_count
export -f check_oci_credentials check_kubectl_context check_helm
export -f get_cluster_info estimate_hourly_cost estimate_deployment_cost format_cost get_oci_tags_file
export -f check_namespace_exists create_namespace_if_missing
export -f get_pod_status get_service_external_ip validate_ngc_api_key
export -f helm_install_or_upgrade cleanup_helm_release cleanup_namespace
export -f wait_for_pod_ready get_pod_logs describe_pods check_gpu_available

