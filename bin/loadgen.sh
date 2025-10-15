#!/bin/bash
# loadgen.sh - Main load generator service
# Orchestrates monitoring, control, and actuation loops
#
# Copyright (c) 2025 Jun Zhang
# Licensed under the MIT License. See LICENSE file in the project root.

set -eo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/loadgen"

# Configuration file
CONFIG_FILE="/etc/loadgen.conf"

# Logging functions
log_debug() {
    if [ "${LOG_LEVEL:-INFO}" = "DEBUG" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*" >&2
    fi
}

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
}

# Load configuration
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi

    # Source config file
    # Parse INI-style config
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ "$key" =~ ^[[:space:]]*$ ]] && continue
        [[ "$key" =~ ^\[ ]] && continue  # Skip section headers

        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # Remove quotes from value
        value="${value%\"}"
        value="${value#\"}"

        # Export as variable
        export "$key=$value"
    done < "$CONFIG_FILE"

    log_info "Configuration loaded from $CONFIG_FILE"
}

# Load modules
load_modules() {
    local modules=(
        "$LIB_DIR/monitor.sh"
        "$LIB_DIR/actuator.sh"
        "$LIB_DIR/controller.sh"
        "$LIB_DIR/reporter.sh"
        "$LIB_DIR/web_reporter.sh"
    )

    for module in "${modules[@]}"; do
        if [ ! -f "$module" ]; then
            log_error "Module not found: $module"
            return 1
        fi
        source "$module"
        log_debug "Loaded module: $(basename "$module")"
    done
}

# Initialize service
initialize() {
    log_info "=== Load Generator Service Starting ==="
    log_info "Version: 1.0"
    log_info "PID: $$"

    # Load configuration
    load_config || exit 1

    # Load modules
    load_modules || exit 1

    # Set up signal handlers
    setup_signal_handlers

    # Initialize monitoring
    init_monitoring

    # Create log directories
    mkdir -p "$(dirname "$REPORT_FILE")"
    mkdir -p "$(dirname "$STATS_FILE")"

    # Create web root directory if dashboard is enabled
    if [ "${ENABLE_WEB_DASHBOARD:-false}" = "true" ]; then
        mkdir -p "${WEB_ROOT:-/var/www/loadgen}"
        log_info "Web dashboard enabled: ${WEB_ROOT:-/var/www/loadgen}"
    fi

    log_info "Initialization complete"
    log_info "CPU Target: ${CPU_TARGET_PERCENT}%"
    log_info "Bandwidth Target: ${BANDWIDTH_TARGET_MBPS} Mbps"
}

# Monitoring loop
monitoring_loop() {
    set +e  # Don't exit on error within loop
    local cycle=0
    while true; do
        log_debug "Monitoring cycle $cycle starting"

        # Clean up stale PIDs
        if ! cleanup_stale_pids; then
            log_error "cleanup_stale_pids failed with exit code $?"
        fi

        # Update metrics (this primes the stats for next cycle)
        if ! get_cpu_usage > /dev/null; then
            log_error "get_cpu_usage failed with exit code $?"
        fi

        if ! get_bandwidth_mbps "$(get_primary_interface)" > /dev/null; then
            log_error "get_bandwidth_mbps failed with exit code $?"
        fi

        log_debug "Monitoring cycle $cycle complete"

        ((cycle++))
        sleep "$MONITOR_INTERVAL"
    done
}

# Control loop
control_loop() {
    set +e  # Don't exit on error within loop
    local cycle=0

    while true; do
        sleep "$ADJUSTMENT_INTERVAL"

        log_debug "Control cycle $cycle starting"

        # Make control decision
        if control_decision; then
            log_debug "Adjustments made in cycle $cycle"
        else
            log_debug "No adjustments needed in cycle $cycle"
        fi

        log_debug "Control decision complete for cycle $cycle"

        # Health check
        if ! health_check; then
            log_debug "Health check failed, restarting failed generators"
            restart_failed_generators
        else
            log_debug "Health check passed for cycle $cycle"
        fi

        log_debug "Control cycle $cycle complete"

        ((cycle++))
    done
}

# Reporting loop
reporting_loop() {
    set +e  # Don't exit on error within loop
    local cycle=0

    while true; do
        sleep "$REPORT_INTERVAL"

        log_debug "Reporting cycle $cycle starting"

        # Generate and write report
        if ! write_report_to_file; then
            log_error "write_report_to_file failed with exit code $?"
        fi

        # Log CSV stats
        if ! log_stats_csv; then
            log_error "log_stats_csv failed with exit code $?"
        fi

        # Rotate logs if needed
        if ! rotate_logs; then
            log_error "rotate_logs failed with exit code $?"
        fi

        # Display quick status
        local status=$(get_quick_status)
        if [ $? -eq 0 ]; then
            log_info "Status: $status"
        else
            log_error "get_quick_status failed with exit code $?"
        fi

        log_debug "Reporting cycle $cycle complete"

        ((cycle++))
    done
}

# HTML dashboard reporting loop
html_reporting_loop() {
    set +e  # Don't exit on error within loop
    local cycle=0

    # Check if web dashboard is enabled
    if [ "${ENABLE_WEB_DASHBOARD:-false}" != "true" ]; then
        log_info "Web dashboard disabled, HTML reporting loop exiting"
        return 0
    fi

    local html_interval="${HTML_REPORT_INTERVAL:-600}"
    local web_root="${WEB_ROOT:-/var/www/loadgen}"

    log_info "HTML reporting loop started (interval: ${html_interval}s)"

    while true; do
        sleep "$html_interval"

        log_debug "HTML reporting cycle $cycle starting"

        # Generate HTML dashboard
        if ! generate_html_dashboard "$web_root/index.html"; then
            log_error "generate_html_dashboard failed with exit code $?"
        else
            log_debug "HTML dashboard generated successfully"
        fi

        log_debug "HTML reporting cycle $cycle complete"

        ((cycle++))
    done
}

# Main service loop
main_loop() {
    log_info "Starting main service loop"

    # Start background loops
    monitoring_loop &
    local monitor_pid=$!
    log_info "Started monitoring_loop: PID=$monitor_pid"

    control_loop &
    local control_pid=$!
    log_info "Started control_loop: PID=$control_pid"

    reporting_loop &
    local report_pid=$!
    log_info "Started reporting_loop: PID=$report_pid"

    # Start HTML reporting loop if enabled
    local html_pid=""
    if [ "${ENABLE_WEB_DASHBOARD:-false}" = "true" ]; then
        html_reporting_loop &
        html_pid=$!
        log_info "Started html_reporting_loop: PID=$html_pid"
    fi

    log_info "Background loops started: monitor=$monitor_pid, control=$control_pid, report=$report_pid, html=$html_pid"

    # Continuous monitoring of background processes
    while true; do
        # Check if all loops are still running
        if ! kill -0 $monitor_pid 2>/dev/null; then
            log_error "Monitoring loop (PID=$monitor_pid) has died"
            wait $monitor_pid 2>/dev/null
            local exit_code=$?
            log_error "Monitoring loop exit code: $exit_code"
            break
        fi

        if ! kill -0 $control_pid 2>/dev/null; then
            log_error "Control loop (PID=$control_pid) has died"
            wait $control_pid 2>/dev/null
            local exit_code=$?
            log_error "Control loop exit code: $exit_code"
            break
        fi

        if ! kill -0 $report_pid 2>/dev/null; then
            log_error "Reporting loop (PID=$report_pid) has died"
            wait $report_pid 2>/dev/null
            local exit_code=$?
            log_error "Reporting loop exit code: $exit_code"
            break
        fi

        # Check HTML loop if enabled
        if [ -n "$html_pid" ] && ! kill -0 $html_pid 2>/dev/null; then
            log_error "HTML reporting loop (PID=$html_pid) has died"
            wait $html_pid 2>/dev/null
            local exit_code=$?
            log_error "HTML reporting loop exit code: $exit_code"
            break
        fi

        # All loops still running, sleep briefly
        sleep 1
    done

    # Clean up remaining loops
    log_info "Cleaning up remaining background processes"
    kill $monitor_pid $control_pid $report_pid $html_pid 2>/dev/null
    graceful_shutdown
    exit 1
}

# Handle reload signal (SIGHUP)
handle_reload() {
    log_info "Received reload signal, reloading configuration"

    # Stop all load
    stop_all_load

    # Reload config
    load_config

    log_info "Configuration reloaded, load generation will resume"
}

# Override signal handlers to add reload
setup_signal_handlers() {
    trap 'graceful_shutdown; exit 0' SIGTERM SIGINT
    trap 'handle_reload' SIGHUP
}

# Print usage
usage() {
    cat <<EOF
Load Generator Service

Usage: $0 [OPTIONS]

Options:
    start       Start the load generator service (default)
    stop        Stop gracefully (send SIGTERM)
    reload      Reload configuration (send SIGHUP)
    status      Show current status
    test        Test configuration and modules
    help        Show this help message

Configuration: $CONFIG_FILE

EOF
}

# Test configuration and modules
test_config() {
    echo "Testing configuration..."

    # Load config
    if ! load_config; then
        echo "❌ Configuration load failed"
        return 1
    fi
    echo "✓ Configuration loaded successfully"

    # Load modules
    if ! load_modules; then
        echo "❌ Module load failed"
        return 1
    fi
    echo "✓ All modules loaded successfully"

    # Test dependencies
    echo ""
    echo "Checking dependencies..."

    if command -v stress-ng &>/dev/null; then
        echo "✓ stress-ng found: $(stress-ng --version 2>&1 | head -1)"
    else
        echo "❌ stress-ng not found (required for CPU load)"
    fi

    if command -v wget &>/dev/null; then
        echo "✓ wget found: $(wget --version 2>&1 | head -1)"
    else
        echo "❌ wget not found (required for bandwidth load)"
    fi

    if command -v bc &>/dev/null; then
        echo "✓ bc found"
    else
        echo "❌ bc not found (required for calculations)"
    fi

    # Test monitoring
    echo ""
    echo "Testing monitoring functions..."
    init_monitoring
    echo "✓ CPU cores: $(get_cpu_cores)"
    echo "✓ Primary interface: $(get_primary_interface)"

    echo ""
    echo "Configuration test complete"
}

# Show status
show_status() {
    # Load config and modules
    load_config &>/dev/null
    load_modules &>/dev/null

    # Check if service is running
    if pgrep -f "loadgen.sh" > /dev/null; then
        echo "Service: RUNNING"
        echo ""

        # Try to show current status
        if [ -f "$REPORT_FILE" ]; then
            echo "Latest Report:"
            tail -30 "$REPORT_FILE"
        else
            echo "No reports generated yet"
        fi
    else
        echo "Service: NOT RUNNING"
    fi
}

# Main entry point
main() {
    local command="${1:-start}"

    case "$command" in
        start)
            initialize
            main_loop
            ;;
        stop)
            echo "Stopping load generator..."
            pkill -SIGTERM -f "loadgen.sh"
            ;;
        reload)
            echo "Reloading configuration..."
            pkill -SIGHUP -f "loadgen.sh"
            ;;
        status)
            show_status
            ;;
        test)
            test_config
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            echo "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
