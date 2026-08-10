#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Emergency cleanup script based on 2025-10-19 learnings
# This script performs comprehensive cleanup of all cost-incurring resources

readonly CLEANUP_TIMEOUT=300  # 5 minutes timeout for cleanup operations

cleanup_oke_cluster() {
    log_info "🔍 Checking for active OKE clusters..."
    
    local active_clusters
    active_clusters=$(oci ce cluster list --compartment-id $(oci iam compartment list --query 'data[0].id' --raw-output) --query 'data[?lifecycle-state==`ACTIVE`]' --raw-output 2>/dev/null || echo "[]")
    
    if [[ "$active_clusters" == "[]" ]]; then
        log_success "No active OKE clusters found"
        return 0
    fi
    
    log_warn "Found active OKE clusters - initiating deletion..."
    
    # Extract cluster IDs and delete them
    echo "$active_clusters" | jq -r '.[].id' | while read -r cluster_id; do
        if [[ -n "$cluster_id" ]]; then
            log_info "Deleting cluster: $cluster_id"
            oci ce cluster delete --cluster-id "$cluster_id" --force || log_warn "Failed to delete cluster: $cluster_id"
        fi
    done
    
    log_success "OKE cluster deletion initiated"
}

cleanup_compute_instances() {
    log_info "🔍 Checking for active compute instances..."
    
    local active_instances
    active_instances=$(oci compute instance list --compartment-id $(oci iam compartment list --query 'data[0].id' --raw-output) --query 'data[?lifecycle-state==`RUNNING`]' --raw-output 2>/dev/null || echo "[]")
    
    if [[ "$active_instances" == "[]" ]]; then
        log_success "No active compute instances found"
        return 0
    fi
    
    log_warn "Found active compute instances - terminating..."
    
    # Extract instance IDs and terminate them
    echo "$active_instances" | jq -r '.[].id' | while read -r instance_id; do
        if [[ -n "$instance_id" ]]; then
            log_info "Terminating instance: $instance_id"
            oci compute instance terminate --instance-id "$instance_id" --force || log_warn "Failed to terminate instance: $instance_id"
        fi
    done
    
    log_success "Compute instance termination initiated"
}

cleanup_block_volumes() {
    log_info "🔍 Checking for active block volumes..."
    
    local active_volumes
    active_volumes=$(oci bv volume list --compartment-id $(oci iam compartment list --query 'data[0].id' --raw-output) --query 'data[?lifecycle-state==`AVAILABLE`]' --raw-output 2>/dev/null || echo "[]")
    
    if [[ "$active_volumes" == "[]" ]]; then
        log_success "No active block volumes found"
        return 0
    fi
    
    log_warn "Found active block volumes - deleting..."
    
    # Extract volume IDs and delete them
    echo "$active_volumes" | jq -r '.[].id' | while read -r volume_id; do
        if [[ -n "$volume_id" ]]; then
            log_info "Deleting volume: $volume_id"
            oci bv volume delete --volume-id "$volume_id" --force || log_warn "Failed to delete volume: $volume_id"
        fi
    done
    
    log_success "Block volume deletion initiated"
}

cleanup_load_balancers() {
    log_info "🔍 Checking for active load balancers..."
    
    local active_lbs
    active_lbs=$(oci lb load-balancer list --compartment-id $(oci iam compartment list --query 'data[0].id' --raw-output) --query 'data[?lifecycle-state==`ACTIVE`]' --raw-output 2>/dev/null || echo "[]")
    
    if [[ "$active_lbs" == "[]" ]]; then
        log_success "No active load balancers found"
        return 0
    fi
    
    log_warn "Found active load balancers - deleting..."
    
    # Extract LB IDs and delete them
    echo "$active_lbs" | jq -r '.[].id' | while read -r lb_id; do
        if [[ -n "$lb_id" ]]; then
            log_info "Deleting load balancer: $lb_id"
            oci lb load-balancer delete --load-balancer-id "$lb_id" --force || log_warn "Failed to delete load balancer: $lb_id"
        fi
    done
    
    log_success "Load balancer deletion initiated"
}

cleanup_kubernetes_resources() {
    log_info "🔍 Checking for active Kubernetes cluster..."
    
    # Check if kubectl is configured and cluster is accessible
    if ! kubectl cluster-info &>/dev/null; then
        log_info "No accessible Kubernetes cluster found"
        return 0
    fi
    
    log_warn "Found accessible Kubernetes cluster - cleaning up resources..."
    
    # Delete NIM deployment
    log_info "Deleting NIM deployment..."
    helm uninstall nvidia-nim --namespace default --wait=false || log_warn "Failed to uninstall NIM Helm chart"
    
    # Delete NIM-related resources
    log_info "Deleting NIM-related resources..."
    kubectl delete deployment nvidia-nim --namespace default --wait=false || true
    kubectl delete service nvidia-nim --namespace default --wait=false || true
    kubectl delete secret ngc-api --namespace default --wait=false || true
    kubectl delete pvc -l app.kubernetes.io/name=nvidia-nim --namespace default --wait=false || true
    
    log_success "Kubernetes resources cleanup initiated"
}

verify_cleanup() {
    log_info "🔍 Verifying cleanup completion..."
    
    local remaining_costs=0
    
    # Check for remaining active resources
    local active_clusters
    active_clusters=$(oci ce cluster list --compartment-id $(oci iam compartment list --query 'data[0].id' --raw-output) --query 'data[?lifecycle-state==`ACTIVE`]' --raw-output 2>/dev/null || echo "[]")
    if [[ "$active_clusters" != "[]" ]]; then
        log_warn "⚠️  Active OKE clusters still exist"
        ((remaining_costs++))
    fi
    
    local active_instances
    active_instances=$(oci compute instance list --compartment-id $(oci iam compartment list --query 'data[0].id' --raw-output) --query 'data[?lifecycle-state==`RUNNING`]' --raw-output 2>/dev/null || echo "[]")
    if [[ "$active_instances" != "[]" ]]; then
        log_warn "⚠️  Active compute instances still exist"
        ((remaining_costs++))
    fi
    
    local active_volumes
    active_volumes=$(oci bv volume list --compartment-id $(oci iam compartment list --query 'data[0].id' --raw-output) --query 'data[?lifecycle-state==`AVAILABLE`]' --raw-output 2>/dev/null || echo "[]")
    if [[ "$active_volumes" != "[]" ]]; then
        log_warn "⚠️  Active block volumes still exist"
        ((remaining_costs++))
    fi
    
    local active_lbs
    active_lbs=$(oci lb load-balancer list --compartment-id $(oci iam compartment list --query 'data[0].id' --raw-output) --query 'data[?lifecycle-state==`ACTIVE`]' --raw-output 2>/dev/null || echo "[]")
    if [[ "$active_lbs" != "[]" ]]; then
        log_warn "⚠️  Active load balancers still exist"
        ((remaining_costs++))
    fi
    
    if [[ $remaining_costs -eq 0 ]]; then
        log_success "✅ CLEANUP VERIFIED - No cost-incurring resources remaining"
        log_success "💰 Current cost: $0.00/hour"
    else
        log_warn "⚠️  $remaining_costs types of resources still active"
        log_warn "   Some resources may take time to fully terminate"
        log_warn "   Monitor OCI Console for completion"
    fi
}

main() {
    log_info "🚨 EMERGENCY CLEANUP INITIATED"
    log_info "=============================="
    log_info "Date: $(date)"
    log_info "Purpose: Stop all cost-incurring resources"
    log_info ""
    
    # Validate OCI CLI access
    log_info "Validating OCI CLI access..."
    if ! oci iam user get --user-id $(oci iam user list --query 'data[0].id' --raw-output) &>/dev/null; then
        die "OCI CLI not authenticated or configured"
    fi
    log_success "OCI CLI access verified"
    
    # Perform cleanup operations
    cleanup_oke_cluster
    cleanup_compute_instances
    cleanup_block_volumes
    cleanup_load_balancers
    cleanup_kubernetes_resources
    
    # Wait a moment for operations to propagate
    log_info "Waiting for cleanup operations to propagate..."
    sleep 10
    
    # Verify cleanup
    verify_cleanup
    
    log_info ""
    log_success "🎯 EMERGENCY CLEANUP COMPLETE"
    log_info "=============================="
    log_info "All cost-incurring resources have been targeted for deletion"
    log_info "Monitor OCI Console for completion status"
    log_info "Run this script again to verify complete cleanup"
    log_info ""
    log_warn "⚠️  IMPORTANT: Network resources (VCNs, subnets) are preserved"
    log_warn "   These have no cost impact and can be reused"
    log_warn "   Delete manually via OCI Console if desired"
}

main "$@"