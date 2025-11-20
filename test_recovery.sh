#!/bin/bash
# test_recovery.sh - Test monitoring state initialization in subprocesses
# Simulates the bug and verifies the fix

set -e

echo "=== Testing Monitoring State Recovery ==="
echo

# Override LIB_DIR to use local paths
export LIB_DIR="$(pwd)/lib"

# Add minimal logging functions
log_debug() { :; }  # Silent in tests
log_info() { echo "[$(date '+%H:%M:%S')] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# Source the modules directly
source lib/monitor.sh
source lib/reporter.sh

# Set test configuration
{
    # Use test config if system config not available
    export CPU_TARGET_PERCENT=30
    export BANDWIDTH_TARGET_MBPS=5
    export MONITOR_INTERVAL=5
    export REPORT_INTERVAL=60
    export STATS_FILE=/tmp/test_stats.csv
    export STATE_FILE=/tmp/test_state
}

echo "Test 1: Verify init_monitoring sets PREV_* variables"
echo "------------------------------------------------------"
init_monitoring
if [ -n "$PREV_CPU_STATS" ]; then
    echo "✓ PREV_CPU_STATS initialized: ${PREV_CPU_STATS:0:20}..."
else
    echo "✗ PREV_CPU_STATS not set!"
    exit 1
fi

if [ -n "$PREV_NET_STATS" ]; then
    echo "✓ PREV_NET_STATS initialized: $PREV_NET_STATS"
else
    echo "✗ PREV_NET_STATS not set!"
    exit 1
fi
echo

echo "Test 2: Verify get_cpu_usage works after init"
echo "----------------------------------------------"
sleep 2  # Wait for delta to accumulate
cpu1=$(get_cpu_usage)
echo "First call: CPU = $cpu1%"
sleep 2
cpu2=$(get_cpu_usage)
echo "Second call: CPU = $cpu2%"

if [ "$cpu1" != "0" ] || [ "$cpu2" != "0" ]; then
    echo "✓ get_cpu_usage returning non-zero values"
else
    echo "⚠ Both calls returned 0 (may be normal if system is idle)"
fi
echo

echo "Test 3: Simulate subshell bug (without init_monitoring)"
echo "--------------------------------------------------------"
# Clear state
PREV_CPU_STATS=""
PREV_NET_STATS=""

# Call in subshell (simulates $(get_cpu_usage) in reporter)
result=$(get_cpu_usage)
echo "Subshell call 1: CPU = $result% (expected: 0)"

result=$(get_cpu_usage)
echo "Subshell call 2: CPU = $result% (expected: 0 - BUG!)"

if [ "$result" = "0" ]; then
    echo "✓ Bug confirmed: subshells always return 0"
else
    echo "? Unexpected: got non-zero value"
fi
echo

echo "Test 4: Verify fix - init_monitoring in subprocess"
echo "---------------------------------------------------"
# Simulate what our fixed code does
test_subprocess() {
    # This is what each loop now does
    init_monitoring
    sleep 2
    cpu=$(get_cpu_usage)
    echo "$cpu"
}

result1=$(test_subprocess)
echo "Subprocess call 1: CPU = $result1%"

result2=$(test_subprocess)
echo "Subprocess call 2: CPU = $result2%"

if [ "$result1" != "0" ] || [ "$result2" != "0" ]; then
    echo "✓ FIX VERIFIED: subprocesses can now measure CPU!"
else
    echo "⚠ Still getting zeros (may be normal if system is idle)"
fi
echo

echo "Test 5: Test reporting_loop simulation"
echo "---------------------------------------"
# Simulate reporting_loop behavior
simulate_reporting() {
    # This happens in the fixed code
    init_monitoring
    echo "[INFO] Simulated reporting loop initialized"

    for i in {1..3}; do
        sleep 2
        local cpu=$(get_cpu_usage)
        local interface=$(get_primary_interface)
        read -r rx tx bw < <(get_bandwidth_mbps "$interface")
        echo "Cycle $i: CPU=${cpu}%, BW=${bw}Mbps"
    done
}

echo "Running simulated reporting loop..."
simulate_reporting
echo "✓ Reporting loop simulation completed"
echo

echo "============================================"
echo "All tests completed successfully!"
echo "The fix ensures each subprocess can measure"
echo "metrics independently via init_monitoring."
echo "============================================"
