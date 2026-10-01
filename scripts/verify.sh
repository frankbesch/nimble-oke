#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly RELEASE_NAME="nvidia-nim"
readonly NAMESPACE="default"
readonly VALUES_FILE="${SCRIPT_DIR}/../helm/values.yaml"

# Kube context pin: provision-cluster.sh records KUBE_CONTEXT=<name> in
# cluster-info.txt. When present, every kubectl/helm call made by this script
# (including the _lib.sh helpers it calls) targets that context. The user's
# current-context is never changed. No KUBE_CONTEXT line: behaviour unchanged.
# NIMBLE_CLUSTER_INFO overrides the file path (tests only).
NIMBLE_CLUSTER_INFO="${NIMBLE_CLUSTER_INFO:-${SCRIPT_DIR}/cluster-info.txt}"
KUBE_CONTEXT_PIN=""
if [[ -f "$NIMBLE_CLUSTER_INFO" ]]; then
    KUBE_CONTEXT_PIN="$(sed -n 's/^KUBE_CONTEXT=//p' "$NIMBLE_CLUSTER_INFO" | tail -1)"
fi
if [[ -n "$KUBE_CONTEXT_PIN" ]]; then
    export HELM_KUBECONTEXT="$KUBE_CONTEXT_PIN"
    kubectl() { command kubectl --context "$KUBE_CONTEXT_PIN" "$@"; }
fi

# Port-forward state for the API checks; cleanup runs on every exit path.
PF_PID=""
LOCAL_PORT=""
RESP_FILE=""
cleanup_api_access() {
    if [[ -n "$PF_PID" ]]; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
        PF_PID=""
    fi
    if [[ -n "$RESP_FILE" ]]; then
        rm -f "$RESP_FILE"
        RESP_FILE=""
    fi
}
trap cleanup_api_access EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

free_local_port() {  # an unused 127.0.0.1 TCP port, chosen by the kernel
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# Model id for the inference request: NIM_MODEL, else the chart image
# repository without its "nim/" prefix (nim/meta/llama3-8b-instruct -> meta/llama3-8b-instruct).
chart_model_id() {
    if [[ -n "${NIM_MODEL:-}" ]]; then
        echo "$NIM_MODEL"
        return 0
    fi
    local repo
    repo=$(sed -n 's/^  repository:[[:space:]]*"\{0,1\}\([^"#[:space:]]*\).*/\1/p' "$VALUES_FILE" | head -1)
    echo "${repo#nim/}"
}

# Port-forward the ClusterIP service to a free local port; wait until it listens.
start_port_forward() {
    local ctx=() _
    [[ -n "$KUBE_CONTEXT_PIN" ]] && ctx=(--context "$KUBE_CONTEXT_PIN")
    LOCAL_PORT=$(free_local_port) || { log_warn "Could not pick a free local port"; return 1; }
    # exec in a subshell: $! is kubectl itself, so the cleanup kill reaches it.
    ( exec kubectl ${ctx[@]+"${ctx[@]}"} port-forward -n "$NAMESPACE" "svc/${RELEASE_NAME}" \
        "${LOCAL_PORT}:8000" </dev/null >/dev/null 2>&1 ) &
    PF_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$PF_PID" 2>/dev/null; then
            wait "$PF_PID" 2>/dev/null || true
            PF_PID=""
            log_warn "kubectl port-forward to svc/${RELEASE_NAME} exited (local port ${LOCAL_PORT})"
            return 1
        fi
        if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${LOCAL_PORT}/" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    log_warn "Port-forward on 127.0.0.1:${LOCAL_PORT} not answering after 10s"
    return 1
}

verify_deployment_exists() {
    # A label query exits 0 with no rows when nothing matches; require a name.
    local deployments
    if ! deployments=$(kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o name 2>/dev/null); then
        log_error "Could not list deployments (kubectl failed)"
        return 1
    fi
    if [[ -z "$deployments" ]]; then
        log_error "NIM deployment not found"
        return 1
    fi
    log_success "Deployment exists"
    return 0
}

verify_pods_running() {
    local pod_count
    pod_count=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$pod_count" == "0" ]]; then
        log_error "No NIM pods running"
        return 1
    fi
    
    log_success "Pods running: $pod_count"
    return 0
}

verify_pods_ready() {
    local ready_count
    ready_count=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status=="True")].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    
    if [[ "$ready_count" == "0" ]]; then
        log_error "No NIM pods ready"
        return 1
    fi
    
    log_success "Pods ready: $ready_count"
    return 0
}

verify_gpu_allocation() {
    local gpu_allocated
    gpu_allocated=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[*].spec.containers[*].resources.requests.nvidia\.com/gpu}' 2>/dev/null | tr ' ' '+' | bc 2>/dev/null || echo "0")
    
    if [[ "$gpu_allocated" == "0" ]] || [[ -z "$gpu_allocated" ]]; then
        log_error "No GPUs allocated to NIM pods"
        return 1
    fi
    
    log_success "GPUs allocated: $gpu_allocated"
    return 0
}

verify_service_exists() {
    if ! kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_error "NIM service not found"
        return 1
    fi
    
    local svc_type
    svc_type=$(kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.type}')
    log_success "Service exists (type: $svc_type)"
    return 0
}

verify_service_endpoint() {
    local external_ip
    external_ip=$(get_service_external_ip "$RELEASE_NAME" "$NAMESPACE")
    
    if [[ -z "$external_ip" ]]; then
        local svc_type
        svc_type=$(kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.type}')
        
        if [[ "$svc_type" == "LoadBalancer" ]]; then
            log_warn "LoadBalancer IP not yet assigned (may still be provisioning)"
            return 1
        else
            log_success "Service endpoint: ClusterIP (use port-forward for access)"
            return 0
        fi
    fi
    
    log_success "External endpoint: http://${external_ip}:8000"
    return 0
}

verify_pvc_bound() {
    local pvc_count
    pvc_count=$(kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim --field-selector=status.phase=Bound --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ "$pvc_count" == "0" ]]; then
        log_warn "No PVCs bound (model caching may not be persistent)"
        return 1
    fi
    
    log_success "PVCs bound: $pvc_count"
    return 0
}

verify_api_health() {
    log_info "Testing API health endpoint through a port-forward..."
    if [[ -z "$PF_PID" ]] && ! start_port_forward; then
        log_warn "API health check: no port-forward"
        return 1
    fi
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "http://127.0.0.1:${LOCAL_PORT}/v1/health/ready" 2>/dev/null || true)
    if [[ "$code" == "200" ]]; then
        log_success "API health check: PASSED (HTTP 200 on /v1/health/ready)"
        return 0
    fi
    log_warn "API health check: FAILED (HTTP ${code:-none}; service may still be starting)"
    return 1
}

# One real inference request. Success only on HTTP 200 with a non-empty completion.
verify_inference() {
    log_info "Sending one chat completion request..."
    if [[ -z "$PF_PID" ]] && ! start_port_forward; then
        log_error "Inference check: no port-forward"
        return 1
    fi
    local model body code text
    model=$(chart_model_id)
    if [[ -z "$model" ]]; then
        log_error "Inference check: no model id (set NIM_MODEL)"
        return 1
    fi
    body=$(python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "messages": [{"role": "user", "content": "Reply with one word: ready"}], "max_tokens": 8, "temperature": 0}))' "$model")
    RESP_FILE=$(mktemp "${TMPDIR:-/tmp}/nim-verify.XXXXXX") || { log_error "mktemp failed"; return 1; }
    code=$(curl -s -o "$RESP_FILE" -w '%{http_code}' --max-time 120 \
        -H 'Content-Type: application/json' -d "$body" \
        "http://127.0.0.1:${LOCAL_PORT}/v1/chat/completions" 2>/dev/null || true)
    text=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    c = d["choices"][0]
    t = (c.get("message") or {}).get("content") or c.get("text") or ""
except Exception:
    t = ""
print(t.strip().replace("\n", " ")[:80])
' "$RESP_FILE" 2>/dev/null || true)
    rm -f "$RESP_FILE"
    RESP_FILE=""
    if [[ "$code" == "200" && -n "$text" ]]; then
        log_success "Inference check: PASSED (model $model, HTTP 200, completion: \"$text\")"
        return 0
    fi
    log_error "Inference check: FAILED (model $model, HTTP ${code:-none}, completion empty=$([[ -z "$text" ]] && echo yes || echo no))"
    return 1
}

verify_model_loading() {
    local pod_name
    pod_name=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$pod_name" ]]; then
        log_warn "No pod found to check model loading"
        return 1
    fi
    
    log_info "Checking model loading status..."
    local logs
    logs=$(kubectl logs "$pod_name" -n "$NAMESPACE" --tail=100 2>/dev/null || echo "")
    
    if echo "$logs" | grep -qi "model.*loaded\|ready.*accept.*request"; then
        log_success "Model appears to be loaded"
        return 0
    elif echo "$logs" | grep -qi "loading.*model\|downloading"; then
        log_warn "Model still loading (this can take 30-45 minutes)"
        return 1
    else
        log_warn "Unable to determine model loading status from logs"
        return 1
    fi
}

main() {
    log_info "Verifying NIM deployment..."
    
    local failed=0
    local warnings=0
    
    echo ""
    echo "=== Deployment Verification ==="
    verify_deployment_exists || failed=$((failed + 1))
    verify_pods_running || failed=$((failed + 1))
    verify_pods_ready || failed=$((failed + 1))
    verify_gpu_allocation || failed=$((failed + 1))
    
    echo ""
    echo "=== Service Verification ==="
    verify_service_exists || failed=$((failed + 1))
    verify_service_endpoint || warnings=$((warnings + 1))
    
    echo ""
    echo "=== Storage Verification ==="
    verify_pvc_bound || warnings=$((warnings + 1))
    
    echo ""
    echo "=== API Verification ==="
    verify_api_health || warnings=$((warnings + 1))
    verify_inference || failed=$((failed + 1))
    cleanup_api_access
    verify_model_loading || warnings=$((warnings + 1))
    
    echo ""
    echo "=== Pod Details ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=nvidia-nim -o wide 2>/dev/null || echo "Unable to get pods"
    
    echo ""
    echo "=== Service Details ==="
    kubectl get svc "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || echo "Service not found"
    
    echo ""
    if [[ $failed -eq 0 ]]; then
        if [[ $warnings -eq 0 ]]; then
            log_success "All verification checks passed"
            echo ""
            log_info "Next steps:"
            log_info "  - Test inference: make test-inference"
            log_info "  - View operations: make operate"
            return 0
        else
            log_success "Critical checks passed ($warnings warnings)"
            log_warn "Some optional checks failed (service may still be initializing)"
            echo ""
            log_info "Wait a few minutes and run 'make verify' again"
            return 0
        fi
    else
        log_error "Verification failed ($failed critical checks failed)"
        echo ""
        log_info "Troubleshoot with: make troubleshoot"
        return 1
    fi
}

main "$@"

