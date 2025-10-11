#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly CLUSTER_NAME="${CLUSTER_NAME:-nimble-oke-cluster}"
readonly NODE_POOL_NAME="gpu-node-pool"
readonly GPU_SHAPE="VM.GPU.A10.1"
readonly NODE_COUNT="${NODE_COUNT:-1}"
readonly K8S_VERSION="${K8S_VERSION:-v1.28.2}"
readonly VCN_NAME="nimble-oke-vcn"
readonly SUBNET_NAME="nimble-oke-subnet"
readonly PROVISION_TIMEOUT=1800

cleanup_on_failure() {
    log_warn "Provisioning failed, attempting cleanup..."
    
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
    local region="${OCI_REGION:-us-ashburn-1}"
    
    log_info "Estimating provisioning cost..."
    local hourly_cost
    hourly_cost=$(estimate_hourly_cost "$NODE_COUNT")
    local test_cost
    test_cost=$(echo "$hourly_cost * 5" | bc -l)
    
    log_info "Configuration:"
    log_info "  Cluster: $CLUSTER_NAME"
    log_info "  Region: $region"
    log_info "  GPU Shape: $GPU_SHAPE"
    log_info "  Node Count: $NODE_COUNT"
    log_info "  Estimated cost: \$$(format_cost "$hourly_cost")/hour"
    log_info "  5-hour test cost: \$$(format_cost "$test_cost")"
    
    cost_guard "$(format_cost "$test_cost")" "OKE cluster provisioning"
    
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
    
    log_info "Creating subnet..."
    local subnet_id
    subnet_id=$(oci network subnet list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --display-name "$SUBNET_NAME" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [[ -z "$subnet_id" ]]; then
        subnet_id=$(oci network subnet create \
            --compartment-id "$compartment_id" \
            --vcn-id "$vcn_id" \
            --display-name "$SUBNET_NAME" \
            --cidr-block "10.0.1.0/24" \
            --route-table-id "$route_table_id" \
            --query 'data.id' \
            --raw-output)
        log_success "Subnet created: $subnet_id"
    else
        log_info "Subnet already exists: $subnet_id"
    fi
    
    log_info "Creating OKE cluster (this takes 5-10 minutes)..."
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
            --wait-for-state ACTIVE \
            --query 'data.id' \
            --raw-output)
        log_success "OKE cluster created: $cluster_id"
    else
        log_info "OKE cluster already exists: $cluster_id"
    fi
    
    log_info "Creating GPU node pool (this takes 5-10 minutes)..."
    local node_pool_id
    node_pool_id=$(oci ce node-pool list \
        --cluster-id "$cluster_id" \
        --name "$NODE_POOL_NAME" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo "")
    
    if [[ -z "$node_pool_id" ]]; then
        node_pool_id=$(oci ce node-pool create \
            --cluster-id "$cluster_id" \
            --compartment-id "$compartment_id" \
            --name "$NODE_POOL_NAME" \
            --node-shape "$GPU_SHAPE" \
            --size "$NODE_COUNT" \
            --subnet-ids "[\"$subnet_id\"]" \
            --wait-for-state ACTIVE \
            --query 'data.id' \
            --raw-output 2>/dev/null) || die "Failed to create GPU node pool (check GPU quota)"
        log_success "GPU node pool created: $node_pool_id"
    else
        log_info "GPU node pool already exists: $node_pool_id"
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
    log_info "  GPU Nodes: $NODE_COUNT × $GPU_SHAPE"
    log_info "  Hourly cost: \$$(format_cost "$hourly_cost")"
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

