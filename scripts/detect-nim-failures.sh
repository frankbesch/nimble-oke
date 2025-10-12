#!/usr/bin/env bash

# NIM-specific failure detection and troubleshooting for Nimble OKE
# Identifies common NIM deployment failure patterns

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

detect_nim_pod_issues() {
    log_info "=== Detecting NIM Pod Issues ==="
    
    local namespace="${NAMESPACE:-default}"
    local nim_pods
    nim_pods=$(kubectl get pods -n "$namespace" -l app.kubernetes.io/name=nvidia-nim --no-headers 2>/dev/null || echo "")
    
    if [[ -z "$nim_pods" ]]; then
        log_error "❌ No NIM pods found"
        echo "  Check: kubectl get pods -n $namespace -l app.kubernetes.io/name=nvidia-nim"
        return 1
    fi
    
    echo "Found NIM pods:"
    echo "$nim_pods"
    echo ""
    
    # Check pod status
    while IFS= read -r pod_line; do
        [[ -z "$pod_line" ]] && continue
        
        local pod_name
        pod_name=$(echo "$pod_line" | awk '{print $1}')
        local pod_status
        pod_status=$(echo "$pod_line" | awk '{print $3}')
        
        echo "Pod: $pod_name"
        echo "Status: $pod_status"
        
        case "$pod_status" in
            "Running")
                log_success "✅ Pod running"
                ;;
            "Pending")
                log_warn "⚠️  Pod pending - checking reasons..."
                check_pod_pending_reasons "$pod_name" "$namespace"
                ;;
            "CrashLoopBackOff"|"Error")
                log_error "❌ Pod crashed - checking logs..."
                check_pod_crash_logs "$pod_name" "$namespace"
                ;;
            "ImagePullBackOff")
                log_error "❌ Image pull failed - checking NGC credentials..."
                check_image_pull_issues "$pod_name" "$namespace"
                ;;
            *)
                log_warn "⚠️  Unknown status: $pod_status"
                ;;
        esac
        echo ""
    done <<< "$nim_pods"
    
    return 0
}

check_pod_pending_reasons() {
    local pod_name="$1"
    local namespace="$2"
    
    local events
    events=$(kubectl describe pod "$pod_name" -n "$namespace" 2>/dev/null | grep -A 10 "Events:" || echo "")
    
    if echo "$events" | grep -q "Insufficient nvidia.com/gpu"; then
        log_error "❌ GPU resource insufficient"
        echo "  Fix: Check GPU node availability and resource requests"
        echo "  Run: kubectl get nodes -o wide | grep gpu"
    elif echo "$events" | grep -q "Insufficient memory"; then
        log_error "❌ Memory insufficient"
        echo "  Fix: Reduce memory requests or add more nodes"
        echo "  Current: kubectl describe node | grep -A 5 'Allocated resources'"
    elif echo "$events" | grep -q "Insufficient cpu"; then
        log_error "❌ CPU insufficient"
        echo "  Fix: Reduce CPU requests or add more nodes"
    elif echo "$events" | grep -q "0/1 nodes are available"; then
        log_error "❌ No suitable nodes"
        echo "  Fix: Check node taints and tolerations"
        echo "  Run: kubectl describe nodes | grep -A 3 Taints"
    else
        log_warn "⚠️  Other pending reason - check pod events"
        echo "$events"
    fi
}

check_pod_crash_logs() {
    local pod_name="$1"
    local namespace="$2"
    
    echo "Recent pod logs:"
    kubectl logs "$pod_name" -n "$namespace" --tail=20 2>/dev/null || echo "  No logs available"
    echo ""
    
    # Check for common NIM crash patterns
    local logs
    logs=$(kubectl logs "$pod_name" -n "$namespace" --tail=50 2>/dev/null || echo "")
    
    if echo "$logs" | grep -q "CUDA out of memory"; then
        log_error "❌ CUDA out of memory"
        echo "  Fix: Reduce model size or increase GPU memory"
        echo "  Check: GPU memory allocation in values.yaml"
    elif echo "$logs" | grep -q "NGC API key"; then
        log_error "❌ NGC API key issue"
        echo "  Fix: Check NGC_API_KEY secret"
        echo "  Run: kubectl get secret nvidia-nim-ngc-api -o yaml"
    elif echo "$logs" | grep -q "Model not found"; then
        log_error "❌ Model download failed"
        echo "  Fix: Check model name and NGC access"
        echo "  Verify: Model name in values.yaml"
    elif echo "$logs" | grep -q "Permission denied"; then
        log_error "❌ File permission issue"
        echo "  Fix: Check PVC mount permissions"
        echo "  Check: securityContext in deployment.yaml"
    else
        log_warn "⚠️  Unknown crash pattern - check full logs"
        echo "  Run: kubectl logs $pod_name -n $namespace --previous"
    fi
}

check_image_pull_issues() {
    local pod_name="$1"
    local namespace="$2"
    
    echo "Image pull events:"
    kubectl describe pod "$pod_name" -n "$namespace" 2>/dev/null | grep -A 5 "Failed to pull image" || echo "  No pull errors found"
    echo ""
    
    # Check NGC secret
    local ngc_secret
    ngc_secret=$(kubectl get secret nvidia-nim-ngc-api -n "$namespace" 2>/dev/null || echo "")
    
    if [[ -z "$ngc_secret" ]]; then
        log_error "❌ NGC secret missing"
        echo "  Fix: Create NGC secret with API key"
        echo "  Run: kubectl create secret generic nvidia-nim-ngc-api --from-literal=NGC_API_KEY=nvapi-..."
    else
        log_success "✅ NGC secret exists"
    fi
    
    # Check image pull secrets
    local pull_secrets
    pull_secrets=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.imagePullSecrets[*].name}' 2>/dev/null || echo "")
    
    if [[ -z "$pull_secrets" ]]; then
        log_error "❌ No image pull secrets configured"
        echo "  Fix: Add ngc-secret to imagePullSecrets"
        echo "  Update: values.yaml imagePullSecrets section"
    else
        log_success "✅ Image pull secrets configured: $pull_secrets"
    fi
}

detect_gpu_issues() {
    log_info "=== Detecting GPU Issues ==="
    
    # Check GPU nodes
    local gpu_nodes
    gpu_nodes=$(kubectl get nodes -o wide | grep gpu || echo "")
    
    if [[ -z "$gpu_nodes" ]]; then
        log_error "❌ No GPU nodes found"
        echo "  Fix: Ensure GPU node pool is created and nodes are ready"
        echo "  Check: oci ce node-pool list --cluster-id <cluster-id>"
        return 1
    fi
    
    echo "GPU nodes found:"
    echo "$gpu_nodes"
    echo ""
    
    # Check NVIDIA device plugin
    local device_plugin
    device_plugin=$(kubectl get daemonset -n kube-system -l name=nvidia-device-plugin-ds 2>/dev/null || echo "")
    
    if [[ -z "$device_plugin" ]]; then
        log_error "❌ NVIDIA device plugin not found"
        echo "  Fix: Install NVIDIA device plugin"
        echo "  Run: kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/main/deployments/static/nvidia-device-plugin.yaml"
    else
        log_success "✅ NVIDIA device plugin installed"
    fi
    
    # Check GPU resources
    local gpu_resources
    gpu_resources=$(kubectl describe nodes | grep -A 5 "nvidia.com/gpu" || echo "")
    
    if [[ -z "$gpu_resources" ]]; then
        log_error "❌ No GPU resources visible to Kubernetes"
        echo "  Fix: Restart NVIDIA device plugin"
        echo "  Run: kubectl rollout restart daemonset/nvidia-device-plugin-ds -n kube-system"
    else
        log_success "✅ GPU resources available:"
        echo "$gpu_resources"
    fi
}

detect_storage_issues() {
    log_info "=== Detecting Storage Issues ==="
    
    local namespace="${NAMESPACE:-default}"
    
    # Check PVC status
    local pvcs
    pvcs=$(kubectl get pvc -n "$namespace" -l app.kubernetes.io/name=nvidia-nim 2>/dev/null || echo "")
    
    if [[ -z "$pvcs" ]]; then
        log_warn "⚠️  No NIM PVCs found"
        echo "  Check: PVC creation in deployment"
        return 0
    fi
    
    echo "NIM PVCs:"
    echo "$pvcs"
    echo ""
    
    # Check PVC status
    while IFS= read -r pvc_line; do
        [[ -z "$pvc_line" ]] && continue
        
        local pvc_name
        pvc_name=$(echo "$pvc_line" | awk '{print $1}')
        local pvc_status
        pvc_status=$(echo "$pvc_line" | awk '{print $2}')
        
        echo "PVC: $pvc_name"
        echo "Status: $pvc_status"
        
        if [[ "$pvc_status" == "Bound" ]]; then
            log_success "✅ PVC bound successfully"
        else
            log_error "❌ PVC not bound"
            echo "  Check: kubectl describe pvc $pvc_name -n $namespace"
            
            # Check storage class
            local storage_class
            storage_class=$(kubectl get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "")
            echo "  Storage class: $storage_class"
            
            # Check if storage class exists
            if ! kubectl get storageclass "$storage_class" &>/dev/null; then
                log_error "❌ Storage class '$storage_class' not found"
                echo "  Fix: Check available storage classes"
                echo "  Run: kubectl get storageclass"
            fi
        fi
        echo ""
    done <<< "$pvcs"
    
    return 0
}

detect_loadbalancer_issues() {
    log_info "=== Detecting LoadBalancer Issues ==="
    
    local namespace="${NAMESPACE:-default}"
    
    # Check service status
    local services
    services=$(kubectl get svc -n "$namespace" -l app.kubernetes.io/name=nvidia-nim 2>/dev/null || echo "")
    
    if [[ -z "$services" ]]; then
        log_error "❌ No NIM services found"
        echo "  Fix: Check service creation in Helm chart"
        return 1
    fi
    
    echo "NIM services:"
    echo "$services"
    echo ""
    
    # Check LoadBalancer status
    while IFS= read -r svc_line; do
        [[ -z "$svc_line" ]] && continue
        
        local svc_name
        svc_name=$(echo "$svc_line" | awk '{print $1}')
        local svc_type
        svc_type=$(echo "$svc_line" | awk '{print $2}')
        local external_ip
        external_ip=$(echo "$svc_line" | awk '{print $4}')
        
        if [[ "$svc_type" == "LoadBalancer" ]]; then
            echo "LoadBalancer Service: $svc_name"
            
            if [[ "$external_ip" == "<pending>" ]] || [[ -z "$external_ip" ]]; then
                log_error "❌ LoadBalancer external IP pending"
                echo "  Check: kubectl describe svc $svc_name -n $namespace"
                
                # Check OCI annotations
                local annotations
                annotations=$(kubectl get svc "$svc_name" -n "$namespace" -o jsonpath='{.metadata.annotations}' 2>/dev/null || echo "")
                
                if echo "$annotations" | grep -q "oci-load-balancer-shape"; then
                    log_success "✅ OCI LoadBalancer annotations present"
                else
                    log_error "❌ Missing OCI LoadBalancer annotations"
                    echo "  Fix: Add OCI annotations to service"
                    echo "  Check: values.yaml service.annotations"
                fi
            else
                log_success "✅ LoadBalancer external IP: $external_ip"
                
                # Test connectivity
                if curl -s --max-time 10 "http://$external_ip:8000/v1/health" &>/dev/null; then
                    log_success "✅ NIM API responding"
                else
                    log_warn "⚠️  NIM API not responding"
                    echo "  Check: Pod logs and health status"
                fi
            fi
        fi
        echo ""
    done <<< "$services"
    
    return 0
}

generate_failure_report() {
    echo ""
    echo "==============================================================="
    echo "NIM FAILURE DETECTION REPORT"
    echo "==============================================================="
    echo ""
    echo "Common NIM Failure Patterns:"
    echo ""
    echo "1. IMAGE PULL FAILURES:"
    echo "   • NGC API key invalid/missing"
    echo "   • Network connectivity to nvcr.io"
    echo "   • Image pull secrets not configured"
    echo ""
    echo "2. GPU RESOURCE ISSUES:"
    echo "   • NVIDIA device plugin not installed"
    echo "   • GPU nodes not available"
    echo "   • Insufficient GPU quota"
    echo ""
    echo "3. MODEL DOWNLOAD FAILURES:"
    echo "   • NGC model access permissions"
    echo "   • Storage space insufficient"
    echo "   • Network timeouts during download"
    echo ""
    echo "4. MEMORY PRESSURE:"
    echo "   • OOM kills due to large model"
    echo "   • Insufficient node memory"
    echo "   • Memory limits too low"
    echo ""
    echo "5. LOADBALANCER ISSUES:"
    echo "   • Missing OCI annotations"
    echo "   • Insufficient quota for external IPs"
    echo "   • Security list restrictions"
    echo ""
}

main() {
    log_info "Starting NIM failure detection..."
    echo ""
    
    detect_nim_pod_issues
    echo ""
    detect_gpu_issues
    echo ""
    detect_storage_issues
    echo ""
    detect_loadbalancer_issues
    echo ""
    generate_failure_report
    
    log_success "✅ NIM failure detection complete"
}

# Usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
