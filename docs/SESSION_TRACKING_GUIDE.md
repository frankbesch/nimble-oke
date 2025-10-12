# Session Tracking Guide - Nimble OKE

Comprehensive workflow optimization through duration, cost, and obstacle tracking.

## Overview

The session tracking system captures complete workflow metrics for continuous improvement:

- **Duration tracking** - Phase-by-phase timing
- **Cost tracking** - Estimated vs actual costs
- **Obstacle logging** - Root cause analysis with time/cost impact
- **Performance metrics** - Efficiency scoring and comparison

## Quick Start

### 1. Initialize Session

```bash
# Automatic initialization (recommended)
make all  # Session tracking starts automatically

# Manual initialization
make session-init
```

### 2. Run Workflow

```bash
# Complete workflow with tracking
make all

# Individual phases with tracking
make discover
make prereqs
make install
make verify
make cleanup
```

### 3. View Results

```bash
# Current session summary
make session-summary

# Compare with previous sessions
make session-compare
```

## Session Data Structure

### Session File Location

```
~/.nimble-oke/sessions/
├── session-20241012-143022.json  # Individual session
├── current.json                  # Current session link
├── all-sessions.txt              # Summary history
└── summary-*.txt                 # Detailed summaries
```

### Session JSON Structure

```json
{
  "session_id": "session-20241012-143022",
  "operation": "complete-workflow",
  "start_time": "2024-10-12T14:30:22Z",
  "environment": "dev",
  "region": "us-phoenix-1",
  "phases": {
    "discover": {
      "start_time": "2024-10-12T14:30:22Z",
      "end_time": "2024-10-12T14:30:45Z",
      "duration": 23,
      "obstacles": ["obs-1697034645-12345"]
    },
    "prereqs": {
      "start_time": "2024-10-12T14:30:45Z",
      "end_time": "2024-10-12T14:31:12Z",
      "duration": 27,
      "obstacles": []
    }
  },
  "obstacles": [
    {
      "id": "obs-1697034645-12345",
      "phase": "discover",
      "type": "network-timeout",
      "description": "kubectl connection timeout",
      "root_cause": "Firewall blocking kubectl API access",
      "fix": "Added security group rule for port 6443",
      "time_delay_seconds": 45,
      "cost_impact_usd": 0.02,
      "timestamp": "2024-10-12T14:30:45Z"
    }
  ],
  "costs": {
    "estimated_hourly": 1.85,
    "actual_hourly": 1.87,
    "session_total": 0.15
  },
  "performance": {
    "total_duration": 1847,
    "obstacle_count": 1,
    "total_obstacle_time": 45,
    "efficiency_score": 97.6
  }
}
```

## Obstacle Types

### Common Obstacle Categories

```bash
# Network issues
log_obstacle "discover" "network-timeout" "kubectl connection timeout" \
  "Firewall blocking kubectl API access" \
  "Added security group rule for port 6443" 45 0.02

# Resource constraints
log_obstacle "install" "resource-quota" "GPU quota exceeded" \
  "No available GPUs in region" \
  "Switched to different availability domain" 120 0.15

# Image pull issues
log_obstacle "deploy" "image-pull" "NVIDIA NGC image pull failed" \
  "NGC API key expired" \
  "Updated NGC_API_KEY environment variable" 180 0.25

# Configuration errors
log_obstacle "verify" "config-error" "Helm values validation failed" \
  "Invalid GPU resource specification" \
  "Fixed values.yaml GPU limits" 30 0.05

# Performance issues
log_obstacle "verify" "performance" "Pod startup timeout" \
  "Model download taking longer than expected" \
  "Increased readiness probe timeout" 300 0.50
```

### Obstacle Tracking in Scripts

```bash
#!/usr/bin/env bash
source scripts/_lib.sh

# Example: Network timeout handling
check_kubectl_connection() {
    local timeout=30
    local start_time=$(date +%s)
    
    if ! kubectl cluster-info --request-timeout="${timeout}s" >/dev/null 2>&1; then
        local end_time=$(date +%s)
        local delay=$((end_time - start_time))
        
        log_obstacle "discover" "network-timeout" \
            "kubectl connection failed" \
            "Network connectivity issue" \
            "Check firewall and security groups" \
            "$delay" "$(echo "scale=2; $delay * 0.001" | bc -l)"
        
        return 1
    fi
    
    return 0
}
```

## Performance Metrics

### Efficiency Score Calculation

```
Efficiency Score = (Planned Time / Actual Time) × 100

Where:
- Planned Time = Total Duration - Obstacle Time
- Actual Time = Total Duration
- Higher score = more efficient (fewer delays)
```

### Example Efficiency Scores

| Score | Interpretation | Typical Causes |
|-------|----------------|----------------|
| 95-100% | Excellent | Minimal obstacles, smooth execution |
| 85-94% | Good | Few minor obstacles, mostly efficient |
| 70-84% | Fair | Several obstacles, room for improvement |
| <70% | Poor | Many obstacles, significant optimization needed |

## Session Comparison

### Automatic Comparison Features

```bash
make session-compare
```

**Output Example:**
```
=== SESSION COMPARISON ===

Recent Sessions:
session-20241012-143022 complete-workflow dev   1847s 97.6% $0.15 1 obs
session-20241012-120045 complete-workflow dev   2156s 89.2% $0.18 3 obs
session-20241012-091230 smoke-test      dev   1245s 94.1% $0.12 0 obs

Improvement Opportunities:
- Duration: Target < 1478s (20% faster)
- Efficiency: Target > 107.6% (10% improvement)
- Cost: Monitor for $0.17 threshold
```

### Historical Analysis

```bash
# View all session history
cat ~/.nimble-oke/sessions/all-sessions.txt

# Filter by operation type
grep "complete-workflow" ~/.nimble-oke/sessions/all-sessions.txt

# Analyze trends
awk -F'|' '{print $4, $5, $6}' ~/.nimble-oke/sessions/all-sessions.txt | \
  sort -k1 -n
```

## Integration Examples

### 1. Complete Workflow with Tracking

```bash
#!/usr/bin/env bash
# scripts/run-workflow.sh

source scripts/_lib.sh

# Initialize session
init_session "complete-workflow"

# Run workflow with automatic tracking
make discover || { log_obstacle "discover" "workflow-failure" "Discovery phase failed" "Cluster not accessible" "Check cluster status" 0 0; exit 1; }
make prereqs || { log_obstacle "prereqs" "validation-failure" "Prerequisites check failed" "Missing requirements" "Install required tools" 0 0; exit 1; }
make install || { log_obstacle "install" "deployment-failure" "NIM deployment failed" "Resource constraints" "Check GPU availability" 0 0; exit 1; }
make verify || { log_obstacle "verify" "verification-failure" "Health check failed" "Service not responding" "Check pod logs" 0 0; exit 1; }

# End session
end_session
```

### 2. Custom Obstacle Detection

```bash
#!/usr/bin/env bash
# Enhanced timeout handling with obstacle logging

with_timeout_and_obstacle_tracking() {
    local timeout="$1"
    local desc="$2"
    local phase="$3"
    shift 3
    
    local start_time=$(date +%s)
    
    if timeout "$timeout" bash -c "$*"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_success "$desc completed in ${duration}s"
        return 0
    else
        local exit_code=$?
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ $exit_code -eq 124 ]]; then
            log_obstacle "$phase" "timeout" \
                "$desc stalled after ${timeout}s" \
                "Operation exceeded timeout threshold" \
                "Increase timeout or optimize operation" \
                "$timeout" "$(echo "scale=2; $timeout * 0.001" | bc -l)"
        else
            log_obstacle "$phase" "execution-error" \
                "$desc failed with exit code $exit_code" \
                "Command execution error" \
                "Check command syntax and dependencies" \
                "$duration" "$(echo "scale=2; $duration * 0.001" | bc -l)"
        fi
        
        return $exit_code
    fi
}

# Usage
with_timeout_and_obstacle_tracking 300 "kubectl wait for pods" "verify" \
    "kubectl wait --for=condition=ready pod -l app=nvidia-nim --timeout=300s"
```

### 3. Cost Tracking Integration

```bash
#!/usr/bin/env bash
# Enhanced cost tracking with session integration

track_session_costs() {
    local estimated_hourly="$1"
    local actual_hourly="$2"
    
    # Update session costs
    if [[ -x "scripts/session-tracker.sh" ]]; then
        scripts/session-tracker.sh update-costs "$estimated_hourly" "$actual_hourly"
    fi
    
    # Log cost variance
    local variance=$(echo "scale=2; ($actual_hourly - $estimated_hourly) / $estimated_hourly * 100" | bc -l)
    
    if (( $(echo "$variance > 10" | bc -l) )); then
        log_obstacle "cost-tracking" "cost-variance" \
            "Actual cost $variance% higher than estimated" \
            "Cost estimation model needs adjustment" \
            "Update cost calculation algorithms" \
            0 "$(echo "scale=2; $actual_hourly - $estimated_hourly" | bc -l)"
    fi
}
```

## Best Practices

### 1. Obstacle Logging

- **Be specific** - Clear description of what failed
- **Root cause analysis** - Identify underlying issue
- **Actionable fixes** - Specific steps to resolve
- **Accurate timing** - Measure actual delay duration
- **Cost impact** - Calculate monetary impact

### 2. Session Management

- **Initialize early** - Start tracking at workflow beginning
- **End properly** - Always call end_session for final metrics
- **Regular comparison** - Review previous sessions for patterns
- **Cleanup old data** - Archive or remove old session files

### 3. Performance Optimization

- **Identify patterns** - Look for recurring obstacles
- **Set targets** - Define improvement goals
- **Track progress** - Monitor efficiency scores over time
- **Document fixes** - Record successful optimizations

## Troubleshooting

### Common Issues

**Session files not created:**
```bash
# Check permissions
ls -la ~/.nimble-oke/sessions/
mkdir -p ~/.nimble-oke/sessions/
```

**Session tracker not executable:**
```bash
chmod +x scripts/session-tracker.sh
```

**jq not found:**
```bash
# Install jq
brew install jq  # macOS
apt-get install jq  # Ubuntu
```

**Session comparison fails:**
```bash
# Check file existence
ls -la ~/.nimble-oke/sessions/all-sessions.txt
```

### Debug Mode

```bash
# Enable debug output
export DEBUG=1
make session-summary
```

---

**Ready to optimize your workflow?** Start with `make session-init` and track your next deployment!
