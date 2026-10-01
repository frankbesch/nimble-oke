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
        log_warn "Network resources (VCN, subnets, gateway) were left in place."
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
            --raw-output 2>/dev/null || echo "")

        if [[ -z "$vcn_id" ]]; then
            vcn_id=$(oci network vcn create \
                --compartment-id "$compartment_id" \
                --display-name "$VCN_NAME" \
                --cidr-block "10.0.0.0/16" \
                --dns-label "nimbleoke" \
                --query 'data.id' \
                --raw-output)
            record_info VCN_CREATED "yes"
            log_success "VCN created: $vcn_id"
        else
            log_info "VCN already exists: $vcn_id"
        fi
    fi
    record_info VCN_ID "$vcn_id"

    log_info "Creating Internet Gateway..."
    local igw_id
    igw_id=$(oci network internet-gateway list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")

    if [[ -z "$igw_id" ]]; then
        igw_id=$(oci network internet-gateway create \
            --compartment-id "$compartment_id" \
            --vcn-id "$vcn_id" \
            --display-name "${VCN_NAME}-igw" \
            --is-enabled true \
            --query 'data.id' \
            --raw-output)
        log_success "Internet Gateway created: $igw_id"
    else
        log_info "Internet Gateway already exists: $igw_id"
    fi
    record_info IGW_ID "$igw_id"

    log_info "Updating route table..."
    local route_table_id
    route_table_id=$(oci network route-table list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --query 'data[0].id' \
        --raw-output)
    record_info ROUTE_TABLE_ID "$route_table_id"

    oci network route-table update \
        --rt-id "$route_table_id" \
        --route-rules "[{\"destination\":\"0.0.0.0/0\",\"networkEntityId\":\"$igw_id\"}]" \
        --force 2>/dev/null || true

    log_info "Creating API endpoint subnet..."
    local api_subnet_id
    api_subnet_id=$(oci network subnet list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --display-name "${SUBNET_NAME}-api" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")

    if [[ -z "$api_subnet_id" ]]; then
        api_subnet_id=$(oci network subnet create \
            --compartment-id "$compartment_id" \
            --vcn-id "$vcn_id" \
            --display-name "${SUBNET_NAME}-api" \
            --cidr-block "10.0.0.0/28" \
            --dns-label "api" \
            --route-table-id "$route_table_id" \
            --wait-for-state AVAILABLE \
            --max-wait-seconds 180 \
            --query 'data.id' \
            --raw-output)
        log_success "API subnet created: $api_subnet_id"
    else
        log_info "API subnet exists: $api_subnet_id"
    fi
    record_info API_SUBNET_ID "$api_subnet_id"

    log_info "Creating worker node subnet..."
    local subnet_id
    subnet_id=$(oci network subnet list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --display-name "${SUBNET_NAME}-workers" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")

    if [[ -z "$subnet_id" ]]; then
        subnet_id=$(oci network subnet create \
            --compartment-id "$compartment_id" \
            --vcn-id "$vcn_id" \
            --display-name "${SUBNET_NAME}-workers" \
            --cidr-block "10.0.1.0/24" \
            --dns-label "workers" \
            --route-table-id "$route_table_id" \
            --wait-for-state AVAILABLE \
            --max-wait-seconds 180 \
            --query 'data.id' \
            --raw-output)
        log_success "Worker subnet created: $subnet_id"
    else
        log_info "Worker subnet exists: $subnet_id"
    fi
    record_info SUBNET_ID "$subnet_id"

    log_info "Creating OKE cluster (ENHANCED type, 10-15 minutes)..."
    local cluster_id
    cluster_id=$(oci_find_cluster_id "$compartment_id" "$CLUSTER_NAME") \
        || die "Failed to list OKE clusters in compartment $compartment_id"

    if [[ -z "$cluster_id" ]]; then
        CLUSTER_CREATE_STARTED="yes"
        cluster_id=$(oci ce cluster create \
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
            --max-wait-seconds 1800 \
            --query 'data.id' \
            --raw-output) || die "OKE cluster create failed"
        if ! is_ocid_of cluster "$cluster_id"; then
            # A waited create may return a work-request id; resolve by name.
            cluster_id=$(oci_find_cluster_id "$compartment_id" "$CLUSTER_NAME") || cluster_id=""
            [[ -n "$cluster_id" ]] || die "Cluster create returned no cluster OCID"
        fi
        CLUSTER_ID="$cluster_id"
        record_info CLUSTER_ID "$cluster_id"
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

        NODE_POOL_CREATE_STARTED="yes"
        node_pool_id=$(oci ce node-pool create \
            --cluster-id "$cluster_id" \
            --compartment-id "$compartment_id" \
            --name "$NODE_POOL_NAME" \
            --node-shape "$GPU_SHAPE" \
            --size "$NODE_COUNT" \
            --kubernetes-version "$K8S_VERSION" \
            --placement-configs "[{\"availabilityDomain\": \"$availability_domain\", \"subnetId\": \"$subnet_id\"}]" \
            --node-source-details "{\"sourceType\": \"IMAGE\", \"imageId\": \"$OKE_GPU_IMAGE_ID\", \"bootVolumeSizeInGBs\": $OKE_BOOT_VOLUME_SIZE_GB}" \
            --wait-for-state SUCCEEDED \
            --wait-for-state FAILED \
            --max-wait-seconds 1800 \
            --query 'data.id' \
            --raw-output) || die "Failed to create GPU node pool - check GPU quota and capacity in region"
        if ! is_ocid_of nodepool "$node_pool_id"; then
            node_pool_id=$(oci_find_node_pool_id "$compartment_id" "$NODE_POOL_NAME" "$cluster_id") || node_pool_id=""
            [[ -n "$node_pool_id" ]] || die "Node pool create returned no node pool OCID"
        fi
        NODE_POOL_ID="$node_pool_id"
        record_info NODE_POOL_ID "$node_pool_id"
        log_success "GPU node pool created: $node_pool_id"
    else
        log_info "GPU node pool exists: $node_pool_id"
        record_info NODE_POOL_ID "$node_pool_id"
    fi

    # All billable resources exist and are recorded. From here a failure must
    # not delete them; it fails loudly and 'make teardown' removes them.
    trap - EXIT INT TERM
    log_info "Cluster information saved to $INFO_FILE"

    log_info "Configuring kubectl..."
    mkdir -p "$HOME/.kube"
    oci ce cluster create-kubeconfig \
        --cluster-id "$cluster_id" \
        --file "$HOME/.kube/config" \
        --region "$region" \
        --token-version 2.0.0 \
        --kube-endpoint PUBLIC_ENDPOINT \
        || die "kubeconfig creation failed. The cluster is billing; fix access and re-run, or run 'make teardown'."

    log_info "Installing NVIDIA GPU device plugin ${NVIDIA_DEVICE_PLUGIN_VERSION}..."
    kubectl cluster-info &>/dev/null \
        || die "Cluster API unreachable; device plugin NOT installed. The cluster is billing; re-run or run 'make teardown'."
    kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/nvidia-device-plugin.yml" \
        || die "NVIDIA device plugin ${NVIDIA_DEVICE_PLUGIN_VERSION} apply FAILED; GPUs are not schedulable. The cluster is billing; re-run or run 'make teardown'."
    log_info "Waiting for device plugin (may take 2-3 minutes)..."
    kubectl wait --for=condition=ready pod -l name=nvidia-device-plugin-ds -n kube-system --timeout=300s 2>/dev/null || log_warn "Device plugin not ready yet"

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
