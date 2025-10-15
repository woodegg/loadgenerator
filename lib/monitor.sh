#!/bin/bash
# monitor.sh - System monitoring functions for load generator
# Collects CPU usage, bandwidth, and distinguishes organic vs synthetic load
#
# Copyright (c) 2025 Jun Zhang
# Licensed under the MIT License. See LICENSE file in the project root.

# Global variables for tracking
declare -a STRESS_PIDS=()
declare -a BANDWIDTH_PIDS=()
PREV_CPU_STATS=""
PREV_NET_STATS=""
PREV_TIMESTAMP=0

# Get number of CPU cores
get_cpu_cores() {
    nproc
}

# Read CPU stats from /proc/stat
# Returns: user nice system idle iowait irq softirq
read_cpu_stats() {
    awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8}' /proc/stat
}

# Calculate total CPU usage percentage
# Returns: float percentage (0-100)
get_cpu_usage() {
    local current_stats prev_stats
    current_stats=$(read_cpu_stats)

    if [ -z "$PREV_CPU_STATS" ]; then
        PREV_CPU_STATS="$current_stats"
        echo "0"
        return
    fi

    prev_stats="$PREV_CPU_STATS"
    PREV_CPU_STATS="$current_stats"

    # Parse current stats
    read -r user1 nice1 system1 idle1 iowait1 irq1 softirq1 <<< "$current_stats"
    # Parse previous stats
    read -r user0 nice0 system0 idle0 iowait0 irq0 softirq0 <<< "$prev_stats"

    # Calculate deltas
    local user_delta=$((user1 - user0))
    local nice_delta=$((nice1 - nice0))
    local system_delta=$((system1 - system0))
    local idle_delta=$((idle1 - idle0))
    local iowait_delta=$((iowait1 - iowait0))
    local irq_delta=$((irq1 - irq0))
    local softirq_delta=$((softirq1 - softirq0))

    # Calculate total and idle
    local total=$((user_delta + nice_delta + system_delta + idle_delta + iowait_delta + irq_delta + softirq_delta))
    local idle=$((idle_delta))

    # Avoid division by zero
    if [ "$total" -eq 0 ]; then
        echo "0"
        return
    fi

    # Calculate usage percentage
    local usage=$((100 * (total - idle) / total))
    echo "$usage"
}

# Read network interface statistics
# Args: $1 = interface name (default: eth0)
read_net_stats() {
    local interface="${1:-eth0}"

    if [ ! -f "/sys/class/net/$interface/statistics/rx_bytes" ]; then
        echo "0 0"
        return
    fi

    local rx_bytes=$(cat "/sys/class/net/$interface/statistics/rx_bytes")
    local tx_bytes=$(cat "/sys/class/net/$interface/statistics/tx_bytes")

    echo "$rx_bytes $tx_bytes"
}

# Calculate bandwidth in Mbps
# Args: $1 = interface name (default: eth0)
# Returns: rx_mbps tx_mbps total_mbps
get_bandwidth_mbps() {
    local interface="${1:-eth0}"
    local current_stats current_time prev_stats

    current_stats=$(read_net_stats "$interface")
    current_time=$(date +%s)

    if [ -z "$PREV_NET_STATS" ] || [ "$PREV_TIMESTAMP" -eq 0 ]; then
        PREV_NET_STATS="$current_stats"
        PREV_TIMESTAMP="$current_time"
        echo "0 0 0"
        return
    fi

    prev_stats="$PREV_NET_STATS"
    local prev_time="$PREV_TIMESTAMP"

    PREV_NET_STATS="$current_stats"
    PREV_TIMESTAMP="$current_time"

    # Parse stats
    read -r rx1 tx1 <<< "$current_stats"
    read -r rx0 tx0 <<< "$prev_stats"

    # Calculate deltas
    local rx_delta=$((rx1 - rx0))
    local tx_delta=$((tx1 - tx0))
    local time_delta=$((current_time - prev_time))

    # Avoid division by zero
    if [ "$time_delta" -eq 0 ]; then
        echo "0 0 0"
        return
    fi

    # Convert to Mbps (bytes to megabits per second)
    # bytes/sec * 8 / 1000000 = Mbps
    local rx_mbps=$(echo "scale=2; $rx_delta * 8 / $time_delta / 1000000" | bc)
    local tx_mbps=$(echo "scale=2; $tx_delta * 8 / $time_delta / 1000000" | bc)
    local total_mbps=$(echo "scale=2; $rx_mbps + $tx_mbps" | bc)

    echo "$rx_mbps $tx_mbps $total_mbps"
}

# Register stress-ng PID for tracking
register_stress_pid() {
    local pid="$1"
    STRESS_PIDS+=("$pid")
}

# Register bandwidth generator PID for tracking
register_bandwidth_pid() {
    local pid="$1"
    BANDWIDTH_PIDS+=("$pid")
}

# Clear all tracked PIDs (call on actuator restart)
clear_tracked_pids() {
    STRESS_PIDS=()
    BANDWIDTH_PIDS=()
}

# Check if process is running
is_process_running() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# Get CPU usage by specific PIDs (including children)
# Args: $@ = list of PIDs
# Returns: total CPU percentage used by those PIDs and their children
get_pids_cpu_usage() {
    local total_cpu=0
    local pid

    for pid in "$@"; do
        # Skip empty or invalid PIDs
        [ -z "$pid" ] && continue
        [[ ! "$pid" =~ ^[0-9]+$ ]] && continue

        if is_process_running "$pid"; then
            # Get CPU for this PID and all its children
            # Use pgrep to find children, then ps to sum up CPU
            local all_pids="$pid $(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"
            log_debug "get_pids_cpu_usage: PID $pid -> all_pids=$all_pids"

            for cpid in $all_pids; do
                [ -z "$cpid" ] && continue
                local cpu=$(ps -p "$cpid" -o %cpu= 2>/dev/null | tr -d ' ')
                log_debug "get_pids_cpu_usage: cpid=$cpid cpu=$cpu"
                if [ -n "$cpu" ] && [ "$cpu" != "0" ] && [ "$cpu" != "0.0" ]; then
                    total_cpu=$(echo "$total_cpu + $cpu" | bc)
                fi
            done
        fi
    done

    log_debug "get_pids_cpu_usage: total_cpu=$total_cpu"
    echo "$total_cpu"
}

# Get synthetic CPU usage (from our stress generators)
# Returns the configured synthetic load percentage
get_synthetic_cpu() {
    # Load state from file (shared across subprocesses)
    if [ -f "${STATE_FILE:-/var/lib/loadgen/state}" ]; then
        source "${STATE_FILE:-/var/lib/loadgen/state}" 2>/dev/null
    fi

    # Use the tracked synthetic CPU percent (set by actuator when starting stress-ng)
    # This is more reliable than trying to measure instantaneous ps %cpu
    local synth_cpu="${SYNTHETIC_CPU_PERCENT:-0}"
    log_debug "get_synthetic_cpu: synthetic_cpu=${synth_cpu}%"
    echo "$synth_cpu"
}

# Estimate synthetic bandwidth usage
# This is approximate - tracks wget/curl processes
get_synthetic_bandwidth() {
    # Load state from file (shared across subprocesses)
    if [ -f "${STATE_FILE:-/var/lib/loadgen/state}" ]; then
        source "${STATE_FILE:-/var/lib/loadgen/state}" 2>/dev/null
    fi

    # For bandwidth, we track the PIDs but estimation is harder
    # We'll use the configured rate as the synthetic value
    # This will be set by the controller
    echo "${SYNTHETIC_BW_RX:-0} ${SYNTHETIC_BW_TX:-0} ${SYNTHETIC_BW_TOTAL:-0}"
}

# Get organic CPU usage (total - synthetic)
get_organic_cpu() {
    local total_cpu=$(get_cpu_usage)
    local synthetic_cpu=$(get_synthetic_cpu)

    local organic=$(echo "$total_cpu - $synthetic_cpu" | bc)

    # Ensure non-negative
    if (( $(echo "$organic < 0" | bc -l) )); then
        organic=0
    fi

    echo "$organic"
}

# Get organic bandwidth (total - synthetic)
# Args: $1 = interface (default: eth0)
get_organic_bandwidth() {
    local interface="${1:-eth0}"

    read -r rx_total tx_total total_mbps < <(get_bandwidth_mbps "$interface")
    read -r rx_synth tx_synth total_synth < <(get_synthetic_bandwidth)

    local rx_organic=$(echo "$rx_total - $rx_synth" | bc)
    local tx_organic=$(echo "$tx_total - $tx_synth" | bc)
    local total_organic=$(echo "$total_mbps - $total_synth" | bc)

    # Ensure non-negative
    if (( $(echo "$rx_organic < 0" | bc -l) )); then rx_organic=0; fi
    if (( $(echo "$tx_organic < 0" | bc -l) )); then tx_organic=0; fi
    if (( $(echo "$total_organic < 0" | bc -l) )); then total_organic=0; fi

    echo "$rx_organic $tx_organic $total_organic"
}

# Get system load average
get_load_average() {
    awk '{print $1, $2, $3}' /proc/loadavg
}

# Get memory usage in MB
get_memory_usage() {
    free -m | awk '/^Mem:/ {print $3, $2}'
}

# Get primary network interface
get_primary_interface() {
    # Get interface with default route
    ip route | awk '/default/ {print $5; exit}'
}

# Initialize monitoring (call at service start)
init_monitoring() {
    # Prime the stats
    PREV_CPU_STATS=$(read_cpu_stats)
    PREV_NET_STATS=$(read_net_stats "$(get_primary_interface)")
    PREV_TIMESTAMP=$(date +%s)

    log_debug "Monitoring initialized for interface: $(get_primary_interface)"
}

# Clean up stale PIDs
cleanup_stale_pids() {
    local cleaned_stress=()
    local cleaned_bandwidth=()
    local pid

    # Clean stress PIDs
    for pid in "${STRESS_PIDS[@]}"; do
        # Skip empty PIDs
        [ -z "$pid" ] && continue
        if is_process_running "$pid"; then
            cleaned_stress+=("$pid")
        fi
    done

    # Clean bandwidth PIDs
    for pid in "${BANDWIDTH_PIDS[@]}"; do
        # Skip empty PIDs
        [ -z "$pid" ] && continue
        if is_process_running "$pid"; then
            cleaned_bandwidth+=("$pid")
        fi
    done

    # Properly reset arrays
    if [ ${#cleaned_stress[@]} -gt 0 ]; then
        STRESS_PIDS=("${cleaned_stress[@]}")
    else
        STRESS_PIDS=()
    fi

    if [ ${#cleaned_bandwidth[@]} -gt 0 ]; then
        BANDWIDTH_PIDS=("${cleaned_bandwidth[@]}")
    else
        BANDWIDTH_PIDS=()
    fi
}

# Export monitoring state for debugging
dump_monitoring_state() {
    echo "=== Monitoring State ==="
    echo "CPU Cores: $(get_cpu_cores)"
    echo "Primary Interface: $(get_primary_interface)"
    echo "Tracked Stress PIDs: ${STRESS_PIDS[*]}"
    echo "Tracked Bandwidth PIDs: ${BANDWIDTH_PIDS[*]}"
    echo "========================"
}
