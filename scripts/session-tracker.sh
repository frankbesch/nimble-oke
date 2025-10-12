#!/usr/bin/env bash

# Session tracking for Nimble OKE workflow optimization
# Tracks duration, costs, and obstacles for continuous improvement

set -euo pipefail

readonly SESSION_DIR="${HOME}/.nimble-oke/sessions"
readonly SESSION_FILE="${SESSION_DIR}/session-$(date +%Y%m%d-%H%M%S).json"
readonly CURRENT_SESSION="${SESSION_DIR}/current.json"

# Initialize session tracking
init_session() {
    local session_id="$1"
    local operation="$2"
    
    mkdir -p "$SESSION_DIR"
    
    # Create session record
    cat > "$SESSION_FILE" <<EOF
{
  "session_id": "$session_id",
  "operation": "$operation",
  "start_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "start_timestamp": $(date +%s),
  "environment": "${ENVIRONMENT:-dev}",
  "region": "${OCI_REGION:-us-phoenix-1}",
  "phases": {},
  "obstacles": [],
  "costs": {
    "estimated_hourly": 0,
    "actual_hourly": 0,
    "session_total": 0
  },
  "performance": {
    "total_duration": 0,
    "phase_breakdown": {},
    "efficiency_score": 0
  }
}
EOF
    
    # Link current session
    ln -sf "$(basename "$SESSION_FILE")" "$CURRENT_SESSION"
    
    echo "$SESSION_FILE"
}

# Start phase tracking
start_phase() {
    local phase="$1"
    local phase_start=$(date +%s)
    
    # Update current session
    if [[ -f "$CURRENT_SESSION" ]]; then
        local session_file=$(readlink -f "$CURRENT_SESSION")
        local temp_file=$(mktemp)
        
        jq --arg phase "$phase" \
           --arg start_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --argjson start_timestamp "$phase_start" \
           '.phases[$phase] = {
             start_time: $start_time,
             start_timestamp: $start_timestamp,
             duration: 0,
             obstacles: [],
             cost_impact: 0
           }' "$session_file" > "$temp_file" && mv "$temp_file" "$session_file"
    fi
    
    echo "$phase_start" > "/tmp/nimble-oke-phase-${phase}-start"
}

# End phase tracking
end_phase() {
    local phase="$1"
    local phase_end=$(date +%s)
    local start_file="/tmp/nimble-oke-phase-${phase}-start"
    
    if [[ -f "$start_file" ]]; then
        local phase_start=$(cat "$start_file")
        local duration=$((phase_end - phase_start))
        
        # Update current session
        if [[ -f "$CURRENT_SESSION" ]]; then
            local session_file=$(readlink -f "$CURRENT_SESSION")
            local temp_file=$(mktemp)
            
            jq --arg phase "$phase" \
               --arg end_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
               --argjson end_timestamp "$phase_end" \
               --argjson duration "$duration" \
               '.phases[$phase].end_time = $end_time |
                .phases[$phase].end_timestamp = $end_timestamp |
                .phases[$phase].duration = $duration' "$session_file" > "$temp_file" && mv "$temp_file" "$session_file"
        fi
        
        rm -f "$start_file"
        echo "$duration"
    else
        echo "0"
    fi
}

# Log obstacle
log_obstacle() {
    local phase="$1"
    local obstacle_type="$2"
    local description="$3"
    local root_cause="$4"
    local fix="$5"
    local time_delay="$6"
    local cost_impact="$7"
    
    local obstacle_id="obs-$(date +%s)-$$"
    
    if [[ -f "$CURRENT_SESSION" ]]; then
        local session_file=$(readlink -f "$CURRENT_SESSION")
        local temp_file=$(mktemp)
        
        local obstacle_json=$(jq -n \
            --arg id "$obstacle_id" \
            --arg phase "$phase" \
            --arg type "$obstacle_type" \
            --arg description "$description" \
            --arg root_cause "$root_cause" \
            --arg fix "$fix" \
            --argjson time_delay "$time_delay" \
            --argjson cost_impact "$cost_impact" \
            --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{
              id: $id,
              phase: $phase,
              type: $type,
              description: $description,
              root_cause: $root_cause,
              fix: $fix,
              time_delay_seconds: $time_delay,
              cost_impact_usd: $cost_impact,
              timestamp: $timestamp
            }')
        
        jq --arg phase "$phase" \
           --argjson obstacle "$obstacle_json" \
           '.obstacles += [$obstacle] |
            .phases[$phase].obstacles += [$obstacle.id]' "$session_file" > "$temp_file" && mv "$temp_file" "$session_file"
    fi
    
    echo "[SESSION][OBSTACLE] $phase: $description (${time_delay}s, \$${cost_impact})"
}

# Update cost tracking
update_costs() {
    local estimated_hourly="$1"
    local actual_hourly="$2"
    
    if [[ -f "$CURRENT_SESSION" ]]; then
        local session_file=$(readlink -f "$CURRENT_SESSION")
        local temp_file=$(mktemp)
        
        jq --argjson estimated "$estimated_hourly" \
           --argjson actual "$actual_hourly" \
           '.costs.estimated_hourly = $estimated |
            .costs.actual_hourly = $actual |
            .costs.session_total = ($actual * (.performance.total_duration / 3600))' "$session_file" > "$temp_file" && mv "$temp_file" "$session_file"
    fi
}

# Calculate performance metrics
calculate_performance() {
    if [[ -f "$CURRENT_SESSION" ]]; then
        local session_file=$(readlink -f "$CURRENT_SESSION")
        local temp_file=$(mktemp)
        
        # Calculate total duration and efficiency
        local total_duration=$(jq -r '.phases | to_entries | map(.value.duration) | add // 0' "$session_file")
        local obstacle_count=$(jq -r '.obstacles | length' "$session_file")
        local total_obstacle_time=$(jq -r '.obstacles | map(.time_delay_seconds) | add // 0' "$session_file")
        
        # Efficiency score: (planned_time / actual_time) * 100
        # Higher score = more efficient (fewer delays)
        local planned_time=$((total_duration - total_obstacle_time))
        local efficiency_score=0
        if [[ $total_duration -gt 0 ]]; then
            efficiency_score=$(echo "scale=1; ($planned_time * 100) / $total_duration" | bc -l)
        fi
        
        jq --argjson total_duration "$total_duration" \
           --argjson obstacle_count "$obstacle_count" \
           --argjson total_obstacle_time "$total_obstacle_time" \
           --argjson efficiency_score "$efficiency_score" \
           '.performance.total_duration = $total_duration |
            .performance.obstacle_count = $obstacle_count |
            .performance.total_obstacle_time = $total_obstacle_time |
            .performance.efficiency_score = $efficiency_score |
            .end_time = (now | strftime("%Y-%m-%dT%H:%M:%SZ")) |
            .end_timestamp = now' "$session_file" > "$temp_file" && mv "$temp_file" "$session_file"
        
        echo "$efficiency_score"
    else
        echo "0"
    fi
}

# Generate session summary
generate_summary() {
    if [[ -f "$CURRENT_SESSION" ]]; then
        local session_file=$(readlink -f "$CURRENT_SESSION")
        local session_id=$(jq -r '.session_id' "$session_file")
        
        echo ""
        echo "==============================================================="
        echo "SESSION SUMMARY: $session_id"
        echo "==============================================================="
        echo ""
        
        # Basic info
        echo "Operation: $(jq -r '.operation' "$session_file")"
        echo "Environment: $(jq -r '.environment' "$session_file")"
        echo "Region: $(jq -r '.region' "$session_file")"
        echo "Total Duration: $(jq -r '.performance.total_duration' "$session_file")s ($(echo "scale=1; $(jq -r '.performance.total_duration' "$session_file") / 60" | bc -l)min)"
        echo "Efficiency Score: $(jq -r '.performance.efficiency_score' "$session_file")%"
        echo ""
        
        # Phase breakdown
        echo "=== PHASE BREAKDOWN ==="
        jq -r '.phases | to_entries[] | "\(.key): \(.value.duration)s (\(.value.obstacles | length) obstacles)"' "$session_file"
        echo ""
        
        # Cost summary
        echo "=== COST SUMMARY ==="
        echo "Estimated Hourly: \$$(jq -r '.costs.estimated_hourly' "$session_file")"
        echo "Actual Hourly: \$$(jq -r '.costs.actual_hourly' "$session_file")"
        echo "Session Total: \$$(jq -r '.costs.session_total' "$session_file")"
        echo ""
        
        # Obstacles
        local obstacle_count=$(jq -r '.obstacles | length' "$session_file")
        if [[ "$obstacle_count" -gt 0 ]]; then
            echo "=== OBSTACLES ($obstacle_count) ==="
            jq -r '.obstacles[] | "\(.phase): \(.description) (\(.time_delay_seconds)s, \$$.cost_impact_usd) - \(.root_cause)"' "$session_file"
            echo ""
        fi
        
        echo "==============================================================="
        echo ""
        
        # Save to sessions directory
        local summary_file="${SESSION_DIR}/summary-${session_id}.txt"
        jq -r '. | "SESSION: \(.session_id) | \(.operation) | \(.environment) | \(.performance.total_duration)s | \(.performance.efficiency_score)% | $\(.costs.session_total) | \(.obstacles | length) obstacles"' "$session_file" >> "${SESSION_DIR}/all-sessions.txt"
        
        echo "Session saved: $session_file"
        echo "Summary saved: $summary_file"
        echo "All sessions: ${SESSION_DIR}/all-sessions.txt"
    fi
}

# Compare with previous sessions
compare_sessions() {
    local current_file="$1"
    
    if [[ -f "${SESSION_DIR}/all-sessions.txt" ]] && [[ $(wc -l < "${SESSION_DIR}/all-sessions.txt") -gt 1 ]]; then
        echo ""
        echo "=== SESSION COMPARISON ==="
        echo ""
        
        # Show last 5 sessions
        echo "Recent Sessions:"
        tail -5 "${SESSION_DIR}/all-sessions.txt" | while IFS='|' read -r session operation env duration efficiency cost obstacles; do
            printf "%-20s %-12s %-6s %8s %6s%% %8s %2s obs\n" \
                "${session#SESSION: }" "$operation" "$env" "$duration" "$efficiency" "$cost" "$obstacles"
        done
        echo ""
        
        # Calculate improvements
        local current_duration=$(jq -r '.performance.total_duration' "$current_file")
        local current_efficiency=$(jq -r '.performance.efficiency_score' "$current_file")
        local current_cost=$(jq -r '.costs.session_total' "$current_file")
        
        echo "Improvement Opportunities:"
        echo "- Duration: Target < $(echo "scale=0; $current_duration * 0.8" | bc -l)s (20% faster)"
        echo "- Efficiency: Target > $(echo "scale=1; $current_efficiency + 10" | bc -l)% (10% improvement)"
        echo "- Cost: Monitor for \$$(echo "scale=2; $current_cost * 1.1" | bc -l) threshold"
        echo ""
    fi
}

# Main execution
case "${1:-}" in
    "init")
        init_session "$2" "$3"
        ;;
    "start-phase")
        start_phase "$2"
        ;;
    "end-phase")
        end_phase "$2"
        ;;
    "log-obstacle")
        log_obstacle "$2" "$3" "$4" "$5" "$6" "$7" "$8"
        ;;
    "update-costs")
        update_costs "$2" "$3"
        ;;
    "calculate-performance")
        calculate_performance
        ;;
    "summary")
        generate_summary
        ;;
    "compare")
        compare_sessions "$2"
        ;;
    *)
        echo "Usage: $0 {init|start-phase|end-phase|log-obstacle|update-costs|calculate-performance|summary|compare}"
        echo ""
        echo "Commands:"
        echo "  init <session_id> <operation>     - Initialize new session"
        echo "  start-phase <phase>               - Start phase tracking"
        echo "  end-phase <phase>                 - End phase tracking"
        echo "  log-obstacle <phase> <type> <desc> <cause> <fix> <delay> <cost>"
        echo "  update-costs <estimated> <actual> - Update cost tracking"
        echo "  calculate-performance             - Calculate final metrics"
        echo "  summary                           - Generate session summary"
        echo "  compare <session_file>            - Compare with previous sessions"
        exit 1
        ;;
esac
