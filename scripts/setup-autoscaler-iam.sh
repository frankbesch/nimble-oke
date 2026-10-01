#!/usr/bin/env bash
#
# Instance-principal IAM for the OKE Cluster Autoscaler add-on
# (Oracle: "Using instance principals to enable the Cluster Autoscaler add-on
# to access node pools"): one dynamic group with the rule
#   ALL {instance.compartment.id = '<compartment-ocid>'}
# and one policy with six statements for that dynamic group.
#
#   --print   (default) print the rule and the six statements; no change
#   --check   read-only; exit 0 only if both objects exist with that content,
#             else exit 3 and say what is missing
#   --apply   create the missing objects after a typed confirmation (the
#             compartment name); never modifies or deletes anything else
#   --delete  delete exactly those two objects after the same confirmation
#
# Where things live:
#   - the dynamic group is a tenancy-level IAM object (tenancy root);
#   - the policy is attached to the cluster's compartment ($OCI_COMPARTMENT_ID),
#     not the tenancy root: its statements only grant access in that
#     compartment, and whoever applies it then needs policy rights in that
#     compartment only. If OCI_COMPARTMENT_ID is the tenancy itself, the
#     statements say "in tenancy" and the policy attaches to the root.
#
# Env: OCI_COMPARTMENT_ID (required), AUTOSCALER_DG_NAME, AUTOSCALER_POLICY_NAME,
#      OCI_TENANCY_ID (else read from the OCI CLI config file), COMPARTMENT_NAME
#      (used by --print only when the name lookup fails).

set -euo pipefail

readonly DG_NAME="${AUTOSCALER_DG_NAME:-nimble-oke-autoscaler}"
readonly POLICY_NAME="${AUTOSCALER_POLICY_NAME:-nimble-oke-autoscaler}"
readonly DESCRIPTION="nimble-oke: OKE Cluster Autoscaler add-on (instance principal)"

say()  { echo "[NIM-OKE][IAM] $*" >&2; }
fail() { echo "[NIM-OKE][IAM][ERROR] $*" >&2; exit "${2:-1}"; }

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit "${1:-0}"
}

mode="--print"
case "${1:-}" in
    ""|--print) mode="--print" ;;
    --check|--apply|--delete) mode="$1" ;;
    -h|--help) usage 0 ;;
    *) say "unknown option: $1"; usage 2 ;;
esac

[[ -n "${OCI_COMPARTMENT_ID:-}" ]] || fail "OCI_COMPARTMENT_ID is not set" 2
readonly COMPARTMENT_ID="$OCI_COMPARTMENT_ID"
readonly MATCHING_RULE="ALL {instance.compartment.id = '${COMPARTMENT_ID}'}"

# Tenancy OCID: OCI_TENANCY_ID, else the compartment itself if it is the
# root, else the "tenancy=" line of the active profile in the CLI config.
tenancy_id() {
    if [[ -n "${OCI_TENANCY_ID:-}" ]]; then printf '%s\n' "$OCI_TENANCY_ID"; return 0; fi
    if [[ "$COMPARTMENT_ID" == ocid1.tenancy.* ]]; then printf '%s\n' "$COMPARTMENT_ID"; return 0; fi
    local cfg="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}" profile="${OCI_CLI_PROFILE:-DEFAULT}" t
    [[ -f "$cfg" ]] || return 1
    t=$(awk -v p="[$profile]" '
        $0 == p {in_p = 1; next}
        /^\[/ {in_p = 0}
        in_p && $0 ~ /^[ \t]*tenancy[ \t]*=/ {sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t]+$/, ""); print; exit}' "$cfg")
    [[ -n "$t" ]] || return 1
    printf '%s\n' "$t"
}

compartment_name() {
    local n
    n=$(oci iam compartment get --compartment-id "$COMPARTMENT_ID" --query 'data.name' --raw-output 2>/dev/null) || return 1
    [[ -n "$n" && "$n" != "null" ]] || return 1
    printf '%s\n' "$n"
}

# The six statements Oracle documents, one per line.
statements() {
    local where="$1" verb
    for verb in "manage cluster-node-pools" "manage instance-family" "use subnets" \
                "read virtual-network-family" "use vnics" "inspect compartments"; do
        printf 'Allow dynamic-group %s to %s in %s\n' "$DG_NAME" "$verb" "$where"
    done
}

location_for() {  # $1 compartment name
    if [[ "$COMPARTMENT_ID" == ocid1.tenancy.* ]]; then echo "tenancy"; else echo "compartment $1"; fi
}

norm() { tr '[:upper:]' '[:lower:]' | tr -s ' \t' ' ' | sed 's/^ //; s/ $//'; }

# Read-only check. Sets DG_ID, POLICY_ID and MISSING (one problem per line).
DG_ID=""; POLICY_ID=""; MISSING=""
check_objects() {
    local where="$1" tenancy out want got s
    DG_ID=""; POLICY_ID=""; MISSING=""
    if ! tenancy=$(tenancy_id); then
        MISSING="tenancy OCID unknown: set OCI_TENANCY_ID (dynamic groups live in the tenancy root)"
        return 0
    fi
    if out=$(oci iam dynamic-group list --compartment-id "$tenancy" --name "$DG_NAME" --all 2>/dev/null); then
        [[ -n "$out" ]] || out='{"data":[]}'
        DG_ID=$(printf '%s' "$out" | jq -r --arg n "$DG_NAME" \
            '[.data[]? | select(.name == $n and (.["lifecycle-state"] // "ACTIVE") == "ACTIVE")] | first | .id // empty') || DG_ID=""
        if [[ -z "$DG_ID" ]]; then
            MISSING="${MISSING}dynamic group '$DG_NAME' (rule: $MATCHING_RULE)"$'\n'
        else
            got=$(printf '%s' "$out" | jq -r --arg id "$DG_ID" '.data[] | select(.id == $id) | .["matching-rule"] // ""' | norm)
            want=$(printf '%s' "$MATCHING_RULE" | norm)
            if [[ "$got" != "$want" ]]; then
                MISSING="${MISSING}dynamic group '$DG_NAME' exists ($DG_ID) but its rule is not: $MATCHING_RULE"$'\n'
            fi
        fi
    else
        MISSING="${MISSING}could not list dynamic groups in tenancy $tenancy (cannot confirm '$DG_NAME')"$'\n'
    fi
    if out=$(oci iam policy list --compartment-id "$COMPARTMENT_ID" --name "$POLICY_NAME" --all 2>/dev/null); then
        [[ -n "$out" ]] || out='{"data":[]}'
        POLICY_ID=$(printf '%s' "$out" | jq -r --arg n "$POLICY_NAME" \
            '[.data[]? | select(.name == $n and (.["lifecycle-state"] // "ACTIVE") == "ACTIVE")] | first | .id // empty') || POLICY_ID=""
        if [[ -z "$POLICY_ID" ]]; then
            MISSING="${MISSING}policy '$POLICY_NAME' in compartment $COMPARTMENT_ID with the six statements"$'\n'
        else
            got=$(printf '%s' "$out" | jq -r --arg id "$POLICY_ID" '.data[] | select(.id == $id) | .statements[]?' | norm)
            while IFS= read -r s; do
                [[ -n "$s" ]] || continue
                if ! printf '%s\n' "$got" | grep -Fqx -- "$(printf '%s' "$s" | norm)"; then
                    MISSING="${MISSING}policy '$POLICY_NAME' ($POLICY_ID) lacks: $s"$'\n'
                fi
            done < <(statements "$where")
        fi
    else
        MISSING="${MISSING}could not list policies in compartment $COMPARTMENT_ID (cannot confirm '$POLICY_NAME')"$'\n'
    fi
}

confirm_typed() {  # $1 compartment name, $2 action words
    local reply=""
    echo "About to $2 in compartment '$1' ($COMPARTMENT_ID)." >&2
    read -r -p "Type the compartment name to confirm: " reply || reply=""
    [[ "$reply" == "$1" ]]
}

# IAM writes are accepted only in the tenancy's home region (live run
# 2026-10-01: 403 NotAllowed, "Please go to your home region ORD"). Reads in
# another region can lag behind a write. So every call here targets the home
# region. IAM_HOME_REGION overrides the lookup.
use_home_region() {
    local tenancy home="${IAM_HOME_REGION:-}"
    if [[ -z "$home" ]]; then
        tenancy=$(tenancy_id) || return 0
        home=$(oci iam region-subscription list --tenancy-id "$tenancy" \
            --query 'data[?"is-home-region"]."region-name" | [0]' --raw-output 2>/dev/null) || home=""
    fi
    if [[ -n "$home" && "$home" != "null" ]]; then
        export OCI_CLI_REGION="$home"
        say "IAM calls target the home region: $home"
    else
        say "could not determine the home region; using the profile's region"
    fi
}

main() {
    local name where
    [[ "$mode" == "--print" ]] || use_home_region
    if ! name=$(compartment_name); then
        if [[ "$mode" == "--print" ]]; then
            name="${COMPARTMENT_NAME:-<compartment-name>}"
            say "could not read the compartment name (offline or no access); using '$name'"
        else
            fail "could not read the name of compartment $COMPARTMENT_ID (oci iam compartment get)" 3
        fi
    fi
    where=$(location_for "$name")

    case "$mode" in
        --print)
            echo "# Dynamic group (tenancy root): $DG_NAME"
            echo "$MATCHING_RULE"
            echo "# Policy: $POLICY_NAME, attached to compartment $name ($COMPARTMENT_ID)"
            statements "$where"
            ;;
        --check)
            check_objects "$where"
            if [[ -n "$MISSING" ]]; then
                say "Cluster Autoscaler IAM is NOT in place:"
                printf '%s' "$MISSING" | sed 's/^/  missing: /' >&2
                say "Run: scripts/setup-autoscaler-iam.sh --apply   (owner action; creates only these two objects)"
                exit 3
            fi
            say "OK: dynamic group '$DG_NAME' ($DG_ID) and policy '$POLICY_NAME' ($POLICY_ID) are in place"
            ;;
        --apply)
            check_objects "$where"
            if [[ -z "$MISSING" ]]; then
                say "Nothing to do: dynamic group and policy already in place"; exit 0
            fi
            if [[ -n "$DG_ID" ]] && printf '%s' "$MISSING" | grep -q "^dynamic group '$DG_NAME' exists"; then
                fail "dynamic group '$DG_NAME' exists with a different rule; not modifying it. Fix it by hand or set AUTOSCALER_DG_NAME."
            fi
            if [[ -n "$POLICY_ID" ]] && printf '%s' "$MISSING" | grep -q "^policy '$POLICY_NAME' ($POLICY_ID) lacks"; then
                fail "policy '$POLICY_NAME' exists without all six statements; not modifying it. Fix it by hand or set AUTOSCALER_POLICY_NAME."
            fi
            if printf '%s' "$MISSING" | grep -q '^could not\|^tenancy OCID'; then
                printf '%s' "$MISSING" >&2; fail "cannot apply while the current state is unknown"
            fi
            echo "Will create (only what is missing):" >&2
            [[ -n "$DG_ID" ]] || echo "  dynamic group $DG_NAME: $MATCHING_RULE" >&2
            if [[ -z "$POLICY_ID" ]]; then
                echo "  policy $POLICY_NAME in compartment $name:" >&2
                statements "$where" | sed 's/^/    /' >&2
            fi
            confirm_typed "$name" "create Cluster Autoscaler IAM objects" \
                || fail "Confirmation did not match the compartment name; nothing created"
            local tenancy stmts_json
            tenancy=$(tenancy_id)
            if [[ -z "$DG_ID" ]]; then
                oci iam dynamic-group create --compartment-id "$tenancy" --name "$DG_NAME" \
                    --description "$DESCRIPTION" --matching-rule "$MATCHING_RULE" \
                    --wait-for-state ACTIVE >/dev/null || fail "dynamic group create failed"
                say "Created dynamic group $DG_NAME"
            fi
            if [[ -z "$POLICY_ID" ]]; then
                stmts_json=$(statements "$where" | jq -R . | jq -cs .)
                oci iam policy create --compartment-id "$COMPARTMENT_ID" --name "$POLICY_NAME" \
                    --description "$DESCRIPTION" --statements "$stmts_json" \
                    --wait-for-state ACTIVE >/dev/null || fail "policy create failed"
                say "Created policy $POLICY_NAME in compartment $name"
            fi
            check_objects "$where"
            [[ -z "$MISSING" ]] || { printf '%s' "$MISSING" >&2; fail "objects created but the check still fails" 3; }
            say "OK: Cluster Autoscaler IAM in place (IAM changes can take a few minutes to propagate)"
            ;;
        --delete)
            check_objects "$where"
            if [[ -z "$DG_ID" && -z "$POLICY_ID" ]]; then
                say "Nothing to delete: no dynamic group '$DG_NAME' and no policy '$POLICY_NAME' found"; exit 0
            fi
            echo "Will delete exactly:" >&2
            [[ -z "$POLICY_ID" ]] || echo "  policy $POLICY_NAME ($POLICY_ID)" >&2
            [[ -z "$DG_ID" ]] || echo "  dynamic group $DG_NAME ($DG_ID)" >&2
            confirm_typed "$name" "DELETE Cluster Autoscaler IAM objects" \
                || fail "Confirmation did not match the compartment name; nothing deleted"
            if [[ -n "$POLICY_ID" ]]; then
                oci iam policy delete --policy-id "$POLICY_ID" --force >/dev/null || fail "policy delete failed: $POLICY_ID"
                say "Deleted policy $POLICY_ID"
            fi
            if [[ -n "$DG_ID" ]]; then
                oci iam dynamic-group delete --dynamic-group-id "$DG_ID" --force >/dev/null || fail "dynamic group delete failed: $DG_ID"
                say "Deleted dynamic group $DG_ID"
            fi
            ;;
    esac
}

main
