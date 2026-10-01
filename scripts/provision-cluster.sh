#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/oke-optimized-config.sh"

readonly CLUSTER_NAME="${CLUSTER_NAME:-nimble-oke-cluster}"
readonly NODE_POOL_NAME="gpu-node-pool"
readonly GPU_SHAPE="${OKE_GPU_SHAPE:-VM.GPU.A10.1}"
readonly NODE_COUNT="${NODE_COUNT:-1}"
readonly K8S_VERSION="${K8S_VERSION:-v1.34.1}"
readonly VCN_NAME="nimble-oke-vcn"
readonly SUBNET_NAME="nimble-oke-subnet"
readonly VCN_CIDR="10.0.0.0/16"
readonly API_SUBNET_CIDR="10.0.0.0/28"
readonly WORKER_SUBNET_CIDR="10.0.1.0/24"
readonly API_SECLIST_NAME="nimble-oke-seclist-api"
readonly WORKER_SECLIST_NAME="nimble-oke-seclist-workers"
# Source CIDR allowed to reach the Kubernetes API (6443) from outside the VCN.
# 0.0.0.0/0 is a short-lived smoke-test default only; set your own IP/32 for
# anything that stays up longer than a test run.
readonly API_ALLOWED_CIDR="${API_ALLOWED_CIDR:-0.0.0.0/0}"
# The Helm chart's nodeSelector/affinity require this label on GPU nodes.
readonly GPU_NODE_LABEL_KEY="nvidia.com/gpu.present"
# Post-Ready steps (NVIDIA OKE guide: grow the root filesystem, then confirm
# the node advertises allocatable nvidia.com/gpu). Timeouts in seconds.
readonly SKIP_GROWFS="${SKIP_GROWFS:-no}"
readonly MIN_EPHEMERAL_STORAGE="${MIN_EPHEMERAL_STORAGE:-150Gi}"
readonly GROWFS_IMAGE="${GROWFS_IMAGE:-docker.io/library/oraclelinux:8}"
readonly NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-1200}"
readonly GROWFS_TIMEOUT="${GROWFS_TIMEOUT:-600}"
readonly GPU_ALLOCATABLE_TIMEOUT="${GPU_ALLOCATABLE_TIMEOUT:-900}"
readonly POLL_INTERVAL="${POLL_INTERVAL:-15}"
readonly INFO_FILE="${SCRIPT_DIR}/cluster-info.txt"
# Pinned device-plugin release. Do not bump without testing.
readonly NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.14.0}"

# Pricing and shape facts come from _lib.sh (single source of truth).
# Budget variables are set as readonly in oke-optimized-config.sh.

# State read by the failure trap. A resource is cleaned up only if THIS run
# started its create call; resources found and reused are left alone.
TRAP_COMPARTMENT_ID=""
CLUSTER_ID=""
NODE_POOL_ID=""
CLUSTER_CREATE_STARTED="no"
NODE_POOL_CREATE_STARTED="no"

# Record KEY=VALUE in cluster-info.txt immediately (replaces an earlier value).
record_info() {
    local key="$1" value="$2" tmp="${INFO_FILE}.tmp.$$"
    {
        if [[ -f "$INFO_FILE" ]]; then
            grep -v "^${key}=" "$INFO_FILE" || true
        fi
        printf '%s=%s\n' "$key" "$value"
    } > "$tmp"
    mv "$tmp" "$INFO_FILE"
}

# Return 0 if $2 looks like an OCID of resource type $1 (cluster, nodepool).
is_ocid_of() {
    [[ "$2" == ocid1."$1".* ]]
}

# Print the value recorded for KEY in cluster-info.txt ("" if none).
info_value() {
    [[ -f "$INFO_FILE" ]] || return 0
    grep "^${1}=" "$INFO_FILE" | tail -1 | cut -d= -f2- || true
}

# Parse the output of a create run with --wait-for-state (a work request).
# Sets WR_STATUS (SUCCEEDED, FAILED, ...; "" if not reported) and
# WR_RESOURCE_ID (identifier of the resource whose entity-type matches $2).
WR_STATUS=""
WR_RESOURCE_ID=""
parse_work_request() {
    local out="$1" entity_re="$2"
    WR_STATUS=""
    WR_RESOURCE_ID=""
    if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        WR_STATUS=$(printf '%s' "$out" | jq -r '.data.status // empty' 2>/dev/null) || WR_STATUS=""
        WR_RESOURCE_ID=$(printf '%s' "$out" | jq -r --arg re "$entity_re" \
            '[.data.resources[]? | select((.["entity-type"] // "") | test($re; "i")) | .identifier] | first // empty' \
            2>/dev/null) || WR_RESOURCE_ID=""
    else
        WR_RESOURCE_ID=$(printf '%s' "$out" | tr -d '[:space:]"')
    fi
}

# Security-list rules mirroring Oracle's Console Quick Create for OKE
# (API endpoint and worker lists), with CIDRs from this script's subnets.
# Egress is stateful allow-all on both lists: traffic leaves through the
# internet gateway, so no Oracle-services-network rule is needed. No SSH.
api_ingress_rules() {
    jq -cn --arg ext "$API_ALLOWED_CIDR" --arg wk "$WORKER_SUBNET_CIDR" '[
      {source: $ext, sourceType: "CIDR_BLOCK", protocol: "6", isStateless: false,
       description: "External access to Kubernetes API endpoint",
       tcpOptions: {destinationPortRange: {min: 6443, max: 6443}}},
      {source: $wk, sourceType: "CIDR_BLOCK", protocol: "6", isStateless: false,
       description: "Kubernetes worker to Kubernetes API endpoint communication",
       tcpOptions: {destinationPortRange: {min: 6443, max: 6443}}},
      {source: $wk, sourceType: "CIDR_BLOCK", protocol: "6", isStateless: false,
       description: "Kubernetes worker to control plane communication",
       tcpOptions: {destinationPortRange: {min: 12250, max: 12250}}},
      {source: $wk, sourceType: "CIDR_BLOCK", protocol: "1", isStateless: false,
       description: "Path discovery", icmpOptions: {type: 3, code: 4}}
    ]'
}
worker_ingress_rules() {
    jq -cn --arg wk "$WORKER_SUBNET_CIDR" --arg api "$API_SUBNET_CIDR" '[
      {source: $wk, sourceType: "CIDR_BLOCK", protocol: "all", isStateless: false,
       description: "Allow pods on one worker node to communicate with pods on other worker nodes"},
      {source: $api, sourceType: "CIDR_BLOCK", protocol: "1", isStateless: false,
       description: "Path discovery", icmpOptions: {type: 3, code: 4}},
      {source: $api, sourceType: "CIDR_BLOCK", protocol: "6", isStateless: false,
       description: "TCP access from Kubernetes Control Plane"}
    ]'
}
egress_all_rules() {
    jq -cn '[{destination: "0.0.0.0/0", destinationType: "CIDR_BLOCK", protocol: "all",
              isStateless: false, description: "All egress (via internet gateway)"}]'
}

# Create the named security list in the VCN, or converge an existing one to
# the wanted rules. Records its OCID under KEY immediately.
#   $1 KEY  $2 compartment  $3 vcn  $4 display name  $5 ingress  $6 egress
ensure_security_list() {
    local key="$1" compartment_id="$2" vcn_id="$3" name="$4" ingress="$5" egress="$6" id
    id=$(oci network security-list list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --display-name "$name" \
        --query 'data[0].id' \
        --raw-output) || die "Listing security lists in VCN $vcn_id failed"
    [[ "$id" == "null" ]] && id=""
    if [[ -z "$id" ]]; then
        id=$(oci network security-list create \
            --compartment-id "$compartment_id" \
            --vcn-id "$vcn_id" \
            --display-name "$name" \
            --ingress-security-rules "$ingress" \
            --egress-security-rules "$egress" \
            --wait-for-state AVAILABLE \
            --max-wait-seconds 180 \
            --query 'data.id' \
            --raw-output) || die "Security list create failed: $name"
        is_ocid_of securitylist "$id" || die "Security list create returned no OCID: $name"
        record_info "$key" "$id"
        log_success "Security list created: $name ($id)"
    else
        record_info "$key" "$id"
        oci network security-list update \
            --security-list-id "$id" \
            --ingress-security-rules "$ingress" \
            --egress-security-rules "$egress" \
            --force \
            --wait-for-state AVAILABLE \
            --max-wait-seconds 180 >/dev/null \
            || die "Updating rules on existing security list $name ($id) failed"
        log_info "Security list exists; rules converged: $name ($id)"
    fi
    ENSURED_ID="$id"
}

# Create the named subnet with this security list, or attach the security
# list (and route table) to an existing subnet. Records its OCID under KEY.
#   $1 KEY $2 compartment $3 vcn $4 name $5 cidr $6 dns label $7 route table $8 seclist
ensure_subnet() {
    local key="$1" compartment_id="$2" vcn_id="$3" name="$4" cidr="$5" dns="$6" rt_id="$7" sl_id="$8" id
    id=$(oci network subnet list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --display-name "$name" \
        --query 'data[0].id' \
        --raw-output) || die "Listing subnets in VCN $vcn_id failed"
    [[ "$id" == "null" ]] && id=""
    if [[ -z "$id" ]]; then
        id=$(oci network subnet create \
            --compartment-id "$compartment_id" \
            --vcn-id "$vcn_id" \
            --display-name "$name" \
            --cidr-block "$cidr" \
            --dns-label "$dns" \
            --route-table-id "$rt_id" \
            --security-list-ids "[\"$sl_id\"]" \
            --wait-for-state AVAILABLE \
            --max-wait-seconds 180 \
            --query 'data.id' \
            --raw-output) || die "Subnet create failed: $name"
        [[ -n "$id" ]] || die "Subnet create returned no OCID: $name"
        record_info "$key" "$id"
        log_success "Subnet created: $name ($id)"
    else
        record_info "$key" "$id"
        oci network subnet update \
            --subnet-id "$id" \
            --route-table-id "$rt_id" \
            --security-list-ids "[\"$sl_id\"]" \
            --force \
            --wait-for-state AVAILABLE \
            --max-wait-seconds 180 >/dev/null \
            || die "Attaching security list $sl_id to existing subnet $name ($id) failed"
        log_info "Subnet exists; security list and route table attached: $name ($id)"
    fi
    ENSURED_ID="$id"
}
ENSURED_ID=""

# Convert a Kubernetes quantity (e.g. 36Gi, 37206272Ki, 39834812416) to
# whole GiB. Non-zero for an unparseable value.
quantity_to_gib() {
    awk -v q="$1" 'BEGIN {
        if (match(q, /^[0-9]+(\.[0-9]+)?/) == 0) exit 1
        n = substr(q, 1, RLENGTH); u = substr(q, RLENGTH + 1)
        if (u == "") m = 1
        else if (u == "Ki") m = 1024
        else if (u == "Mi") m = 1048576
        else if (u == "Gi") m = 1073741824
        else if (u == "Ti") m = 1099511627776
        else if (u == "k") m = 1000
        else if (u == "M") m = 1000000
        else if (u == "G") m = 1000000000
        else if (u == "T") m = 1000000000000
        else exit 1
        printf "%d\n", (n * m) / 1073741824
    }'
}

# kubectl pinned to this cluster's context (set after create-kubeconfig).
KCTL=(kubectl)

# Wait until NODE_COUNT GPU-labelled nodes exist and all are Ready.
wait_gpu_nodes_ready() {
    local deadline counts total=0 ready=0 lines
    deadline=$(( $(date +%s) + NODE_READY_TIMEOUT ))
    while :; do
        lines=$("${KCTL[@]}" get nodes -l "${GPU_NODE_LABEL_KEY}=true" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
            2>/dev/null) || lines=""
        counts=$(printf '%s\n' "$lines" | awk -F'\t' 'NF && $1 != "" {t++} $2 == "True" {r++} END {print t + 0, r + 0}')
        total="${counts%% *}"
        ready="${counts##* }"
        if (( total >= NODE_COUNT && ready == total )); then
            log_success "GPU nodes Ready: $ready/$NODE_COUNT (label ${GPU_NODE_LABEL_KEY}=true)"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            die "Only $ready of $total GPU node(s) labelled ${GPU_NODE_LABEL_KEY}=true are Ready after ${NODE_READY_TIMEOUT}s (expected $NODE_COUNT). The cluster is billing; re-run or run 'make teardown'."
        fi
        sleep "$POLL_INTERVAL"
    done
}

# Run one privileged, host-PID pod on a node that enters the host namespaces
# (the NVIDIA OKE guide's kubectl-only method). $1 node, $2 purpose, rest = command.
run_node_pod() {
    local node="$1" purpose="$2" pod overrides cmd_json rc=0
    shift 2
    pod="nimble-${purpose}-$(date +%s)"
    # Command words as a JSON array (jq --args would read "-y" as an option).
    cmd_json=$(printf '%s\n' nsenter -t 1 -m -u -i -n "$@" | jq -R . | jq -cs .) || return 1
    overrides=$(jq -cn --arg node "$node" --arg pod "$pod" --arg image "$GROWFS_IMAGE" --argjson cmd "$cmd_json" '{
        spec: {nodeName: $node, hostPID: true, restartPolicy: "Never",
               tolerations: [{operator: "Exists"}],
               containers: [{name: $pod, image: $image,
                             command: $cmd, securityContext: {privileged: true}}]}}') || return 1
    log_info "Running $purpose on $node: $*"
    "${KCTL[@]}" -n kube-system run "$pod" --image="$GROWFS_IMAGE" --restart=Never \
        --overrides="$overrides" >/dev/null || return 1
    "${KCTL[@]}" -n kube-system wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" \
        --timeout="${GROWFS_TIMEOUT}s" >/dev/null || rc=1
    if [[ $rc -ne 0 ]]; then
        log_error "$purpose pod $pod did not succeed; its logs follow"
        "${KCTL[@]}" -n kube-system logs "$pod" >&2 || true
    fi
    "${KCTL[@]}" -n kube-system delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1 \
        || log_warn "Could not delete helper pod kube-system/$pod; delete it by hand"
    return "$rc"
}

# Print "<raw>\t<GiB>" for a node's ephemeral-storage capacity.
node_ephemeral() {
    local raw gib
    raw=$("${KCTL[@]}" get node "$1" -o jsonpath='{.status.capacity.ephemeral-storage}') || return 1
    gib=$(quantity_to_gib "$raw") || { log_error "Unparseable ephemeral-storage '$raw' on $1"; return 1; }
    printf '%s\t%s\n' "$raw" "$gib"
}

# N3: with a large boot volume the root filesystem stays ~35 GB until
# oci-growfs runs; the chart requests 100Gi ephemeral storage. Idempotent:
# a node already above MIN_EPHEMERAL_STORAGE is skipped.
ensure_ephemeral_storage() {
    if [[ "$SKIP_GROWFS" == "yes" ]]; then
        log_warn "SKIP_GROWFS=yes: not expanding node root filesystems"
        return 0
    fi
    local min_gib nodes node cur raw gib deadline
    min_gib=$(quantity_to_gib "$MIN_EPHEMERAL_STORAGE") || die "MIN_EPHEMERAL_STORAGE '$MIN_EPHEMERAL_STORAGE' is not a quantity"
    nodes=$("${KCTL[@]}" get nodes -l "${GPU_NODE_LABEL_KEY}=true" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || die "Listing GPU nodes failed"
    [[ -n "$nodes" ]] || die "No GPU nodes found for the ephemeral-storage check"
    for node in $nodes; do
        cur=$(node_ephemeral "$node") || die "Reading ephemeral-storage capacity of $node failed"
        raw="${cur%%$'\t'*}"; gib="${cur##*$'\t'}"
        if (( gib >= min_gib )); then
            log_info "Node $node ephemeral-storage ${raw} (${gib}Gi) >= ${MIN_EPHEMERAL_STORAGE}; growfs not needed"
            continue
        fi
        log_info "Node $node ephemeral-storage ${raw} (${gib}Gi) < ${MIN_EPHEMERAL_STORAGE}; expanding root filesystem (oci-growfs)..."
        run_node_pod "$node" growfs /usr/libexec/oci-growfs -y \
            || die "oci-growfs failed on node $node. The cluster is billing; re-run or run 'make teardown'."
        # The NVIDIA OKE guide restarts kubelet after growfs so the node
        # reports the new capacity.
        run_node_pod "$node" restart-kubelet systemctl restart kubelet \
            || log_warn "kubelet restart pod on $node did not report success; checking capacity anyway"
        deadline=$(( $(date +%s) + GROWFS_TIMEOUT ))
        while :; do
            cur=$(node_ephemeral "$node") || cur=$'unknown\t0'
            raw="${cur%%$'\t'*}"; gib="${cur##*$'\t'}"
            if (( gib >= min_gib )); then
                log_success "Node $node ephemeral-storage now ${raw} (${gib}Gi)"
                break
            fi
            if (( $(date +%s) >= deadline )); then
                die "GROWFS FAILED: node $node ephemeral-storage capacity is ${raw} (${gib}Gi) after oci-growfs + kubelet restart; need >= ${MIN_EPHEMERAL_STORAGE}. The cluster is billing; investigate or run 'make teardown'."
            fi
            sleep "$POLL_INTERVAL"
        done
    done
}

# Highest allocatable nvidia.com/gpu across nodes (0 if none).
gpu_allocatable_max() {
    local out
    out=$("${KCTL[@]}" get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}') || return 1
    printf '%s\n' "$out" | awk -F'\t' 'BEGIN {m = 0} ($2 + 0) > m {m = $2 + 0} END {print m}'
}

# N4: the success criterion. Apply the upstream device plugin only if no
# node already advertises GPUs (OKE GPU images may run their own), then wait
# until a node reports allocatable nvidia.com/gpu >= 1.
ensure_gpu_allocatable() {
    local gpus deadline
    gpus=$(gpu_allocatable_max) || die "Reading node allocatable resources failed"
    if (( gpus >= 1 )); then
        log_info "A node already reports allocatable nvidia.com/gpu=$gpus; not applying the upstream device plugin"
    else
        log_info "No node reports allocatable nvidia.com/gpu; applying NVIDIA device plugin ${NVIDIA_DEVICE_PLUGIN_VERSION}..."
        "${KCTL[@]}" apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/nvidia-device-plugin.yml" \
            || die "NVIDIA device plugin ${NVIDIA_DEVICE_PLUGIN_VERSION} apply FAILED; GPUs are not schedulable. The cluster is billing; re-run or run 'make teardown'."
    fi
    deadline=$(( $(date +%s) + GPU_ALLOCATABLE_TIMEOUT ))
    while (( gpus < 1 )); do
        if (( $(date +%s) >= deadline )); then
            die "GPU CHECK FAILED: no node reports allocatable nvidia.com/gpu after ${GPU_ALLOCATABLE_TIMEOUT}s (last observed max: ${gpus}). GPUs are NOT schedulable. The cluster is billing; investigate the device plugin or run 'make teardown'."
        fi
        sleep "$POLL_INTERVAL"
        gpus=$(gpu_allocatable_max) || gpus=0
    done
    log_success "GPU check passed: node allocatable nvidia.com/gpu=$gpus"
}

cleanup_on_failure() {
    local rc=$?
    trap - EXIT
    set +e
    [[ $rc -eq 0 ]] && rc=1

    log_warn "Provisioning failed (exit $rc); cleaning up GPU/cluster resources created by this run..."
    local ok="yes" deleted=""

    if [[ "$NODE_POOL_CREATE_STARTED" == "yes" ]]; then
        if [[ -z "$NODE_POOL_ID" ]]; then
            log_info "Node pool OCID unknown; looking it up by name '$NODE_POOL_NAME'..."
            if ! NODE_POOL_ID=$(oci_find_node_pool_id "$TRAP_COMPARTMENT_ID" "$NODE_POOL_NAME" "$CLUSTER_ID"); then
                log_error "Node pool lookup failed; cannot confirm whether a node pool exists"
                NODE_POOL_ID=""
                ok="no"
            fi
        fi
        if [[ -n "$NODE_POOL_ID" ]]; then
            if oci_ce_delete_confirmed node-pool "$NODE_POOL_ID"; then
                deleted="$deleted node-pool"
            else
                ok="no"
            fi
        fi
    fi

    if [[ "$CLUSTER_CREATE_STARTED" == "yes" ]]; then
        if [[ -z "$CLUSTER_ID" ]]; then
            log_info "Cluster OCID unknown; looking it up by name '$CLUSTER_NAME'..."
            if ! CLUSTER_ID=$(oci_find_cluster_id "$TRAP_COMPARTMENT_ID" "$CLUSTER_NAME"); then
                log_error "Cluster lookup failed; cannot confirm whether a cluster exists"
                CLUSTER_ID=""
                ok="no"
            fi
        fi
        if [[ -n "$CLUSTER_ID" ]]; then
            if oci_ce_delete_confirmed cluster "$CLUSTER_ID"; then
                deleted="$deleted cluster"
            else
                ok="no"
            fi
        fi
    fi

    if [[ "$ok" == "yes" ]]; then
        if [[ -n "$deleted" ]]; then
            log_success "Failure cleanup confirmed: deleted${deleted}"
        else
            log_info "No node pool or cluster was created by this run; nothing to delete"
        fi
    else
        log_error "FAILURE CLEANUP INCOMPLETE - a GPU node pool or OKE cluster may still be billing"
        log_error "Check OCI Console > Kubernetes Clusters (OKE) in compartment ${TRAP_COMPARTMENT_ID:-unknown}"
    fi
    if [[ -f "$INFO_FILE" ]]; then
        log_warn "Network resources (VCN, security lists, subnets, gateway) were left in place."
        log_warn "Resource IDs are kept in $INFO_FILE; run 'make teardown' to remove them."
    fi
    exit "$rc"
}

main() {
    log_info "Provisioning OKE cluster with GPU nodes..."

    check_oci_credentials || die "OCI credentials not configured"
    check_env_var OCI_COMPARTMENT_ID
    check_command jq

    local compartment_id="${OCI_COMPARTMENT_ID}"
    local region="${OCI_REGION:-us-phoenix-1}"

    log_info "Estimating provisioning cost..."
    local gpus_per_node
    gpus_per_node=$(get_shape_gpu_count "$GPU_SHAPE") || die "Unsupported GPU shape: $GPU_SHAPE"
    local node_rate
    node_rate=$(get_gpu_hourly_rate "$GPU_SHAPE") || die "Cannot price GPU shape: $GPU_SHAPE"
    local hourly_cost
    hourly_cost=$(estimate_hourly_cost "$NODE_COUNT" "$GPU_SHAPE") || die "Cannot price GPU shape: $GPU_SHAPE"
    local test_cost
    test_cost=$(echo "$hourly_cost * 5" | bc -l)

    log_info "Configuration:"
    log_info "  Cluster: $CLUSTER_NAME"
    log_info "  Region: $region"
    log_info "  GPU Shape: $GPU_SHAPE (${gpus_per_node}x NVIDIA A10 GPU per node)"
    log_info "  Node Count: $NODE_COUNT"
    log_info "  Estimated cost: \$$(format_cost "$hourly_cost")/hour"
    log_info "    GPU \$${node_rate}/node-hour + enhanced cluster \$${NIM_ENHANCED_CLUSTER_HOURLY_USD}/hour"
    log_info "    + load balancer and storage (estimate, unverified)"
    log_info "  5-hour test cost: \$$(format_cost "$test_cost")"
    log_info ""
    log_info "Budget Options:"
    log_info "  Fast Test (1 hour): \$$(format_cost "$hourly_cost")"
    log_info "  Short Test (2 hours): \$$(format_cost "$(echo "$hourly_cost * 2" | bc -l)")"
    log_info "  Extended Test (4 hours): \$$(format_cost "$(echo "$hourly_cost * 4" | bc -l)")"
    log_info "  Full Day (24 hours): \$$(format_cost "$(echo "$hourly_cost * 24" | bc -l)")"

    cost_guard "$(format_cost "$test_cost")" "OKE cluster provisioning ($GPU_SHAPE)"

    # Arm the failure trap only now: nothing billable exists before this point.
    TRAP_COMPARTMENT_ID="$compartment_id"
    trap cleanup_on_failure EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    record_info OCI_COMPARTMENT_ID "$compartment_id"
    record_info REGION "$region"
    record_info CLUSTER_NAME "$CLUSTER_NAME"
    record_info NODE_POOL_NAME "$NODE_POOL_NAME"
    record_info VCN_NAME "$VCN_NAME"
    record_info GPU_SHAPE "$GPU_SHAPE"
    record_info NODE_COUNT "$NODE_COUNT"

    log_info "Setting up VCN..."
    local vcn_id

    # Use existing VCN if VCN_OCID is provided
    if [[ -n "${VCN_OCID:-}" ]]; then
        vcn_id="$VCN_OCID"
        log_info "Using existing VCN: $vcn_id"
        record_info VCN_CREATED "no"
    else
        # Look for existing VCN by name
        vcn_id=$(oci network vcn list \
            --compartment-id "$compartment_id" \
            --display-name "$VCN_NAME" \
            --query 'data[0].id' \
            --raw-output) || die "Listing VCNs in compartment $compartment_id failed"
        [[ "$vcn_id" == "null" ]] && vcn_id=""

        if [[ -z "$vcn_id" ]]; then
            vcn_id=$(oci network vcn create \
                --compartment-id "$compartment_id" \
                --display-name "$VCN_NAME" \
                --cidr-blocks "[\"$VCN_CIDR\"]" \
                --dns-label "nimbleoke" \
                --wait-for-state AVAILABLE \
                --max-wait-seconds 180 \
                --query 'data.id' \
                --raw-output) || die "VCN create failed"
            [[ -n "$vcn_id" ]] || die "VCN create returned no OCID"
            record_info VCN_CREATED "yes"
            record_info VCN_ID "$vcn_id"
            log_success "VCN created: $vcn_id"
        elif [[ "$(info_value VCN_ID)" == "$vcn_id" && "$(info_value VCN_CREATED)" == "yes" ]]; then
            # An earlier run of this project created it (recorded in cluster-info.txt).
            log_info "VCN already exists (created by an earlier run of this project): $vcn_id"
        else
            # Found by name but not created by this project: reuse it, never delete it.
            record_info VCN_CREATED "no"
            log_warn "Reusing pre-existing VCN named $VCN_NAME: $vcn_id"
            log_warn "Teardown will NOT delete this VCN, its gateway, or its route rules."
        fi
    fi
    record_info VCN_ID "$vcn_id"
    local vcn_owned
    vcn_owned="$(info_value VCN_CREATED)"

    log_info "Creating Internet Gateway..."
    local igw_id
    igw_id=$(oci network internet-gateway list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --query 'data[0].id' \
        --raw-output) || die "Listing internet gateways in VCN $vcn_id failed"
    [[ "$igw_id" == "null" ]] && igw_id=""

    if [[ -z "$igw_id" ]]; then
        igw_id=$(oci network internet-gateway create \
            --compartment-id "$compartment_id" \
            --vcn-id "$vcn_id" \
            --display-name "${VCN_NAME}-igw" \
            --is-enabled true \
            --query 'data.id' \
            --raw-output) || die "Internet gateway create failed"
        log_success "Internet Gateway created: $igw_id"
    else
        log_info "Internet Gateway already exists: $igw_id"
    fi
    record_info IGW_ID "$igw_id"

    log_info "Updating route table..."
    local route_table_id
    route_table_id=$(oci network vcn get \
        --vcn-id "$vcn_id" \
        --query 'data."default-route-table-id"' \
        --raw-output) || die "Reading the default route table of VCN $vcn_id failed"
    [[ -n "$route_table_id" && "$route_table_id" != "null" ]] || die "VCN $vcn_id has no default route table"
    record_info ROUTE_TABLE_ID "$route_table_id"

    local rules_json default_target rule_count
    rules_json=$(oci network route-table get \
        --rt-id "$route_table_id" \
        --query 'data."route-rules"') || die "Reading route rules of $route_table_id failed"
    default_target=$(printf '%s' "${rules_json:-[]}" | jq -r '[.[]? | select(.destination == "0.0.0.0/0") | .["network-entity-id"]] | first // empty') \
        || die "Unparseable route rules on $route_table_id"
    rule_count=$(printf '%s' "${rules_json:-[]}" | jq 'length') || die "Unparseable route rules on $route_table_id"
    if [[ "$default_target" == "$igw_id" ]]; then
        log_info "Route table already sends 0.0.0.0/0 to $igw_id"
    elif [[ "$vcn_owned" != "yes" && "$rule_count" != "0" ]]; then
        die "Route table $route_table_id of the pre-existing VCN has $rule_count rule(s) and no 0.0.0.0/0 -> $igw_id; refusing to overwrite them. Add the route yourself or pass VCN_OCID of a VCN you own."
    else
        oci network route-table update \
            --rt-id "$route_table_id" \
            --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw_id\"}]" \
            --force >/dev/null \
            || die "Route table update FAILED on $route_table_id; nodes would have no internet route"
        log_success "Route 0.0.0.0/0 -> $igw_id set on $route_table_id"
    fi

    log_info "Creating security lists (API endpoint, workers)..."
    local egress_rules api_seclist_id worker_seclist_id
    egress_rules=$(egress_all_rules) || die "Building egress rules failed"
    ensure_security_list API_SECLIST_ID "$compartment_id" "$vcn_id" "$API_SECLIST_NAME" \
        "$(api_ingress_rules)" "$egress_rules"
    api_seclist_id="$ENSURED_ID"
    ensure_security_list WORKER_SECLIST_ID "$compartment_id" "$vcn_id" "$WORKER_SECLIST_NAME" \
        "$(worker_ingress_rules)" "$egress_rules"
    worker_seclist_id="$ENSURED_ID"

    log_info "Creating API endpoint subnet..."
    local api_subnet_id
    ensure_subnet API_SUBNET_ID "$compartment_id" "$vcn_id" "${SUBNET_NAME}-api" \
        "$API_SUBNET_CIDR" "api" "$route_table_id" "$api_seclist_id"
    api_subnet_id="$ENSURED_ID"

    log_info "Creating worker node subnet..."
    local subnet_id
    ensure_subnet SUBNET_ID "$compartment_id" "$vcn_id" "${SUBNET_NAME}-workers" \
        "$WORKER_SUBNET_CIDR" "workers" "$route_table_id" "$worker_seclist_id"
    subnet_id="$ENSURED_ID"

    log_info "Creating OKE cluster (ENHANCED type, 10-15 minutes)..."
    local cluster_id wr_out state
    cluster_id=$(oci_find_cluster_id "$compartment_id" "$CLUSTER_NAME") \
        || die "Failed to list OKE clusters in compartment $compartment_id"

    if [[ -z "$cluster_id" ]]; then
        CLUSTER_CREATE_STARTED="yes"
        wr_out=$(oci ce cluster create \
            --compartment-id "$compartment_id" \
            --name "$CLUSTER_NAME" \
            --vcn-id "$vcn_id" \
            --kubernetes-version "$K8S_VERSION" \
            --type ENHANCED_CLUSTER \
            --endpoint-subnet-id "$api_subnet_id" \
            --endpoint-public-ip-enabled true \
            --service-lb-subnet-ids "[\"$subnet_id\"]" \
            --wait-for-state SUCCEEDED \
            --wait-for-state FAILED \
            --max-wait-seconds 1800) || die "OKE cluster create failed"
        parse_work_request "$wr_out" '^cluster$'
        cluster_id="$WR_RESOURCE_ID"
        if ! is_ocid_of cluster "$cluster_id"; then
            # Resolve by name when the work request names no cluster.
            cluster_id=$(oci_find_cluster_id "$compartment_id" "$CLUSTER_NAME") || cluster_id=""
        fi
        CLUSTER_ID="$cluster_id"
        [[ -n "$cluster_id" ]] && record_info CLUSTER_ID "$cluster_id"
        if [[ -n "$WR_STATUS" && "$WR_STATUS" != "SUCCEEDED" ]]; then
            die "OKE cluster create work request ended in state $WR_STATUS (not SUCCEEDED)"
        fi
        [[ -n "$cluster_id" ]] || die "Cluster create returned no cluster OCID"
        if [[ -z "$WR_STATUS" ]]; then
            state=$(oci_ce_get_state cluster "$cluster_id") || die "Could not read state of cluster $cluster_id"
            [[ "$state" == "ACTIVE" ]] || die "Cluster $cluster_id is in state '$state', not ACTIVE"
        fi
        log_success "OKE cluster created (ENHANCED): $cluster_id"
    else
        log_info "OKE cluster exists: $cluster_id"
        record_info CLUSTER_ID "$cluster_id"
    fi

    log_info "Creating GPU node pool (10-15 minutes)..."
    local node_pool_id
    node_pool_id=$(oci_find_node_pool_id "$compartment_id" "$NODE_POOL_NAME" "$cluster_id") \
        || die "Failed to list node pools in compartment $compartment_id"

    if [[ -z "$node_pool_id" ]]; then
        # Validate OKE-optimized configuration
        validate_oke_gpu_quota "$NODE_COUNT" "$GPU_SHAPE" || die "GPU quota validation failed"
        validate_oke_image "$OKE_GPU_IMAGE_ID" || die "OKE-optimized image validation failed"

        # Get availability domain for placement
        local availability_domain
        availability_domain=$(get_oke_availability_domain "$compartment_id" "$region") || die "Failed to get availability domain"

        log_info "Creating GPU node pool with OKE-optimized configuration..."
        log_info "  Shape: $GPU_SHAPE"
        log_info "  Image: $OKE_GPU_IMAGE_NAME"
        log_info "  Boot Volume: ${OKE_BOOT_VOLUME_SIZE_GB}GB"
        log_info "  Availability Domain: $availability_domain"
        log_info "  Node label: ${GPU_NODE_LABEL_KEY}=true"

        NODE_POOL_CREATE_STARTED="yes"
        wr_out=$(oci ce node-pool create \
            --cluster-id "$cluster_id" \
            --compartment-id "$compartment_id" \
            --name "$NODE_POOL_NAME" \
            --node-shape "$GPU_SHAPE" \
            --size "$NODE_COUNT" \
            --kubernetes-version "$K8S_VERSION" \
            --placement-configs "[{\"availabilityDomain\": \"$availability_domain\", \"subnetId\": \"$subnet_id\"}]" \
            --node-source-details "{\"sourceType\": \"IMAGE\", \"imageId\": \"$OKE_GPU_IMAGE_ID\", \"bootVolumeSizeInGBs\": $OKE_BOOT_VOLUME_SIZE_GB}" \
            --initial-node-labels "[{\"key\": \"${GPU_NODE_LABEL_KEY}\", \"value\": \"true\"}]" \
            --wait-for-state SUCCEEDED \
            --wait-for-state FAILED \
            --max-wait-seconds 1800) || die "Failed to create GPU node pool - check GPU quota and capacity in region"
        parse_work_request "$wr_out" '^node.?pool$'
        node_pool_id="$WR_RESOURCE_ID"
        if ! is_ocid_of nodepool "$node_pool_id"; then
            node_pool_id=$(oci_find_node_pool_id "$compartment_id" "$NODE_POOL_NAME" "$cluster_id") || node_pool_id=""
        fi
        NODE_POOL_ID="$node_pool_id"
        [[ -n "$node_pool_id" ]] && record_info NODE_POOL_ID "$node_pool_id"
        if [[ -n "$WR_STATUS" && "$WR_STATUS" != "SUCCEEDED" ]]; then
            die "GPU node pool create work request ended in state $WR_STATUS (not SUCCEEDED) - check GPU capacity in the AD"
        fi
        [[ -n "$node_pool_id" ]] || die "Node pool create returned no node pool OCID"
        if [[ -z "$WR_STATUS" ]]; then
            state=$(oci_ce_get_state node-pool "$node_pool_id") || die "Could not read state of node pool $node_pool_id"
            [[ "$state" == "ACTIVE" ]] || die "Node pool $node_pool_id is in state '$state', not ACTIVE"
        fi
        log_success "GPU node pool created: $node_pool_id"
    else
        log_info "GPU node pool exists: $node_pool_id"
        record_info NODE_POOL_ID "$node_pool_id"
    fi

    # All billable resources exist and are recorded. From here a failure must
    # not delete them; it fails loudly and 'make teardown' removes them.
    trap - EXIT INT TERM
    log_info "Cluster information saved to $INFO_FILE"

    # N9: write this cluster's entries into the kubeconfig kubectl reads
    # (first KUBECONFIG entry, else ~/.kube/config), merged with the others,
    # and pin every later call to this cluster's context.
    log_info "Configuring kubectl..."
    local kubeconfig_file="${KUBECONFIG:-$HOME/.kube/config}"
    kubeconfig_file="${kubeconfig_file%%:*}"
    mkdir -p "$(dirname "$kubeconfig_file")"
    oci ce cluster create-kubeconfig \
        --cluster-id "$cluster_id" \
        --file "$kubeconfig_file" \
        --region "$region" \
        --token-version 2.0.0 \
        --kube-endpoint PUBLIC_ENDPOINT \
        || die "kubeconfig creation failed. The cluster is billing; fix access and re-run, or run 'make teardown'."
    local kube_ctx
    kube_ctx=$(kube_contexts_for_cluster "$cluster_id" | head -1 | cut -f1)
    [[ -n "$kube_ctx" ]] || die "No kubeconfig context found for cluster $cluster_id in $kubeconfig_file. The cluster is billing; re-run or run 'make teardown'."
    record_info KUBE_CONTEXT "$kube_ctx"
    log_info "kubectl context for this cluster: $kube_ctx (recorded as KUBE_CONTEXT)"
    KCTL=(kubectl --context "$kube_ctx")

    "${KCTL[@]}" --request-timeout=20s cluster-info &>/dev/null \
        || die "Cluster API unreachable via context $kube_ctx. The cluster is billing; re-run or run 'make teardown'."

    log_info "Waiting for GPU node(s) to register and become Ready..."
    wait_gpu_nodes_ready
    ensure_ephemeral_storage
    ensure_gpu_allocatable

    log_success "OKE cluster provisioning complete!"
    echo ""
    log_info "Cluster details:"
    log_info "  Cluster ID: $cluster_id"
    log_info "  GPU Nodes: $NODE_COUNT × $GPU_SHAPE (${gpus_per_node}x NVIDIA A10 GPU per node)"
    log_info "  Hourly cost: \$$(format_cost "$hourly_cost") (LB and storage portions are estimates, unverified)"
    echo ""
    log_info "Budget tracking:"
    log_info "  Current rate: \$$(format_cost "$hourly_cost")/hour"
    log_info "  Fast test (1h): \$$(format_cost "$hourly_cost")"
    log_info "  Short test (2h): \$$(format_cost "$(echo "$hourly_cost * 2" | bc -l)")"
    log_info "  Extended test (4h): \$$(format_cost "$(echo "$hourly_cost * 4" | bc -l)")"
    echo ""
    log_info "Next steps:"
    log_info "  1. Run: make discover"
    log_info "  2. Run: make prereqs"
    log_info "  3. Run: NGC_API_KEY=nvapi-xxx make install"
    echo ""
    log_warn "Cost meter started! Currently \$$(format_cost "$hourly_cost")/hour"
    log_warn "Run 'make teardown' when finished to stop GPU billing"
}

main "$@"
