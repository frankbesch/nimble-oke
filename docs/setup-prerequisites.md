# Setup Prerequisites for NVIDIA NIM on OKE

This guide covers all prerequisites needed before deploying NVIDIA NIM on Oracle Kubernetes Engine.

## 1. Oracle Cloud Infrastructure (OCI) Account

### Create OCI Account

1. Visit: https://www.oracle.com/cloud/free/
2. Sign up for an account (free tier available)
3. Complete verification process
4. Note your **Tenancy OCID** and **Home Region**

### Request GPU Quota

By default, new accounts may not have GPU quota. Request increase:

1. Navigate to: **Governance → Limits, Quotas and Usage**
2. Select your home region
3. Filter for "GPU"
4. Find: **VM.Standard.GPU.A10.1 count**
5. Click **Request Service Limit Increase**
6. Request at least **1 GPU**

**Processing time:** Usually 24-48 hours

### Get Compartment ID

```bash
# List all compartments
oci iam compartment list --all

# Your root compartment
oci iam compartment list --compartment-id-in-subtree true | jq -r '.data[] | select(.name=="<your-tenancy-name>") | .id'
```

Save this as `OCI_COMPARTMENT_ID`

## 2. Install OCI CLI

### macOS

```bash
# Using Homebrew
brew install oci-cli

# Or using installer
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

### Linux

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

### Configure OCI CLI

```bash
oci setup config
```

You'll need:
- **Tenancy OCID:** From OCI Console → User menu → Tenancy
- **User OCID:** From OCI Console → User menu → User Settings
- **Region:** Your home region (e.g., us-ashburn-1)
- **Generate RSA key pair:** Yes

Test configuration:

```bash
oci iam region list
```

## 3. NVIDIA NGC Account & API Key

### Register for NGC

1. Visit: https://catalog.ngc.nvidia.com/
2. Click **Sign Up** (top right)
3. Create account (free)
4. Verify email

### Generate API Key

1. Log in to NGC
2. Click your profile → **Setup**
3. Click **Generate API Key**
4. Copy the API key (starts with `nvapi-...`)
5. **Important:** Save this key securely - you can't view it again!

**Store your key:**

```bash
export NGC_API_KEY="nvapi-xxxxxxxxxxxxxxxxxxxx"
```

### Test NGC Access

```bash
# Login to NGC registry
echo $NGC_API_KEY | docker login nvcr.io --username '$oauthtoken' --password-stdin

# Pull a test image (optional)
docker pull nvcr.io/nvidia/cuda:12.0.0-base-ubuntu22.04
```

## 4. Install Required Tools

### kubectl

**macOS:**
```bash
brew install kubectl
```

**Linux:**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
```

**Verify:**
```bash
kubectl version --client
```

### Helm 3

**macOS:**
```bash
brew install helm
```

**Linux:**
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

**Verify:**
```bash
helm version
```

### jq (JSON processor)

**macOS:**
```bash
brew install jq
```

**Linux:**
```bash
sudo apt-get install jq  # Debian/Ubuntu
sudo yum install jq      # RHEL/CentOS
```

**Verify:**
```bash
jq --version
```

## 5. OCI IAM Setup

### Create User Group (Optional)

For better security, create a dedicated group:

```bash
# Create group
oci iam group create --name NIM-Users --description "Users for NIM deployment"

# Add yourself to group
USER_ID=$(oci iam user list --query "data[?name=='<your-username>'].id | [0]" --raw-output)
GROUP_ID=$(oci iam group list --query "data[?name=='NIM-Users'].id | [0]" --raw-output)
oci iam group add-user --user-id $USER_ID --group-id $GROUP_ID
```

### Create IAM Policy

Required permissions for NIM deployment:

```bash
# Get compartment ID
COMPARTMENT_ID="<your-compartment-id>"

# Create policy
cat > nim-policy.json <<EOF
{
  "statements": [
    "Allow group NIM-Users to manage virtual-network-family in compartment id $COMPARTMENT_ID",
    "Allow group NIM-Users to manage cluster-family in compartment id $COMPARTMENT_ID",
    "Allow group NIM-Users to manage instance-family in compartment id $COMPARTMENT_ID",
    "Allow group NIM-Users to use subnets in compartment id $COMPARTMENT_ID",
    "Allow group NIM-Users to use vnics in compartment id $COMPARTMENT_ID",
    "Allow group NIM-Users to inspect compartments in compartment id $COMPARTMENT_ID",
    "Allow group NIM-Users to manage object-family in compartment id $COMPARTMENT_ID"
  ]
}
EOF

oci iam policy create \
  --compartment-id $COMPARTMENT_ID \
  --name nim-deployment-policy \
  --description "Policy for NIM deployment on OKE" \
  --statements file://nim-policy.json
```

### Enable Instance Principals (for OKE)

This allows OKE nodes to access OCI services without credentials:

```bash
# Create dynamic group
cat > dynamic-group.json <<EOF
{
  "matchingRules": [
    "ALL {instance.compartment.id = '$COMPARTMENT_ID'}"
  ]
}
EOF

oci iam dynamic-group create \
  --name oke-nim-nodes \
  --description "OKE nodes for NIM deployment" \
  --matching-rule "$(cat dynamic-group.json | jq -r '.matchingRules[0]')"

# Create policy for dynamic group
cat > dynamic-group-policy.json <<EOF
{
  "statements": [
    "Allow dynamic-group oke-nim-nodes to read objects in compartment id $COMPARTMENT_ID",
    "Allow dynamic-group oke-nim-nodes to manage objects in compartment id $COMPARTMENT_ID where any {request.permission='OBJECT_CREATE', request.permission='OBJECT_INSPECT'}"
  ]
}
EOF

oci iam policy create \
  --compartment-id $COMPARTMENT_ID \
  --name oke-nim-instance-principals \
  --description "Allow OKE nodes to access object storage" \
  --statements file://dynamic-group-policy.json
```

## 6. Verify Prerequisites Checklist

Use this checklist before provisioning:

```bash
# Save this as check-prerequisites.sh
#!/bin/bash

echo "Checking prerequisites..."
echo ""

# OCI CLI
if command -v oci &> /dev/null; then
    echo "✅ OCI CLI installed: $(oci --version 2>&1 | head -n1)"
else
    echo "❌ OCI CLI not found"
fi

# kubectl
if command -v kubectl &> /dev/null; then
    echo "✅ kubectl installed: $(kubectl version --client --short 2>&1)"
else
    echo "❌ kubectl not found"
fi

# Helm
if command -v helm &> /dev/null; then
    echo "✅ Helm installed: $(helm version --short)"
else
    echo "❌ Helm not found"
fi

# jq
if command -v jq &> /dev/null; then
    echo "✅ jq installed: $(jq --version)"
else
    echo "❌ jq not found"
fi

# OCI Configuration
if [ -f "$HOME/.oci/config" ]; then
    echo "✅ OCI config found"
else
    echo "❌ OCI config not found - run 'oci setup config'"
fi

# Environment variables
if [ -n "$OCI_COMPARTMENT_ID" ]; then
    echo "✅ OCI_COMPARTMENT_ID set"
else
    echo "⚠️  OCI_COMPARTMENT_ID not set"
fi

if [ -n "$NGC_API_KEY" ]; then
    echo "✅ NGC_API_KEY set"
else
    echo "⚠️  NGC_API_KEY not set"
fi

echo ""
echo "Checking GPU quota..."
COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-$(oci iam compartment list --query 'data[0].id' --raw-output)}"
GPU_LIMIT=$(oci limits value list \
  --compartment-id "$COMPARTMENT_ID" \
  --service-name compute \
  --query "data[?name=='vm-gpu-a10-count'].value | [0]" \
  --raw-output 2>/dev/null || echo "0")

if [ "$GPU_LIMIT" -gt 0 ]; then
    echo "✅ GPU quota available: $GPU_LIMIT"
else
    echo "⚠️  No GPU quota - request VM.GPU.A10.1 quota increase"
fi

echo ""
echo "Prerequisites check complete!"
```

Run it:

```bash
chmod +x check-prerequisites.sh
./check-prerequisites.sh
```

## 7. Cost Preparation

### Set Up Budget Alerts

1. Navigate to: **Governance → Cost Management → Budgets**
2. Click **Create Budget**
3. Set budget amount: **$50** (or your preferred limit)
4. Add alert thresholds:
   - 50% ($25)
   - 80% ($40)
   - 100% ($50)
5. Set notification email

### Monitor Costs

```bash
# View cost analysis
oci usage-api usage summarized-usage list \
  --tenant-id "$(oci iam tenancy get --query 'data.id' --raw-output)" \
  --time-usage-started "$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --time-usage-ended "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --granularity DAILY
```

## 8. Network Preparation (Optional)

If you have existing VCN/networking requirements:

```bash
# List existing VCNs
oci network vcn list --compartment-id $OCI_COMPARTMENT_ID

# List available subnets
oci network subnet list --compartment-id $OCI_COMPARTMENT_ID --vcn-id <vcn-ocid>
```

The provisioning script will create a new VCN by default, but you can modify it to use existing networking.

## Next Steps

Once all prerequisites are complete:

1. ✅ Clone/download this project
2. ✅ Export environment variables:
   ```bash
   export OCI_COMPARTMENT_ID=ocid1.compartment.oc1...
   export OCI_REGION=us-phoenix-1
   export NGC_API_KEY=nvapi-...
   ```
3. ✅ Proceed to [Deployment Guide](deployment-guide.md)

## Troubleshooting

### OCI CLI Authentication Fails

```bash
# Regenerate config
oci setup repair-file-permissions --file ~/.oci/config
oci setup repair-file-permissions --file ~/.oci/oci_api_key.pem
```

### GPU Quota Request Denied

- Ensure you've completed account verification
- Add payment method (even for free tier)
- Try a different region with GPU availability

### NGC Registry Access Denied

- Verify API key is correct (no extra spaces)
- Check if key has expired (regenerate if needed)
- Ensure you've accepted NGC terms of service

## Additional Resources

- **OCI CLI Reference:** https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/
- **NGC Setup Guide:** https://docs.nvidia.com/ngc/ngc-catalog-user-guide/
- **OKE Best Practices:** https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengbestpractices.htm


