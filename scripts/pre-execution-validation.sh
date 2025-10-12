#!/usr/bin/env bash

# Pre-execution validation for Nimble OKE
# Comprehensive testing before deployment to minimize bugs, time, and costs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly VALIDATION_TIMEOUT=300
readonly DEFAULT_GPU_SHAPE="VM.GPU.A10.1"
readonly DEFAULT_REQUIRED_GPUS=1

# Validation results tracking (using temporary file for compatibility)
readonly VALIDATION_RESULTS_FILE="/tmp/nimble-oke-validation-$$.json"

record_validation() {
    local test_name="$1"
    local result="$2"
    local message="${3:-}"
    
    # Store result in temporary file
    echo "$test_name:$result" >> "$VALIDATION_RESULTS_FILE"
    
    if [[ "$result" == "PASS" ]]; then
        log_success "✓ $test_name: $message"
    elif [[ "$result" == "FAIL" ]]; then
        log_error "✗ $test_name: $message"
    else
        log_warn "⚠ $test_name: $message"
    fi
}

validate_environment_variables() {
    log_info "=== Validating Environment Variables ==="
    
    local missing_vars=()
    
    # Required variables
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        missing_vars+=("NGC_API_KEY")
    fi
    
    if [[ -z "${OCI_COMPARTMENT_ID:-}" ]]; then
        missing_vars+=("OCI_COMPARTMENT_ID")
    fi
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        record_validation "environment_variables" "FAIL" "Missing required variables: ${missing_vars[*]}"
        return 1
    else
        record_validation "environment_variables" "PASS" "All required variables set"
        return 0
    fi
}

validate_tools() {
    log_info "=== Validating Required Tools ==="
    
    local missing_tools=()
    local tools=("kubectl" "helm" "oci" "jq" "curl")
    
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        record_validation "tools" "FAIL" "Missing tools: ${missing_tools[*]}"
        return 1
    else
        record_validation "tools" "PASS" "All required tools available"
        return 0
    fi
}

validate_oci_configuration() {
    log_info "=== Validating OCI Configuration ==="
    
    local oci_ok=true
    
    # Check OCI CLI config file
    if [[ ! -f "$HOME/.oci/config" ]]; then
        record_validation "oci_config_file" "FAIL" "OCI config not found at ~/.oci/config"
        oci_ok=false
    else
        record_validation "oci_config_file" "PASS" "OCI config file exists"
    fi
    
    # Check OCI authentication
    if ! oci iam region list &>/dev/null; then
        record_validation "oci_auth" "FAIL" "OCI CLI authentication failed"
        oci_ok=false
    else
        record_validation "oci_auth" "PASS" "OCI CLI authenticated"
    fi
    
    # Check compartment access
    if [[ -n "${OCI_COMPARTMENT_ID:-}" ]]; then
        if oci iam compartment get --compartment-id "${OCI_COMPARTMENT_ID}" &>/dev/null; then
            record_validation "oci_compartment" "PASS" "Compartment accessible: ${OCI_COMPARTMENT_ID:0:20}..."
        else
            record_validation "oci_compartment" "FAIL" "Cannot access compartment: ${OCI_COMPARTMENT_ID:0:20}..."
            oci_ok=false
        fi
    else
        record_validation "oci_compartment" "FAIL" "OCI_COMPARTMENT_ID not set"
        oci_ok=false
    fi
    
    if [[ "$oci_ok" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

validate_kubernetes_connectivity() {
    log_info "=== Validating Kubernetes Connectivity ==="
    
    local k8s_ok=true
    
    # Check kubectl config
    if [[ ! -f "$HOME/.kube/config" ]]; then
        record_validation "kubectl_config" "FAIL" "kubectl config not found at ~/.kube/config"
        k8s_ok=false
    else
        record_validation "kubectl_config" "PASS" "kubectl config file exists"
    fi
    
    # Check cluster connectivity
    if ! kubectl cluster-info &>/dev/null; then
        record_validation "k8s_connectivity" "FAIL" "Cannot connect to Kubernetes cluster"
        k8s_ok=false
    else
        local context
        context=$(kubectl config current-context 2>/dev/null || echo "unknown")
        record_validation "k8s_connectivity" "PASS" "Connected to cluster (context: $context)"
    fi
    
    # Check cluster version
    local k8s_version
    k8s_version=$(kubectl version --short 2>/dev/null | grep "Server Version" | awk '{print $3}' || echo "unknown")
    record_validation "k8s_version" "INFO" "Kubernetes version: $k8s_version"
    
    if [[ "$k8s_ok" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

validate_gpu_resources() {
    log_info "=== Validating GPU Resources ==="
    
    local gpu_ok=true
    local shape="${GPU_SHAPE:-$DEFAULT_GPU_SHAPE}"
    local required="${REQUIRED_GPUS:-$DEFAULT_REQUIRED_GPUS}"
    
    # Check GPU quota
    if ! validate_gpu_quota "$shape" "$required"; then
        gpu_ok=false
    fi
    
    # Check GPU nodes in cluster
    local gpu_nodes
    gpu_nodes=$(get_gpu_nodes)
    local gpu_count
    gpu_count=$(get_gpu_count)
    
    if [[ "$gpu_count" -gt 0 ]]; then
        record_validation "gpu_nodes" "PASS" "Found $gpu_count GPU nodes: $gpu_nodes"
    else
        record_validation "gpu_nodes" "WARN" "No GPU nodes found in cluster"
    fi
    
    # Check NVIDIA device plugin
    if kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds &>/dev/null; then
        record_validation "nvidia_device_plugin" "PASS" "NVIDIA device plugin installed"
    else
        record_validation "nvidia_device_plugin" "WARN" "NVIDIA device plugin not found"
    fi
    
    if [[ "$gpu_ok" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

validate_storage_resources() {
    log_info "=== Validating Storage Resources ==="
    
    local storage_ok=true
    local default_sc
    default_sc=$(get_default_storage_class)
    
    # Validate default storage class
    if ! validate_storage_class "$default_sc"; then
        storage_ok=false
    fi
    
    # List all available storage classes
    log_info "Available storage classes:"
    kubectl get storageclass 2>/dev/null || log_warn "Unable to list storage classes"
    
    if [[ "$storage_ok" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

validate_network_connectivity() {
    log_info "=== Validating Network Connectivity ==="
    
    local network_ok=true
    
    # Test basic cluster connectivity
    if ! validate_network_connectivity "kubernetes.default.svc.cluster.local" "443"; then
        network_ok=false
    fi
    
    # Test external connectivity (if not dry run)
    if [[ "$DRY_RUN" != "true" ]]; then
        if curl -s --max-time 10 "https://api.ngc.nvidia.com" &>/dev/null; then
            record_validation "external_connectivity" "PASS" "External connectivity to NGC verified"
        else
            record_validation "external_connectivity" "WARN" "External connectivity test failed"
        fi
    else
        record_validation "external_connectivity" "SKIP" "Skipped in dry-run mode"
    fi
    
    if [[ "$network_ok" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

validate_ngc_credentials() {
    log_info "=== Validating NGC Credentials ==="
    
    local ngc_ok=true
    
    # Check NGC API key format
    if [[ -z "${NGC_API_KEY:-}" ]]; then
        record_validation "ngc_api_key" "FAIL" "NGC_API_KEY not set"
        ngc_ok=false
    elif [[ ! "$NGC_API_KEY" =~ ^nvapi- ]]; then
        record_validation "ngc_api_key" "WARN" "NGC_API_KEY format may be incorrect (should start with 'nvapi-')"
    else
        record_validation "ngc_api_key" "PASS" "NGC_API_KEY format looks correct"
    fi
    
    # Test NGC API connectivity
    if ! validate_ngc_api_connectivity; then
        ngc_ok=false
    fi
    
    if [[ "$ngc_ok" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

validate_helm_charts() {
    log_info "=== Validating Helm Charts ==="
    
    local helm_ok=true
    local chart_dir="${SCRIPT_DIR}/../helm"
    
    # Check Chart.yaml exists
    if [[ ! -f "${chart_dir}/Chart.yaml" ]]; then
        record_validation "helm_chart_yaml" "FAIL" "Chart.yaml not found at $chart_dir"
        helm_ok=false
    else
        record_validation "helm_chart_yaml" "PASS" "Chart.yaml exists"
    fi
    
    # Check values.yaml exists
    if [[ ! -f "${chart_dir}/values.yaml" ]]; then
        record_validation "helm_values_yaml" "FAIL" "values.yaml not found at $chart_dir"
        helm_ok=false
    else
        record_validation "helm_values_yaml" "PASS" "values.yaml exists"
    fi
    
    # Validate Helm chart syntax
    if [[ "$DRY_RUN" != "true" ]] && command -v helm &>/dev/null; then
        if helm lint "$chart_dir" &>/dev/null; then
            record_validation "helm_syntax" "PASS" "Helm chart syntax valid"
        else
            record_validation "helm_syntax" "FAIL" "Helm chart syntax errors"
            helm_ok=false
        fi
    else
        record_validation "helm_syntax" "SKIP" "Skipped in dry-run mode or Helm not available"
    fi
    
    if [[ "$helm_ok" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

validate_cost_estimation() {
    log_info "=== Validating Cost Estimation ==="
    
    local duration="${1:-5}"  # Default 5 hours
    local gpu_count="${2:-1}"  # Default 1 GPU
    
    # Calculate estimated costs
    local hourly_cost
    hourly_cost=$(estimate_hourly_cost "$gpu_count")
    local total_cost
    total_cost=$(estimate_deployment_cost "$duration")
    
    record_validation "cost_estimation" "INFO" "Estimated cost: \$$(format_cost "$total_cost") for ${duration}h with ${gpu_count} GPU(s)"
    
    # Check against cost threshold
    if (( $(echo "$total_cost > $COST_THRESHOLD_USD" | bc -l) )); then
        record_validation "cost_threshold" "WARN" "Estimated cost \$$(format_cost "$total_cost") exceeds threshold \$$COST_THRESHOLD_USD"
    else
        record_validation "cost_threshold" "PASS" "Estimated cost within threshold"
    fi
    
    # Show cost breakdown
    echo ""
    echo "Cost Breakdown:"
    echo "  GPU Node (${gpu_count}x): \$$(echo "scale=2; $hourly_cost * $duration" | bc -l)"
    echo "  OKE Control Plane: \$$(echo "scale=2; 0.10 * $duration" | bc -l)"
    echo "  ENHANCED Cluster: \$$(echo "scale=2; 0.10 * $duration" | bc -l)"
    echo "  Storage (50GB): \$1.50"
    echo "  Load Balancer: \$$(echo "scale=2; 1.25 * $duration" | bc -l)"
    echo "  Total: \$$(format_cost "$total_cost")"
    echo ""
    
    return 0
}

generate_validation_report() {
    echo ""
    echo "==============================================================="
    echo "PRE-EXECUTION VALIDATION REPORT"
    echo "==============================================================="
    echo ""
    
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    local warning_tests=0
    
    # Read results from file
    while IFS=':' read -r test_name result; do
        [[ -z "$test_name" ]] && continue
        total_tests=$((total_tests + 1))
        
        case "$result" in
            "PASS")
                passed_tests=$((passed_tests + 1))
                echo "✓ $test_name: PASS"
                ;;
            "FAIL")
                failed_tests=$((failed_tests + 1))
                echo "✗ $test_name: FAIL"
                ;;
            "WARN"|"INFO")
                warning_tests=$((warning_tests + 1))
                echo "⚠ $test_name: $result"
                ;;
            "SKIP")
                echo "⏭ $test_name: SKIP"
                ;;
        esac
    done < "$VALIDATION_RESULTS_FILE" 2>/dev/null
    
    echo ""
    echo "Summary:"
    echo "  Total Tests: $total_tests"
    echo "  Passed: $passed_tests"
    echo "  Failed: $failed_tests"
    echo "  Warnings: $warning_tests"
    echo ""
    
    # Cleanup
    rm -f "$VALIDATION_RESULTS_FILE"
    
    if [[ $failed_tests -gt 0 ]]; then
        echo "❌ VALIDATION FAILED - Fix issues before deployment"
        return 1
    elif [[ $warning_tests -gt 0 ]]; then
        echo "⚠️  VALIDATION PASSED WITH WARNINGS - Review warnings"
        return 0
    else
        echo "✅ VALIDATION PASSED - Ready for deployment"
        return 0
    fi
}

main() {
    local duration="${1:-5}"
    local gpu_count="${2:-1}"
    
    # Initialize results file
    > "$VALIDATION_RESULTS_FILE"
    
    log_info "Starting pre-execution validation..."
    log_info "Mode: ${DRY_RUN:+DRY-RUN }${DEBUG:+DEBUG }${ENVIRONMENT}"
    log_info "Duration: ${duration}h, GPU Count: ${gpu_count}"
    echo ""
    
    # Run all validations
    validate_environment_variables
    validate_tools
    validate_oci_configuration
    validate_kubernetes_connectivity
    validate_gpu_resources
    validate_storage_resources
    validate_network_connectivity
    validate_ngc_credentials
    validate_helm_charts
    validate_cost_estimation "$duration" "$gpu_count"
    
    # Generate final report
    generate_validation_report
}

# Usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
