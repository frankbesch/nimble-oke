#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

calculate_total_cost() {
    if [[ -f "${SCRIPT_DIR}/cluster-info.txt" ]]; then
        local start_time
        start_time=$(stat -f %m "${SCRIPT_DIR}/cluster-info.txt" 2>/dev/null || stat -c %Y "${SCRIPT_DIR}/cluster-info.txt" 2>/dev/null || echo "0")
        
        if [[ "$start_time" != "0" ]]; then
            local current_time
            current_time=$(date +%s)
            local elapsed_hours
            elapsed_hours=$(echo "scale=2; ($current_time - $start_time) / 3600" | bc -l)
            
            local node_count="${NODE_COUNT:-1}"
            local hourly_cost
            hourly_cost=$(estimate_hourly_cost "$node_count")
            local total_cost
            total_cost=$(echo "scale=2; $elapsed_hours * $hourly_cost" | bc -l)
            
            log_info "Cluster running time: $(format_cost "$elapsed_hours") hours"
            log_info "Estimated total cost: \$$(format_cost "$total_cost")"
        fi
    fi
}

main() {
    log_warn "OKE Cluster Teardown"
    
    if [[ ! -f "${SCRIPT_DIR}/cluster-info.txt" ]]; then
        log_error "cluster-info.txt not found"
        log_info "Cannot determine cluster resources to delete"
        log_info "Manual cleanup required via OCI Console"
        exit 1
    fi
    
    source "${SCRIPT_DIR}/cluster-info.txt"
    
    calculate_total_cost
    
    echo ""
    log_warn "This will DELETE:"
    log_warn "  - OKE Cluster: ${CLUSTER_NAME:-unknown}"
    log_warn "  - GPU Node Pool: ${NODE_POOL_NAME:-unknown}"
    log_warn "  - VCN: ${VCN_NAME:-unknown}"
    log_warn "  - All networking resources"
    echo ""
    
    local force="${FORCE:-no}"
    
    if [[ "$force" != "yes" ]]; then
        read -p "Type 'yes' to confirm teardown: " -r
        if [[ ! $REPLY == "yes" ]]; then
            log_info "Teardown cancelled"
            exit 0
        fi
    fi
    
    log_info "Deleting node pool..."
    if [[ -n "${NODE_POOL_ID:-}" ]]; then
        oci ce node-pool delete \
            --node-pool-id "$NODE_POOL_ID" \
            --force \
            --wait-for-state DELETED 2>/dev/null || log_warn "Node pool deletion failed or already deleted"
        log_success "Node pool deleted"
    fi
    
    log_info "Deleting OKE cluster..."
    if [[ -n "${CLUSTER_ID:-}" ]]; then
        oci ce cluster delete \
            --cluster-id "$CLUSTER_ID" \
            --force \
            --wait-for-state DELETED 2>/dev/null || log_warn "Cluster deletion failed or already deleted"
        log_success "Cluster deleted"
    fi
    
    log_info "Deleting subnets..."
    if [[ -n "${SUBNET_ID:-}" ]]; then
        oci network subnet delete --subnet-id "$SUBNET_ID" --force 2>/dev/null || true
    fi
    
    log_info "Deleting internet gateway..."
    if [[ -n "${VCN_ID:-}" ]]; then
        local igw_ids
        igw_ids=$(oci network internet-gateway list \
            --compartment-id "${OCI_COMPARTMENT_ID}" \
            --vcn-id "$VCN_ID" \
            --query 'data[*].id' \
            --raw-output 2>/dev/null | tr '\t' '\n')
        
        for igw_id in $igw_ids; do
            oci network internet-gateway delete --ig-id "$igw_id" --force 2>/dev/null || true
        done
    fi
    
    sleep 5
    
    log_info "Deleting VCN..."
    if [[ -n "${VCN_ID:-}" ]]; then
        oci network vcn delete --vcn-id "$VCN_ID" --force 2>/dev/null || log_warn "VCN deletion failed (may have dependencies)"
        log_success "VCN deleted"
    fi
    
    log_info "Cleaning up local files..."
    rm -f "${SCRIPT_DIR}/cluster-info.txt"
    rm -f "${SCRIPT_DIR}/.nim-endpoint"
    rm -f "${SCRIPT_DIR}/.nim-deployed-at"
    rm -f "$HOME/.kube/config" 2>/dev/null || true
    
    log_success "Teardown complete!"
    echo ""
    log_info "All OKE resources deleted"
    log_warn "Charges stopped - no more costs"
    
    log_info "Verifying cleanup..."
    if [[ -n "${OCI_COMPARTMENT_ID:-}" ]]; then
        local remaining
        remaining=$(oci ce cluster list \
            --compartment-id "$OCI_COMPARTMENT_ID" \
            --lifecycle-state ACTIVE \
            --query 'data | length(@)' \
            --raw-output 2>/dev/null || echo "0")
        
        if [[ "$remaining" == "0" ]]; then
            log_success "No active OKE clusters remain"
        else
            log_warn "$remaining active cluster(s) still exist"
        fi
    fi
}

main "$@"

