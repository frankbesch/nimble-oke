# Oracle Blog vs Nimble OKE - Quick Reference

> **Reading time:** 6 minutes  
> **Quick reference** - 1-page decision guide

*Historical working note from October 2025; figures corrected 2026-10-01. See README for current status.*

Statements about the Oracle blog are as of October 2025, not re-verified. Nimble OKE times are estimate (static assumption, not measured).

**1-page decision guide for choosing the right approach**

---

## 🎯 Use Case Decision Tree

```
┌─────────────────────────────────────┐
│ What's your primary goal?          │
└──────────────┬──────────────────────┘
               │
       ┌───────┴───────┐
       │               │
   ┌───▼───┐       ┌───▼────┐
   │ Dev/  │       │ Prod   │
   │ Test  │       │ Deploy │
   └───┬───┘       └───┬────┘
       │               │
   ┌───▼────────┐  ┌───▼─────────┐
   │ Nimble OKE │  │ Oracle Blog │
   │ (You)      │  │ Approach    │
   └────────────┘  └─────────────┘
```

---

## Quick Comparison

| Feature | Oracle Blog | Nimble OKE |
|---------|-------------|------------|
| **Setup Time** | Not re-verified | Not measured yet |
| **Cost (5hr test)** | Not re-verified | $10.50 (5 h × $2.10), plus LB and storage |
| **Model Storage** | Object Storage | Block Volume |
| **Scalability** | HPA (automatic) | Manual |
| **Cost Guards** | None | Built-in |
| **Monitoring** | Full (Prom+Graf) | Logs only |
| **Idempotency** | Not specified | 100% |
| **Cleanup** | Manual | Automatic on failure |
| **Optimization** | TensorRT-LLM | Stock NIM |

**Summary:** The Oracle blog covers production features (monitoring, scalability, optimization). Nimble OKE covers developer workflow (automation, cost guards).

---

## Cost Comparison

### Nimble OKE (Current)
```
Hourly: $2.10, plus load balancer and block storage
5-hour test: $10.50 (5 h × $2.10)
24/7 month: $1,533 (730 h × $2.10)

Components:
• GPU (VM.GPU.A10.1): $2.00/hr
• ENHANCED cluster: $0.10/hr (no separate control-plane charge)
• Storage and LB: not verified here
```

### Oracle Blog (Production Pattern)
```
Hourly: same base + monitoring overhead
Monitoring and Object Storage costs: not verified here
```

---

## Key Differentiators

| Category | Oracle Blog Strengths | Nimble OKE Strengths |
|----------|------------------|-----------------|
| **Storage** | ✅ Centralized model repository (Object Storage)<br/>✅ Multi-environment model sharing | ✅ PVC model caching (speedup not measured)<br/>✅ Session cost tracking |
| **Operations** | ✅ Production observability (metrics, dashboards)<br/>✅ Autoscaling (HPA-based) | ✅ 100% idempotent (safe re-runs)<br/>✅ Automatic cleanup (fail-safe)<br/>✅ Runbook automation (Makefile) |
| **Performance** | ✅ Performance optimization (TensorRT-LLM) | ✅ Proactive cost guards (prevent surprise bills) |

---

## 📋 Feature Matrix

| Capability | Oracle Blog | Nimble OKE |
|------------|-------------|------------|
| **Deployment** |
| First deployment | Not re-verified | Not measured yet |
| Subsequent deployments | Not re-verified | Not measured yet |
| Helm-based | ✅ | ✅ |
| Makefile automation | ❌ | ✅ |
| **Storage** |
| Model caching | Object Storage | Block Volume (PVC) |
| Cache warmup | Every pod start | Once per cluster |
| Cross-cluster sharing | ✅ | ❌ |
| **Operations** |
| Idempotent ops | Not specified | ✅ 100% |
| Cost guards | ❌ | ✅ Proactive |
| Auto cleanup | ❌ | ✅ On failure |
| Session tracking | ❌ | ✅ Cost + time |
| **Observability** |
| Structured logs | Basic | ✅ [NIM-OKE] |
| Prometheus metrics | ✅ | ❌ (roadmap) |
| Grafana dashboards | ✅ | ❌ (roadmap) |
| **Scalability** |
| Horizontal scaling | ✅ HPA | Manual |
| Autoscaling | ✅ | ❌ (roadmap) |
| Multi-replica | ✅ | ✅ (basic) |
| **Security** |
| Non-root | ✅ | ✅ |
| Seccomp | ✅ Runtime/Default | Disabled (GPU compat) |
| Network policies | ✅ | ❌ (roadmap) |
| **Performance** |
| TensorRT-LLM | ✅ | ❌ (roadmap) |
| Quantization | ✅ (int8/fp16) | ❌ (roadmap) |
| Benchmarking | ✅ GenAI-Perf | ❌ (roadmap) |

---

## 🚀 Migration Path

### Development → Production

**Phase 1: Develop with Nimble OKE**
```bash
# Fast iteration, cost-controlled testing
make provision CONFIRM_COST=yes  # 15min
make install
make verify                       # 2min
make cleanup                      # 2min
# Cost: $10.50 for a 5-hour test, plus LB and storage
```

**Phase 2: Adopt Oracle Patterns (Gradual)**
```bash
# 1. Add monitoring (optional)
helm upgrade --set monitoring.enabled=true

# 2. Switch to Object Storage (if multi-env)
helm upgrade --set model.source=object-storage

# 3. Enable autoscaling (if variable load)
helm upgrade --set autoscaling.enabled=true

# 4. Add TensorRT-LLM (if latency critical)
helm upgrade --set model.optimization.tensorrt=true
```

---

## 🎓 Recommendations by Scenario

| Scenario | Recommendation | Rationale |
|----------|---------------|-----------|
| **First-time NIM evaluation** | Nimble OKE | Fast setup, cost guards prevent mistakes, idempotent operations safe to retry |
| **Multi-environment CI/CD (dev/stage/prod)** | Oracle Blog pattern | Centralized model repository, Object Storage versioning, autoscaling |
| **Production 24/7 inference service** | Oracle Blog + Nimble automation | Need monitoring, autoscaling, but want Nimble's cleanup/idempotency |
| **Cost-sensitive POC (small budget)** | Nimble OKE | Time-boxed testing, cost guards, automatic cleanup prevents overspend |
| **Performance-critical production (low latency)** | Oracle Blog pattern | TensorRT-LLM, quantization, optimization pipeline |
| **Rapid iteration during development** | Nimble OKE | PVC model caching, idempotent operations |

---

## ⚙️ Hybrid Configuration Example

**Best of both worlds:**

```yaml
# values.yaml - Hybrid configuration
model:
  source: "pvc"  # Switch to "object-storage" for prod
  objectStorage:
    enabled: false  # Enable for prod
    bucketName: "nimble-oke-models"
  cache:
    enabled: true
    size: 200Gi

autoscaling:
  enabled: false  # Enable for prod

monitoring:
  enabled: false  # Enable for prod
  prometheus:
    enabled: false
  grafana:
    enabled: false

# Nimble OKE features (always on)
costOptimization:
  scheduleDowntime: false  # Dev/test pattern

# Oracle Blog features (enable for prod)
optimization:
  tensorrt: false  # Enable for prod
  quantization: "none"  # Set to int8/fp16 for prod
```

**Deploy strategy:**
```bash
# Development
helm install nim ./helm -f values.dev.yaml

# Production
helm install nim ./helm -f values.prod.yaml
```

---

## Performance Expectations

| Metric | Oracle Blog Pattern | Nimble OKE Pattern |
|--------|-------------------|-------------------|
| **First deployment** | Download from Object Storage | Download + cache to PVC (time not measured) |
| **Subsequent deployments** | No persistent cache | Cached models (time not measured) |
| **Inference latency** | Lower (with TensorRT-LLM) | Standard (stock NIM) |
| **Throughput** | Higher (with optimization) | Standard (stock NIM) |

---

## 🔧 Quick Setup Commands

### Oracle Blog Approach
```bash
# Manual Helm deployment
helm repo add oci https://...
kubectl create namespace nim
kubectl create secret docker-registry <pull-secret> --docker-server=nvcr.io
helm install nim oci/nvidia-nim -n nim -f values.yaml
kubectl wait --for=condition=ready pod -l app=nim --timeout=1200s
```

### Nimble OKE Approach
```bash
# Makefile-driven automation
export NGC_API_KEY=nvapi-xxx
make provision CONFIRM_COST=yes  # Create cluster (once)
make install                      # Deploy + verify
make cleanup                      # Remove NIM release only
make teardown                     # Delete node pool + cluster (stops GPU billing)
```

---

## 💡 When to Switch Approaches

| Migration Direction | When to Switch | Use Cases |
|---------------------|---------------|-----------|
| **Nimble → Oracle** | ✅ Moving to production<br/>✅ Multi-environment deployments<br/>✅ Cost less important than performance<br/>✅ Regulatory compliance requires network policies | Production inference services<br/>Enterprise deployments<br/>Compliance requirements |
| **Oracle → Nimble** | ✅ Rapid iteration more important<br/>✅ Budget-constrained development<br/>✅ Single-cluster workflow sufficient<br/>✅ Need fail-safe automation | Development/testing<br/>Cost-sensitive POCs<br/>Rapid prototyping |
| **Use Both** | ✅ Dev/test with Nimble, deploy with Oracle<br/>✅ Nimble automation + Oracle observability<br/>✅ Gradual migration to production | Hybrid workflows<br/>Gradual production migration<br/>Best of both worlds |

---

## 📞 Support Resources

### Nimble OKE
- README: `README.md`
- Runbook: `docs/RUNBOOK.md`
- Quick Start: `QUICKSTART.md`
- Comparison: `docs/ORACLE_BLOG_COMPARISON.md`

### Oracle Blog
- Blog post: https://blogs.oracle.com/ai-and-datascience/post/running-nim-on-oke-for-llm-inference
- NVIDIA NIM docs: https://docs.nvidia.com/nim/
- OCI docs: https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm

---

**Quick decision:** Dev/test → Nimble OKE | Production → Oracle Blog pattern | Both → Hybrid approach

