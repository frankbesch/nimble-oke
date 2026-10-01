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
# Label set on the GPU node pool (--initial-node-labels); the node waits below
# select GPU nodes by it. The Helm chart no longer requires it (it schedules
# on the nvidia.com/gpu resource request).
readonly GPU_NODE_LABEL_KEY="nvidia.com/gpu.present"
readonly GPU_NODE_SELECTOR="${GPU_NODE_LABEL_KEY}=true"
# AUTOSCALE=1: GPU pool starts at size 0 and the OKE ClusterAutoscaler add-on
# scales it 0 -> MAX_GPU_NODES -> 0. AUTOSCALE unset/0: fixed GPU pool.
readonly AUTOSCALE="${AUTOSCALE:-0}"
readonly MAX_GPU_NODES="${MAX_GPU_NODES:-1}"
readonly SCALE_DOWN_UNNEEDED="${SCALE_DOWN_UNNEEDED:-3m}"
readonly SCALE_DOWN_DELAY_AFTER_ADD="${SCALE_DOWN_DELAY_AFTER_ADD:-3m}"
readonly ADDON_TIMEOUT="${ADDON_TIMEOUT:-900}"
# Non-autoscaled system pool (Oracle: keep one pool the autoscaler does not
# manage, for critical add-ons and the autoscaler itself).
readonly SYSTEM_NODE_POOL_NAME="system-node-pool"
readonly SYSTEM_SHAPE="VM.Standard.E4.Flex"
readonly SYSTEM_OCPUS="${SYSTEM_OCPUS:-2}"
readonly SYSTEM_MEMORY_GB="${SYSTEM_MEMORY_GB:-16}"
# Ephemeral storage the autoscaler's template node advertises for the empty
# GPU pool (freeform tag read by the OCI cloud provider): boot volume minus a
# safety margin for partitions, GB-vs-GiB, and kubelet eviction reserve.
readonly EPHEMERAL_TAG_MARGIN_GB="${EPHEMERAL_TAG_MARGIN_GB:-100}"
readonly EPHEMERAL_STORAGE_TAG_KEY="cluster-autoscaler/node-ephemeral-storage"
# The GPU node must report at least this much ephemeral storage once Ready
# (verification only: the root filesystem is grown by cloud-init at boot).
readonly MIN_EPHEMERAL_STORAGE="${MIN_EPHEMERAL_STORAGE:-150Gi}"
readonly NODE_READY_TIMEOUT="${NODE_READY_TIMEOUT:-1200}"
readonly GPU_ALLOCATABLE_TIMEOUT="${GPU_ALLOCATABLE_TIMEOUT:-900}"
# Cluster DNS gate: at least one Ready kube-dns (CoreDNS) pod in kube-system.
readonly DNS_READY_TIMEOUT="${DNS_READY_TIMEOUT:-600}"
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
SYSTEM_NODE_POOL_ID=""
CLUSTER_CREATE_STARTED="no"
NODE_POOL_CREATE_STARTED="no"
SYSTEM_NODE_POOL_CREATE_STARTED="no"

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
# KCTL adds a per-request timeout so a hung API call cannot stall the deadline
# loops.
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

# E1: Oracle's documented custom cloud-init for a node pool (OKE docs,
# "Using Custom Cloud-init Initialization Scripts", Example 5): fetch the OKE
# init script, grow the root partition and filesystem, then run the init
# script. Printed base64 (one line) for node metadata "user_data". Nodes are
# never mutated after creation: a node the autoscaler adds gets it at boot.
gpu_cloud_init() {
    cat <<'CLOUDINIT'
#!/bin/bash
curl --fail -H "Authorization: Bearer Oracle" -L0 http://169.254.169.254/opc/v2/instance/metadata/oke_init_script | base64 --decode >/var/run/oke-init.sh
bash /usr/libexec/oci-growfs -y
bash /var/run/oke-init.sh
CLOUDINIT
}
gpu_node_metadata_json() {
    local b64
    b64=$(gpu_cloud_init | base64 | tr -d '\n') || return 1
    jq -cn --arg ud "$b64" '{user_data: $ud}'
}

# E2: newest Oracle Linux x86_64 non-GPU OKE image for K8S_VERSION, from
# `oci ce node-pool-options get --node-pool-option-id all` (data.sources[]).
# Rule: source-type IMAGE; source-name matches
#   Oracle-Linux-<ver>-[Gen2-]<YYYY.MM.DD>-<n>-OKE-<k8s version>-<build>
# (so no GPU or aarch64 variant, which insert a word before the date);
# newest by the date in the name, then by name. Prints "<ocid>\t<name>".
# SYSTEM_IMAGE_ID overrides the lookup.
resolve_system_image() {
    local compartment_id="$1" ver="${K8S_VERSION#v}" out sel
    if [[ -n "${SYSTEM_IMAGE_ID:-}" ]]; then
        printf '%s\t%s\n' "$SYSTEM_IMAGE_ID" "SYSTEM_IMAGE_ID override"
        return 0
    fi
    out=$(oci ce node-pool-options get --node-pool-option-id all --compartment-id "$compartment_id") || return 1
    sel=$(printf '%s' "$out" | jq -r --arg v "$ver" '
        [ .data.sources[]?
          | select((.["source-type"] // "") == "IMAGE")
          | select((.["source-name"] // "") | test("^Oracle-Linux-[0-9]+(\\.[0-9]+)?-(Gen2-)?[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}-[0-9]+-OKE-"))
          | select(.["source-name"] | contains("-OKE-" + $v + "-"))
          | select(.["source-name"] | test("GPU|aarch64"; "i") | not)
          | {id: .["image-id"], name: .["source-name"],
             date: (.["source-name"] | capture("(?<d>[0-9]{4}\\.[0-9]{2}\\.[0-9]{2})").d)} ]
        | if length == 0 then empty else (sort_by(.date, .name) | last | "\(.id)\t\(.name)") end') || return 1
    [[ -n "$sel" ]] || return 1
    printf '%s\n' "$sel"
}

# Wait until at least one non-GPU (system pool) node is Ready. CoreDNS and the
# Cluster Autoscaler run there; the DNS gate depends on it.
wait_system_node_ready() {
    local deadline lines ready
    deadline=$(( $(date +%s) + NODE_READY_TIMEOUT ))
    while :; do
        lines=$("${KCTL[@]}" get nodes -l "!${GPU_NODE_LABEL_KEY}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
            2>/dev/null) || lines=""
        ready=$(printf '%s\n' "$lines" | awk -F'\t' '$2 == "True" {r++} END {print r + 0}')
        if (( ready >= 1 )); then
            log_success "System pool node(s) Ready: $ready (no ${GPU_NODE_LABEL_KEY} label)"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            die "No Ready system-pool node after ${NODE_READY_TIMEOUT}s (pool $SYSTEM_NODE_POOL_NAME). CoreDNS and the autoscaler cannot run. The cluster is billing; re-run or run 'make teardown'."
        fi
        sleep "$POLL_INTERVAL"
    done
}

# Print "<raw>\t<GiB>" for a node's ephemeral-storage capacity.
node_ephemeral() {
    local raw gib
    raw=$("${KCTL[@]}" get node "$1" -o jsonpath='{.status.capacity.ephemeral-storage}') || return 1
    gib=$(quantity_to_gib "$raw") || { log_error "Unparseable ephemeral-storage '$raw' on $1"; return 1; }
    printf '%s\t%s\n' "$raw" "$gib"
}

# E1 verification only: every GPU node must report ephemeral-storage capacity
# >= MIN_EPHEMERAL_STORAGE (the chart requests 20Gi, limit 200Gi). Nothing is
# changed on the node; a failure means the cloud-init growfs did not work.
verify_ephemeral_storage() {
    local min_gib nodes node cur raw gib
    min_gib=$(quantity_to_gib "$MIN_EPHEMERAL_STORAGE") || die "MIN_EPHEMERAL_STORAGE '$MIN_EPHEMERAL_STORAGE' is not a quantity"
    nodes=$("${KCTL[@]}" get nodes -l "$GPU_NODE_SELECTOR" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || die "Listing GPU nodes failed"
    [[ -n "$nodes" ]] || die "No GPU nodes found for the ephemeral-storage check"
    for node in $nodes; do
        cur=$(node_ephemeral "$node") || die "Reading ephemeral-storage capacity of $node failed"
        raw="${cur%%$'\t'*}"; gib="${cur##*$'\t'}"
        if (( gib < min_gib )); then
            die "EPHEMERAL STORAGE CHECK FAILED: node $node reports ephemeral-storage ${raw} (${gib}Gi); need >= ${MIN_EPHEMERAL_STORAGE}. The node pool's cloud-init (oci-growfs) did not take effect; nodes are not modified after creation. The cluster is billing; investigate or run 'make teardown'."
        fi
        log_success "Node $node ephemeral-storage ${raw} (${gib}Gi) >= ${MIN_EPHEMERAL_STORAGE}"
    done
}

# Create a node pool (or reuse one with the same name in this cluster) and
# record its OCID under $2. Sets CREATED_POOL_ID.
#   $1 role (system|gpu)  $2 info key  $3 name  $4 compartment  $5 cluster
#   rest: extra `oci ce node-pool create` arguments
CREATED_POOL_ID=""
create_node_pool() {
    local role="$1" key="$2" name="$3" compartment_id="$4" cluster_id="$5" id wr_out state
    shift 5
    CREATED_POOL_ID=""
    id=$(oci_find_node_pool_id "$compartment_id" "$name" "$cluster_id") \
        || die "Failed to list node pools in compartment $compartment_id"
    if [[ -n "$id" ]]; then
        log_info "Node pool exists: $name ($id)"
        record_info "$key" "$id"
        CREATED_POOL_ID="$id"
        return 0
    fi
    if [[ "$role" == "gpu" ]]; then NODE_POOL_CREATE_STARTED="yes"; else SYSTEM_NODE_POOL_CREATE_STARTED="yes"; fi
    wr_out=$(oci ce node-pool create \
        --cluster-id "$cluster_id" \
        --compartment-id "$compartment_id" \
        --name "$name" \
        --kubernetes-version "$K8S_VERSION" \
        "$@" \
        --wait-for-state SUCCEEDED \
        --wait-for-state FAILED \
        --max-wait-seconds 1800) || die "Failed to create node pool $name - check quota and capacity in region"
    parse_work_request "$wr_out" '^node.?pool$'
    id="$WR_RESOURCE_ID"
    if ! is_ocid_of nodepool "$id"; then
        id=$(oci_find_node_pool_id "$compartment_id" "$name" "$cluster_id") || id=""
    fi
    if [[ "$role" == "gpu" ]]; then NODE_POOL_ID="$id"; else SYSTEM_NODE_POOL_ID="$id"; fi
    [[ -n "$id" ]] && record_info "$key" "$id"
    if [[ -n "$WR_STATUS" && "$WR_STATUS" != "SUCCEEDED" ]]; then
        die "Node pool $name create work request ended in state $WR_STATUS (not SUCCEEDED) - check capacity in the AD"
    fi
    [[ -n "$id" ]] || die "Node pool create returned no node pool OCID: $name"
    if [[ -z "$WR_STATUS" ]]; then
        state=$(oci_ce_get_state node-pool "$id") || die "Could not read state of node pool $id"
        [[ "$state" == "ACTIVE" ]] || die "Node pool $id is in state '$state', not ACTIVE"
    fi
    log_success "Node pool created: $name ($id)"
    CREATED_POOL_ID="$id"
}

# Lifecycle state of the ClusterAutoscaler add-on ("" if not installed).
# Non-zero if the list call fails.
addon_state() {
    local out
    out=$(oci ce cluster list-addons --cluster-id "$1" --all) || return 1
    [[ -n "$out" ]] || { echo ""; return 0; }
    printf '%s' "$out" | jq -r '[.data[]? | select(.name == "ClusterAutoscaler") | .["lifecycle-state"]] | first // empty'
}

addon_evidence() {
    local cluster_id="$1"
    echo "--- oci ce cluster get-addon --addon-name ClusterAutoscaler ---" >&2
    oci ce cluster get-addon --cluster-id "$cluster_id" --addon-name ClusterAutoscaler >&2 || true
    echo "--- kubectl get pods -n kube-system -o wide ---" >&2
    "${KCTL[@]}" get pods -n kube-system -o wide >&2 || true
}

# Name and node of a Running cluster-autoscaler pod on a non-GPU node ("" if none).
autoscaler_pod_on_system_node() {
    local pods gpu_nodes name phase node
    pods=$("${KCTL[@]}" -n kube-system get pods \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.nodeName}{"\n"}{end}' 2>/dev/null) || return 0
    gpu_nodes=$("${KCTL[@]}" get nodes -l "$GPU_NODE_SELECTOR" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null) || gpu_nodes=""
    while IFS=$'\t' read -r name phase node; do
        [[ "$name" == cluster-autoscaler* && "$phase" == "Running" && -n "$node" ]] || continue
        if ! printf '%s\n' "$gpu_nodes" | grep -Fqx -- "$node"; then
            printf '%s\t%s\n' "$name" "$node"
            return 0
        fi
    done <<< "$pods"
}

# I1: install the OKE ClusterAutoscaler add-on for the GPU pool (min 0) and
# wait, bounded by ADDON_TIMEOUT, for ACTIVE plus a Running autoscaler pod on
# the system pool. Fails loudly with the add-on state and pod evidence.
ensure_cluster_autoscaler() {
    local cluster_id="$1" gpu_pool_id="$2" state cfg deadline pod
    state=$(addon_state "$cluster_id") || die "Listing cluster add-ons failed (oci ce cluster list-addons). The cluster is billing; re-run or run 'make teardown'."
    if [[ -n "$state" && "$state" != "DELETED" ]]; then
        log_warn "ClusterAutoscaler add-on already installed (state $state); keeping its existing configuration"
    else
        cfg="${TMPDIR:-/tmp}/nimble-ca-addon.$$.json"
        jq -n --arg nodes "0:${MAX_GPU_NODES}:${gpu_pool_id}" \
              --arg unneeded "$SCALE_DOWN_UNNEEDED" --arg delay "$SCALE_DOWN_DELAY_AFTER_ADD" '{
            configurations: [
              {key: "nodes", value: $nodes},
              {key: "authType", value: "instance"},
              {key: "scaleDownUnneededTime", value: $unneeded},
              {key: "scaleDownDelayAfterAdd", value: $delay},
              {key: "maxNodeProvisionTime", value: "25m"}
            ]}' > "$cfg" || die "Writing the add-on configuration failed"
        log_info "Installing ClusterAutoscaler add-on: nodes=0:${MAX_GPU_NODES}:${gpu_pool_id}, scaleDownUnneededTime=${SCALE_DOWN_UNNEEDED}, scaleDownDelayAfterAdd=${SCALE_DOWN_DELAY_AFTER_ADD}"
        if ! oci ce cluster install-addon --addon-name ClusterAutoscaler \
            --from-json "file://$cfg" --cluster-id "$cluster_id" >/dev/null; then
            rm -f "$cfg"
            die "ClusterAutoscaler add-on install FAILED. The cluster is billing; fix and re-run, or run 'make teardown'."
        fi
        rm -f "$cfg"
    fi
    deadline=$(( $(date +%s) + ADDON_TIMEOUT ))
    while :; do
        state=$(addon_state "$cluster_id") || state="UNKNOWN (list failed)"
        if [[ "$state" == "FAILED" ]]; then
            log_error "ClusterAutoscaler add-on is FAILED; evidence follows"
            addon_evidence "$cluster_id"
            die "AUTOSCALER CHECK FAILED: add-on state FAILED. The cluster is billing; fix and re-run, or run 'make teardown'."
        fi
        if [[ "$state" == "ACTIVE" ]]; then
            pod=$(autoscaler_pod_on_system_node)
            if [[ -n "$pod" ]]; then
                log_success "ClusterAutoscaler add-on ACTIVE; pod ${pod%%$'\t'*} Running on system node ${pod##*$'\t'}"
                return 0
            fi
        fi
        if (( $(date +%s) >= deadline )); then
            log_error "ClusterAutoscaler not ready after ${ADDON_TIMEOUT}s (add-on state: ${state:-not installed}); evidence follows"
            addon_evidence "$cluster_id"
            die "AUTOSCALER CHECK FAILED: add-on state '${state:-not installed}', no Running cluster-autoscaler pod on the system pool after ${ADDON_TIMEOUT}s. GPU nodes will NOT scale up. The cluster is billing; fix and re-run, or run 'make teardown'."
        fi
        sleep "$POLL_INTERVAL"
    done
}

# Autoscale mode: make sure an NVIDIA device plugin DaemonSet exists so GPU
# nodes that appear later advertise nvidia.com/gpu. Applies the pinned
# upstream manifest only if no kube-system DaemonSet matches nvidia.*device-plugin.
ensure_device_plugin_daemonset() {
    local ds
    ds=$("${KCTL[@]}" -n kube-system get daemonsets \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || die "Listing kube-system DaemonSets failed"
    if printf '%s\n' "$ds" | grep -Eq 'nvidia.*device-plugin'; then
        log_info "NVIDIA device plugin DaemonSet present: $(printf '%s\n' "$ds" | grep -E 'nvidia.*device-plugin' | head -1)"
        return 0
    fi
    log_info "No NVIDIA device plugin DaemonSet in kube-system; applying ${NVIDIA_DEVICE_PLUGIN_VERSION}..."
    "${KCTL[@]}" apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/nvidia-device-plugin.yml" \
        || die "NVIDIA device plugin ${NVIDIA_DEVICE_PLUGIN_VERSION} apply FAILED. The cluster is billing; re-run or run 'make teardown'."
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

# Ready kube-dns pods in kube-system (0 if the list fails).
dns_ready_count() {
    local out
    out=$("${KCTL[@]}" -n kube-system get pods -l k8s-app=kube-dns \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null) || out=""
    printf '%s\n' "$out" | awk -F'\t' '$2 == "True" {r++} END {print r + 0}'
}

# Cluster DNS gate: NIM resolves the NGC endpoints through CoreDNS. If every
# node is a tainted GPU node, CoreDNS can stay Pending and the model download
# fails 20 minutes later with no evidence; fail here instead, with evidence.
ensure_cluster_dns() {
    local deadline n
    deadline=$(( $(date +%s) + DNS_READY_TIMEOUT ))
    while :; do
        n=$(dns_ready_count)
        if (( n >= 1 )); then
            log_success "DNS check passed: $n Ready kube-dns pod(s) in kube-system"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            log_error "No Ready kube-dns pod in kube-system after ${DNS_READY_TIMEOUT}s; evidence follows"
            echo "--- kubectl get pods -n kube-system -o wide ---" >&2
            "${KCTL[@]}" get pods -n kube-system -o wide >&2 || true
            echo "--- kubectl describe pods -n kube-system -l k8s-app=kube-dns (tolerations, events) ---" >&2
            "${KCTL[@]}" describe pods -n kube-system -l k8s-app=kube-dns >&2 || true
            echo "--- node taints ---" >&2
            "${KCTL[@]}" get nodes -o 'custom-columns=NAME:.metadata.name,TAINTS:.spec.taints' >&2 || true
            die "DNS CHECK FAILED: no Ready kube-dns (CoreDNS) pod after ${DNS_READY_TIMEOUT}s; NIM could not download its model. Check node taints vs CoreDNS tolerations above. The cluster is billing; fix and re-run, or run 'make teardown'."
        fi
        sleep "$POLL_INTERVAL"
    done
}

cleanup_on_failure() {
    local rc=$?
    trap - EXIT
    set +e
    [[ $rc -eq 0 ]] && rc=1

    log_warn "Provisioning failed (exit $rc); cleaning up GPU/cluster resources created by this run..."
    local ok="yes" deleted=""

    # GPU pool first, then the system pool (both only if this run created them).
    local role started pool_id pool_name
    for role in gpu system; do
        if [[ "$role" == "gpu" ]]; then
            started="$NODE_POOL_CREATE_STARTED"; pool_id="$NODE_POOL_ID"; pool_name="$NODE_POOL_NAME"
        else
            started="$SYSTEM_NODE_POOL_CREATE_STARTED"; pool_id="$SYSTEM_NODE_POOL_ID"; pool_name="$SYSTEM_NODE_POOL_NAME"
        fi
        [[ "$started" == "yes" ]] || continue
        if [[ -z "$pool_id" ]]; then
            log_info "Node pool OCID unknown; looking it up by name '$pool_name'..."
            if ! pool_id=$(oci_find_node_pool_id "$TRAP_COMPARTMENT_ID" "$pool_name" "$CLUSTER_ID"); then
                log_error "Node pool lookup failed; cannot confirm whether node pool $pool_name exists"
                pool_id=""
                ok="no"
            fi
        fi
        if [[ -n "$pool_id" ]]; then
            if oci_ce_delete_confirmed node-pool "$pool_id"; then
                deleted="$deleted node-pool($pool_name)"
            else
                ok="no"
            fi
        fi
    done

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

    # GPU pool size at create: 0 in autoscale mode (the add-on scales it).
    local autoscale="no" gpu_pool_size="$NODE_COUNT" priced_nodes="$NODE_COUNT"
    case "$AUTOSCALE" in
        1|yes|true) autoscale="yes" ;;
        0|no|false|"") autoscale="no" ;;
        *) die "AUTOSCALE must be 1 or 0 (got '$AUTOSCALE')" ;;
    esac
    if [[ "$autoscale" == "yes" ]]; then
        [[ "$MAX_GPU_NODES" =~ ^[1-9][0-9]*$ ]] || die "MAX_GPU_NODES must be a whole number >= 1 (got '$MAX_GPU_NODES')"
        gpu_pool_size=0
        priced_nodes="$MAX_GPU_NODES"
        # I5: preflight - nothing is created unless the autoscaler's IAM exists.
        log_info "AUTOSCALE=1: checking Cluster Autoscaler IAM (scripts/setup-autoscaler-iam.sh --check)..."
        if ! "${BASH:-bash}" "${SCRIPT_DIR}/setup-autoscaler-iam.sh" --check; then
            die "PREFLIGHT FAILED: Cluster Autoscaler IAM (dynamic group + policy) is not in place; nothing was created. The owner runs: scripts/setup-autoscaler-iam.sh --print, then --apply."
        fi
    fi

    log_info "Estimating provisioning cost..."
    local gpus_per_node
    gpus_per_node=$(get_shape_gpu_count "$GPU_SHAPE") || die "Unsupported GPU shape: $GPU_SHAPE"
    local node_rate system_rate
    node_rate=$(get_gpu_hourly_rate "$GPU_SHAPE") || die "Cannot price GPU shape: $GPU_SHAPE"
    system_rate=$(get_system_pool_hourly_rate) || die "Cannot price the system pool"
    local hourly_cost
    hourly_cost=$(estimate_hourly_cost "$priced_nodes" "$GPU_SHAPE") || die "Cannot price GPU shape: $GPU_SHAPE"
    local test_cost
    test_cost=$(echo "$hourly_cost * 5" | bc -l)

    log_info "Configuration:"
    log_info "  Cluster: $CLUSTER_NAME"
    log_info "  Region: $region"
    log_info "  GPU Shape: $GPU_SHAPE (${gpus_per_node}x NVIDIA A10 GPU per node)"
    if [[ "$autoscale" == "yes" ]]; then
        log_info "  GPU nodes: autoscaled 0..$MAX_GPU_NODES (cost shown at $MAX_GPU_NODES node(s))"
    else
        log_info "  Node Count: $NODE_COUNT"
    fi
    log_info "  System pool: 1 x $SYSTEM_SHAPE (${SYSTEM_OCPUS} OCPU, ${SYSTEM_MEMORY_GB} GB) \$${system_rate}/hour"
    log_info "  Estimated cost: \$$(format_cost "$hourly_cost")/hour"
    log_info "    GPU \$${node_rate}/node-hour + system pool \$${system_rate}/hour + enhanced cluster \$${NIM_ENHANCED_CLUSTER_HOURLY_USD}/hour"
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
    record_info SYSTEM_NODE_POOL_NAME "$SYSTEM_NODE_POOL_NAME"
    record_info GPU_NODE_SELECTOR "$GPU_NODE_SELECTOR"
    if [[ "$autoscale" == "yes" ]]; then
        record_info AUTOSCALE 1
        record_info MAX_GPU_NODES "$MAX_GPU_NODES"
    else
        record_info AUTOSCALE 0
        record_info MAX_GPU_NODES "$NODE_COUNT"
    fi

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
        # No --service-lb-subnet-ids: OKE refuses a node pool in a subnet that
        # is also the cluster's service load-balancer subnet, and the chart's
        # Service is ClusterIP, so no load balancer is created.
        wr_out=$(oci ce cluster create \
            --compartment-id "$compartment_id" \
            --name "$CLUSTER_NAME" \
            --vcn-id "$vcn_id" \
            --kubernetes-version "$K8S_VERSION" \
            --type ENHANCED_CLUSTER \
            --endpoint-subnet-id "$api_subnet_id" \
            --endpoint-public-ip-enabled true \
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

    # Availability domain shared by both pools.
    local availability_domain
    availability_domain=$(get_oke_availability_domain "$compartment_id" "$region") || die "Failed to get availability domain"
    local placement="[{\"availabilityDomain\": \"$availability_domain\", \"subnetId\": \"$subnet_id\"}]"

    # E2: non-autoscaled system pool first (CoreDNS, the Cluster Autoscaler).
    log_info "Creating system node pool ($SYSTEM_SHAPE, ${SYSTEM_OCPUS} OCPU / ${SYSTEM_MEMORY_GB} GB, size 1)..."
    local system_pool_id
    system_pool_id=$(oci_find_node_pool_id "$compartment_id" "$SYSTEM_NODE_POOL_NAME" "$cluster_id") \
        || die "Failed to list node pools in compartment $compartment_id"
    if [[ -n "$system_pool_id" ]]; then
        log_info "System node pool exists: $system_pool_id"
        record_info SYSTEM_NODE_POOL_ID "$system_pool_id"
    else
        local sys_image sys_image_id
        sys_image=$(resolve_system_image "$compartment_id") \
            || die "No Oracle Linux x86_64 non-GPU OKE image found for Kubernetes ${K8S_VERSION#v} (oci ce node-pool-options get --node-pool-option-id all). Set SYSTEM_IMAGE_ID to an OKE image OCID and re-run."
        sys_image_id="${sys_image%%$'\t'*}"
        log_info "  System pool image: ${sys_image##*$'\t'} ($sys_image_id)"
        create_node_pool system SYSTEM_NODE_POOL_ID "$SYSTEM_NODE_POOL_NAME" "$compartment_id" "$cluster_id" \
            --node-shape "$SYSTEM_SHAPE" \
            --node-shape-config "{\"ocpus\": $SYSTEM_OCPUS, \"memoryInGBs\": $SYSTEM_MEMORY_GB}" \
            --size 1 \
            --placement-configs "$placement" \
            --node-source-details "{\"sourceType\": \"IMAGE\", \"imageId\": \"$sys_image_id\"}"
        system_pool_id="$CREATED_POOL_ID"
    fi

    log_info "Creating GPU node pool (10-15 minutes)..."
    local node_pool_id
    node_pool_id=$(oci_find_node_pool_id "$compartment_id" "$NODE_POOL_NAME" "$cluster_id") \
        || die "Failed to list node pools in compartment $compartment_id"
    if [[ -n "$node_pool_id" ]]; then
        log_info "GPU node pool exists: $node_pool_id"
        record_info NODE_POOL_ID "$node_pool_id"
    else
        validate_oke_gpu_quota "$priced_nodes" "$GPU_SHAPE" || die "GPU quota validation failed"
        validate_oke_image "$OKE_GPU_IMAGE_ID" || die "OKE-optimized image validation failed"
        local node_metadata
        node_metadata=$(gpu_node_metadata_json) || die "Building the GPU pool cloud-init failed"
        local gpu_extra_tags=""
        log_info "  Shape: $GPU_SHAPE, size $gpu_pool_size"
        log_info "  Image: $OKE_GPU_IMAGE_NAME"
        log_info "  Boot Volume: ${OKE_BOOT_VOLUME_SIZE_GB}GB (root grown at boot by cloud-init oci-growfs)"
        log_info "  Availability Domain: $availability_domain"
        log_info "  Node label: $GPU_NODE_SELECTOR"
        if [[ "$autoscale" == "yes" ]]; then
            local eph_gb=$(( OKE_BOOT_VOLUME_SIZE_GB - EPHEMERAL_TAG_MARGIN_GB ))
            (( eph_gb > 0 )) || die "Boot volume ${OKE_BOOT_VOLUME_SIZE_GB}GB minus margin ${EPHEMERAL_TAG_MARGIN_GB}GB leaves no ephemeral storage"
            gpu_extra_tags=$(jq -cn --arg k "$EPHEMERAL_STORAGE_TAG_KEY" --arg v "${eph_gb}Gi" '{($k): $v}')
            log_info "  Autoscaler template: freeform tag $EPHEMERAL_STORAGE_TAG_KEY=${eph_gb}Gi"
            create_node_pool gpu NODE_POOL_ID "$NODE_POOL_NAME" "$compartment_id" "$cluster_id" \
                --node-shape "$GPU_SHAPE" \
                --size "$gpu_pool_size" \
                --placement-configs "$placement" \
                --node-source-details "{\"sourceType\": \"IMAGE\", \"imageId\": \"$OKE_GPU_IMAGE_ID\", \"bootVolumeSizeInGBs\": $OKE_BOOT_VOLUME_SIZE_GB}" \
                --initial-node-labels "[{\"key\": \"${GPU_NODE_LABEL_KEY}\", \"value\": \"true\"}]" \
                --node-metadata "$node_metadata" \
                --freeform-tags "$gpu_extra_tags"
        else
            create_node_pool gpu NODE_POOL_ID "$NODE_POOL_NAME" "$compartment_id" "$cluster_id" \
                --node-shape "$GPU_SHAPE" \
                --size "$gpu_pool_size" \
                --placement-configs "$placement" \
                --node-source-details "{\"sourceType\": \"IMAGE\", \"imageId\": \"$OKE_GPU_IMAGE_ID\", \"bootVolumeSizeInGBs\": $OKE_BOOT_VOLUME_SIZE_GB}" \
                --initial-node-labels "[{\"key\": \"${GPU_NODE_LABEL_KEY}\", \"value\": \"true\"}]" \
                --node-metadata "$node_metadata"
        fi
        node_pool_id="$CREATED_POOL_ID"
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
    KCTL=(kubectl --context "$kube_ctx" --request-timeout=30s)

    "${KCTL[@]}" cluster-info &>/dev/null \
        || die "Cluster API unreachable via context $kube_ctx. The cluster is billing; re-run or run 'make teardown'."

    log_info "Waiting for the system pool node to register and become Ready..."
    wait_system_node_ready
    if [[ "$autoscale" == "yes" ]]; then
        # No GPU node exists yet; the autoscaler adds one when a GPU pod is Pending.
        ensure_cluster_autoscaler "$cluster_id" "$node_pool_id"
        ensure_device_plugin_daemonset
    else
        log_info "Waiting for GPU node(s) to register and become Ready..."
        wait_gpu_nodes_ready
        verify_ephemeral_storage
        ensure_gpu_allocatable
    fi
    ensure_cluster_dns

    log_success "OKE cluster provisioning complete!"
    echo ""
    log_info "Cluster details:"
    log_info "  Cluster ID: $cluster_id"
    log_info "  System pool: $system_pool_id (1 × $SYSTEM_SHAPE)"
    if [[ "$autoscale" == "yes" ]]; then
        log_info "  GPU pool: $node_pool_id, autoscaled 0..$MAX_GPU_NODES × $GPU_SHAPE (now 0 nodes; select with $GPU_NODE_SELECTOR)"
    else
        log_info "  GPU Nodes: $NODE_COUNT × $GPU_SHAPE (${gpus_per_node}x NVIDIA A10 GPU per node)"
    fi
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
