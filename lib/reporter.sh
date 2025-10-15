#!/bin/bash
# reporter.sh - Reporting and logging functions
# Generates human-readable reports and CSV statistics
#
# Copyright (c) 2025 Jun Zhang
# Licensed under the MIT License. See LICENSE file in the project root.

# Generate comprehensive status report
generate_report() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local interface=$(get_primary_interface)

    # Collect current metrics
    local cpu_target=$CPU_TARGET_PERCENT
    local cpu_total=$(get_cpu_usage)
    local cpu_organic=$(get_organic_cpu)
    local cpu_synthetic=$(get_synthetic_cpu)

    read -r rx_total tx_total bw_total < <(get_bandwidth_mbps "$interface")
    read -r rx_org tx_org bw_organic < <(get_organic_bandwidth "$interface")
    read -r rx_synth tx_synth bw_synthetic < <(get_synthetic_bandwidth)

    local bw_target=$BANDWIDTH_TARGET_MBPS

    # Calculate percentages
    local cpu_organic_pct=$(calculate_percentage "$cpu_organic" "$cpu_target")
    local cpu_synthetic_pct=$(calculate_percentage "$cpu_synthetic" "$cpu_target")
    local cpu_status=$(get_status_indicator "$cpu_total" "$cpu_target")

    local bw_organic_pct=$(calculate_percentage "$bw_organic" "$bw_target")
    local bw_synthetic_pct=$(calculate_percentage "$bw_synthetic" "$bw_target")
    local bw_status=$(get_status_indicator "$bw_total" "$bw_target")

    # Get system info
    read -r load1 load5 load15 < <(get_load_average)
    read -r mem_used mem_total < <(get_memory_usage)

    # Get controller state
    eval "$(get_controller_state)"

    # Generate report
    cat <<EOF
=== Load Generator Report ===
Timestamp: $timestamp

CPU Status:
  Target:    ${cpu_target}%
  Organic:   ${cpu_organic}%  (${cpu_organic_pct}% of target)
  Synthetic: ${cpu_synthetic}%  (${cpu_synthetic_pct}% of target)
  Total:     ${cpu_total}%  $cpu_status

Bandwidth Status:
  Target:    ${bw_target} Mbps
  Organic:   ${bw_organic} Mbps   (${bw_organic_pct}% of target)
  Synthetic: ${bw_synthetic} Mbps   (${bw_synthetic_pct}% of target)
  Total:     ${bw_total} Mbps  $bw_status
  Interface: $interface

Active Generators:
  - CPU: ${CPU_WORKERS} workers @ ${CPU_LOAD_PERCENT}% load
  - Bandwidth: ${BW_DOWNLOADERS} downloaders @ ${BW_RATE_MBPS} Mbps each

System Health:
  - Load Average: $load1, $load5, $load15
  - Memory: ${mem_used}MB / ${mem_total}MB
  - Network: $interface active

============================
EOF
}

# Calculate percentage of actual vs target
# Args: $1 = actual value
#       $2 = target value
# Returns: percentage (0-100+)
calculate_percentage() {
    local actual="$1"
    local target="$2"

    if (( $(echo "$target <= 0" | bc -l) )); then
        echo "0"
        return
    fi

    local pct=$(echo "scale=0; ($actual * 100) / $target" | bc)
    echo "$pct"
}

# Get status indicator based on how close actual is to target
# Args: $1 = actual value
#       $2 = target value
# Returns: status string
get_status_indicator() {
    local actual="$1"
    local target="$2"

    local diff=$(echo "$actual - $target" | bc)
    local abs_diff=$(echo "$diff" | tr -d '-')

    if (( $(echo "$abs_diff <= $MIN_ADJUSTMENT_THRESHOLD" | bc -l) )); then
        echo "(✓ ON TARGET)"
    elif (( $(echo "$diff > 0" | bc -l) )); then
        echo "(↑ ABOVE TARGET)"
    else
        echo "(↓ BELOW TARGET)"
    fi
}

# Log statistics to CSV file
log_stats_csv() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local interface=$(get_primary_interface)

    # Collect metrics
    local cpu_target=$CPU_TARGET_PERCENT
    local cpu_total=$(get_cpu_usage)
    local cpu_organic=$(get_organic_cpu)
    local cpu_synthetic=$(get_synthetic_cpu)

    read -r rx_total tx_total bw_total < <(get_bandwidth_mbps "$interface")
    read -r rx_org tx_org bw_organic < <(get_organic_bandwidth "$interface")
    read -r rx_synth tx_synth bw_synthetic < <(get_synthetic_bandwidth)

    local bw_target=$BANDWIDTH_TARGET_MBPS

    # Ensure stats file exists with header
    if [ ! -f "$STATS_FILE" ]; then
        mkdir -p "$(dirname "$STATS_FILE")"
        echo "timestamp,cpu_target,cpu_organic,cpu_synthetic,cpu_total,bw_target,bw_organic,bw_synthetic,bw_total" > "$STATS_FILE"
    fi

    # Append stats
    echo "$timestamp,$cpu_target,$cpu_organic,$cpu_synthetic,$cpu_total,$bw_target,$bw_organic,$bw_synthetic,$bw_total" >> "$STATS_FILE"
}

# Write report to log file
write_report_to_file() {
    local report=$(generate_report)

    # Ensure report file exists
    if [ ! -f "$REPORT_FILE" ]; then
        mkdir -p "$(dirname "$REPORT_FILE")"
        touch "$REPORT_FILE"
    fi

    # Write report
    echo "$report" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
}

# Display report to stdout
display_report() {
    generate_report
}

# Get quick status summary (one-liner)
get_quick_status() {
    local cpu_total=$(get_cpu_usage)
    local cpu_target=$CPU_TARGET_PERCENT

    local interface=$(get_primary_interface)
    read -r rx tx bw_total < <(get_bandwidth_mbps "$interface")
    local bw_target=$BANDWIDTH_TARGET_MBPS

    echo "CPU: ${cpu_total}%/${cpu_target}% | BW: ${bw_total}Mbps/${bw_target}Mbps"
}

# Rotate log files if they get too large
rotate_logs() {
    local max_size_mb=100

    # Check report file
    if [ -f "$REPORT_FILE" ]; then
        local size_mb=$(du -m "$REPORT_FILE" | cut -f1)
        if [ "$size_mb" -gt "$max_size_mb" ]; then
            log_info "Rotating report file (${size_mb}MB)"
            mv "$REPORT_FILE" "${REPORT_FILE}.old"
            gzip "${REPORT_FILE}.old" &
        fi
    fi

    # Check stats file
    if [ -f "$STATS_FILE" ]; then
        local size_mb=$(du -m "$STATS_FILE" | cut -f1)
        if [ "$size_mb" -gt "$max_size_mb" ]; then
            log_info "Rotating stats file (${size_mb}MB)"

            # Keep header
            head -1 "$STATS_FILE" > "${STATS_FILE}.tmp"
            mv "$STATS_FILE" "${STATS_FILE}.old"
            mv "${STATS_FILE}.tmp" "$STATS_FILE"
            gzip "${STATS_FILE}.old" &
        fi
    fi
}

# Generate HTML report (optional, for web viewing)
generate_html_report() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local report=$(generate_report | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

    cat <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Load Generator Status - $timestamp</title>
    <meta http-equiv="refresh" content="60">
    <style>
        body { font-family: monospace; background: #1e1e1e; color: #d4d4d4; padding: 20px; }
        pre { background: #2d2d2d; padding: 15px; border-radius: 5px; }
        h1 { color: #4ec9b0; }
    </style>
</head>
<body>
    <h1>Load Generator Status</h1>
    <pre>$report</pre>
    <p><small>Auto-refreshes every 60 seconds</small></p>
</body>
</html>
EOF
}

# Export report to HTML file
export_html_report() {
    local html_file="${REPORT_FILE%.log}.html"
    generate_html_report > "$html_file"
    log_debug "HTML report exported to $html_file"
}

# Generate summary statistics
generate_summary_stats() {
    if [ ! -f "$STATS_FILE" ]; then
        echo "No statistics available yet"
        return
    fi

    local total_lines=$(wc -l < "$STATS_FILE")
    local data_lines=$((total_lines - 1))

    if [ "$data_lines" -le 0 ]; then
        echo "No data points collected yet"
        return
    fi

    echo "=== Summary Statistics ==="
    echo "Data points collected: $data_lines"
    echo ""

    # Calculate averages using awk
    tail -n +2 "$STATS_FILE" | awk -F',' '
    {
        cpu_total += $5
        cpu_organic += $3
        cpu_synthetic += $4
        bw_total += $9
        bw_organic += $7
        bw_synthetic += $8
        count++
    }
    END {
        if (count > 0) {
            printf "Average CPU Total: %.1f%%\n", cpu_total/count
            printf "Average CPU Organic: %.1f%%\n", cpu_organic/count
            printf "Average CPU Synthetic: %.1f%%\n", cpu_synthetic/count
            printf "\n"
            printf "Average BW Total: %.1f Mbps\n", bw_total/count
            printf "Average BW Organic: %.1f Mbps\n", bw_organic/count
            printf "Average BW Synthetic: %.1f Mbps\n", bw_synthetic/count
        }
    }'

    echo "=========================="
}
