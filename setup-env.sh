#!/usr/bin/env bash

# Nimble OKE Environment Setup
# Run: source setup-env.sh

echo "==============================================================="
echo "NIMBLE OKE - ENVIRONMENT SETUP"
echo "==============================================================="
echo ""

# Get tenancy ID from OCI config
TENANCY_ID=$(grep "^tenancy=" ~/.oci/config | head -1 | cut -d'=' -f2)

if [[ -z "$TENANCY_ID" ]]; then
    echo "❌ ERROR: Could not find tenancy ID in ~/.oci/config"
    echo "   Run: oci setup config"
    return 1
fi

echo "✅ Found OCI Tenancy:"
echo "   $TENANCY_ID"
echo ""

# Check for nimble-oke compartment
NIMBLE_COMPARTMENT=$(oci iam compartment list \
    --compartment-id "$TENANCY_ID" \
    --name "nimble-oke" \
    --query 'data[0].id' \
    --raw-output 2>/dev/null || echo "")

if [[ -n "$NIMBLE_COMPARTMENT" ]]; then
    export OCI_COMPARTMENT_ID="$NIMBLE_COMPARTMENT"
    echo "✅ Found nimble-oke compartment"
    echo "   Using dedicated compartment for isolation and cost tracking"
    echo ""
else
    export OCI_COMPARTMENT_ID="$TENANCY_ID"
    echo "✅ Using root compartment (tenancy)"
    echo "   💡 Tip: Create 'nimble-oke' compartment for better organization"
    echo ""
fi

# Check for NGC API Key
if [[ -z "${NGC_API_KEY:-}" ]]; then
    echo "⚠️  NGC_API_KEY not set"
    echo ""
    echo "To get your NGC API key:"
    echo "  1. Go to: https://ngc.nvidia.com/setup/api-key"
    echo "  2. Sign in (or create NVIDIA account)"
    echo "  3. Generate API key"
    echo "  4. Run: export NGC_API_KEY=nvapi-your-key-here"
    echo ""
else
    echo "✅ NGC_API_KEY already set (${NGC_API_KEY:0:10}...)"
    echo ""
fi

# Set region to us-phoenix-1 (optimal for Austin)
export OCI_REGION="us-phoenix-1"
echo "✅ Set OCI_REGION to us-phoenix-1 (optimal for Austin)"
echo ""

# Set daily budget
export DAILY_BUDGET_USD=50
echo "✅ Set DAILY_BUDGET_USD to \$50"
echo ""

echo "==============================================================="
echo "ENVIRONMENT VARIABLES SET:"
echo "==============================================================="
echo "  OCI_COMPARTMENT_ID: ${OCI_COMPARTMENT_ID:0:40}..."
echo "  OCI_REGION:         $OCI_REGION"
echo "  DAILY_BUDGET_USD:   \$$DAILY_BUDGET_USD"
if [[ -n "${NGC_API_KEY:-}" ]]; then
    echo "  NGC_API_KEY:        ${NGC_API_KEY:0:10}... (set)"
else
    echo "  NGC_API_KEY:        (NOT SET - required before deployment)"
fi
echo ""

echo "==============================================================="
echo "NEXT STEPS:"
echo "==============================================================="
echo ""

if [[ -z "${NGC_API_KEY:-}" ]]; then
    echo "1. Get NGC API Key:"
    echo "   https://ngc.nvidia.com/setup/api-key"
    echo ""
    echo "2. Set NGC API Key:"
    echo "   export NGC_API_KEY=nvapi-your-key-here"
    echo ""
    echo "3. Test without costs:"
else
    echo "1. Test without costs:"
fi

echo "   make cost-simulate"
echo "   make cost-scenarios"
echo "   make dry-run"
echo ""
echo "2. Full validation (when NGC_API_KEY is set):"
echo "   make validate"
echo ""
echo "3. Deploy to OCI (costs start):"
echo "   make provision CONFIRM_COST=yes"
echo ""

echo "==============================================================="
echo "To persist these settings, add to ~/.zshrc:"
echo "==============================================================="
echo ""
echo "echo 'export OCI_COMPARTMENT_ID=$OCI_COMPARTMENT_ID' >> ~/.zshrc"
echo "echo 'export OCI_REGION=$OCI_REGION' >> ~/.zshrc"
echo "echo 'export DAILY_BUDGET_USD=$DAILY_BUDGET_USD' >> ~/.zshrc"
if [[ -n "${NGC_API_KEY:-}" ]]; then
    echo "echo 'export NGC_API_KEY=$NGC_API_KEY' >> ~/.zshrc"
fi
echo ""

