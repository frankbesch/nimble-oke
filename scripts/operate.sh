#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly RELEASE_NAME="nvidia-nim"
readonly NAMESPACE="default"

main() {
    log_info "NIM Operational Commands"
    
    local external_ip
    external_ip=$(get_service_external_ip "$RELEASE_NAME" "$NAMESPACE")
    
    echo ""
    echo "=== Quick Status ==="
    echo "Deployment: $RELEASE_NAME"
    echo "Namespace: $NAMESPACE"
    
    if [[ -n "$external_ip" ]]; then
        echo "Endpoint: http://${external_ip}:8000"
        echo "Export: export NIM_ENDPOINT=http://${external_ip}:8000"
    else
        echo "Endpoint: Not yet available (LoadBalancer provisioning)"
        echo "Use port-forward: kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME 8000:8000"
    fi
    
    echo ""
    echo "=== View Pods ==="
    echo "kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim"
    echo "kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim -o wide"
    
    echo ""
    echo "=== View Logs ==="
    echo "# All pods:"
    echo "kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim --tail=100"
    echo ""
    echo "# Follow logs:"
    echo "kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim -f"
    echo ""
    echo "# Specific pod:"
    echo "kubectl logs -n $NAMESPACE <pod-name>"
    
    echo ""
    echo "=== Describe Resources ==="
    echo "kubectl describe deployment -n $NAMESPACE $RELEASE_NAME"
    echo "kubectl describe pods -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim"
    echo "kubectl describe svc -n $NAMESPACE $RELEASE_NAME"
    
    echo ""
    echo "=== Check GPU Usage ==="
    echo "kubectl exec -n $NAMESPACE -it <pod-name> -- nvidia-smi"
    
    echo ""
    echo "=== Port Forward (if LoadBalancer not ready) ==="
    echo "kubectl port-forward -n $NAMESPACE svc/$RELEASE_NAME 8000:8000"
    echo "# Then access: http://localhost:8000"
    
    echo ""
    echo "=== API Testing ==="
    if [[ -n "$external_ip" ]]; then
        echo "# Health check:"
        echo "curl http://${external_ip}:8000/v1/health/ready"
        echo ""
        echo "# List models:"
        echo "curl http://${external_ip}:8000/v1/models"
        echo ""
        echo "# Test inference:"
        echo "curl -X POST http://${external_ip}:8000/v1/chat/completions \\"
        echo "  -H 'Content-Type: application/json' \\"
        echo "  -d '{
    \"model\": \"meta/llama-3.1-8b-instruct\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}],
    \"max_tokens\": 50
  }'"
    else
        echo "# (Set NIM_ENDPOINT first)"
        echo "curl \$NIM_ENDPOINT/v1/health/ready"
        echo "curl \$NIM_ENDPOINT/v1/models"
    fi
    
    echo ""
    echo "=== Resource Usage ==="
    echo "kubectl top pods -n $NAMESPACE -l app.kubernetes.io/name=nvidia-nim"
    echo "kubectl top nodes"
    
    echo ""
    echo "=== Helm Operations ==="
    echo "# List releases:"
    echo "helm list -n $NAMESPACE"
    echo ""
    echo "# Get values:"
    echo "helm get values $RELEASE_NAME -n $NAMESPACE"
    echo ""
    echo "# Upgrade with new values:"
    echo "helm upgrade $RELEASE_NAME ./helm -n $NAMESPACE -f ./helm/values.yaml"
    echo ""
    echo "# Rollback:"
    echo "helm rollback $RELEASE_NAME -n $NAMESPACE"
    
    echo ""
    echo "=== Scaling ==="
    echo "# Scale up:"
    echo "kubectl scale deployment $RELEASE_NAME -n $NAMESPACE --replicas=2"
    echo ""
    echo "# Scale down:"
    echo "kubectl scale deployment $RELEASE_NAME -n $NAMESPACE --replicas=1"
    
    echo ""
    echo "=== Events ==="
    echo "kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | grep -i nim"
    
    echo ""
    echo "=== Cost Monitoring ==="
    local gpu_count
    gpu_count=$(get_gpu_count)
    local hourly_cost
    hourly_cost=$(estimate_hourly_cost "$gpu_count")
    echo "Current hourly cost: \$$(format_cost "$hourly_cost")"
    echo "Daily cost (if running 24/7): \$$(format_cost "$(echo "$hourly_cost * 24" | bc -l)")"
    echo "REMINDER: Run 'make cleanup' when finished to stop charges"
    
    echo ""
    echo "=== Quick Troubleshooting ==="
    echo "make troubleshoot    # Run full troubleshooting"
    echo "make verify          # Re-run verification"
    echo ""
    
    log_success "Operational commands listed above"
}

main "$@"

