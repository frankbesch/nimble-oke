#!/usr/bin/env bash
#
# Diagnose OCI CLI authentication and region configuration.
#
# Read-only: this script never edits ~/.oci/config. It prints only profile
# names and their regions (no OCIDs, fingerprints, or key paths), tests
# authentication per profile, and shows the commands you could run yourself.

set -euo pipefail

OCI_CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"

echo "==============================================================="
echo "OCI AUTHENTICATION CHECK (read-only)"
echo "==============================================================="
echo ""

if [[ ! -f "$OCI_CONFIG_FILE" ]]; then
    echo "No OCI config found at $OCI_CONFIG_FILE"
    echo "Run: oci setup config"
    exit 1
fi

# Print profile names and regions only. Every other key is withheld.
echo "Profiles in $OCI_CONFIG_FILE (name → region):"
profiles=()
current_profile=""
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]]; then
        current_profile="${BASH_REMATCH[1]}"
        profiles+=("$current_profile")
    elif [[ -n "$current_profile" && "$line" =~ ^[[:space:]]*region[[:space:]]*=[[:space:]]*([^[:space:]]+) ]]; then
        echo "  [$current_profile] region=${BASH_REMATCH[1]}"
    fi
done < "$OCI_CONFIG_FILE"
echo ""

if [[ ${#profiles[@]} -eq 0 ]]; then
    echo "No profiles found in $OCI_CONFIG_FILE"
    echo "Run: oci setup config"
    exit 1
fi

if ! command -v oci &>/dev/null; then
    echo "oci CLI not found on PATH; cannot test authentication."
    exit 1
fi

profile="${OCI_CLI_PROFILE:-DEFAULT}"
test_region="${1:-}"
region_args=()
if [[ -n "$test_region" ]]; then
    region_args=(--region "$test_region")
fi

echo "Testing authentication for profile [$profile]${test_region:+ in region $test_region}..."
if oci iam region-subscription list --profile "$profile" ${region_args[@]+"${region_args[@]}"} \
        --query 'data[].{region:"region-name",status:status}' --output table; then
    echo ""
    echo "✅ Authentication works for profile [$profile]"
    echo "The table above lists the regions this tenancy subscribes to."
else
    echo ""
    echo "❌ Authentication failed for profile [$profile]"
    echo ""
    echo "Options (this script changes nothing; run one yourself if it fits):"
    echo "  - Re-create the profile:         oci setup config"
    echo "  - Use another region per call:   export OCI_REGION=us-chicago-1"
    echo "  - Change the profile's region:   edit $OCI_CONFIG_FILE and set region=<region> under [$profile]"
    exit 1
fi
