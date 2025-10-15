#!/bin/bash
# actuator.sh - Load generation actuators
# Start/stop/manage CPU and bandwidth load generators
#
# Copyright (c) 2025 Jun Zhang
# Licensed under the MIT License. See LICENSE file in the project root.

# PIDs of running processes
STRESS_NG_PID=""
declare -a BANDWIDTH_DOWNLOADER_PIDS=()

# Track synthetic load levels
SYNTHETIC_CPU_PERCENT=0
SYNTHETIC_BW_TOTAL=0
SYNTHETIC_BW_RX=0
SYNTHETIC_BW_TX=0

# State file for sharing synthetic load values across subprocesses
STATE_FILE="${STATE_FILE:-/var/lib/loadgen/state}"

# Save synthetic load state to file
save_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    cat > "$STATE_FILE" << EOF
SYNTHETIC_CPU_PERCENT=$SYNTHETIC_CPU_PERCENT
SYNTHETIC_BW_TOTAL=$SYNTHETIC_BW_TOTAL
SYNTHETIC_BW_RX=$SYNTHETIC_BW_RX
SYNTHETIC_BW_TX=$SYNTHETIC_BW_TX
CPU_WORKERS=${CPU_WORKERS:-0}
CPU_LOAD_PERCENT=${CPU_LOAD_PERCENT:-0}
BW_DOWNLOADERS=${BW_DOWNLOADERS:-0}
BW_RATE_MBPS=${BW_RATE_MBPS:-0}
EOF
    log_debug "State saved: CPU=${SYNTHETIC_CPU_PERCENT}%, BW=${SYNTHETIC_BW_TOTAL}Mbps"
}

# Load synthetic load state from file
load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        log_debug "State loaded: CPU=${SYNTHETIC_CPU_PERCENT}%, BW=${SYNTHETIC_BW_TOTAL}Mbps"
    else
        log_debug "No state file found, using defaults"
    fi
}

# Start CPU load using stress-ng
# Args: $1 = number of workers
#       $2 = load percentage per worker
start_cpu_load() {
    local workers="$1"
    local load_percent="$2"

    if [ "$workers" -eq 0 ] || [ "$load_percent" -eq 0 ]; then
        log_debug "No CPU load requested (workers=$workers, load=$load_percent)"
        return 0
    fi

    # Check if stress-ng is available
    if ! command -v stress-ng &>/dev/null; then
        log_error "stress-ng not found, cannot generate CPU load"
        return 1
    fi

    # Start stress-ng in background
    # --cpu: number of workers
    # --cpu-load: percentage load per worker
    # --timeout 0: run indefinitely
    # --quiet: less verbose output
    stress-ng --cpu "$workers" --cpu-load "$load_percent" --timeout 0 --quiet &
    STRESS_NG_PID=$!

    # Register PID with monitor
    register_stress_pid "$STRESS_NG_PID"

    # Track synthetic CPU
    # Formula: (workers * load_percent) / num_cores
    # This gives us the percentage of TOTAL system CPU
    local num_cores=$(get_cpu_cores)
    SYNTHETIC_CPU_PERCENT=$(echo "scale=2; ($workers * $load_percent) / $num_cores" | bc | cut -d'.' -f1)
    export SYNTHETIC_CPU_PERCENT

    # Track worker count and load for state file
    CPU_WORKERS=$workers
    CPU_LOAD_PERCENT=$load_percent
    export CPU_WORKERS CPU_LOAD_PERCENT

    # Save state for other subprocesses
    save_state

    log_info "Started CPU load: workers=$workers, load=$load_percent%, PID=$STRESS_NG_PID, synthetic=${SYNTHETIC_CPU_PERCENT}% (${num_cores} cores)"

    return 0
}

# Stop CPU load
stop_cpu_load() {
    if [ -n "$STRESS_NG_PID" ] && is_process_running "$STRESS_NG_PID"; then
        log_info "Stopping CPU load: PID=$STRESS_NG_PID"
        kill "$STRESS_NG_PID" 2>/dev/null
        wait "$STRESS_NG_PID" 2>/dev/null

        # Also kill any child processes
        pkill -P "$STRESS_NG_PID" 2>/dev/null
    fi

    # Clear all stress-ng processes as fallback
    pkill -f "stress-ng.*--cpu" 2>/dev/null

    STRESS_NG_PID=""
    SYNTHETIC_CPU_PERCENT=0
    CPU_WORKERS=0
    CPU_LOAD_PERCENT=0
    export SYNTHETIC_CPU_PERCENT CPU_WORKERS CPU_LOAD_PERCENT
    clear_tracked_pids

    # Save state for other subprocesses
    save_state
}

# Start bandwidth load using wget
# Args: $1 = rate per downloader (Mbps)
#       $2 = number of downloaders
#       $@ = URLs to download from
start_bandwidth_load() {
    local rate_mbps="$1"
    local num_downloaders="$2"
    shift 2
    local urls=("$@")

    if [ "$num_downloaders" -eq 0 ]; then
        log_debug "No bandwidth load requested (downloaders=$num_downloaders)"
        return 0
    fi

    # Check if wget is available
    if ! command -v wget &>/dev/null; then
        log_error "wget not found, cannot generate bandwidth load"
        return 1
    fi

    # Convert Mbps to MB/s for wget --limit-rate (0 = unlimited)
    local rate_mbs="0"
    if (( $(echo "$rate_mbps > 0" | bc -l) )); then
        rate_mbs=$(echo "scale=2; $rate_mbps / 8" | bc)
    fi

    if [ "$rate_mbs" = "0" ]; then
        log_info "Starting bandwidth load: UNLIMITED rate, downloaders=$num_downloaders"
    else
        log_info "Starting bandwidth load: rate=${rate_mbps}Mbps (${rate_mbs}MB/s), downloaders=$num_downloaders"
    fi

    # Start downloaders
    for ((i=0; i<num_downloaders; i++)); do
        # Select URL (round-robin)
        local url_index=$((i % ${#urls[@]}))
        local url="${urls[$url_index]}"

        if [ -z "$url" ]; then
            log_warn "No URL available for downloader $i, skipping"
            continue
        fi

        # Start downloader in background
        start_single_downloader "$rate_mbs" "$url" &
        local downloader_pid=$!

        BANDWIDTH_DOWNLOADER_PIDS+=("$downloader_pid")
        register_bandwidth_pid "$downloader_pid"

        log_debug "Started downloader $i: rate=${rate_mbs}MB/s, URL=$url, PID=$downloader_pid"
    done

    # Calculate estimated synthetic bandwidth
    # If rate is unlimited (0), we'll measure actual usage in monitor
    # Otherwise, estimate from configured rate
    if [ "$rate_mbps" != "0" ] && (( $(echo "$rate_mbps > 0" | bc -l) )); then
        SYNTHETIC_BW_TOTAL=$(echo "scale=2; $rate_mbps * $num_downloaders" | bc)
        SYNTHETIC_BW_RX="$SYNTHETIC_BW_TOTAL"  # Downloads = RX
        SYNTHETIC_BW_TX="0"
    else
        # For unlimited, we'll measure it dynamically
        SYNTHETIC_BW_TOTAL=0
        SYNTHETIC_BW_RX=0
        SYNTHETIC_BW_TX=0
    fi
    export SYNTHETIC_BW_TOTAL SYNTHETIC_BW_RX SYNTHETIC_BW_TX

    # Track downloader count and rate for state file
    BW_DOWNLOADERS=$num_downloaders
    BW_RATE_MBPS=$rate_mbps
    export BW_DOWNLOADERS BW_RATE_MBPS

    # Save state for other subprocesses
    save_state

    return 0
}

# Start a single downloader loop
# Args: $1 = rate in MB/s (0 = unlimited)
#       $2 = URL
start_single_downloader() {
    local rate_mbs="$1"
    local url="$2"

    # Loop continuously downloading
    while true; do
        # Build wget command
        local wget_cmd="wget --quiet --output-document=/dev/null"

        # Add rate limit if specified (0 = unlimited)
        if [ "$rate_mbs" != "0" ] && (( $(echo "$rate_mbs > 0" | bc -l) )); then
            wget_cmd="$wget_cmd --limit-rate=${rate_mbs}M"
        fi

        # Common options
        wget_cmd="$wget_cmd --tries=1 --timeout=10 --no-check-certificate"

        # Execute download
        eval "$wget_cmd \"$url\"" 2>/dev/null

        # Small delay between downloads
        sleep 0.1
    done
}

# Stop bandwidth load
stop_bandwidth_load() {
    if [ ${#BANDWIDTH_DOWNLOADER_PIDS[@]} -gt 0 ]; then
        log_info "Stopping bandwidth load: ${#BANDWIDTH_DOWNLOADER_PIDS[@]} downloaders"

        for pid in "${BANDWIDTH_DOWNLOADER_PIDS[@]}"; do
            if is_process_running "$pid"; then
                kill "$pid" 2>/dev/null

                # Kill children (wget processes)
                pkill -P "$pid" 2>/dev/null
            fi
        done

        # Wait for processes to terminate
        for pid in "${BANDWIDTH_DOWNLOADER_PIDS[@]}"; do
            wait "$pid" 2>/dev/null
        done
    fi

    # Clear all wget processes as fallback (both limited and unlimited)
    pkill -f "wget.*--output-document=/dev/null" 2>/dev/null

    BANDWIDTH_DOWNLOADER_PIDS=()
    SYNTHETIC_BW_TOTAL=0
    SYNTHETIC_BW_RX=0
    SYNTHETIC_BW_TX=0
    export SYNTHETIC_BW_TOTAL SYNTHETIC_BW_RX SYNTHETIC_BW_TX

    # Save state for other subprocesses
    save_state
}

# Stop all load generation
stop_all_load() {
    log_info "Stopping all load generators"
    stop_cpu_load
    stop_bandwidth_load
}

# Graceful shutdown - cleanup all processes
graceful_shutdown() {
    log_info "Graceful shutdown initiated"

    stop_all_load

    # Give processes time to terminate
    sleep 1

    # Force kill any remaining child processes
    local parent_pid=$$
    pkill -P "$parent_pid" 2>/dev/null

    log_info "Shutdown complete"
}

# Get actuator status
get_actuator_status() {
    echo "=== Actuator Status ==="

    # CPU Load Status
    if [ -n "$STRESS_NG_PID" ] && is_process_running "$STRESS_NG_PID"; then
        echo "CPU Load: ACTIVE (PID=$STRESS_NG_PID)"
    else
        echo "CPU Load: INACTIVE"
    fi

    # Bandwidth Load Status
    local active_downloaders=0
    for pid in "${BANDWIDTH_DOWNLOADER_PIDS[@]}"; do
        if is_process_running "$pid"; then
            ((active_downloaders++))
        fi
    done

    if [ "$active_downloaders" -gt 0 ]; then
        echo "Bandwidth Load: ACTIVE ($active_downloaders downloaders)"
    else
        echo "Bandwidth Load: INACTIVE"
    fi

    echo "======================="
}

# Health check - verify generators are running as expected
health_check() {
    local issues=0

    # Check CPU load health
    if [ -n "$STRESS_NG_PID" ]; then
        if ! is_process_running "$STRESS_NG_PID"; then
            log_warn "CPU load generator PID $STRESS_NG_PID is not running"
            issues=$((issues + 1))
        fi
    fi

    # Check bandwidth load health
    for pid in "${BANDWIDTH_DOWNLOADER_PIDS[@]}"; do
        if ! is_process_running "$pid"; then
            log_warn "Bandwidth downloader PID $pid is not running"
            issues=$((issues + 1))
        fi
    done

    if [ "$issues" -eq 0 ]; then
        log_debug "Health check passed: all generators running"
        return 0
    else
        log_warn "Health check found $issues issues"
        return 1
    fi
}

# Restart failed generators
restart_failed_generators() {
    log_info "Restarting failed generators"

    # CPU load restart handled by controller
    if [ -n "$STRESS_NG_PID" ] && ! is_process_running "$STRESS_NG_PID"; then
        log_warn "CPU load generator died, will be restarted by controller"
        STRESS_NG_PID=""
    fi

    # Bandwidth load - clean up dead PIDs
    local alive_pids=()
    for pid in "${BANDWIDTH_DOWNLOADER_PIDS[@]}"; do
        if is_process_running "$pid"; then
            alive_pids+=("$pid")
        fi
    done

    if [ ${#alive_pids[@]} -ne ${#BANDWIDTH_DOWNLOADER_PIDS[@]} ]; then
        log_warn "Some bandwidth downloaders died, will be restarted by controller"
        BANDWIDTH_DOWNLOADER_PIDS=("${alive_pids[@]}")
    fi
}

# Signal handlers are set up in main loadgen.sh
# (removed duplicate setup_signal_handlers function)
