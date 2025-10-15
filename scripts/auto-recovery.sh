#!/bin/bash

# Auto-Recovery System for NVIDIA NIM on OKE
# Provides self-healing capabilities with automatic failure detection and recovery

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Configuration
NAMESPACE="${NAMESPACE:-nim}"
RELEASE_NAME="${RELEASE_NAME:-nvidia-nim}"
MONITORING_INTERVAL="${MONITORING_INTERVAL:-30}"  # seconds
MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-3}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-300}"  # 5 minutes
NOTIFICATION_ENABLED="${NOTIFICATION_ENABLED:-yes}"
RECOVERY_LOG_FILE="/tmp/nim-auto-recovery.log"

log_info "Auto-Recovery System initialized"
log_info "Namespace: $NAMESPACE"
log_info "Release: $RELEASE_NAME"
log_info "Monitoring interval: ${MONITORING_INTERVAL}s"

# Function to check pod health status
check_pod_health() {
    local namespace="$1"
    
    log_info "Checking pod health status..."
    
    local pods
    pods=$(kubectl get pods -n "$namespace" -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null || echo "")
    
    if [[ -z "$pods" ]]; then
        log_error "No NIM pods found"
        return 1
    fi
    
    local unhealthy_pods=0
    local total_pods=0
    
    echo "$pods" | while read -r line; do
        local pod_name
        local status
        local ready_status
        local restarts
        
        pod_name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $3}')
        ready_status=$(echo "$line" | awk '{print $2}')
        restarts=$(echo "$line" | awk '{print $4}')
        
        ((total_pods++))
        
        # Check for unhealthy conditions
        if [[ "$status" != "Running" ]]; then
            log_warn "Pod $pod_name is not running (status: $status)"
            ((unhealthy_pods++))
        elif [[ "$ready_status" != "1/1" ]]; then
            log_warn "Pod $pod_name is not ready ($ready_status)"
            ((unhealthy_pods++))
        elif [[ "$restarts" -gt 2 ]]; then
            log_warn "Pod $pod_name has excessive restarts ($restarts)"
            ((unhealthy_pods++))
        else
            log_success "Pod $pod_name is healthy"
        fi
    done
    
    # Check overall health
    if [[ $unhealthy_pods -gt 0 ]]; then
        log_error "Pod health check failed: $unhealthy_pods/$total_pods pods unhealthy"
        return 1
    else
        log_success "All pods are healthy: $total_pods/$total_pods"
        return 0
    fi
}

# Function to check service health
check_service_health() {
    local namespace="$1"
    
    log_info "Checking service health..."
    
    local services
    services=$(kubectl get svc -n "$namespace" -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null || echo "")
    
    if [[ -z "$services" ]]; then
        log_error "No NIM services found"
        return 1
    fi
    
    echo "$services" | while read -r line; do
        local service_name
        local service_type
        local cluster_ip
        local external_ip
        
        service_name=$(echo "$line" | awk '{print $1}')
        service_type=$(echo "$line" | awk '{print $2}')
        cluster_ip=$(echo "$line" | awk '{print $3}')
        external_ip=$(echo "$line" | awk '{print $4}')
        
        # Check service endpoints
        local endpoints
        endpoints=$(kubectl get endpoints "$service_name" -n "$namespace" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
        
        if [[ -z "$endpoints" ]]; then
            log_error "Service $service_name has no endpoints"
            return 1
        else
            log_success "Service $service_name has endpoints: $endpoints"
        fi
        
        # Check external IP for LoadBalancer
        if [[ "$service_type" == "LoadBalancer" && "$external_ip" == "<pending>" ]]; then
            log_warn "LoadBalancer $service_name is still pending external IP"
            return 1
        fi
    done
    
    log_success "All services are healthy"
    return 0
}

# Function to check GPU allocation
check_gpu_allocation() {
    local namespace="$1"
    
    log_info "Checking GPU allocation..."
    
    local pods
    pods=$(kubectl get pods -n "$namespace" -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null || echo "")
    
    if [[ -z "$pods" ]]; then
        log_error "No pods found for GPU allocation check"
        return 1
    fi
    
    local gpu_allocation_issues=0
    
    echo "$pods" | while read -r line; do
        local pod_name
        pod_name=$(echo "$line" | awk '{print $1}')
        
        # Check if GPU is allocated
        local gpu_allocated
        gpu_allocated=$(kubectl describe pod "$pod_name" -n "$namespace" | grep -c "nvidia.com/gpu: 1" || echo "0")
        
        if [[ $gpu_allocated -eq 0 ]]; then
            log_error "Pod $pod_name has no GPU allocation"
            ((gpu_allocation_issues++))
        else
            log_success "Pod $pod_name has GPU allocated"
        fi
    done
    
    if [[ $gpu_allocation_issues -gt 0 ]]; then
        log_error "GPU allocation check failed: $gpu_allocation_issues issues found"
        return 1
    else
        log_success "GPU allocation check passed"
        return 0
    fi
}

# Function to attempt pod restart
attempt_pod_restart() {
    local namespace="$1"
    local max_wait_time="${2:-300}"  # 5 minutes default
    
    log_info "Attempting pod restart..."
    
    # Get unhealthy pods
    local unhealthy_pods
    unhealthy_pods=$(kubectl get pods -n "$namespace" -l app.kubernetes.io/name=nvidia-nim --field-selector=status.phase!=Running --no-headers | awk '{print $1}' || echo "")
    
    if [[ -z "$unhealthy_pods" ]]; then
        # Force restart all pods
        log_info "Force restarting all NIM pods..."
        kubectl delete pods -n "$namespace" -l app.kubernetes.io/name=nvidia-nim --grace-period=30
    else
        # Restart only unhealthy pods
        log_info "Restarting unhealthy pods: $unhealthy_pods"
        echo "$unhealthy_pods" | xargs -I {} kubectl delete pod {} -n "$namespace" --grace-period=30
    fi
    
    # Wait for pods to be ready
    log_info "Waiting for pods to be ready..."
    local wait_time=0
    
    while [[ $wait_time -lt $max_wait_time ]]; do
        local ready_pods
        local total_pods
        
        total_pods=$(kubectl get pods -n "$namespace" -l app.kubernetes.io/name=nvidia-nim --no-headers | wc -l)
        ready_pods=$(kubectl get pods -n "$namespace" -l app.kubernetes.io/name=nvidia-nim --no-headers | grep "Running" | wc -l)
        
        if [[ $ready_pods -eq $total_pods && $total_pods -gt 0 ]]; then
            log_success "All pods are ready: $ready_pods/$total_pods"
            return 0
        fi
        
        log_info "Pods ready: $ready_pods/$total_pods (waiting...)"
        sleep 10
        wait_time=$((wait_time + 10))
    done
    
    log_error "Timeout waiting for pods to be ready"
    return 1
}

# Function to attempt redeployment
attempt_redeployment() {
    local namespace="$1"
    local release_name="$2"
    
    log_info "Attempting redeployment..."
    
    # Uninstall current deployment
    log_info "Uninstalling current deployment..."
    helm uninstall "$release_name" -n "$namespace" --wait || true
    
    # Wait for resources to be cleaned up
    sleep 30
    
    # Redeploy using parallel deployment
    log_info "Redeploying using parallel pipeline..."
    if [[ -f "${SCRIPT_DIR}/deploy-parallel.sh" ]]; then
        "${SCRIPT_DIR}/deploy-parallel.sh"
    else
        # Fallback to standard deployment
        log_info "Using standard deployment as fallback..."
        "${SCRIPT_DIR}/deploy.sh"
    fi
    
    local deployment_exit_code=$?
    
    if [[ $deployment_exit_code -eq 0 ]]; then
        log_success "Redeployment completed successfully"
        return 0
    else
        log_error "Redeployment failed"
        return 1
    fi
}

# Function to notify operator
notify_operator() {
    local message="$1"
    local severity="${2:-WARNING}"
    
    if [[ "$NOTIFICATION_ENABLED" != "yes" ]]; then
        log_info "Notifications disabled, skipping operator notification"
        return 0
    fi
    
    log_info "Notifying operator: $message"
    
    # Log to recovery log file
    echo "[$(date)] [$severity] $message" >> "$RECOVERY_LOG_FILE"
    
    # Send notification (implement based on your notification system)
    # Examples: email, Slack, PagerDuty, etc.
    
    # For now, just log to console
    case "$severity" in
        "CRITICAL")
            log_error "CRITICAL ALERT: $message"
            ;;
        "WARNING")
            log_warn "WARNING: $message"
            ;;
        "INFO")
            log_info "INFO: $message"
            ;;
    esac
    
    # Example: Send to webhook (uncomment and configure as needed)
    # curl -X POST -H "Content-Type: application/json" \
    #      -d "{\"text\":\"[$severity] $message\"}" \
    #      "$NOTIFICATION_WEBHOOK_URL" || true
}

# Function to record recovery history
record_recovery_history() {
    local action="$1"
    local success="$2"
    local details="$3"
    
    local history_file="/tmp/nim-recovery-history.json"
    
    # Create history entry
    local entry
    entry=$(cat <<EOF
{
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "action": "$action",
    "success": $success,
    "details": "$details"
}
EOF
)
    
    # Append to history file
    if [[ -f "$history_file" ]]; then
        # Add comma and new entry
        echo "," >> "$history_file"
        echo "$entry" >> "$history_file"
    else
        # Create new file with array
        echo "[$entry" > "$history_file"
    fi
    
    log_info "Recovery history recorded: $action ($(if $success; then echo "SUCCESS"; else echo "FAILED"; fi))"
}

# Function to get recovery statistics
get_recovery_statistics() {
    local history_file="/tmp/nim-recovery-history.json"
    
    if [[ ! -f "$history_file" ]]; then
        log_info "No recovery history found"
        return 0
    fi
    
    # Complete JSON array
    echo "]" >> "$history_file"
    
    # Parse statistics
    local total_recoveries
    local successful_recoveries
    local failed_recoveries
    
    total_recoveries=$(jq '. | length' "$history_file")
    successful_recoveries=$(jq '[.[] | select(.success == true)] | length' "$history_file")
    failed_recoveries=$(jq '[.[] | select(.success == false)] | length' "$history_file")
    
    log_info "Recovery Statistics:"
    log_info "  Total recoveries: $total_recoveries"
    log_info "  Successful: $successful_recoveries"
    log_info "  Failed: $failed_recoveries"
    
    if [[ $total_recoveries -gt 0 ]]; then
        local success_rate
        success_rate=$(echo "scale=1; ($successful_recoveries / $total_recoveries) * 100" | bc -l)
        log_info "  Success rate: ${success_rate}%"
    fi
}

# Function to perform comprehensive health check
comprehensive_health_check() {
    local namespace="$1"
    local health_issues=0
    
    log_info "Performing comprehensive health check..."
    
    # Check pod health
    if ! check_pod_health "$namespace"; then
        ((health_issues++))
    fi
    
    # Check service health
    if ! check_service_health "$namespace"; then
        ((health_issues++))
    fi
    
    # Check GPU allocation
    if ! check_gpu_allocation "$namespace"; then
        ((health_issues++))
    fi
    
    # Check API endpoint
    local service_ip
    service_ip=$(kubectl get svc -n "$namespace" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -n "$service_ip" ]]; then
        if ! curl -s --connect-timeout 10 "http://$service_ip:8000/health" >/dev/null; then
            log_warn "API endpoint health check failed"
            ((health_issues++))
        else
            log_success "API endpoint is healthy"
        fi
    else
        log_warn "No external service IP found for health check"
    fi
    
    return $health_issues
}

# Function to execute auto-recovery
execute_auto_recovery() {
    local namespace="$1"
    local release_name="$2"
    local recovery_attempt="${3:-1}"
    
    log_info "Executing auto-recovery (attempt $recovery_attempt/$MAX_RECOVERY_ATTEMPTS)..."
    
    # Try pod restart first
    if attempt_pod_restart "$namespace" "$RECOVERY_TIMEOUT"; then
        log_success "Pod restart successful"
        record_recovery_history "pod_restart" true "Pods restarted successfully"
        
        # Verify health after restart
        sleep 30
        if comprehensive_health_check "$namespace"; then
            log_success "Health check passed after pod restart"
            return 0
        else
            log_warn "Health check failed after pod restart"
        fi
    else
        log_warn "Pod restart failed"
        record_recovery_history "pod_restart" false "Pod restart failed"
    fi
    
    # Try redeployment if pod restart failed or health check failed
    if [[ $recovery_attempt -lt $MAX_RECOVERY_ATTEMPTS ]]; then
        log_info "Attempting redeployment..."
        
        if attempt_redeployment "$namespace" "$release_name"; then
            log_success "Redeployment successful"
            record_recovery_history "redeployment" true "Full redeployment completed"
            
            # Verify health after redeployment
            sleep 60
            if comprehensive_health_check "$namespace"; then
                log_success "Health check passed after redeployment"
                return 0
            else
                log_error "Health check failed after redeployment"
                record_recovery_history "redeployment" false "Health check failed after redeployment"
            fi
        else
            log_error "Redeployment failed"
            record_recovery_history "redeployment" false "Redeployment failed"
        fi
    fi
    
    # All recovery attempts failed
    log_error "All recovery attempts failed"
    notify_operator "Auto-recovery failed after $MAX_RECOVERY_ATTEMPTS attempts. Manual intervention required." "CRITICAL"
    return 1
}

# Function to run continuous monitoring
run_continuous_monitoring() {
    local namespace="$1"
    local release_name="$2"
    
    log_info "Starting continuous monitoring and auto-recovery..."
    log_info "Monitoring interval: ${MONITORING_INTERVAL} seconds"
    log_info "Max recovery attempts: $MAX_RECOVERY_ATTEMPTS"
    
    local recovery_count=0
    
    while true; do
        log_info "Performing health check..."
        
        if ! comprehensive_health_check "$namespace"; then
            log_warn "Health check failed, initiating auto-recovery..."
            
            ((recovery_count++))
            
            if execute_auto_recovery "$namespace" "$release_name" "$recovery_count"; then
                log_success "Auto-recovery successful"
                recovery_count=0  # Reset counter on success
            else
                log_error "Auto-recovery failed (attempt $recovery_count)"
                
                if [[ $recovery_count -ge $MAX_RECOVERY_ATTEMPTS ]]; then
                    log_error "Maximum recovery attempts reached, stopping monitoring"
                    notify_operator "Auto-recovery system stopped after $MAX_RECOVERY_ATTEMPTS failed attempts" "CRITICAL"
                    break
                fi
            fi
        else
            log_success "Health check passed"
            recovery_count=0  # Reset counter on successful health check
        fi
        
        # Show recovery statistics
        if [[ $((recovery_count % 10)) -eq 0 ]]; then  # Every 10 iterations
            get_recovery_statistics
        fi
        
        log_info "Waiting ${MONITORING_INTERVAL} seconds until next health check..."
        sleep "$MONITORING_INTERVAL"
    done
}

# Function to stop monitoring
stop_monitoring() {
    log_info "Stopping auto-recovery monitoring..."
    
    # Kill any running monitoring processes
    local monitor_pid
    monitor_pid=$(pgrep -f "auto-recovery.sh" | grep -v $$ || echo "")
    
    if [[ -n "$monitor_pid" ]]; then
        kill "$monitor_pid" 2>/dev/null || true
        log_success "Monitoring stopped (PID: $monitor_pid)"
    else
        log_info "No monitoring processes found"
    fi
    
    # Show final statistics
    get_recovery_statistics
}

# Main auto-recovery function
auto_recovery() {
    local namespace="${1:-$NAMESPACE}"
    local release_name="${2:-$RELEASE_NAME}"
    local action="${3:-monitor}"
    
    case "$action" in
        "monitor")
            run_continuous_monitoring "$namespace" "$release_name"
            ;;
        "check")
            comprehensive_health_check "$namespace"
            ;;
        "recover")
            execute_auto_recovery "$namespace" "$release_name" 1
            ;;
        "stop")
            stop_monitoring
            ;;
        "stats")
            get_recovery_statistics
            ;;
        *)
            log_error "Unknown action: $action"
            log_info "Available actions: monitor, check, recover, stop, stats"
            return 1
            ;;
    esac
}

# Main execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_recovery "$@"
fi
