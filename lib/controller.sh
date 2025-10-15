#!/bin/bash
# controller.sh - Load control logic
# Calculates gaps between target and actual load, applies safety limits, decides adjustments
#
# Copyright (c) 2025 Jun Zhang
# Licensed under the MIT License. See LICENSE file in the project root.

# Load configuration
source /etc/loadgen.conf 2>/dev/null || {
    log_error "Failed to load /etc/loadgen.conf"
    exit 1
}

# Current state variables
CURRENT_CPU_WORKERS=0
CURRENT_CPU_LOAD_PERCENT=0
CURRENT_BW_RATE_MBPS=0
CURRENT_BW_DOWNLOADERS=0

# Calculate CPU gap (how much more/less CPU we need)
# Returns: gap in percentage points
calculate_cpu_gap() {
    local total_cpu=$(get_cpu_usage)
    local organic_cpu=$(get_organic_cpu)
    local synthetic_cpu=$(get_synthetic_cpu)

    # Gap = target - (organic + current synthetic)
    local gap=$(echo "$CPU_TARGET_PERCENT - $total_cpu" | bc)

    log_debug "CPU: target=$CPU_TARGET_PERCENT%, total=$total_cpu%, organic=$organic_cpu%, synthetic=$synthetic_cpu%, gap=$gap%"

    echo "$gap"
}

# Calculate bandwidth gap (how much more/less bandwidth we need)
# Returns: gap in Mbps
calculate_bandwidth_gap() {
    local interface=$(get_primary_interface)
    read -r rx_total tx_total total_mbps < <(get_bandwidth_mbps "$interface")
    read -r rx_org tx_org org_mbps < <(get_organic_bandwidth "$interface")
    read -r rx_synth tx_synth synth_mbps < <(get_synthetic_bandwidth)

    # Gap = target - current total
    local gap=$(echo "$BANDWIDTH_TARGET_MBPS - $total_mbps" | bc)

    log_debug "Bandwidth: target=${BANDWIDTH_TARGET_MBPS}Mbps, total=${total_mbps}Mbps, organic=${org_mbps}Mbps, synthetic=${synth_mbps}Mbps, gap=${gap}Mbps"

    echo "$gap"
}

# Check if adjustment is needed based on threshold
# Args: $1 = gap value
# Returns: 0 if adjustment needed, 1 if not
should_adjust() {
    local gap="$1"
    local abs_gap=$(echo "$gap" | tr -d '-')

    # Check if gap exceeds threshold
    if (( $(echo "$abs_gap >= $MIN_ADJUSTMENT_THRESHOLD" | bc -l) )); then
        return 0  # Yes, adjust
    else
        return 1  # No, within threshold
    fi
}

# Apply CPU safety limits
# Args: $1 = proposed total CPU%
# Returns: adjusted CPU% within safety limits
apply_cpu_safety() {
    local proposed_total="$1"
    local organic_cpu=$(get_organic_cpu)

    # Check if we'd exceed maximum
    if (( $(echo "$proposed_total > $MAX_CPU_PERCENT" | bc -l) )); then
        log_warn "Proposed CPU ${proposed_total}% exceeds max ${MAX_CPU_PERCENT}%"
        # Reduce to max, accounting for organic
        local max_synthetic=$(echo "$MAX_CPU_PERCENT - $organic_cpu" | bc)
        if (( $(echo "$max_synthetic < 0" | bc -l) )); then
            max_synthetic=0
        fi
        echo "$max_synthetic"
        return
    fi

    # Return the synthetic portion (proposed - organic)
    local synthetic=$(echo "$proposed_total - $organic_cpu" | bc)
    if (( $(echo "$synthetic < 0" | bc -l) )); then
        synthetic=0
    fi

    echo "$synthetic"
}

# Apply bandwidth safety limits
# Args: $1 = proposed total bandwidth Mbps
# Returns: adjusted bandwidth Mbps within safety limits
apply_bandwidth_safety() {
    local proposed_total="$1"
    local interface=$(get_primary_interface)
    read -r rx_org tx_org org_mbps < <(get_organic_bandwidth "$interface")

    # Check if we'd exceed maximum
    if (( $(echo "$proposed_total > $MAX_BANDWIDTH_MBPS" | bc -l) )); then
        log_warn "Proposed bandwidth ${proposed_total}Mbps exceeds max ${MAX_BANDWIDTH_MBPS}Mbps"
        # Reduce to max, accounting for organic
        local max_synthetic=$(echo "$MAX_BANDWIDTH_MBPS - $org_mbps" | bc)
        if (( $(echo "$max_synthetic < 0" | bc -l) )); then
            max_synthetic=0
        fi
        echo "$max_synthetic"
        return
    fi

    # Return the synthetic portion (proposed - organic)
    local synthetic=$(echo "$proposed_total - $org_mbps" | bc)
    if (( $(echo "$synthetic < 0" | bc -l) )); then
        synthetic=0
    fi

    echo "$synthetic"
}

# Calculate CPU workers and load percentage needed
# Args: $1 = target synthetic CPU percentage
# Returns: "workers load_percent"
calculate_cpu_parameters() {
    local target_synthetic="$1"
    local cpu_cores=$(get_cpu_cores)

    # If target is 0 or negative, no workers needed
    if (( $(echo "$target_synthetic <= 0" | bc -l) )); then
        echo "0 0"
        return
    fi

    # Strategy: Use multiple workers with moderate load for better distribution
    # Each worker at L% load uses L% of ONE core
    # On a C-core system: total_system_cpu% = (workers * load_percent) / C * 100
    # Therefore: workers * load_percent = (target_synthetic * C) / 100

    # For efficiency, use workers = cpu_cores for best distribution
    local workers="$cpu_cores"

    # Calculate load percent per worker
    # load_percent = target_synthetic (since workers = cores)
    local load_percent=$(printf "%.0f" $(echo "scale=2; $target_synthetic" | bc))

    # Cap at 100%
    if [ "$load_percent" -gt 100 ]; then
        load_percent=100
    fi

    echo "$workers $load_percent"
}

# Calculate bandwidth parameters
# Args: $1 = target synthetic bandwidth Mbps
# Returns: "rate_per_downloader num_downloaders"
calculate_bandwidth_parameters() {
    local target_synthetic="$1"

    # If target is 0 or negative, no downloaders needed
    if (( $(echo "$target_synthetic <= 0" | bc -l) )); then
        echo "0 0"
        return
    fi

    # Strategy: High-speed servers (Linode/Cloudflare) deliver ~650 Mbps each
    # Calculate downloaders needed based on expected throughput
    local expected_mbps_per_downloader=650

    # For targets < 600 Mbps, use rate limiting (single downloader exceeds target)
    if (( $(echo "$target_synthetic < 600" | bc -l) )); then
        # Use rate limiting for more precise control
        local num_downloaders=1
        if (( $(echo "$target_synthetic >= 200" | bc -l) )); then
            num_downloaders=4
        elif (( $(echo "$target_synthetic >= 100" | bc -l) )); then
            num_downloaders=3
        elif (( $(echo "$target_synthetic >= 50" | bc -l) )); then
            num_downloaders=2
        fi
        local rate_per_downloader=$(echo "scale=2; $target_synthetic / $num_downloaders" | bc)
        echo "$rate_per_downloader $num_downloaders"
        return
    fi

    # High bandwidth (>= 600 Mbps): calculate downloaders needed, no rate limiting
    # num_downloaders = ceil(target / expected_throughput_per_downloader)
    local num_downloaders=$(printf "%.0f" $(echo "scale=2; ($target_synthetic / $expected_mbps_per_downloader) + 0.99" | bc))

    # Ensure at least 1 downloader
    if [ "$num_downloaders" -lt 1 ]; then
        num_downloaders=1
    fi

    # Cap at 6 downloaders (6 * 650 = 3900 Mbps max)
    if [ "$num_downloaders" -gt 6 ]; then
        num_downloaders=6
    fi

    # For high-speed: return 0 rate (unlimited) and calculated downloader count
    echo "0 $num_downloaders"
}

# Main control decision function
# Returns: 0 if adjustments made, 1 if no changes
control_decision() {
    log_debug "=== Control Decision Cycle ==="

    # Calculate gaps
    local cpu_gap=$(calculate_cpu_gap)
    local bw_gap=$(calculate_bandwidth_gap)

    local adjustments_made=0

    # CPU Control
    if should_adjust "$cpu_gap"; then
        log_info "CPU adjustment needed: gap=${cpu_gap}%"

        # Calculate new target total
        local current_total=$(get_cpu_usage)
        log_debug "current_total=$current_total"

        local new_total=$(echo "$current_total + $cpu_gap" | bc)
        log_debug "new_total=$new_total"

        # Apply safety limits
        local new_synthetic=$(apply_cpu_safety "$new_total")
        log_debug "new_synthetic=$new_synthetic"

        # Calculate worker parameters
        local calc_result=$(calculate_cpu_parameters "$new_synthetic")
        log_debug "calc_result=$calc_result"
        read -r new_workers new_load <<< "$calc_result"
        log_debug "new_workers=$new_workers new_load=$new_load"

        # Check if different from current
        if [ "$new_workers" != "$CURRENT_CPU_WORKERS" ] || [ "$new_load" != "$CURRENT_CPU_LOAD_PERCENT" ]; then
            log_info "Adjusting CPU: workers=$new_workers, load=$new_load%"

            # Stop current CPU load
            stop_cpu_load

            # Start new CPU load if needed
            if [ "$new_workers" -gt 0 ]; then
                start_cpu_load "$new_workers" "$new_load"
            fi

            CURRENT_CPU_WORKERS="$new_workers"
            CURRENT_CPU_LOAD_PERCENT="$new_load"
            adjustments_made=1
        fi
    else
        log_debug "CPU within threshold: gap=${cpu_gap}%"
    fi

    # Bandwidth Control
    if should_adjust "$bw_gap"; then
        log_info "Bandwidth adjustment needed: gap=${bw_gap}Mbps"

        # Calculate new target total
        local interface=$(get_primary_interface)
        read -r rx tx current_total < <(get_bandwidth_mbps "$interface")
        local new_total=$(echo "$current_total + $bw_gap" | bc)

        # Apply safety limits
        local new_synthetic=$(apply_bandwidth_safety "$new_total")

        # Calculate bandwidth parameters
        read -r new_rate new_count < <(calculate_bandwidth_parameters "$new_synthetic")

        # Check if different from current
        if [ "$new_count" != "$CURRENT_BW_DOWNLOADERS" ] || \
           (( $(echo "$new_rate != $CURRENT_BW_RATE_MBPS" | bc -l) )); then

            log_info "Adjusting Bandwidth: rate=${new_rate}Mbps, downloaders=$new_count"

            # Stop current bandwidth load
            stop_bandwidth_load

            # Start new bandwidth load if needed
            if [ "$new_count" -gt 0 ]; then
                # Get download URLs from config
                local urls=($DOWNLOAD_URLS)
                start_bandwidth_load "$new_rate" "$new_count" "${urls[@]}"

                # Update synthetic bandwidth tracking for monitoring
                SYNTHETIC_BW_TOTAL="$new_synthetic"
                SYNTHETIC_BW_RX="$new_synthetic"  # Mostly RX for downloads
                SYNTHETIC_BW_TX="0"
                export SYNTHETIC_BW_TOTAL SYNTHETIC_BW_RX SYNTHETIC_BW_TX
            fi

            CURRENT_BW_RATE_MBPS="$new_rate"
            CURRENT_BW_DOWNLOADERS="$new_count"
            adjustments_made=1
        fi
    else
        log_debug "Bandwidth within threshold: gap=${bw_gap}Mbps"
    fi

    log_debug "=== End Control Decision ==="

    return $((1 - adjustments_made))
}

# Emergency shutdown - called when safety limits exceeded repeatedly
emergency_shutdown() {
    log_error "EMERGENCY: Safety limits exceeded, shutting down all load generators"

    stop_cpu_load
    stop_bandwidth_load

    CURRENT_CPU_WORKERS=0
    CURRENT_CPU_LOAD_PERCENT=0
    CURRENT_BW_RATE_MBPS=0
    CURRENT_BW_DOWNLOADERS=0
}

# Get current controller state for status reporting
get_controller_state() {
    echo "CPU_WORKERS=$CURRENT_CPU_WORKERS"
    echo "CPU_LOAD_PERCENT=$CURRENT_CPU_LOAD_PERCENT"
    echo "BW_RATE_MBPS=$CURRENT_BW_RATE_MBPS"
    echo "BW_DOWNLOADERS=$CURRENT_BW_DOWNLOADERS"
}
