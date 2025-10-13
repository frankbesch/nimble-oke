# Region Migration Guide: Chicago → Phoenix

Complete guide for migrating from us-chicago-1 to us-phoenix-1.

## Why Phoenix?

**Optimal for Austin, Texas:**
- Lower latency (~30ms vs ~40ms from Austin)
- Better GPU availability (A10.1, GPU3.x, H100)
- Same pricing across US regions
- More availability domains

## Quick Migration

### 1. **Cleanup Chicago Resources** (Automated)

```bash
# Run automated cleanup script
./scripts/cleanup-chicago-cluster.sh
```

This script will:
- ✅ Delete OKE clusters in Chicago
- ✅ Remove node pools
- ✅ Clean up kubectl contexts
- ✅ Update OCI CLI region to Phoenix
- ✅ Verify Phoenix region access

### 2. **Update Environment**

```bash
# Reload environment with Phoenix region
source setup-env.sh

# Verify region is set
echo $OCI_REGION  # Should show: us-phoenix-1
```

### 3. **Verify Setup**

```bash
# Run full validation
make validate
```

### 4. **Deploy in Phoenix**

```bash
# Provision fresh cluster in Phoenix
make provision CONFIRM_COST=yes
```

---

## Manual Migration (If Needed)

### Step 1: List Chicago Resources

```bash
# Set Chicago region temporarily
export OCI_REGION=us-chicago-1

# List clusters
oci ce cluster list \
    --compartment-id $OCI_COMPARTMENT_ID \
    --region us-chicago-1 \
    --lifecycle-state ACTIVE

# List compute instances
oci compute instance list \
    --compartment-id $OCI_COMPARTMENT_ID \
    --region us-chicago-1 \
    --lifecycle-state RUNNING
```

### Step 2: Delete OKE Cluster

```bash
# Get cluster ID from above
CLUSTER_ID="ocid1.cluster.oc1.ord..."

# Delete cluster
oci ce cluster delete \
    --cluster-id $CLUSTER_ID \
    --region us-chicago-1 \
    --force
```

### Step 3: Delete Node Pools

```bash
# List node pools
oci ce node-pool list \
    --cluster-id $CLUSTER_ID \
    --region us-chicago-1

# Delete each node pool
oci ce node-pool delete \
    --node-pool-id "ocid1.nodepool..." \
    --region us-chicago-1 \
    --force
```

### Step 4: Clean Up kubectl Context

```bash
# List contexts
kubectl config get-contexts

# Delete Chicago context
kubectl config delete-context context-c4ahhm6k46a

# Or delete all contexts and start fresh
rm -f ~/.kube/config
```

### Step 5: Update OCI CLI Region

```bash
# Edit OCI config
nano ~/.oci/config

# Change or add:
region=us-phoenix-1
```

### Step 6: Update Environment Variables

```bash
# Set Phoenix region
export OCI_REGION=us-phoenix-1

# Verify
oci iam region list --region us-phoenix-1

# Should show Phoenix in subscribed regions
oci iam region-subscription list
```

---

## Verification Checklist

After migration, verify:

```bash
# 1. Check environment variables
echo "Region: $OCI_REGION"
echo "Compartment: ${OCI_COMPARTMENT_ID:0:40}..."
echo "NGC Key: ${NGC_API_KEY:0:20}..."

# 2. Verify OCI CLI region
cat ~/.oci/config | grep region

# 3. Check no Chicago resources remain
oci ce cluster list \
    --compartment-id $OCI_COMPARTMENT_ID \
    --region us-chicago-1

# 4. Verify Phoenix access
oci iam region list --region us-phoenix-1

# 5. Check kubectl contexts
kubectl config get-contexts

# 6. Run full validation
make validate
```

---

## Cost Implications

**No cost difference:**
- OCI charges same rates across US regions
- us-chicago-1: $2.62/hour for VM.GPU.A10.1
- us-phoenix-1: $2.62/hour for VM.GPU.A10.1

**Benefits of Phoenix:**
- Better GPU availability
- Lower latency from Austin
- More availability domains

---

## Fresh Start in Phoenix

### Configuration

All scripts default to Phoenix:
- `provision-cluster.sh`: Uses `us-phoenix-1`
- `setup-env.sh`: Sets `OCI_REGION=us-phoenix-1`
- `discover.sh`: Recommends Phoenix for Austin

### Deploy

```bash
# 1. Set environment (includes Phoenix region)
source setup-env.sh

# 2. Validate
make validate

# 3. Check cost
make cost-simulate

# 4. Provision in Phoenix
make provision CONFIRM_COST=yes

# 5. Deploy NIM
make install CONFIRM_COST=yes

# 6. Verify
make verify
```

---

## Troubleshooting

### Chicago Resources Not Deleting

```bash
# Check deletion status
oci ce cluster list \
    --compartment-id $OCI_COMPARTMENT_ID \
    --region us-chicago-1 \
    --lifecycle-state DELETING

# Deletion is asynchronous - wait 10-15 minutes
# Resources in DELETING state will be removed automatically
```

### kubectl Context Issues

```bash
# Remove all contexts and start fresh
rm -f ~/.kube/config

# After provisioning Phoenix cluster:
make configure-kubectl
```

### Region Not Switching

```bash
# Verify OCI config
cat ~/.oci/config | grep region

# Should show:
# region=us-phoenix-1

# If not, edit manually:
nano ~/.oci/config

# Or run automated cleanup:
./scripts/cleanup-chicago-cluster.sh
```

### Phoenix Not Subscribed

```bash
# Check subscribed regions
oci iam region-subscription list

# If Phoenix not listed, subscribe in OCI Console:
# Identity > Regions > Subscribe to us-phoenix-1
```

---

## Quick Reference

### Automated (Recommended)

```bash
# One-command cleanup and migration
./scripts/cleanup-chicago-cluster.sh && source setup-env.sh && make validate
```

### Manual Steps

1. Delete Chicago cluster: `./scripts/cleanup-chicago-cluster.sh`
2. Update region: `export OCI_REGION=us-phoenix-1`
3. Clean kubectl: `kubectl config delete-context <chicago-context>`
4. Update OCI config: Edit `~/.oci/config`
5. Validate: `make validate`
6. Deploy: `make provision CONFIRM_COST=yes`

---

## Region Comparison

| Feature | Chicago (us-chicago-1) | Phoenix (us-phoenix-1) |
|---------|----------------------|----------------------|
| **Latency from Austin** | ~40-50ms | ~30-35ms |
| **GPU Availability** | Limited | Excellent |
| **Availability Domains** | 1 | 3 |
| **GPU Shapes Available** | A10.1, GPU3.x | A10.1, GPU3.x, H100 |
| **Pricing (A10.1)** | $2.62/hour | $2.62/hour |
| **Network Performance** | Good | Excellent |
| **Recommended for Austin** | ❌ No | ✅ Yes |

---

## After Migration

Your Nimble OKE deployment will be fully configured for Phoenix:
- ✅ All scripts use `us-phoenix-1` by default
- ✅ Environment variables point to Phoenix
- ✅ OCI CLI defaults to Phoenix
- ✅ kubectl configured for Phoenix cluster
- ✅ Ready for fresh deployment

**Start fresh:** `make provision CONFIRM_COST=yes`

