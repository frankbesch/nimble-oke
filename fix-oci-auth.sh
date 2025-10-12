#!/usr/bin/env bash

# Fix OCI authentication and region configuration

echo "==============================================================="
echo "FIX OCI AUTHENTICATION"
echo "==============================================================="
echo ""

# Check OCI config
echo "Current OCI config:"
cat ~/.oci/config
echo ""

# Restore Chicago region temporarily to test auth
echo "Testing authentication with Chicago region..."
cp ~/.oci/config ~/.oci/config.backup

# Update to Chicago temporarily
sed -i.tmp 's/region=us-phoenix-1/region=us-chicago-1/' ~/.oci/config

# Test Chicago auth
if oci iam region-subscription list --region us-chicago-1 &>/dev/null; then
    echo "✅ Authentication works with Chicago"
    echo ""
    echo "Getting subscribed regions..."
    oci iam region-subscription list --region us-chicago-1
    echo ""
    echo "You can deploy in Chicago or subscribe to Phoenix"
else
    echo "❌ Authentication still failing"
    echo ""
    echo "Please run: oci setup config"
fi

