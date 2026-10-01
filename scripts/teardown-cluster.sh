#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly INFO_FILE="${SCRIPT_DIR}/cluster-info.txt"
readonly NIM_RELEASE_NAME="${NIM_RELEASE_NAME:-nvidia-nim}"
readonly NIM_NAMESPACE="${NIM_NAMESPACE:-default}"
readonly NIM_SELECTOR="app.kubernetes.io/instance=${NIM_RELEASE_NAME}"
readonly PV_DELETE_TIMEOUT="${PV_DELETE_TIMEOUT:-300}"

calculate_total_cost() {
    if [[ -f "$INFO_FILE" ]]; then
        local start_time
        start_time=$(stat -f %m "$INFO_FILE" 2>/dev/null || stat -c %Y "$INFO_FILE" 2>/dev/null || echo "0")

        if [[ "$start_time" != "0" ]]; then
            local current_time
            current_time=$(date +%s)
            local elapsed_hours
            elapsed_hours=$(echo "scale=2; ($current_time - $start_time) / 3600" | bc -l)

            local node_count="${NODE_COUNT:-1}"
            local hourly_cost
            if ! hourly_cost=$(estimate_hourly_cost "$node_count" "${GPU_SHAPE:-}"); then
                log_warn "Cannot estimate cost for shape '${GPU_SHAPE:-}'"
                return 0
            fi
            local total_cost
            total_cost=$(echo "scale=2; $elapsed_hours * $hourly_cost" | bc -l)

            log_info "Cluster running time: $(format_cost "$elapsed_hours") hours"
            log_info "Estimated total cost: \$$(format_cost "$total_cost") (LB and storage portions are estimates, unverified)"
        fi
    fi
}

# Context of THIS cluster in the local kubeconfig ("" if none).
KUBE_CTX=""

warn_k8s_orphans() {
    log_warn "!!! Cluster API for ${CLUSTER_NAME:-this cluster} is NOT reachable: $1"
    log_warn "!!! Kubernetes-created cloud resources cannot be removed first and may be ORPHANED and keep billing:"
    log_warn "!!!   - the NIM model-cache PersistentVolume (100Gi OCI Block Volume)"
    log_warn "!!!   - any OCI Load Balancer created for a LoadBalancer Service"
    log_warn "!!! After teardown check OCI Console > Block Storage > Block Volumes and"
    log_warn "!!! Networking > Load Balancers in compartment ${OCI_COMPARTMENT_ID}."
}

# M4: remove Kubernetes-owned cloud resources (PVC-backed block volume,
# LoadBalancer Service) before the cluster that manages them is deleted.
# Returns non-zero if something may be left behind.
cleanup_nim_k8s_resources() {
    log_info "Removing Kubernetes-owned cloud resources before cluster deletion..."

    local ctx_lines
    ctx_lines=$(kube_contexts_for_cluster "${CLUSTER_ID:-}")
    if [[ -z "$ctx_lines" ]]; then
        warn_k8s_orphans "no kubeconfig context found for cluster ${CLUSTER_ID:-unknown}"
        return 1
    fi
    # Prefer the context provision recorded (KUBE_CONTEXT) if it still
    # authenticates to this cluster; otherwise the first matching context.
    if [[ -n "${KUBE_CONTEXT:-}" ]] && printf '%s\n' "$ctx_lines" | cut -f1 | grep -Fqx -- "$KUBE_CONTEXT"; then
        KUBE_CTX="$KUBE_CONTEXT"
    else
        KUBE_CTX=$(printf '%s\n' "$ctx_lines" | head -1 | cut -f1)
    fi

    if ! kubectl --context "$KUBE_CTX" --request-timeout=20s cluster-info &>/dev/null; then
        warn_k8s_orphans "context $KUBE_CTX did not answer"
        return 1
    fi

    local k=(kubectl --context "$KUBE_CTX" -n "$NIM_NAMESPACE")
    local ok="yes" releases pv_names svc_left

    # PV names must be read before the PVCs go away.
    if ! pv_names=$("${k[@]}" get pvc -l "$NIM_SELECTOR" -o jsonpath='{.items[*].spec.volumeName}'); then
        log_error "Could not list NIM PVCs"
        ok="no"
        pv_names=""
    fi

    if ! releases=$(helm --kube-context "$KUBE_CTX" list -n "$NIM_NAMESPACE" -a -q --filter "^${NIM_RELEASE_NAME}\$"); then
        log_error "Could not list Helm releases"
        ok="no"
        releases=""
    fi
    if [[ -n "$releases" ]]; then
        if helm --kube-context "$KUBE_CTX" uninstall "$NIM_RELEASE_NAME" -n "$NIM_NAMESPACE" --wait --timeout 300s; then
            log_success "Helm release $NIM_RELEASE_NAME uninstalled"
        else
            log_error "Helm uninstall of $NIM_RELEASE_NAME failed"
            ok="no"
        fi
    else
        log_info "No Helm release $NIM_RELEASE_NAME found"
    fi

    if "${k[@]}" delete svc -l "$NIM_SELECTOR" --ignore-not-found --wait=true --timeout=180s; then
        log_info "NIM Services deleted (frees any OCI Load Balancer)"
    else
        log_error "Deleting NIM Services failed"
        ok="no"
    fi

    if "${k[@]}" delete pvc -l "$NIM_SELECTOR" --ignore-not-found --wait=true --timeout=180s; then
        log_info "NIM PVCs deleted"
    else
        log_error "Deleting NIM PVCs failed"
        ok="no"
    fi

    local pv
    for pv in $pv_names; do
        log_info "Waiting for PersistentVolume $pv (block volume) to be released..."
        if kubectl --context "$KUBE_CTX" wait --for=delete "pv/$pv" --timeout="${PV_DELETE_TIMEOUT}s"; then
            log_success "PersistentVolume $pv deleted"
        else
            log_error "PersistentVolume $pv still exists; its OCI Block Volume may be orphaned"
            ok="no"
        fi
    done

    # Anything else that would orphan a cloud load balancer.
    if svc_left=$(kubectl --context "$KUBE_CTX" get svc -A \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{" "}{end}'); then
        if [[ -n "${svc_left// /}" ]]; then
            log_warn "Other LoadBalancer Services remain and their OCI Load Balancers may be orphaned: $svc_left"
            ok="no"
        fi
    else
        log_error "Could not list LoadBalancer Services"
        ok="no"
    fi

    [[ "$ok" == "yes" ]]
}

# Delete a subnet, security list or VCN and wait for TERMINATED.
# $1 kind, $2 flag, $3 OCID. A 404 / NotAuthorizedOrNotFound answer means
# it is already gone (e.g. a previous teardown run deleted it).
delete_network_resource() {
    local kind="$1" flag="$2" id="$3" err rc=0
    err=$(mktemp "${TMPDIR:-/tmp}/oci-err.XXXXXX")
    oci network "$kind" delete "$flag" "$id" --force --wait-for-state TERMINATED --max-wait-seconds 600 \
        2>"$err" >&2 || rc=$?
    if [[ $rc -eq 0 ]]; then
        rm -f "$err"
        log_success "$kind deleted: $id"
        return 0
    fi
    if oci_is_not_found_error < "$err"; then
        rm -f "$err"
        log_info "$kind already deleted (not found): $id"
        return 0
    fi
    cat "$err" >&2
    rm -f "$err"
    log_error "$kind delete failed: $id"
    return 1
}

# Print the lifecycle-state of the VCN, NOTFOUND on 404; non-zero otherwise.
vcn_state() {
    local err out rc=0
    err=$(mktemp "${TMPDIR:-/tmp}/oci-err.XXXXXX")
    out=$(oci network vcn get --vcn-id "$1" --query 'data."lifecycle-state"' --raw-output 2>"$err") || rc=$?
    if [[ $rc -eq 0 ]]; then
        rm -f "$err"; printf '%s\n' "$out"; return 0
    fi
    if oci_is_not_found_error < "$err"; then
        rm -f "$err"; printf 'NOTFOUND\n'; return 0
    fi
    cat "$err" >&2
    rm -f "$err"
    return 1
}

delete_network() {
    local ok="yes" sid

    log_info "Deleting subnets..."
    for sid in "${SUBNET_ID:-}" "${API_SUBNET_ID:-}"; do
        [[ -n "$sid" ]] || continue
        delete_network_resource subnet --subnet-id "$sid" || ok="no"
    done
    if [[ -z "${API_SUBNET_ID:-}" ]]; then
        log_warn "API_SUBNET_ID not recorded in $INFO_FILE; the API subnet may block VCN deletion"
    fi

    # Security lists can be deleted only after the subnets using them.
    log_info "Deleting security lists..."
    local slid any_sl="no"
    for slid in "${WORKER_SECLIST_ID:-}" "${API_SECLIST_ID:-}"; do
        [[ -n "$slid" ]] || continue
        any_sl="yes"
        if [[ "$ok" != "yes" ]]; then
            log_error "Skipping security list $slid: a subnet delete is not confirmed"
            continue
        fi
        delete_network_resource security-list --security-list-id "$slid" || ok="no"
    done
    [[ "$any_sl" == "yes" ]] || log_info "No security lists recorded"

    if [[ -z "${VCN_ID:-}" ]]; then
        log_info "VCN_ID not recorded; no gateway or VCN to delete"
        [[ "$ok" == "yes" ]]
        return
    fi
    if [[ "${VCN_CREATED:-}" != "yes" ]]; then
        log_info "VCN $VCN_ID was not created by this project (VCN_OCID or a pre-existing VCN); not deleting it, its gateway or its route rules"
        [[ "$ok" == "yes" ]]
        return
    fi

    local vstate
    if ! vstate=$(vcn_state "$VCN_ID"); then
        log_error "Could not read VCN $VCN_ID state"
        return 1
    fi
    if [[ "$vstate" == "NOTFOUND" || "$vstate" == "TERMINATED" ]]; then
        log_info "VCN already deleted (${vstate}): $VCN_ID"
        [[ "$ok" == "yes" ]]
        return
    fi

    log_info "Clearing route rules so the internet gateway can be deleted..."
    local rt_id="${ROUTE_TABLE_ID:-}"
    if [[ -z "$rt_id" ]]; then
        rt_id=$(oci network vcn get --vcn-id "$VCN_ID" --query 'data."default-route-table-id"' --raw-output) || rt_id=""
    fi
    if [[ -n "$rt_id" ]]; then
        if ! oci network route-table update --rt-id "$rt_id" --route-rules '[]' --force >&2; then
            log_error "Clearing route rules on $rt_id failed"
            ok="no"
        fi
    else
        log_warn "Route table unknown; gateway deletion may fail"
    fi

    log_info "Deleting internet gateway..."
    local igw_ids igw_id
    if igw_ids=$(oci network internet-gateway list \
        --compartment-id "$OCI_COMPARTMENT_ID" \
        --vcn-id "$VCN_ID" \
        --query 'data[*].id' \
        --raw-output); then
        igw_ids=$(printf '%s' "$igw_ids" | tr -d '[]",' | tr '\t' '\n')
        for igw_id in $igw_ids; do
            delete_network_resource internet-gateway --ig-id "$igw_id" || ok="no"
        done
    else
        log_error "Listing internet gateways failed"
        ok="no"
    fi

    log_info "Deleting VCN..."
    delete_network_resource vcn --vcn-id "$VCN_ID" || ok="no"

    [[ "$ok" == "yes" ]]
}

remove_kube_entries() {
    local ctx cl user current
    current=$(kubectl config current-context 2>/dev/null || true)
    while IFS=$'\t' read -r ctx cl user; do
        [[ -n "$ctx" ]] || continue
        log_info "Removing kubeconfig entries for this cluster: context=$ctx cluster=$cl user=$user"
        kubectl config delete-context "$ctx" >/dev/null 2>&1 || log_info "  context $ctx already absent"
        if [[ -n "$cl" ]]; then
            kubectl config delete-cluster "$cl" >/dev/null 2>&1 || log_info "  cluster $cl already absent"
        fi
        if [[ -n "$user" ]]; then
            kubectl config unset "users.$user" >/dev/null 2>&1 || log_info "  user $user already absent"
        fi
        if [[ "$current" == "$ctx" ]]; then
            kubectl config unset current-context >/dev/null 2>&1 || true
        fi
    done < <(kube_contexts_for_cluster "${CLUSTER_ID:-}")
}

main() {
    log_warn "OKE Cluster Teardown"

    if [[ ! -f "$INFO_FILE" ]]; then
        log_info "Nothing to tear down: $INFO_FILE not found (no recorded resources)."
        log_info "A completed teardown removes that file. If resources exist without a record, check the OCI Console."
        exit 1
    fi

    local env_compartment="${OCI_COMPARTMENT_ID:-}"
    # shellcheck disable=SC1090
    source "$INFO_FILE"
    OCI_COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-$env_compartment}"
    if [[ -z "$OCI_COMPARTMENT_ID" ]]; then
        die "OCI_COMPARTMENT_ID is not in $INFO_FILE or the environment; export it and re-run"
    fi

    calculate_total_cost

    echo ""
    log_warn "This will DELETE:"
    log_warn "  - NIM Helm release, its PVC (block volume) and Service (load balancer), if reachable"
    log_warn "  - GPU Node Pool: ${NODE_POOL_NAME:-unknown}"
    log_warn "  - OKE Cluster: ${CLUSTER_NAME:-unknown}"
    log_warn "  - Subnets, security lists, internet gateway and VCN: ${VCN_NAME:-unknown}"
    log_warn "    (the VCN and gateway only if this project created them)"
    echo ""

    local force="${FORCE:-no}"

    if [[ "$force" != "yes" ]]; then
        read -p "Type 'yes' to confirm teardown: " -r
        if [[ ! $REPLY == "yes" ]]; then
            log_info "Teardown cancelled"
            exit 0
        fi
    fi

    local k8s_ok="yes" np_ok="yes" cl_ok="yes" net_ok="yes" verify_ok="yes"

    # N5: Kubernetes-owned cloud resources can exist only on a live cluster.
    # A cluster never recorded/found, already DELETED or 404 means nothing to do.
    local cluster_state="UNKNOWN"
    if [[ -z "${CLUSTER_ID:-}" && -n "${CLUSTER_NAME:-}" ]]; then
        if CLUSTER_ID=$(oci_find_cluster_id "$OCI_COMPARTMENT_ID" "$CLUSTER_NAME"); then
            [[ -z "$CLUSTER_ID" ]] && cluster_state="NONE"
        else
            log_error "Cluster lookup by name failed"
            CLUSTER_ID=""
        fi
    fi
    if [[ -n "${CLUSTER_ID:-}" ]]; then
        cluster_state=$(oci_ce_get_state cluster "$CLUSTER_ID") || cluster_state="UNKNOWN"
    fi
    case "$cluster_state" in
        NONE|DELETED|NOTFOUND)
            log_info "Kubernetes resources: nothing to do (cluster ${cluster_state}: ${CLUSTER_ID:-never created})" ;;
        *)
            cleanup_nim_k8s_resources || k8s_ok="no" ;;
    esac

    log_info "Deleting node pool..."
    if [[ -z "${NODE_POOL_ID:-}" && -n "${NODE_POOL_NAME:-}" ]]; then
        if ! NODE_POOL_ID=$(oci_find_node_pool_id "$OCI_COMPARTMENT_ID" "$NODE_POOL_NAME" "${CLUSTER_ID:-}"); then
            log_error "Node pool lookup by name failed"
            NODE_POOL_ID=""
            np_ok="no"
        fi
    fi
    if [[ -n "${NODE_POOL_ID:-}" ]]; then
        oci_ce_delete_confirmed node-pool "$NODE_POOL_ID" || np_ok="no"
    elif [[ "$np_ok" == "yes" ]]; then
        log_info "No node pool found to delete"
    fi

    log_info "Deleting OKE cluster..."
    if [[ "$np_ok" != "yes" ]]; then
        log_error "Skipping cluster deletion because node pool deletion is not confirmed"
        cl_ok="no"
    else
        if [[ -z "${CLUSTER_ID:-}" && -n "${CLUSTER_NAME:-}" ]]; then
            if ! CLUSTER_ID=$(oci_find_cluster_id "$OCI_COMPARTMENT_ID" "$CLUSTER_NAME"); then
                log_error "Cluster lookup by name failed"
                CLUSTER_ID=""
                cl_ok="no"
            fi
        fi
        if [[ -n "${CLUSTER_ID:-}" ]]; then
            oci_ce_delete_confirmed cluster "$CLUSTER_ID" || cl_ok="no"
        elif [[ "$cl_ok" == "yes" ]]; then
            log_info "No cluster found to delete"
        fi
    fi

    if [[ "$np_ok" == "yes" && "$cl_ok" == "yes" ]]; then
        delete_network || net_ok="no"
    else
        net_ok="no"
        log_error "Skipping network deletion: node pool or cluster deletion not confirmed"
    fi

    log_info "Verifying cleanup..."
    local remaining_json remaining
    if remaining_json=$(oci ce cluster list \
        --compartment-id "$OCI_COMPARTMENT_ID" \
        --name "${CLUSTER_NAME:-}" \
        --lifecycle-state ACTIVE \
        --query 'data[].id'); then
        remaining=$(printf '%s' "${remaining_json:-[]}" | jq 'length') || remaining="unknown"
        if [[ "$remaining" == "0" ]]; then
            log_success "No active OKE cluster named ${CLUSTER_NAME:-} remains"
        else
            log_error "$remaining active cluster(s) named ${CLUSTER_NAME:-} still exist"
            verify_ok="no"
        fi
    else
        log_error "Verification failed: could not list clusters in $OCI_COMPARTMENT_ID"
        verify_ok="no"
    fi

    if [[ "$np_ok" != "yes" || "$cl_ok" != "yes" || "$verify_ok" != "yes" ]]; then
        log_error "TEARDOWN INCOMPLETE - the GPU node pool or OKE cluster is NOT confirmed deleted"
        log_error "GPU billing may be continuing. $INFO_FILE is kept; fix the error and re-run 'make teardown'."
        exit 1
    fi

    log_success "GPU node pool and OKE cluster confirmed deleted - GPU and cluster billing stopped"
    remove_kube_entries
    rm -f "${SCRIPT_DIR}/.nim-endpoint" "${SCRIPT_DIR}/.nim-deployed-at"

    if [[ "$k8s_ok" != "yes" || "$net_ok" != "yes" ]]; then
        if [[ "$k8s_ok" != "yes" ]]; then
            log_error "Kubernetes-owned block volumes or load balancers may be orphaned (see warnings above)"
        fi
        if [[ "$net_ok" != "yes" ]]; then
            log_error "Network cleanup incomplete (subnets, gateway or VCN remain)"
        fi
        log_error "$INFO_FILE is kept; re-run 'make teardown' or clean up in the OCI Console."
        exit 2
    fi

    rm -f "$INFO_FILE"
    log_success "Teardown complete! All recorded OKE resources deleted"
}

main "$@"
