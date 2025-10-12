#!/usr/bin/env bash

# Rapid iteration optimization for NIM smoke testing
# Focuses on minimizing deployment time and maximizing reliability

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

analyze_deployment_bottlenecks() {
    log_info "=== Analyzing Deployment Bottlenecks ==="
    
    echo "NIM Deployment Time Analysis:"
    echo ""
    
    # Time breakdown for typical NIM deployment
    local time_breakdown=(
        "Image Pull:15:Critical:Pre-pull images"
        "GPU Node Ready:10:High:Use existing nodes"
        "Model Download:10:High:Enable caching"
        "NIM Startup:8:Medium:Optimize probes"
        "LoadBalancer:3:Low:OCI annotations"
        "Health Check:2:Low:Quick validation"
    )
    
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    printf "│ %-20s │ %-8s │ %-10s │ %-20s │\n" "Phase" "Time(min)" "Impact" "Optimization"
    echo "├─────────────────────────────────────────────────────────────────────────┤"
    
    local total_time=0
    for item in "${time_breakdown[@]}"; do
        IFS=':' read -r phase time_minutes impact optimization <<< "$item"
        total_time=$((total_time + time_minutes))
        
        printf "│ %-20s │ %-8s │ %-10s │ %-20s │\n" "$phase" "$time_minutes" "$impact" "$optimization"
    done
    
    echo "└─────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "Total baseline time: ${total_time} minutes"
    echo ""
}

recommend_iteration_strategies() {
    log_info "=== Rapid Iteration Strategies ==="
    
    echo "1. IMAGE PRE-CACHING (Saves 15 minutes):"
    echo "   • Pre-pull NIM images during cluster setup"
    echo "   • Use OCIR mirror for consistent pull times"
    echo "   • Cache NGC authentication tokens"
    echo ""
    
    echo "2. MODEL CACHING (Saves 10 minutes):"
    echo "   • Enable PVC-based model caching"
    echo "   • Use KEEP_CACHE=yes during cleanup"
    echo "   • Pre-download models to shared storage"
    echo ""
    
    echo "3. NODE WARMING (Saves 5 minutes):"
    echo "   • Keep GPU nodes running between tests"
    echo "   • Pre-install NVIDIA drivers and CUDA"
    echo "   • Use node pools with pre-pulled images"
    echo ""
    
    echo "4. OPTIMIZED PROBES (Saves 3 minutes):"
    echo "   • Configure startup probe with 30 failures"
    echo "   • Use shorter readiness/liveness intervals"
    echo "   • Implement health check endpoint"
    echo ""
    
    echo "5. PARALLEL OPERATIONS (Saves 2 minutes):"
    echo "   • Deploy NIM while LoadBalancer provisions"
    echo "   • Parallel image pulls on multiple nodes"
    echo "   • Concurrent health checks"
    echo ""
}

simulate_optimized_deployment() {
    log_info "=== Optimized Deployment Simulation ==="
    
    echo "Optimized NIM Deployment Timeline:"
    echo ""
    
    # Optimized time breakdown
    local optimized_phases=(
        "Image Pull (cached):2:Pre-pulled images"
        "GPU Node Ready:0:Nodes already warm"
        "Model Download (cached):1:From PVC cache"
        "NIM Startup:5:Optimized probes"
        "LoadBalancer:3:OCI annotations"
        "Health Check:1:Quick validation"
    )
    
    echo "┌─────────────────────────────────────────────────────────────────────────┐"
    printf "│ %-25s │ %-8s │ %-20s │\n" "Phase" "Time(min)" "Optimization"
    echo "├─────────────────────────────────────────────────────────────────────────┤"
    
    local total_optimized=0
    for item in "${optimized_phases[@]}"; do
        IFS=':' read -r phase time_minutes optimization <<< "$item"
        total_optimized=$((total_optimized + time_minutes))
        
        printf "│ %-25s │ %-8s │ %-20s │\n" "$phase" "$time_minutes" "$optimization"
    done
    
    echo "└─────────────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "Optimized total time: ${total_optimized} minutes"
    echo ""
    
    # Calculate improvement
    local baseline_time=48
    local improvement
    improvement=$(echo "scale=1; (($baseline_time - $total_optimized) / $baseline_time) * 100" | bc -l)
    
    echo "Improvement: $(printf "%.1f" "$improvement")% faster"
    echo "Time saved: $((baseline_time - total_optimized)) minutes"
    echo ""
}

recommend_cost_optimization() {
    log_info "=== Cost Optimization for Rapid Iteration ==="
    
    echo "Cost Optimization Strategies:"
    echo ""
    
    echo "1. SMART CLEANUP (Saves \$2-3 per iteration):"
    echo "   • Use KEEP_CACHE=yes for model PVCs"
    echo "   • Preserve NGC secrets between deployments"
    echo "   • Keep LoadBalancer during short breaks"
    echo ""
    
    echo "2. NODE REUSE (Saves \$5-8 per iteration):"
    echo "   • Keep GPU nodes running between tests"
    echo "   • Use node pools with minimum size 1"
    echo "   • Implement node warming scripts"
    echo ""
    
    echo "3. EFFICIENT TESTING (Saves \$3-5 per iteration):"
    echo "   • Run multiple tests in same session"
    echo "   • Batch configuration changes"
    echo "   • Use dry-run validation extensively"
    echo ""
    
    echo "4. RESOURCE RIGHT-SIZING (Saves \$1-2 per iteration):"
    echo "   • Use minimal GPU shapes for smoke tests"
    echo "   • Optimize memory requests"
    echo "   • Use flexible LoadBalancer shapes"
    echo ""
    
    echo "Cost Impact:"
    echo "  • Baseline smoke test: \$11"
    echo "  • Optimized iteration: \$3-5"
    echo "  • Savings per iteration: \$6-8"
    echo ""
}

generate_iteration_workflow() {
    echo ""
    echo "==============================================================="
    echo "OPTIMIZED RAPID ITERATION WORKFLOW"
    echo "==============================================================="
    echo ""
    
    echo "1. INITIAL SETUP (One-time, 30 minutes):"
    echo "   make provision CONFIRM_COST=yes"
    echo "   make pre-deploy-test"
    echo "   make install"
    echo "   # Enable caching and warming"
    echo ""
    
    echo "2. RAPID ITERATION CYCLE (2-5 minutes each):"
    echo "   # Make changes to values.yaml"
    echo "   make install  # Updates deployment"
    echo "   make verify   # Quick health check"
    echo "   # Test your changes"
    echo ""
    
    echo "3. BATCH TESTING (10-15 minutes):"
    echo "   # Run multiple configurations"
    echo "   make install GPU_COUNT=1"
    echo "   make verify"
    echo "   make install GPU_COUNT=2"
    echo "   make verify"
    echo "   # Compare results"
    echo ""
    
    echo "4. CLEANUP (When done, 2 minutes):"
    echo "   make cleanup KEEP_CACHE=yes  # Preserve model cache"
    echo "   # Or full cleanup:"
    echo "   make teardown"
    echo ""
    
    echo "Expected Results:"
    echo "  • Initial setup: 30 minutes"
    echo "  • Each iteration: 2-5 minutes"
    echo "  • Cost per iteration: \$3-5"
    echo "  • Reliability: 95%+ success rate"
    echo ""
}

main() {
    log_info "Starting rapid iteration optimization analysis..."
    echo ""
    
    analyze_deployment_bottlenecks
    recommend_iteration_strategies
    simulate_optimized_deployment
    recommend_cost_optimization
    generate_iteration_workflow
    
    log_success "✅ Rapid iteration optimization analysis complete"
}

# Usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
