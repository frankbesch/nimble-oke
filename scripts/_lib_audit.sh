#!/usr/bin/env bash

set -euo pipefail

readonly DAILY_BUDGET_USD="${DAILY_BUDGET_USD:-50}"
readonly BUDGET_WARN_80=$(echo "$DAILY_BUDGET_USD * 0.80" | bc -l)
readonly BUDGET_WARN_90=$(echo "$DAILY_BUDGET_USD * 0.90" | bc -l)
readonly BUDGET_WARN_100=$(echo "$DAILY_BUDGET_USD * 1.00" | bc -l)
readonly BUDGET_WARN_110=$(echo "$DAILY_BUDGET_USD * 1.10" | bc -l)
readonly BUDGET_WARN_120=$(echo "$DAILY_BUDGET_USD * 1.20" | bc -l)
readonly BUDGET_HARD_FAIL=$(echo "$DAILY_BUDGET_USD * 1.25" | bc -l)
readonly POLICY_CACHE_DIR="${HOME}/.nimble-oke"
readonly POLICY_CACHE_FILE="${POLICY_CACHE_DIR}/policy-cache.json"
readonly POLICY_CACHE_TTL=3600

get_tenancy_name() {
    oci iam tenancy get \
        --tenancy-id "$(oci iam region-subscription list --query 'data[0]."tenancy-id"' --raw-output 2>/dev/null)" \
        --query 'data.name' \
        --raw-output 2>/dev/null || echo "unknown"
}

get_tenancy_ocid() {
    oci iam region-subscription list \
        --query 'data[0]."tenancy-id"' \
        --raw-output 2>/dev/null || echo "unknown"
}

get_subscription_type() {
    local tenancy_ocid
    tenancy_ocid=$(get_tenancy_ocid)
    
    if [[ "$tenancy_ocid" == "unknown" ]]; then
        echo "unknown"
        return
    fi
    
    local tenancy_info
    tenancy_info=$(oci iam tenancy get --tenancy-id "$tenancy_ocid" 2>/dev/null || echo "")
    
    if echo "$tenancy_info" | jq -e '.data."freeform-tags"."OracleFreeHomeTier"' &>/dev/null; then
        echo "Free Tier"
    elif echo "$tenancy_info" | jq -e '.data' | grep -qi "universal"; then
        echo "Universal Credits"
    else
        echo "Pay-As-You-Go"
    fi
}

get_active_regions() {
    oci iam region-subscription list \
        --query 'data[].{name:"region-name",status:status}' \
        --output json 2>/dev/null | \
        jq -r '.[] | select(.status=="READY") | .name' || echo ""
}

check_cli_authentication() {
    if oci iam region-subscription list &>/dev/null; then
        return 0
    else
        return 1
    fi
}

get_user_ocid() {
    oci iam user list --query 'data[0].id' --raw-output 2>/dev/null || \
    grep "^user=" ~/.oci/config 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' ' || \
    echo "unknown"
}

get_user_name() {
    local user_ocid
    user_ocid=$(get_user_ocid)
    
    if [[ "$user_ocid" == "unknown" ]] || [[ -z "$user_ocid" ]]; then
        echo "unknown"
        return
    fi
    
    oci iam user get --user-id "$user_ocid" \
        --query 'data.name' \
        --raw-output 2>/dev/null || echo "unknown"
}

get_user_groups() {
    local user_ocid
    user_ocid=$(get_user_ocid)
    
    if [[ "$user_ocid" == "unknown" ]] || [[ -z "$user_ocid" ]]; then
        echo ""
        return
    fi
    
    oci iam group list --user-id "$user_ocid" \
        --query 'data[].name' \
        --raw-output 2>/dev/null | tr '\t' ',' || echo ""
}

list_accessible_compartments() {
    oci iam compartment list \
        --compartment-id-in-subtree true \
        --all \
        --query 'data[?!"lifecycle-state"==`DELETED`].{name:name,id:id}' \
        --output json 2>/dev/null | \
        jq -r '.[] | "\(.name)|\(.id)"' || echo ""
}

get_compartment_count() {
    list_accessible_compartments | wc -l | tr -d ' '
}

list_policies_in_compartment() {
    local compartment_id="$1"
    
    oci iam policy list \
        --compartment-id "$compartment_id" \
        --all \
        --query 'data[].{name:name,statements:statements}' \
        --output json 2>/dev/null || echo "[]"
}

parse_policy_for_permissions() {
    local policy_json="$1"
    local resource_type="$2"
    
    echo "$policy_json" | jq -r \
        --arg resource "$resource_type" \
        '.[] | .statements[] | select(. | test($resource; "i"))' 2>/dev/null || echo ""
}

check_oke_permissions() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if [[ -z "$compartment_id" ]]; then
        return 1
    fi
    
    local policies
    policies=$(list_policies_in_compartment "$compartment_id")
    
    local cluster_perms
    cluster_perms=$(parse_policy_for_permissions "$policies" "cluster-family")
    
    if [[ -n "$cluster_perms" ]]; then
        return 0
    else
        return 1
    fi
}

check_compute_permissions() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if [[ -z "$compartment_id" ]]; then
        return 1
    fi
    
    local policies
    policies=$(list_policies_in_compartment "$compartment_id")
    
    local compute_perms
    compute_perms=$(parse_policy_for_permissions "$policies" "instance-family")
    
    if [[ -n "$compute_perms" ]]; then
        return 0
    else
        return 1
    fi
}

check_network_permissions() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if [[ -z "$compartment_id" ]]; then
        return 1
    fi
    
    local policies
    policies=$(list_policies_in_compartment "$compartment_id")
    
    local network_perms
    network_perms=$(parse_policy_for_permissions "$policies" "virtual-network-family")
    
    if [[ -n "$network_perms" ]]; then
        return 0
    else
        return 1
    fi
}

list_vcns_in_compartment() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if [[ -z "$compartment_id" ]]; then
        echo ""
        return
    fi
    
    oci network vcn list \
        --compartment-id "$compartment_id" \
        --all \
        --query 'data[?!"lifecycle-state"==`TERMINATED`].{name:"display-name",id:id,cidr:"cidr-block"}' \
        --output json 2>/dev/null | \
        jq -r '.[] | "\(.name)|\(.id)|\(.cidr)"' || echo ""
}

check_internet_gateway_exists() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    local vcn_id="$1"
    
    if [[ -z "$compartment_id" ]] || [[ -z "$vcn_id" ]]; then
        return 1
    fi
    
    local igw_count
    igw_count=$(oci network internet-gateway list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --query 'data | length(@)' \
        --raw-output 2>/dev/null || echo "0")
    
    [[ "$igw_count" != "0" ]]
}

check_service_gateway_exists() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    local vcn_id="$1"
    
    if [[ -z "$compartment_id" ]] || [[ -z "$vcn_id" ]]; then
        return 1
    fi
    
    local sgw_count
    sgw_count=$(oci network service-gateway list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --query 'data | length(@)' \
        --raw-output 2>/dev/null || echo "0")
    
    [[ "$sgw_count" != "0" ]]
}

get_ocir_namespace() {
    local tenancy_name
    tenancy_name=$(get_tenancy_name)
    echo "${tenancy_name,,}"
}

check_ocir_access() {
    local region="${OCI_REGION:-us-phoenix-1}"
    local namespace
    namespace=$(get_ocir_namespace)
    local endpoint="${region}.ocir.io"
    
    if command -v docker &>/dev/null; then
        if docker info &>/dev/null; then
            if docker login -u "placeholder" -p "test" "${endpoint}/${namespace}" &>/dev/null; then
                return 0
            fi
        fi
    fi
    
    return 1
}

list_gpu_shapes_in_region() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    local region="${OCI_REGION:-us-phoenix-1}"
    
    if [[ -z "$compartment_id" ]]; then
        echo ""
        return
    fi
    
    oci compute shape list \
        --compartment-id "$compartment_id" \
        --all \
        --query 'data[?contains("shape", `GPU`) == `true`].shape' \
        --raw-output 2>/dev/null | tr '\t' '\n' || echo ""
}

check_gpu_shape_capacity() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    local shape="${1:-VM.GPU.A10.1}"
    local ad="$2"
    
    if [[ -z "$compartment_id" ]] || [[ -z "$ad" ]]; then
        return 1
    fi
    
    oci limits resource-availability get \
        --compartment-id "$compartment_id" \
        --service-name compute \
        --limit-name "gpu-a10-count" \
        --availability-domain "$ad" \
        --query 'data.available' \
        --raw-output 2>/dev/null | grep -q "^[1-9]"
}

get_gpu_service_limit() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    local shape="${1:-VM.GPU.A10.1}"
    
    if [[ -z "$compartment_id" ]]; then
        echo "0"
        return
    fi
    
    local limit_name
    case "$shape" in
        VM.GPU.A10.*|BM.GPU.A10.*)
            limit_name="gpu-a10-count"
            ;;
        VM.GPU3.*|BM.GPU3.*)
            limit_name="gpu3-count"
            ;;
        *H100*)
            limit_name="gpu-h100-count"
            ;;
        *)
            limit_name="gpu-count"
            ;;
    esac
    
    oci limits value list \
        --compartment-id "$compartment_id" \
        --service-name compute \
        --all \
        --query "data[?name=='$limit_name'].value | [0]" \
        --raw-output 2>/dev/null || echo "0"
}

get_kubernetes_versions_available() {
    oci ce cluster-options get \
        --cluster-option-id all \
        --query 'data."kubernetes-versions"[]' \
        --raw-output 2>/dev/null | tr '\t' '\n' || echo ""
}

check_kubernetes_version_compatible() {
    local version="$1"
    local min_version="v1.28"
    
    if [[ "$version" > "$min_version" ]] || [[ "$version" == "$min_version"* ]]; then
        return 0
    else
        return 1
    fi
}

estimate_daily_cost() {
    local gpu_count="${1:-1}"
    local hourly
    hourly=$(estimate_hourly_cost "$gpu_count")
    echo "$hourly * 24" | bc -l
}

check_daily_budget_with_warnings() {
    local daily_cost="$1"
    local budget_status="ok"
    
    local percent
    percent=$(echo "scale=1; ($daily_cost / $DAILY_BUDGET_USD) * 100" | bc -l)
    
    if (( $(echo "$daily_cost >= $BUDGET_HARD_FAIL" | bc -l) )); then
        log_error "BUDGET EXCEEDED: Daily cost \$$(format_cost "$daily_cost") is 125%+ of budget (\$$DAILY_BUDGET_USD)"
        log_error "This exceeds the hard fail threshold of \$$(format_cost "$BUDGET_HARD_FAIL")"
        log_info "Increase budget: export DAILY_BUDGET_USD=$(echo "$daily_cost + 10" | bc | cut -d. -f1)"
        return 1
    elif (( $(echo "$daily_cost >= $BUDGET_WARN_120" | bc -l) )); then
        log_warn "⚠️  BUDGET ALERT (120%): Daily cost \$$(format_cost "$daily_cost") is at $(format_cost "$percent")% of \$$DAILY_BUDGET_USD budget"
        log_warn "Approaching hard fail at 125% (\$$(format_cost "$BUDGET_HARD_FAIL"))"
        log_warn "Consider reducing resources or increasing budget"
        budget_status="critical"
    elif (( $(echo "$daily_cost >= $BUDGET_WARN_110" | bc -l) )); then
        log_warn "⚠️  BUDGET ALERT (110%): Daily cost \$$(format_cost "$daily_cost") is at $(format_cost "$percent")% of \$$DAILY_BUDGET_USD budget"
        log_warn "Hard fail occurs at 125% (\$$(format_cost "$BUDGET_HARD_FAIL"))"
        budget_status="high"
    elif (( $(echo "$daily_cost >= $BUDGET_WARN_100" | bc -l) )); then
        log_warn "⚠️  BUDGET ALERT (100%): Daily cost \$$(format_cost "$daily_cost") equals \$$DAILY_BUDGET_USD budget"
        log_warn "Hard fail occurs at 125% (\$$(format_cost "$BUDGET_HARD_FAIL"))"
        budget_status="at-limit"
    elif (( $(echo "$daily_cost >= $BUDGET_WARN_90" | bc -l) )); then
        log_warn "⚠️  BUDGET ALERT (90%): Daily cost \$$(format_cost "$daily_cost") is at $(format_cost "$percent")% of \$$DAILY_BUDGET_USD budget"
        budget_status="warning"
    elif (( $(echo "$daily_cost >= $BUDGET_WARN_80" | bc -l) )); then
        log_warn "⚠️  BUDGET ALERT (80%): Daily cost \$$(format_cost "$daily_cost") is at $(format_cost "$percent")% of \$$DAILY_BUDGET_USD budget"
        budget_status="caution"
    else
        log_success "Budget OK: Daily cost \$$(format_cost "$daily_cost") is within \$$DAILY_BUDGET_USD budget ($(format_cost "$percent")%)"
        budget_status="ok"
    fi
    
    echo "$budget_status"
    return 0
}

check_daily_budget() {
    local gpu_count="${1:-1}"
    local daily_cost
    daily_cost=$(estimate_daily_cost "$gpu_count")
    
    local status
    status=$(check_daily_budget_with_warnings "$daily_cost")
    
    [[ "$status" != "critical" ]]
}

get_current_tenancy_burn_rate() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if [[ -z "$compartment_id" ]]; then
        echo "0"
        return
    fi
    
    local compute_instances
    compute_instances=$(oci compute instance list \
        --compartment-id "$compartment_id" \
        --all \
        --lifecycle-state RUNNING \
        --query 'data | length(@)' \
        --raw-output 2>/dev/null || echo "0")
    
    local oke_clusters
    oke_clusters=$(oci ce cluster list \
        --compartment-id "$compartment_id" \
        --lifecycle-state ACTIVE \
        --query 'data | length(@)' \
        --raw-output 2>/dev/null || echo "0")
    
    local estimated_cost
    estimated_cost=$(echo "($compute_instances * 0.5) + ($oke_clusters * 0.1)" | bc -l)
    echo "$estimated_cost"
}

list_availability_domains() {
    oci iam availability-domain list \
        --query 'data[].name' \
        --raw-output 2>/dev/null | tr '\t' '\n' || echo ""
}

check_budget_alerts_configured() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if [[ -z "$compartment_id" ]]; then
        return 1
    fi
    
    local budget_count
    budget_count=$(oci budgets budget list \
        --compartment-id "$compartment_id" \
        --target-type COMPARTMENT \
        --query 'data | length(@)' \
        --raw-output 2>/dev/null || echo "0")
    
    [[ "$budget_count" != "0" ]]
}

get_oke_cluster_quota() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if [[ -z "$compartment_id" ]]; then
        echo "0"
        return
    fi
    
    oci limits value list \
        --compartment-id "$compartment_id" \
        --service-name container-engine \
        --query 'data[?name==`cluster-count`].value | [0]' \
        --raw-output 2>/dev/null || echo "0"
}

check_vcn_has_internet_access() {
    local vcn_id="$1"
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if ! check_internet_gateway_exists "$compartment_id" "$vcn_id"; then
        return 1
    fi
    
    local route_tables
    route_tables=$(oci network route-table list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --query 'data[].{id:id,rules:"route-rules"}' \
        --output json 2>/dev/null)
    
    if echo "$route_tables" | jq -e '.[] | .rules[] | select(.destination=="0.0.0.0/0")' &>/dev/null; then
        return 0
    else
        return 1
    fi
}

ensure_cache_dir() {
    if [[ ! -d "$POLICY_CACHE_DIR" ]]; then
        mkdir -p "$POLICY_CACHE_DIR"
    fi
}

is_cache_valid() {
    if [[ ! -f "$POLICY_CACHE_FILE" ]]; then
        return 1
    fi
    
    local cache_age
    cache_age=$(( $(date +%s) - $(stat -f %m "$POLICY_CACHE_FILE" 2>/dev/null || stat -c %Y "$POLICY_CACHE_FILE" 2>/dev/null || echo "0") ))
    
    if [[ $cache_age -lt $POLICY_CACHE_TTL ]]; then
        return 0
    else
        return 1
    fi
}

parse_all_policies() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    local use_cache="${USE_POLICY_CACHE:-yes}"
    
    if [[ -z "$compartment_id" ]]; then
        echo "[]"
        return
    fi
    
    ensure_cache_dir
    
    if [[ "$use_cache" == "yes" ]] && is_cache_valid; then
        cat "$POLICY_CACHE_FILE"
        return
    fi
    
    local tenancy_ocid
    tenancy_ocid=$(get_tenancy_ocid)
    
    local tenancy_policies
    tenancy_policies=$(oci iam policy list \
        --compartment-id "$tenancy_ocid" \
        --all \
        --query 'data[]' \
        --output json 2>/dev/null || echo "[]")
    
    local compartment_policies
    compartment_policies=$(oci iam policy list \
        --compartment-id "$compartment_id" \
        --all \
        --query 'data[]' \
        --output json 2>/dev/null || echo "[]")
    
    local combined
    combined=$(echo "$tenancy_policies $compartment_policies" | jq -s 'add')
    
    echo "$combined" > "$POLICY_CACHE_FILE"
    echo "$combined"
}

clear_policy_cache() {
    rm -f "$POLICY_CACHE_FILE"
    log_info "Policy cache cleared"
}

check_permission_in_policies() {
    local policies="$1"
    local resource_family="$2"
    local verb="${3:-use}"
    
    local matching_statements
    matching_statements=$(echo "$policies" | jq -r \
        --arg resource "$resource_family" \
        --arg verb "$verb" \
        '.[].statements[] | select(. | test("\\b" + $verb + "\\b.*\\b" + $resource + "\\b"; "i"))' 2>/dev/null)
    
    if [[ -n "$matching_statements" ]]; then
        return 0
    else
        return 1
    fi
}

check_dynamic_groups() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if [[ -z "$compartment_id" ]]; then
        return 1
    fi
    
    local tenancy_ocid
    tenancy_ocid=$(get_tenancy_ocid)
    
    local dg_count
    dg_count=$(oci iam dynamic-group list \
        --compartment-id "$tenancy_ocid" \
        --query 'data | length(@)' \
        --raw-output 2>/dev/null || echo "0")
    
    [[ "$dg_count" != "0" ]]
}

get_nvidia_compatible_images() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    
    if [[ -z "$compartment_id" ]]; then
        echo ""
        return
    fi
    
    oci compute image list \
        --compartment-id "$compartment_id" \
        --all \
        --query 'data[?contains("display-name", `GPU`) || contains("display-name", `CUDA`)].{"display-name":"display-name",id:id}' \
        --output json 2>/dev/null | \
        jq -r '.[] | "\(."display-name")|\(.id)"' || echo ""
}

get_latest_gpu_image() {
    local compartment_id="${OCI_COMPARTMENT_ID:-}"
    local shape="${1:-VM.GPU.A10.1}"
    
    if [[ -z "$compartment_id" ]]; then
        echo ""
        return
    fi
    
    oci compute image list \
        --compartment-id "$compartment_id" \
        --operating-system "Oracle Linux" \
        --operating-system-version "8" \
        --shape "$shape" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --limit 1 \
        --query 'data[0].id' \
        --raw-output 2>/dev/null || echo ""
}

export -f get_tenancy_name get_tenancy_ocid get_subscription_type
export -f get_active_regions check_cli_authentication
export -f get_user_ocid get_user_name get_user_groups
export -f list_accessible_compartments get_compartment_count
export -f list_policies_in_compartment parse_policy_for_permissions
export -f check_permission_in_policies
export -f check_oke_permissions check_compute_permissions check_network_permissions
export -f check_internet_gateway_exists check_service_gateway_exists
export -f get_ocir_namespace check_ocir_access
export -f list_gpu_shapes_in_region check_gpu_shape_capacity get_gpu_service_limit
export -f get_kubernetes_versions_available check_kubernetes_version_compatible
export -f estimate_daily_cost check_daily_budget
export -f get_current_tenancy_burn_rate
export -f list_availability_domains
export -f check_budget_alerts_configured get_oke_cluster_quota
export -f check_vcn_has_internet_access
export -f parse_all_policies check_dynamic_groups
export -f get_nvidia_compatible_images get_latest_gpu_image
export -f check_daily_budget_with_warnings
export -f ensure_cache_dir is_cache_valid clear_policy_cache

