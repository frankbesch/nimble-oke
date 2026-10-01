#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Emergency cleanup: stop GPU and cluster billing for THIS project.
# Scope is deliberately narrow:
#   - OKE node pools and clusters in $OCI_COMPARTMENT_ID
#   - the node pool / cluster recorded in cluster-info.txt
#   - the NIM release's PVC/Service, only via this cluster's kubeconfig context
# It never touches other compute instances, volumes or load balancers.

readonly INFO_FILE="${SCRIPT_DIR}/cluster-info.txt"
readonly RELEASE_NAME="nvidia-nim"
readonly NIM_NAMESPACE="default"
readonly NIM_SELECTOR="app.kubernetes.io/instance=${RELEASE_NAME}"
readonly SETTLE_SECONDS="${EMERGENCY_SETTLE_SECONDS:-10}"
readonly ALIVE_FILTER="data[?\"lifecycle-state\"!='DELETED' && \"lifecycle-state\"!='DELETING'].id"

FAILURES=0
REC_CLUSTER_ID=""
REC_NODE_POOL_ID=""

fail() {
    log_error "$*"
    FAILURES=$((FAILURES + 1))
}

# Print OCIDs (one per line) of non-deleted OKE resources of $1 kind
# (cluster | node-pool) in the compartment. Non-zero if the list call fails.
list_alive() {
    local kind="$1" json
    json=$(oci ce "$kind" list --compartment-id "$OCI_COMPARTMENT_ID" --all --query "$ALIVE_FILTER") || return 1
    printf '%s' "${json:-[]}" | jq -r '.[]'
}

load_recorded_ids() {
    if [[ -f "$INFO_FILE" ]]; then
        REC_CLUSTER_ID=$(grep '^CLUSTER_ID=' "$INFO_FILE" | tail -1 | cut -d= -f2- || true)
        REC_NODE_POOL_ID=$(grep '^NODE_POOL_ID=' "$INFO_FILE" | tail -1 | cut -d= -f2- || true)
        log_info "cluster-info.txt: cluster=${REC_CLUSTER_ID:-none} node-pool=${REC_NODE_POOL_ID:-none}"
    fi
}

confirm_scope() {
    local name
    name=$(oci iam compartment get --compartment-id "$OCI_COMPARTMENT_ID" --query 'data.name' --raw-output) \
        || die "Cannot read compartment $OCI_COMPARTMENT_ID (OCI CLI not authenticated, or wrong OCID)"
    [[ -n "$name" ]] || die "Compartment $OCI_COMPARTMENT_ID has no name"

    log_warn "This force-deletes ALL OKE node pools and clusters in compartment '$name'"
    log_warn "  ($OCI_COMPARTMENT_ID) plus the resources recorded in cluster-info.txt."
    if [[ "${FORCE:-no}" == "yes" ]]; then
        log_warn "FORCE=yes set; skipping typed confirmation"
        return 0
    fi
    local reply=""
    read -r -p "Type the compartment name ('$name') to confirm: " reply || reply=""
    if [[ "$reply" != "$name" ]]; then
        log_info "Confirmation did not match; nothing deleted"
        exit 1
    fi
}

cleanup_kubernetes_resources() {
    log_info "🔍 Removing NIM PVC/Service (block volume, load balancer) if this cluster is reachable..."
    local ctx_line ctx
    ctx_line=$(kube_contexts_for_cluster "$REC_CLUSTER_ID" | head -1)
    if [[ -z "$ctx_line" ]]; then
        log_warn "No kubeconfig context for the recorded cluster; NIM block volume / load balancer may be orphaned"
        return 0
    fi
    ctx="${ctx_line%%$'\t'*}"
    if ! kubectl --context "$ctx" --request-timeout=15s cluster-info &>/dev/null; then
        log_warn "Cluster context $ctx unreachable; NIM block volume / load balancer may be orphaned"
        return 0
    fi
    helm --kube-context "$ctx" uninstall "$RELEASE_NAME" -n "$NIM_NAMESPACE" --wait=false \
        || log_warn "Helm uninstall of $RELEASE_NAME failed (may be absent)"
    kubectl --context "$ctx" -n "$NIM_NAMESPACE" delete svc,pvc -l "$NIM_SELECTOR" --ignore-not-found --wait=false \
        || fail "Deleting NIM Service/PVC failed"
}

delete_kind() {
    local kind="$1" recorded="$2" flag ids id
    case "$kind" in
        cluster) flag="--cluster-id" ;;
        node-pool) flag="--node-pool-id" ;;
    esac
    log_info "🔍 Listing OKE ${kind}s in compartment..."
    if ! ids=$(list_alive "$kind"); then
        fail "Listing OKE ${kind}s failed; cannot clean up"
        return 0
    fi
    if [[ -n "$recorded" ]] && ! printf '%s\n' "$ids" | grep -Fqx -- "$recorded"; then
        ids=$(printf '%s\n%s\n' "$ids" "$recorded")
    fi
    for id in $ids; do
        log_info "Deleting $kind: $id"
        oci ce "$kind" delete "$flag" "$id" --force >&2 || fail "Failed to delete $kind: $id"
    done
    [[ -n "$ids" ]] || log_success "No OKE ${kind}s to delete"
}

verify_cleanup() {
    log_info "🔍 Verifying cleanup..."
    local remaining=0 kind ids n
    for kind in node-pool cluster; do
        if ! ids=$(list_alive "$kind"); then
            fail "Verification list of OKE ${kind}s failed"
            continue
        fi
        n=$(printf '%s' "$ids" | grep -c . || true)
        if [[ "$n" != "0" ]]; then
            log_warn "⚠️  $n OKE $kind(s) not yet DELETED/DELETING"
            remaining=$((remaining + n))
        fi
    done

    if [[ $FAILURES -ne 0 ]]; then
        log_error "CLEANUP UNCONFIRMED - $FAILURES error(s) above; GPU billing may continue"
        return 1
    fi
    if [[ $remaining -ne 0 ]]; then
        log_warn "CLEANUP UNCONFIRMED - $remaining resource(s) still active; re-run in a few minutes"
        return 1
    fi
    log_success "✅ CLEANUP VERIFIED - no OKE node pools or clusters active in this compartment"
    log_success "💰 OKE GPU and cluster charges for this compartment: \$0.00/hour (deletion may still be completing)"
    return 0
}

main() {
    log_info "🚨 EMERGENCY CLEANUP INITIATED"
    log_info "=============================="
    log_info "Date: $(date)"
    log_info "Purpose: Stop GPU and OKE cluster billing for this project"
    log_info ""

    check_env_var OCI_COMPARTMENT_ID
    load_recorded_ids
    confirm_scope

    cleanup_kubernetes_resources
    delete_kind node-pool "$REC_NODE_POOL_ID"
    delete_kind cluster "$REC_CLUSTER_ID"

    log_info "Waiting ${SETTLE_SECONDS}s for deletions to propagate..."
    sleep "$SETTLE_SECONDS"

    if ! verify_cleanup; then
        log_info "Monitor OCI Console and run this script again to verify"
        exit 1
    fi

    log_info ""
    log_warn "⚠️  Not touched: VCNs/subnets (run 'make teardown' with cluster-info.txt),"
    log_warn "   and any other compute instances, block volumes or load balancers."
    log_warn "   Check Block Storage and Load Balancers in the OCI Console for NIM orphans."
}

main "$@"
