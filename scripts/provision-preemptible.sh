#!/bin/bash

# Preemptible Instance Integration for NVIDIA NIM on OKE
# Provides cost optimization through OCI preemptible instances with fallback

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

# Configuration
USE_PREEMPTIBLE="${USE_PREEMPTIBLE:-yes}"
PREEMPTIBLE_TIMEOUT="${PREEMPTIBLE_TIMEOUT:-300}"  # 5 minutes timeout for preemptible
FALLBACK_ENABLED="${FALLBACK_ENABLED:-yes}"
COST_SAVINGS_THRESHOLD="${COST_SAVINGS_THRESHOLD:-30}"  # 30% savings minimum

log_info "Preemptible Instance Integration initialized"
log_info "Preemptible instances: $USE_PREEMPTIBLE"
log_info "Fallback enabled: $FALLBACK_ENABLED"

# Function to check preemptible instance availability
check_preemptible_availability() {
    log_info "Checking preemptible instance availability..."
    
    local shape="${1:-VM.GPU.A10.1}"
    local region="${2:-${OCI_REGION:-us-phoenix-1}}"
    
    # Check preemptible capacity in the region
    local availability_response
    availability_response=$(oci compute capacity-report get \
        --compartment-id "${OCI_COMPARTMENT_ID}" \
        --shape-name "$shape" \
        --availability-domain "$(oci iam availability-domain list --query 'data[0].name' --raw-output)" \
        --query 'data."preemptible-capacity"' \
        --raw-output 2>/dev/null || echo "0")
    
    if [[ "$availability_response" -gt 0 ]]; then
        log_success "Preemptible instances available: $availability_response capacity"
        return 0
    else
        log_warn "No preemptible capacity available"
        return 1
    fi
}

# Function to provision preemptible GPU nodes
provision_preemptible_gpu_nodes() {
    local node_count="${1:-1}"
    local shape="${2:-VM.GPU.A10.1}"
    local availability_domain="${3:-$(oci iam availability-domain list --query 'data[0].name' --raw-output)}"
    
    log_info "Provisioning preemptible GPU nodes..."
    log_info "Node count: $node_count"
    log_info "Shape: $shape"
    log_info "Availability domain: $availability_domain"
    
    # Create node pool with preemptible configuration
    local node_pool_name="nim-preemptible-gpu-pool"
    local subnet_id
    
    # Subnet: PREEMPTIBLE_SUBNET_ID, else the one subnet named
    # "nimble-oke-subnet" (the name provision-cluster.sh creates). Taking the
    # first subnet in the compartment could land nodes in an unrelated VCN.
    subnet_id="${PREEMPTIBLE_SUBNET_ID:-}"
    if [[ -z "$subnet_id" ]]; then
        local subnet_ids
        subnet_ids=$(oci network subnet list \
            --compartment-id "${OCI_COMPARTMENT_ID}" \
            --display-name "nimble-oke-subnet" \
            --lifecycle-state AVAILABLE \
            --query 'data[].id' \
            --raw-output) || { log_error "Subnet lookup failed (oci network subnet list)"; return 1; }
        local n
        n=$(echo "$subnet_ids" | grep -c 'ocid1\.subnet' || true)
        if [[ "$n" -ne 1 ]]; then
            log_error "Expected exactly one subnet named nimble-oke-subnet, found $n; set PREEMPTIBLE_SUBNET_ID"
            return 1
        fi
        subnet_id=$(echo "$subnet_ids" | grep -o 'ocid1\.subnet[^"[:space:],]*')
    fi
    
    # Create preemptible node pool
    local node_pool_config
    node_pool_config=$(cat <<EOF
{
    "compartmentId": "${OCI_COMPARTMENT_ID}",
    "clusterId": "${OKE_CLUSTER_ID}",
    "name": "$node_pool_name",
    "nodeShape": "$shape",
    "nodeShapeConfig": {
        "ocpus": 15,
        "memoryInGBs": 240
    },
    "nodeSourceDetails": {
        "sourceType": "IMAGE",
        "imageId": "$(get_gpu_node_image_id)"
    },
    "nodeConfigDetails": {
        "size": $node_count,
        "placementConfigs": [
            {
                "availabilityDomain": "$availability_domain",
                "subnetId": "$subnet_id"
            }
        ],
        "nsgIds": ["$(get_default_nsg_id)"]
    },
    "initialNodeLabels": [
        {
            "key": "nvidia.com/gpu.present",
            "value": "true"
        },
        {
            "key": "node-type",
            "value": "preemptible"
        }
    ],
    "preemptibleNodeConfig": {
        "preemptionAction": {
            "type": "TERMINATE",
            "isPreserveBootVolume": false
        }
    },
    "sshPublicKey": "$(get_ssh_public_key)"
}
EOF
)
    
    # Create the node pool
    log_info "Creating preemptible node pool..."
    local node_pool_response
    node_pool_response=$(oci container-engine node-pool create \
        --from-json "$node_pool_config" \
        --query 'data.id' \
        --raw-output)
    
    if [[ -z "$node_pool_response" || "$node_pool_response" == "null" ]]; then
        log_error "Failed to create preemptible node pool"
        return 1
    fi
    
    log_success "Preemptible node pool created: $node_pool_response"
    
    # Wait for nodes to be ready
    log_info "Waiting for preemptible nodes to be ready..."
    local wait_time=0
    local max_wait_time=600  # 10 minutes
    
    while [[ $wait_time -lt $max_wait_time ]]; do
        local ready_nodes
        ready_nodes=$(kubectl get nodes -l node-type=preemptible --no-headers | grep Ready | wc -l || echo "0")
        
        if [[ $ready_nodes -eq $node_count ]]; then
            log_success "All preemptible nodes are ready: $ready_nodes/$node_count"
            return 0
        fi
        
        log_info "Preemptible nodes ready: $ready_nodes/$node_count (waiting...)"
        sleep 30
        wait_time=$((wait_time + 30))
    done
    
    log_error "Timeout waiting for preemptible nodes to be ready"
    return 1
}

# Function to provision on-demand GPU nodes (fallback)
provision_ondemand_gpu_nodes() {
    local node_count="${1:-1}"
    local shape="${2:-VM.GPU.A10.1}"
    
    log_info "Provisioning on-demand GPU nodes (fallback)..."
    
    # Use existing provision-cluster.sh logic
    if [[ -f "${SCRIPT_DIR}/provision-cluster.sh" ]]; then
        log_info "Using existing cluster provisioning script"
        "${SCRIPT_DIR}/provision-cluster.sh" "$node_count" "$shape"
    else
        log_error "No cluster provisioning script found"
        return 1
    fi
}

# Function to monitor preemptible instance status
monitor_preemptible_status() {
    local node_pool_name="${1:-nim-preemptible-gpu-pool}"
    
    log_info "Monitoring preemptible instance status..."
    
    # Check for preemption events
    local preemption_events
    preemption_events=$(kubectl get events --field-selector type=Warning,reason=Preempted -o json | jq -r '.items[] | select(.involvedObject.kind=="Node") | .message' 2>/dev/null || echo "")
    
    if [[ -n "$preemption_events" ]]; then
        log_warn "Preemption events detected:"
        echo "$preemption_events"
        
        # Check if we need to handle preemption
        handle_preemption "$node_pool_name"
    else
        log_success "No preemption events detected"
    fi
    
    # Check node status
    local total_nodes
    local ready_nodes
    local preemptible_nodes
    
    total_nodes=$(kubectl get nodes --no-headers | wc -l)
    ready_nodes=$(kubectl get nodes --no-headers | grep Ready | wc -l)
    preemptible_nodes=$(kubectl get nodes -l node-type=preemptible --no-headers | wc -l)
    
    log_info "Node status:"
    log_info "  Total nodes: $total_nodes"
    log_info "  Ready nodes: $ready_nodes"
    log_info "  Preemptible nodes: $preemptible_nodes"
}

# Function to handle preemption events
handle_preemption() {
    local node_pool_name="$1"
    
    log_warn "Handling preemption event..."
    
    # Check if fallback is enabled
    if [[ "$FALLBACK_ENABLED" != "yes" ]]; then
        log_info "Fallback disabled - preemption will terminate deployment"
        return 1
    fi
    
    # Check if we have enough on-demand nodes
    local ondemand_nodes
    ondemand_nodes=$(kubectl get nodes -l node-type=ondemand --no-headers | wc -l)
    
    if [[ $ondemand_nodes -gt 0 ]]; then
        log_info "On-demand nodes available for fallback: $ondemand_nodes"
        return 0
    fi
    
    # Provision additional on-demand nodes
    log_info "Provisioning on-demand nodes for fallback..."
    provision_ondemand_gpu_nodes 1 VM.GPU.A10.1
    
    if [[ $? -eq 0 ]]; then
        log_success "Fallback on-demand nodes provisioned successfully"
    else
        log_error "Failed to provision fallback nodes"
        return 1
    fi
}

# Function to get GPU node image ID
get_gpu_node_image_id() {
    # Get the latest Oracle Linux 8 GPU image
    local image_id
    # data[0] is the NEWEST image: sorted by TIMECREATED DESC with limit 1.
    image_id=$(oci compute image list \
        --compartment-id "${OCI_COMPARTMENT_ID}" \
        --operating-system "Oracle Linux" \
        --operating-system-version "8" \
        --shape "${GPU_SHAPE:-VM.GPU.A10.1}" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --limit 1 \
        --query 'data[0].id' \
        --raw-output) || { log_error "Image lookup failed (oci compute image list)"; return 1; }
    
    if [[ -z "$image_id" || "$image_id" == "null" ]]; then
        log_error "No GPU-compatible image found"
        return 1
    fi
    
    echo "$image_id"
}

# Function to get default NSG ID
get_default_nsg_id() {
    # The first NSG in the compartment is an arbitrary pick; require it explicitly.
    local nsg_id="${PREEMPTIBLE_NSG_ID:-}"
    if [[ -z "$nsg_id" ]]; then
        log_error "PREEMPTIBLE_NSG_ID not set (export the NSG OCID for the GPU nodes)"
        return 1
    fi
    
    echo "$nsg_id"
}

# Function to get SSH public key
get_ssh_public_key() {
    local ssh_key_file="${HOME}/.ssh/id_rsa.pub"
    
    if [[ -f "$ssh_key_file" ]]; then
        cat "$ssh_key_file"
    else
        log_error "SSH public key not found at $ssh_key_file"
        return 1
    fi
}

# Function to calculate cost savings
calculate_cost_savings() {
    local node_count="${1:-1}"
    local hours="${2:-5}"
    local shape="${3:-${GPU_SHAPE:-$NIM_DEFAULT_GPU_SHAPE}}"
    # On-demand node rate from _lib.sh. The 50% preemptible discount is an
    # ESTIMATE (static assumption, not verified against Oracle pricing).
    local ondemand_cost preemptible_cost
    ondemand_cost=$(get_gpu_hourly_rate "$shape") || { log_error "No verified rate for $shape"; return 1; }
    preemptible_cost=$(echo "$ondemand_cost * 0.5" | bc -l)
    
    local preemptible_total
    preemptible_total=$(echo "$preemptible_cost * $node_count * $hours" | bc -l)
    local ondemand_total
    ondemand_total=$(echo "$ondemand_cost * $node_count * $hours" | bc -l)
    local savings
    savings=$(echo "$ondemand_total - $preemptible_total" | bc -l)
    local savings_percentage
    savings_percentage=$(echo "scale=1; ($savings / $ondemand_total) * 100" | bc -l)
    
    log_info "Cost comparison for $node_count x $shape over $hours hours (GPU nodes only):"
    log_info "  Preemptible cost: \$$(printf "%.2f" "$preemptible_total") - ESTIMATE (static assumption, not measured: 50% discount)"
    log_info "  On-demand cost: \$$(printf "%.2f" "$ondemand_total")"
    log_info "  Savings: \$$(printf "%.2f" "$savings") (${savings_percentage}%)"
    
    # Check if savings meet threshold
    if (( $(echo "$savings_percentage >= $COST_SAVINGS_THRESHOLD" | bc -l) )); then
        log_success "Cost savings meet threshold (${savings_percentage}% >= ${COST_SAVINGS_THRESHOLD}%)"
        return 0
    else
        log_warn "Cost savings below threshold (${savings_percentage}% < ${COST_SAVINGS_THRESHOLD}%)"
        return 1
    fi
}

# Function to set up preemption monitoring
setup_preemption_monitoring() {
    log_info "Setting up preemption monitoring..."
    
    # Private working directory (mktemp), not predictable /tmp paths
    local monitor_dir
    monitor_dir=$(mktemp -d "${TMPDIR:-/tmp}/nim-preemption-monitor.XXXXXX") || { log_error "mktemp failed"; return 1; }

    # Create monitoring script
    cat > "$monitor_dir/preemption-monitor.sh" << 'EOF'
#!/bin/bash

# Preemption monitoring script
while true; do
    # Check for preemption events
    kubectl get events --field-selector type=Warning,reason=Preempted -o json | jq -r '.items[] | select(.involvedObject.kind=="Node") | .message' 2>/dev/null | while read -r event; do
        if [[ -n "$event" ]]; then
            echo "[$(date)] Preemption event: $event"
            # Trigger fallback if needed
            if [[ "${FALLBACK_ENABLED:-yes}" == "yes" ]]; then
                echo "[$(date)] Triggering fallback..."
                # Add fallback logic here
            fi
        fi
    done
    
    sleep 30
done
EOF
    
    chmod 700 "$monitor_dir/preemption-monitor.sh"

    # Start monitoring in background
    nohup "$monitor_dir/preemption-monitor.sh" > "$monitor_dir/preemption-monitor.log" 2>&1 &
    local monitor_pid=$!

    echo "$monitor_pid" > "$monitor_dir/preemption-monitor.pid"
    log_success "Preemption monitoring started (PID: $monitor_pid)"
    log_info "  Log: $monitor_dir/preemption-monitor.log  Stop: kill $monitor_pid"
}

# Main preemptible provisioning function
provision_preemptible_cluster() {
    local node_count="${1:-1}"
    local shape="${2:-VM.GPU.A10.1}"
    local region="${3:-${OCI_REGION:-us-phoenix-1}}"
    
    log_info "Starting preemptible cluster provisioning..."
    
    # Calculate cost savings
    calculate_cost_savings "$node_count" 5 "$shape"

    # Check if preemptible instances should be used
    if [[ "$USE_PREEMPTIBLE" != "yes" ]]; then
        log_info "Preemptible instances disabled, using on-demand"
        provision_ondemand_gpu_nodes "$node_count" "$shape"
        return $?
    fi
    
    # Check preemptible availability
    if ! check_preemptible_availability "$shape" "$region"; then
        log_warn "Preemptible instances not available, falling back to on-demand"
        provision_ondemand_gpu_nodes "$node_count" "$shape"
        return $?
    fi
    
    # Provision preemptible nodes
    if provision_preemptible_gpu_nodes "$node_count" "$shape"; then
        log_success "Preemptible nodes provisioned successfully"
        
        # Set up monitoring
        setup_preemption_monitoring
        
        # Monitor initial status
        monitor_preemptible_status
        
        return 0
    else
        log_error "Failed to provision preemptible nodes"
        
        # Fallback to on-demand if enabled
        if [[ "$FALLBACK_ENABLED" == "yes" ]]; then
            log_info "Falling back to on-demand instances..."
            provision_ondemand_gpu_nodes "$node_count" "$shape"
            return $?
        else
            return 1
        fi
    fi
}

# Main execution. `monitor` (used by `make monitor-preemptible`) only reports
# status; before, it was passed on as the node count.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "${1:-}" == "monitor" ]]; then
        monitor_preemptible_status
    else
        provision_preemptible_cluster "$@"
    fi
fi
