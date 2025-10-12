#!/usr/bin/env bash

# Cleanup Chicago region cluster and prepare for Phoenix
# This script will:
# 1. Identify OKE clusters in us-chicago-1
# 2. Delete them to start fresh in us-phoenix-1
# 3. Clean up kubectl contexts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

readonly CHICAGO_REGION="us-chicago-1"
readonly PHOENIX_REGION="us-phoenix-1"

cleanup_chicago_oke_cluster() {
    log_info "Searching for OKE clusters in $CHICAGO_REGION..."
    
    local clusters
    clusters=$(oci ce cluster list \
        --compartment-id "$OCI_COMPARTMENT_ID" \
        --region "$CHICAGO_REGION" \
        --lifecycle-state ACTIVE \
        --query 'data[*].{id:id,name:name}' \
        --output json 2>/dev/null || echo "[]")
    
    local cluster_count
    cluster_count=$(echo "$clusters" | jq '. | length')
    
    if [[ "$cluster_count" -eq 0 ]]; then
        log_info "No active OKE clusters found in $CHICAGO_REGION"
        return 0
    fi
    
    log_warn "Found $cluster_count OKE cluster(s) in $CHICAGO_REGION"
    echo "$clusters" | jq -r '.[] | "  - \(.name) (\(.id))"'
    echo ""
    
    # Delete each cluster
    echo "$clusters" | jq -r '.[] | "\(.id)|\(.name)"' | while IFS='|' read -r cluster_id cluster_name; do
        log_info "Deleting cluster: $cluster_name"
        
        # Delete node pools first
        log_info "  Listing node pools..."
        local node_pools
        node_pools=$(oci ce node-pool list \
            --cluster-id "$cluster_id" \
            --region "$CHICAGO_REGION" \
            --query 'data[*].id' \
            --output json 2>/dev/null || echo "[]")
        
        echo "$node_pools" | jq -r '.[]' | while read -r pool_id; do
            if [[ -n "$pool_id" ]]; then
                log_info "  Deleting node pool: $pool_id"
                oci ce node-pool delete \
                    --node-pool-id "$pool_id" \
                    --region "$CHICAGO_REGION" \
                    --force \
                    2>/dev/null || log_warn "    Failed to delete node pool (may already be deleted)"
            fi
        done
        
        # Wait a bit for node pools to start deleting
        sleep 5
        
        # Delete cluster
        log_info "  Deleting OKE cluster: $cluster_id"
        oci ce cluster delete \
            --cluster-id "$cluster_id" \
            --region "$CHICAGO_REGION" \
            --force \
            2>/dev/null || log_warn "    Failed to delete cluster (may already be deleted)"
        
        log_success "  Cluster deletion initiated: $cluster_name"
    done
    
    log_info "Cluster deletion is asynchronous - resources will be removed in background"
    return 0
}

cleanup_kubectl_contexts() {
    log_info "Cleaning up kubectl contexts for Chicago clusters..."
    
    local contexts
    contexts=$(kubectl config get-contexts -o name 2>/dev/null | grep -i chicago || echo "")
    
    if [[ -z "$contexts" ]]; then
        log_info "No Chicago-related kubectl contexts found"
        return 0
    fi
    
    echo "$contexts" | while read -r context; do
        if [[ -n "$context" ]]; then
            log_info "  Removing context: $context"
            kubectl config delete-context "$context" 2>/dev/null || true
        fi
    done
    
    log_success "kubectl contexts cleaned up"
    return 0
}

update_oci_cli_region() {
    log_info "Updating OCI CLI default region to $PHOENIX_REGION..."
    
    # Update OCI config file
    if [[ -f ~/.oci/config ]]; then
        # Check if region line exists
        if grep -q "^region=" ~/.oci/config; then
            # Update existing region
            sed -i.bak "s/^region=.*/region=$PHOENIX_REGION/" ~/.oci/config
            log_success "Updated OCI CLI region to $PHOENIX_REGION"
        else
            # Add region line after first profile
            sed -i.bak "/^\[DEFAULT\]/a\\
region=$PHOENIX_REGION" ~/.oci/config
            log_success "Added OCI CLI region: $PHOENIX_REGION"
        fi
    else
        log_warn "OCI config file not found at ~/.oci/config"
    fi
}

verify_phoenix_ready() {
    log_info "Verifying Phoenix region readiness..."
    
    # Test Phoenix region access
    if oci iam region list --region "$PHOENIX_REGION" &>/dev/null; then
        log_success "Phoenix region ($PHOENIX_REGION) is accessible"
    else
        log_error "Cannot access Phoenix region - check OCI configuration"
        return 1
    fi
    
    # Check if Phoenix is subscribed
    local subscribed
    subscribed=$(oci iam region-subscription list \
        --query "data[?\"region-name\"=='$PHOENIX_REGION'].status | [0]" \
        --raw-output 2>/dev/null || echo "")
    
    if [[ "$subscribed" == "READY" ]]; then
        log_success "Phoenix region subscription is active"
    else
        log_warn "Phoenix region may not be subscribed or ready"
    fi
    
    return 0
}

main() {
    echo ""
    echo "==============================================================="
    echo "CHICAGO CLUSTER CLEANUP & PHOENIX MIGRATION"
    echo "==============================================================="
    echo ""
    
    log_warn "This will DELETE all OKE resources in us-chicago-1"
    log_warn "And prepare for fresh deployment in us-phoenix-1"
    echo ""
    
    if [[ -z "${OCI_COMPARTMENT_ID:-}" ]]; then
        log_error "OCI_COMPARTMENT_ID not set"
        log_info "Run: source setup-env.sh"
        exit 1
    fi
    
    log_info "Compartment: ${OCI_COMPARTMENT_ID:0:40}..."
    log_info "Chicago Region: $CHICAGO_REGION"
    log_info "Phoenix Region: $PHOENIX_REGION"
    echo ""
    
    # Cleanup Chicago resources
    cleanup_chicago_oke_cluster
    echo ""
    
    # Cleanup kubectl contexts
    cleanup_kubectl_contexts
    echo ""
    
    # Update OCI CLI region
    update_oci_cli_region
    echo ""
    
    # Verify Phoenix is ready
    verify_phoenix_ready
    echo ""
    
    echo "==============================================================="
    log_success "✅ CLEANUP COMPLETE"
    echo "==============================================================="
    echo ""
    echo "Next Steps:"
    echo "  1. Update environment variable:"
    echo "     export OCI_REGION=us-phoenix-1"
    echo ""
    echo "  2. Or reload environment:"
    echo "     source setup-env.sh"
    echo ""
    echo "  3. Verify setup:"
    echo "     make validate"
    echo ""
    echo "  4. Deploy fresh in Phoenix:"
    echo "     make provision CONFIRM_COST=yes"
    echo ""
    echo "Note: Chicago cluster deletion is asynchronous"
    echo "      Resources will be removed in the background"
    echo ""
}

main "$@"

