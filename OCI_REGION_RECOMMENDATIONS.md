# OCI Region Recommendations for Nimble OKE
## Optimal Region Selection for Austin, Texas

---

## Quick Recommendation

**Primary:** `us-phoenix-1` (Phoenix, Arizona)  
**Backup:** `us-ashburn-1` (Ashburn, Virginia)

---

## Analysis for Austin, Texas Deployment

### Geography & Latency

**From Austin, Texas:**

| Region | Location | Distance | Est. Latency | Recommendation |
|--------|----------|----------|--------------|----------------|
| `us-phoenix-1` | Phoenix, AZ | ~900 miles | 15-25ms | **PRIMARY** |
| `us-ashburn-1` | Ashburn, VA | ~1,500 miles | 25-35ms | **BACKUP** |
| `us-sanjose-1` | San Jose, CA | ~1,500 miles | 30-40ms | Alternative |
| `ca-toronto-1` | Toronto, Canada | ~1,400 miles | 30-40ms | Alternative |
| `sa-saopaulo-1` | São Paulo, Brazil | ~5,000 miles | 120-150ms | Not recommended |

**Winner:** `us-phoenix-1` (closest to Austin)

### GPU Availability (VM.GPU.A10.1)

**OCI Regions with A10 GPU Availability:**

**Tier 1 (Best Availability):**
- `us-phoenix-1` - Phoenix, Arizona
- `us-ashburn-1` - Ashburn, Virginia
- `us-sanjose-1` - San Jose, California

**Tier 2 (Good Availability):**
- `eu-frankfurt-1` - Frankfurt, Germany
- `ap-tokyo-1` - Tokyo, Japan
- `ap-sydney-1` - Sydney, Australia

**Tier 3 (Limited):**
- Newer regions may have limited GPU quota

**Winner:** `us-phoenix-1` and `us-ashburn-1` (established regions with good GPU capacity)

### Cost Comparison

**OCI GPU Pricing (Uniform Across Regions):**

VM.GPU.A10.1 pricing is **identical across all OCI regions**:
- Standard rate: $2.62/hour
- No regional price variations (unlike AWS/GCP)

**Other Components (Also Uniform):**
- ENHANCED cluster: $0.10/hour (all regions)
- Block storage: $0.0255/GB/month (all regions)
- Load Balancer: ~$0.25/hour (all regions)
- Network egress: First 10TB free, then $0.0085/GB

**Winner:** Tie - all regions have same pricing

### Deployment Speed Factors

**What Affects Deployment Speed:**

1. **GPU Capacity in Availability Domains**
   - More important than region choice
   - Check with `make discover` before provisioning

2. **Network Connectivity**
   - Austin → Phoenix: Better backbone routing
   - Austin → Ashburn: Cross-country, but mature infrastructure

3. **Region Maturity**
   - Older regions (phoenix, ashburn) = more capacity
   - Newer regions = may have quota/capacity constraints

**Winner:** `us-phoenix-1` (established, west coast)

---

## Final Recommendation

### PRIMARY: `us-phoenix-1` (Phoenix, Arizona)

**Pros:**
- Closest to Austin (~900 miles, 15-25ms latency)
- Established region with good GPU capacity
- West coast data center with mature infrastructure
- Same pricing as all other regions

**Cons:**
- None significant for your use case

**Configuration:**
```bash
export OCI_REGION=us-phoenix-1
make provision
```

### BACKUP: `us-ashburn-1` (Ashburn, Virginia)

**Pros:**
- Second closest to Austin (~1,500 miles, 25-35ms)
- OCI's original US region (best capacity)
- Excellent GPU availability
- Default in our scripts

**Cons:**
- 10-15ms higher latency vs Phoenix
- Cross-country distance

**Configuration:**
```bash
export OCI_REGION=us-ashburn-1
make provision
```

---

## Cost Comparison (Both Regions)

**5-Hour Smoke Test:**
```
Region: us-phoenix-1 OR us-ashburn-1
ENHANCED cluster: $0.50
GPU (VM.GPU.A10.1): $13.10
Storage + LB: $7.75
────────────────────────
Total: $21.35 (identical)
```

**No cost difference between regions.**

---

## Network Performance from Austin

### Phoenix (us-phoenix-1)
- **Distance:** ~900 miles
- **Expected Latency:** 15-25ms
- **Route:** Direct west coast backbone
- **Best for:** Latency-sensitive operations

### Ashburn (us-ashburn-1)
- **Distance:** ~1,500 miles
- **Expected Latency:** 25-35ms
- **Route:** Cross-country backbone
- **Best for:** Maximum capacity availability

**Latency Impact on Your Workflow:**

For smoke testing workflows (kubectl commands, API tests):
- Phoenix: Slightly faster feedback (~10-15ms per command)
- Ashburn: Negligible impact for scripted automation
- **Verdict:** Phoenix preferred but Ashburn perfectly acceptable

---

## GPU Capacity Verification

**Before deploying, check actual capacity:**

```bash
# Set region
export OCI_REGION=us-phoenix-1

# Run discovery (includes capacity check)
make discover

# Check availability domains
oci iam availability-domain list --region $OCI_REGION

# Check GPU capacity per AD
for ad in $(oci iam availability-domain list --region $OCI_REGION --query 'data[].name' --raw-output); do
  echo "Checking $ad..."
  oci limits resource-availability get \
    --compartment-id $OCI_COMPARTMENT_ID \
    --service-name compute \
    --limit-name "gpu-a10-count" \
    --availability-domain "$ad"
done
```

---

## Alternative Considerations

### If Phoenix/Ashburn Have No Capacity

**Try these regions in order:**

1. **us-sanjose-1** (San Jose, CA)
   - Distance: ~1,500 miles
   - Latency: 30-40ms
   - West coast alternative

2. **ca-toronto-1** (Toronto, Canada)
   - Distance: ~1,400 miles
   - Latency: 30-40ms
   - Good A10 availability

3. **eu-frankfurt-1** (Frankfurt, Germany)
   - Distance: ~5,000 miles
   - Latency: 100-120ms
   - Large capacity, but high latency

---

## Decision Matrix

| Factor | us-phoenix-1 | us-ashburn-1 | us-sanjose-1 |
|--------|--------------|--------------|--------------|
| **Distance from Austin** | 900 mi | 1,500 mi | 1,500 mi |
| **Latency** | 15-25ms ⭐ | 25-35ms ✓ | 30-40ms |
| **GPU Availability** | High ⭐ | Very High ⭐ | High ✓ |
| **Cost** | $11 | $11 | $11 |
| **Deployment Speed** | Fast ⭐ | Fast ⭐ | Fast ✓ |
| **Recommendation** | **PRIMARY** | **BACKUP** | Alternative |

---

## Recommended Configuration

### For Austin, Texas

```bash
# Primary configuration
export OCI_REGION=us-phoenix-1
export OCI_COMPARTMENT_ID=ocid1.compartment...
export CLUSTER_NAME=nimble-oke-phoenix
export NGC_API_KEY=nvapi-...

# Verify before provisioning
make discover
make prereqs

# If GPU capacity available
make provision

# If Phoenix has no capacity, try Ashburn
export OCI_REGION=us-ashburn-1
export CLUSTER_NAME=nimble-oke-ashburn
make discover
make prereqs
make provision
```

---

## Summary

**Best Region for Austin:** `us-phoenix-1`

**Reasons:**
1. Closest distance (~900 miles)
2. Lowest latency (15-25ms)
3. Established region with good GPU capacity
4. Same cost as all other regions
5. West coast routing

**Backup:** `us-ashburn-1` (if Phoenix lacks capacity)

**Cost:** $11 per 5-hour test (identical in all US regions)

**Action:** Update scripts to use `us-phoenix-1` as default for Austin-based deployment.

