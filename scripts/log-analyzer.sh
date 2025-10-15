#!/bin/bash

# Enhanced Log Analyzer for NVIDIA NIM on OKE
# Provides pattern recognition and actionable troubleshooting insights

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Configuration
NAMESPACE="${NAMESPACE:-nim}"
LOG_DIR="/tmp/nim-logs"
ANALYSIS_OUTPUT="/tmp/nim-analysis.json"

log_info "Enhanced Log Analyzer initialized"
log_info "Namespace: $NAMESPACE"
log_info "Log directory: $LOG_DIR"

# Function to collect logs from all sources
collect_deployment_logs() {
    local namespace="$1"
    
    log_info "Collecting deployment logs..."
    mkdir -p "$LOG_DIR"
    
    # Helm release status
    helm status nim-release -n "$namespace" > "$LOG_DIR/helm-status.log" 2>&1 || true
    
    # Deployment status
    kubectl get deployment -n "$namespace" -o yaml > "$LOG_DIR/deployment.yaml" 2>&1 || true
    
    # Service status
    kubectl get service -n "$namespace" -o yaml > "$LOG_DIR/service.yaml" 2>&1 || true
    
    log_success "Deployment logs collected"
}

# Function to collect pod logs
collect_pod_logs() {
    local namespace="$1"
    
    log_info "Collecting pod logs..."
    
    # Get all pods in namespace
    kubectl get pods -n "$namespace" -o name | while read -r pod; do
        local pod_name="${pod#pod/}"
        log_info "Collecting logs for pod: $pod_name"
        
        # Current logs
        kubectl logs "$pod_name" -n "$namespace" > "$LOG_DIR/pods-${pod_name}.log" 2>&1 || true
        
        # Previous logs (if pod restarted)
        kubectl logs "$pod_name" -n "$namespace" --previous > "$LOG_DIR/pods-${pod_name}-previous.log" 2>&1 || true
        
        # Pod description
        kubectl describe pod "$pod_name" -n "$namespace" > "$LOG_DIR/pods-${pod_name}-describe.log" 2>&1 || true
    done
    
    log_success "Pod logs collected"
}

# Function to collect events
collect_events() {
    local namespace="$1"
    
    log_info "Collecting events..."
    
    # Namespace events
    kubectl get events -n "$namespace" --sort-by='.lastTimestamp' > "$LOG_DIR/events.log" 2>&1 || true
    
    # All events (broader context)
    kubectl get events --all-namespaces --sort-by='.lastTimestamp' | grep -i nim > "$LOG_DIR/events-all.log" 2>&1 || true
    
    log_success "Events collected"
}

# Function to analyze error patterns
analyze_error_patterns() {
    log_info "Analyzing error patterns..."
    
    local error_count=0
    local error_patterns=()
    
    # Pattern: Image pull failures
    if grep -q "ImagePullBackOff\|ErrImagePull\|Failed to pull image" "$LOG_DIR"/*.log 2>/dev/null; then
        log_error "Image pull failure detected"
        error_patterns+=("IMAGE_PULL_FAILURE")
        ((error_count++))
        
        # Extract specific image pull errors
        grep -h "ImagePullBackOff\|ErrImagePull\|Failed to pull image" "$LOG_DIR"/*.log 2>/dev/null | head -5
        echo ""
    fi
    
    # Pattern: GPU allocation issues
    if grep -q "Insufficient nvidia.com/gpu\|No nodes are available\|didn't have free resources" "$LOG_DIR"/*.log 2>/dev/null; then
        log_error "GPU allocation failure detected"
        error_patterns+=("GPU_ALLOCATION_FAILURE")
        ((error_count++))
        
        # Extract GPU allocation errors
        grep -h "Insufficient nvidia.com/gpu\|No nodes are available\|didn't have free resources" "$LOG_DIR"/*.log 2>/dev/null | head -5
        echo ""
    fi
    
    # Pattern: Memory pressure
    if grep -q "OOMKilled\|MemoryPressure\|Out of memory" "$LOG_DIR"/*.log 2>/dev/null; then
        log_error "Memory pressure detected"
        error_patterns+=("MEMORY_PRESSURE")
        ((error_count++))
        
        # Extract memory errors
        grep -h "OOMKilled\|MemoryPressure\|Out of memory" "$LOG_DIR"/*.log 2>/dev/null | head -5
        echo ""
    fi
    
    # Pattern: Storage issues
    if grep -q "FailedMount\|MountVolume\|PersistentVolumeClaim" "$LOG_DIR"/*.log 2>/dev/null; then
        log_error "Storage mounting issues detected"
        error_patterns+=("STORAGE_MOUNT_FAILURE")
        ((error_count++))
        
        # Extract storage errors
        grep -h "FailedMount\|MountVolume\|PersistentVolumeClaim" "$LOG_DIR"/*.log 2>/dev/null | head -5
        echo ""
    fi
    
    # Pattern: Network connectivity
    if grep -q "Connection refused\|Connection timeout\|Network unreachable" "$LOG_DIR"/*.log 2>/dev/null; then
        log_error "Network connectivity issues detected"
        error_patterns+=("NETWORK_CONNECTIVITY")
        ((error_count++))
        
        # Extract network errors
        grep -h "Connection refused\|Connection timeout\|Network unreachable" "$LOG_DIR"/*.log 2>/dev/null | head -5
        echo ""
    fi
    
    # Pattern: NGC authentication
    if grep -q "authentication failed\|unauthorized\|401\|403" "$LOG_DIR"/*.log 2>/dev/null; then
        log_error "NGC authentication issues detected"
        error_patterns+=("NGC_AUTHENTICATION")
        ((error_count++))
        
        # Extract auth errors
        grep -h "authentication failed\|unauthorized\|401\|403" "$LOG_DIR"/*.log 2>/dev/null | head -5
        echo ""
    fi
    
    log_info "Error analysis completed: $error_count patterns detected"
    echo "${error_patterns[@]}" > "$LOG_DIR/error-patterns.txt"
}

# Function to analyze performance patterns
analyze_performance_patterns() {
    log_info "Analyzing performance patterns..."
    
    # Check pod startup times
    local startup_time=$(grep -h "Started container\|Container started" "$LOG_DIR"/*.log 2>/dev/null | wc -l)
    log_info "Container startup events: $startup_time"
    
    # Check for slow operations
    if grep -q "slow\|timeout\|taking longer than expected" "$LOG_DIR"/*.log 2>/dev/null; then
        log_warn "Slow operations detected"
        grep -h "slow\|timeout\|taking longer than expected" "$LOG_DIR"/*.log 2>/dev/null | head -3
        echo ""
    fi
    
    # Check resource usage
    if grep -q "high memory usage\|high cpu usage\|resource usage" "$LOG_DIR"/*.log 2>/dev/null; then
        log_warn "High resource usage detected"
        grep -h "high memory usage\|high cpu usage\|resource usage" "$LOG_DIR"/*.log 2>/dev/null | head -3
        echo ""
    fi
    
    log_success "Performance analysis completed"
}

# Function to analyze resource patterns
analyze_resource_patterns() {
    log_info "Analyzing resource patterns..."
    
    # Check node capacity
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    local gpu_nodes=$(kubectl get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | wc -l)
    
    log_info "Node analysis:"
    log_info "  Total nodes: $node_count"
    log_info "  GPU nodes: $gpu_nodes"
    
    # Check pod resource requests
    if kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q Pending; then
        log_warn "Pending pods detected - check resource availability"
        kubectl get pods -n "$NAMESPACE" | grep Pending
        echo ""
    fi
    
    # Check PVC status
    if kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q Pending; then
        log_warn "Pending PVCs detected - check storage availability"
        kubectl get pvc -n "$NAMESPACE" | grep Pending
        echo ""
    fi
    
    log_success "Resource analysis completed"
}

# Function to generate troubleshooting report
generate_troubleshooting_report() {
    log_info "Generating troubleshooting report..."
    
    local report_file="$LOG_DIR/troubleshooting-report.md"
    
    cat > "$report_file" << EOF
# NVIDIA NIM Troubleshooting Report

**Generated:** $(date)
**Namespace:** $NAMESPACE

## Summary

EOF

    # Add error patterns if found
    if [[ -f "$LOG_DIR/error-patterns.txt" ]]; then
        local error_patterns=($(cat "$LOG_DIR/error-patterns.txt"))
        if [[ ${#error_patterns[@]} -gt 0 ]]; then
            cat >> "$report_file" << EOF
### Detected Issues

EOF
            for pattern in "${error_patterns[@]}"; do
                case "$pattern" in
                    "IMAGE_PULL_FAILURE")
                        cat >> "$report_file" << EOF
- **Image Pull Failure**: Check NGC API key and image access
  - Verify NGC_API_KEY is set correctly
  - Check NGC catalog access for model: ${NIM_MODEL:-meta/llama-3.1-8b-instruct}

EOF
                        ;;
                    "GPU_ALLOCATION_FAILURE")
                        cat >> "$report_file" << EOF
- **GPU Allocation Failure**: Check GPU node availability
  - Verify GPU nodes are running: kubectl get nodes -l nvidia.com/gpu.present=true
  - Check GPU quota in OCI Console

EOF
                        ;;
                    "MEMORY_PRESSURE")
                        cat >> "$report_file" << EOF
- **Memory Pressure**: Increase memory limits
  - Current limits may be too low for model size
  - Consider increasing memory requests/limits in values.yaml

EOF
                        ;;
                    "STORAGE_MOUNT_FAILURE")
                        cat >> "$report_file" << EOF
- **Storage Mount Failure**: Check PVC and storage class
  - Verify PVC status: kubectl get pvc -n $NAMESPACE
  - Check storage class availability

EOF
                        ;;
                    "NETWORK_CONNECTIVITY")
                        cat >> "$report_file" << EOF
- **Network Connectivity**: Check service and ingress
  - Verify service endpoints: kubectl get endpoints -n $NAMESPACE
  - Check LoadBalancer external IP

EOF
                        ;;
                    "NGC_AUTHENTICATION")
                        cat >> "$report_file" << EOF
- **NGC Authentication**: Verify NGC credentials
  - Check NGC_API_KEY is valid: curl -H "Authorization: Bearer \$NGC_API_KEY" https://api.ngc.nvidia.com/v2/auth/verify
  - Regenerate NGC API key if needed

EOF
                        ;;
                esac
            done
        fi
    fi
    
    # Add recommendations
    cat >> "$report_file" << EOF
## Recommended Actions

1. **Check pod status**: kubectl get pods -n $NAMESPACE
2. **View recent events**: kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp'
3. **Check service status**: kubectl get svc -n $NAMESPACE
4. **Verify GPU allocation**: kubectl describe nodes | grep -A 5 "nvidia.com/gpu"

## Log Files

- Deployment logs: $LOG_DIR/helm-status.log
- Pod logs: $LOG_DIR/pods-*.log
- Events: $LOG_DIR/events.log

EOF
    
    log_success "Troubleshooting report generated: $report_file"
}

# Function to suggest solutions based on patterns
suggest_solutions() {
    local pattern="$1"
    
    case "$pattern" in
        "IMAGE_PULL_FAILURE")
            log_info "Suggested solutions for image pull failure:"
            log_info "1. Verify NGC_API_KEY: export NGC_API_KEY=nvapi-your-key-here"
            log_info "2. Check NGC access: curl -H 'Authorization: Bearer \$NGC_API_KEY' https://api.ngc.nvidia.com/v2/auth/verify"
            log_info "3. Regenerate NGC API key at: https://ngc.nvidia.com/setup/api-key"
            ;;
        "GPU_ALLOCATION_FAILURE")
            log_info "Suggested solutions for GPU allocation failure:"
            log_info "1. Check GPU nodes: kubectl get nodes -l nvidia.com/gpu.present=true"
            log_info "2. Verify GPU quota in OCI Console → Service Limits"
            log_info "3. Request GPU quota increase if needed"
            ;;
        "MEMORY_PRESSURE")
            log_info "Suggested solutions for memory pressure:"
            log_info "1. Increase memory limits in helm/values.yaml"
            log_info "2. Check model size vs. available memory"
            log_info "3. Consider smaller model or larger instance"
            ;;
        *)
            log_info "No specific solutions for pattern: $pattern"
            ;;
    esac
}

# Main analysis function
analyze_logs() {
    local namespace="${1:-$NAMESPACE}"
    
    log_info "Starting comprehensive log analysis for namespace: $namespace"
    
    # Collect all logs
    collect_deployment_logs "$namespace"
    collect_pod_logs "$namespace"
    collect_events "$namespace"
    
    # Analyze patterns
    analyze_error_patterns
    analyze_performance_patterns
    analyze_resource_patterns
    
    # Generate report
    generate_troubleshooting_report
    
    log_success "Log analysis completed successfully"
    log_info "Review troubleshooting report: $LOG_DIR/troubleshooting-report.md"
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    analyze_logs "$@"
fi
