#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"
source "${SCRIPT_DIR}/oke-optimized-config.sh"

readonly CLUSTER_NAME="${CLUSTER_NAME:-nimble-oke-cluster}"
readonly NODE_POOL_NAME="gpu-node-pool"
readonly GPU_SHAPE="VM.GPU.A10.4"
readonly NODE_COUNT="${NODE_COUNT:-1}"
readonly K8S_VERSION="${K8S_VERSION:-v1.34.1}"
readonly VCN_NAME="nimble-oke-vcn"
readonly SUBNET_NAME="nimble-oke-subnet"
readonly PROVISION_TIMEOUT=1800

# Budget Configuration (VM.GPU.A10.4 pricing: ~$12.44/hour)
readonly BUDGET_FAST="${BUDGET_FAST:-15}"      # 1 hour test
readonly BUDGET_SHORT="${BUDGET_SHORT:-25}"     # 2 hour test  
readonly BUDGET_EXTENDED="${BUDGET_EXTENDED:-50}" # 4 hour test
readonly BUDGET_FULL_DAY="${BUDGET_FULL_DAY:-300}" # 24 hour test

cleanup_on_failure() {
    log_warn "Provisioning failed, cleanup initiated..."
    
    if [[ -f "${SCRIPT_DIR}/cluster-info.txt" ]]; then
        source "${SCRIPT_DIR}/cluster-info.txt"
        
        [[ -n "${NODE_POOL_ID:-}" ]] && oci ce node-pool delete --node-pool-id "$NODE_POOL_ID" --force 2>/dev/null || true
        [[ -n "${CLUSTER_ID:-}" ]] && oci ce cluster delete --cluster-id "$CLUSTER_ID" --force 2>/dev/null || true
        
        rm -f "${SCRIPT_DIR}/cluster-info.txt"
    fi
    
    log_info "Partial cleanup complete"
}

main() {
    log_info "Provisioning OKE cluster with GPU nodes..."
    
    trap cleanup_on_failure EXIT ERR INT TERM
    
    check_oci_credentials || die "OCI credentials not configured"
    check_env_var OCI_COMPARTMENT_ID
    check_command jq
    
    local compartment_id="${OCI_COMPARTMENT_ID}"
    local region="${OCI_REGION:-us-phoenix-1}"
    
    log_info "Estimating provisioning cost with OKE-optimized configuration..."
    local hourly_cost
    hourly_cost=$(estimate_oke_cost 1 "$NODE_COUNT")
    local test_cost
    test_cost=$(estimate_oke_cost 5 "$NODE_COUNT")
    
    log_info "Configuration:"
    log_info "  Cluster: $CLUSTER_NAME"
    log_info "  Region: $region"
    log_info "  GPU Shape: $GPU_SHAPE (4x NVIDIA A10 GPUs)"
    log_info "  Node Count: $NODE_COUNT"
    log_info "  Estimated cost: \$$(format_cost "$hourly_cost")/hour"
    log_info "  5-hour test cost: \$$(format_cost "$test_cost")"
    log_info ""
    log_info "Budget Options:"
    log_info "  Fast Test (1 hour): \$$(format_cost "$hourly_cost")"
    log_info "  Short Test (2 hours): \$$(format_cost "$(echo "$hourly_cost * 2" | bc -l)")"
    log_info "  Extended Test (4 hours): \$$(format_cost "$(echo "$hourly_cost * 4" | bc -l)")"
    log_info "  Full Day (24 hours): \$$(format_cost "$(echo "$hourly_cost * 24" | bc -l)")"
    
    # Use appropriate budget based on test duration
    local budget_threshold="$BUDGET_EXTENDED"  # Default to 4-hour test budget
    cost_guard "$(format_cost "$test_cost")" "OKE cluster provisioning (VM.GPU.A10.4)"
    
    log_info "Creating VCN..."
    local vcn_id
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
        log_success "VCN created: $vcn_id"
    else
        log_info "VCN already exists: $vcn_id"
    fi
    
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
    
    log_info "Updating route table..."
    local route_table_id
    route_table_id=$(oci network route-table list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --query 'data[0].id' \
        --raw-output)
    
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
    
    log_info "Creating OKE cluster (ENHANCED type, 10-15 minutes)..."
    local cluster_id
    cluster_id=$(oci ce cluster list \
        --compartment-id "$compartment_id" \
        --name "$CLUSTER_NAME" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [[ -z "$cluster_id" ]]; then
        cluster_id=$(oci ce cluster create \
            --compartment-id "$compartment_id" \
            --name "$CLUSTER_NAME" \
            --vcn-id "$vcn_id" \
            --kubernetes-version "$K8S_VERSION" \
            --cluster-type ENHANCED \
            --endpoint-subnet-id "$api_subnet_id" \
            --endpoint-public-ip-enabled true \
            --service-lb-subnet-ids "[\"$subnet_id\"]" \
            --wait-for-state SUCCEEDED \
            --wait-for-state FAILED \
            --max-wait-seconds 1800 \
            --query 'data.id' \
            --raw-output)
        log_success "OKE cluster created (ENHANCED): $cluster_id"
    else
        log_info "OKE cluster exists: $cluster_id"
    fi
    
    log_info "Creating GPU node pool (10-15 minutes)..."
    local node_pool_id
    node_pool_id=$(oci ce node-pool list \
        --cluster-id "$cluster_id" \
        --name "$NODE_POOL_NAME" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
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
            --raw-output 2>/dev/null) || die "Failed to create GPU node pool - check GPU quota and capacity in region"
        log_success "GPU node pool created: $node_pool_id"
    else
        log_info "GPU node pool exists: $node_pool_id"
    fi
    
    log_info "Saving cluster information..."
    cat > "${SCRIPT_DIR}/cluster-info.txt" <<EOF
CLUSTER_ID=$cluster_id
VCN_ID=$vcn_id
SUBNET_ID=$subnet_id
NODE_POOL_ID=$node_pool_id
REGION=$region
GPU_SHAPE=$GPU_SHAPE
NODE_COUNT=$NODE_COUNT
CLUSTER_NAME=$CLUSTER_NAME
NODE_POOL_NAME=$NODE_POOL_NAME
VCN_NAME=$VCN_NAME
EOF
    
    log_info "Configuring kubectl..."
    oci ce cluster create-kubeconfig \
        --cluster-id "$cluster_id" \
        --file "$HOME/.kube/config" \
        --region "$region" \
        --token-version 2.0.0 \
        --kube-endpoint PUBLIC_ENDPOINT 2>/dev/null || true
    
    log_info "Installing NVIDIA GPU device plugin..."
    if kubectl cluster-info &>/dev/null; then
        kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.0/nvidia-device-plugin.yml || true
        log_info "Waiting for device plugin (may take 2-3 minutes)..."
        kubectl wait --for=condition=ready pod -l name=nvidia-device-plugin-ds -n kube-system --timeout=300s 2>/dev/null || log_warn "Device plugin not ready yet"
    else
        log_warn "kubectl not connected, skipping device plugin installation"
    fi
    
    trap - EXIT ERR INT TERM
    
    log_success "OKE cluster provisioning complete!"
    echo ""
    log_info "Cluster details:"
    log_info "  Cluster ID: $cluster_id"
    log_info "  GPU Nodes: $NODE_COUNT × $GPU_SHAPE (4x NVIDIA A10 GPUs)"
    log_info "  Hourly cost: \$$(format_cost "$hourly_cost")"
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
    log_warn "Run 'make cleanup-cluster' when finished to stop charges"
}

main "$@"

