#!/bin/bash
# web_reporter.sh - Generate HTML dashboard for load generator
# Creates a cyberpunk-themed web interface showing 7-day historical data
#
# Copyright (c) 2025 Jun Zhang
# Licensed under the MIT License. See LICENSE file in the project root.

# Generate HTML dashboard
generate_html_dashboard() {
    local output_file="$1"
    local stats_file="${STATS_FILE:-/var/log/loadgen/stats.csv}"

    # Get current stats
    local cpu_total=$(get_cpu_usage)
    local cpu_organic=$(get_organic_cpu)
    local cpu_synthetic=$(get_synthetic_cpu)

    local interface=$(get_primary_interface)
    read -r rx_total tx_total total_mbps < <(get_bandwidth_mbps "$interface")
    read -r rx_org tx_org org_mbps < <(get_organic_bandwidth "$interface")
    read -r rx_synth tx_synth synth_mbps < <(get_synthetic_bandwidth)

    # Load state file to get controller state
    local state_file="${STATE_FILE:-/var/lib/loadgen/state}"
    if [ -f "$state_file" ]; then
        source "$state_file" 2>/dev/null
    fi

    # Get controller state (from state file variables)
    local cpu_workers="${CPU_WORKERS:-0}"
    local cpu_load="${CPU_LOAD_PERCENT:-0}"
    local bw_downloaders="${BW_DOWNLOADERS:-0}"

    # Get 7-day historical data from CSV
    local chart_data=$(generate_chart_data "$stats_file")

    # Get timestamp
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local uptime_info=$(uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')

    # Generate HTML
    cat > "$output_file" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Load Generator Dashboard</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
            background: #0a0a0a;
            color: #e0e0e0;
            min-height: 100vh;
            padding: 20px;
            background-image:
                repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(0, 212, 255, 0.03) 2px, rgba(0, 212, 255, 0.03) 4px);
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
        }

        header {
            text-align: center;
            margin-bottom: 40px;
            padding: 30px 20px;
            background: linear-gradient(135deg, #121212 0%, #1a1a1a 100%);
            border: 1px solid #00d4ff;
            border-radius: 10px;
            box-shadow: 0 0 20px rgba(0, 212, 255, 0.2);
        }

        h1 {
            font-size: 2.5em;
            color: #00d4ff;
            text-transform: uppercase;
            letter-spacing: 3px;
            text-shadow: 0 0 10px rgba(0, 212, 255, 0.5);
            margin-bottom: 10px;
        }

        .subtitle {
            color: #888;
            font-size: 0.9em;
            text-transform: uppercase;
            letter-spacing: 2px;
        }

        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }

        .stat-card {
            background: #121212;
            border: 1px solid #333;
            border-radius: 8px;
            padding: 25px;
            transition: all 0.3s;
            position: relative;
            overflow: hidden;
        }

        .stat-card::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 3px;
            background: linear-gradient(90deg, #00d4ff, #0088ff);
        }

        .stat-card:hover {
            border-color: #00d4ff;
            box-shadow: 0 0 20px rgba(0, 212, 255, 0.3);
            transform: translateY(-2px);
        }

        .stat-label {
            font-size: 0.85em;
            color: #888;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 10px;
        }

        .stat-value {
            font-size: 2.5em;
            font-weight: bold;
            color: #00d4ff;
            font-family: 'Consolas', 'Courier New', monospace;
            margin-bottom: 10px;
        }

        .stat-detail {
            font-size: 0.9em;
            color: #999;
            display: flex;
            justify-content: space-between;
            margin-top: 10px;
            padding-top: 10px;
            border-top: 1px solid #222;
        }

        .detail-item {
            display: flex;
            flex-direction: column;
        }

        .detail-label {
            font-size: 0.75em;
            color: #666;
            text-transform: uppercase;
        }

        .detail-value {
            color: #aaa;
            margin-top: 2px;
        }

        .organic { color: #4CAF50; }
        .synthetic { color: #ff9800; }
        .target { color: #00d4ff; }

        .chart-section {
            background: #121212;
            border: 1px solid #333;
            border-radius: 8px;
            padding: 30px;
            margin-bottom: 30px;
        }

        .chart-title {
            font-size: 1.3em;
            color: #00d4ff;
            text-transform: uppercase;
            letter-spacing: 2px;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 2px solid #00d4ff;
        }

        .chart-container {
            height: 300px;
            margin-bottom: 20px;
            background: #0a0a0a;
            border: 1px solid #222;
            border-radius: 5px;
            padding: 20px;
            position: relative;
        }

        canvas {
            width: 100% !important;
            height: 100% !important;
        }

        .system-info {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 15px;
            margin-top: 30px;
        }

        .info-item {
            background: #0a0a0a;
            padding: 15px;
            border-radius: 5px;
            border-left: 3px solid #00d4ff;
        }

        .info-label {
            font-size: 0.8em;
            color: #666;
            text-transform: uppercase;
            margin-bottom: 5px;
        }

        .info-value {
            color: #ddd;
            font-family: 'Consolas', 'Courier New', monospace;
        }

        footer {
            text-align: center;
            margin-top: 40px;
            padding: 20px;
            color: #666;
            font-size: 0.85em;
        }

        .status-indicator {
            display: inline-block;
            width: 10px;
            height: 10px;
            border-radius: 50%;
            background: #4CAF50;
            box-shadow: 0 0 10px #4CAF50;
            margin-right: 8px;
            animation: pulse 2s infinite;
        }

        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }

        .progress-bar {
            width: 100%;
            height: 8px;
            background: #222;
            border-radius: 4px;
            overflow: hidden;
            margin-top: 10px;
        }

        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, #00d4ff, #0088ff);
            border-radius: 4px;
            transition: width 0.3s;
        }

        @media (max-width: 768px) {
            h1 { font-size: 1.8em; }
            .stat-value { font-size: 2em; }
            .stats-grid { grid-template-columns: 1fr; }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>⚡ Load Generator Dashboard</h1>
            <p class="subtitle"><span class="status-indicator"></span>System Active</p>
        </header>

        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-label">CPU Load</div>
                <div class="stat-value">__CPU_TOTAL__%</div>
                <div class="progress-bar">
                    <div class="progress-fill" style="width: __CPU_TOTAL__%"></div>
                </div>
                <div class="stat-detail">
                    <div class="detail-item">
                        <span class="detail-label">Target</span>
                        <span class="detail-value target">__CPU_TARGET__%</span>
                    </div>
                    <div class="detail-item">
                        <span class="detail-label">Organic</span>
                        <span class="detail-value organic">__CPU_ORGANIC__%</span>
                    </div>
                    <div class="detail-item">
                        <span class="detail-label">Synthetic</span>
                        <span class="detail-value synthetic">__CPU_SYNTHETIC__%</span>
                    </div>
                </div>
            </div>

            <div class="stat-card">
                <div class="stat-label">Bandwidth Usage</div>
                <div class="stat-value">__BW_TOTAL__ Mbps</div>
                <div class="progress-bar">
                    <div class="progress-fill" style="width: __BW_PERCENT__%"></div>
                </div>
                <div class="stat-detail">
                    <div class="detail-item">
                        <span class="detail-label">Target</span>
                        <span class="detail-value target">__BW_TARGET__ Mbps</span>
                    </div>
                    <div class="detail-item">
                        <span class="detail-label">Organic</span>
                        <span class="detail-value organic">__BW_ORGANIC__ Mbps</span>
                    </div>
                    <div class="detail-item">
                        <span class="detail-label">Synthetic</span>
                        <span class="detail-value synthetic">__BW_SYNTHETIC__ Mbps</span>
                    </div>
                </div>
            </div>

            <div class="stat-card">
                <div class="stat-label">Active Generators</div>
                <div class="stat-value">__TOTAL_PROCESSES__</div>
                <div class="stat-detail">
                    <div class="detail-item">
                        <span class="detail-label">CPU Workers</span>
                        <span class="detail-value">__CPU_WORKERS__</span>
                    </div>
                    <div class="detail-item">
                        <span class="detail-label">Downloaders</span>
                        <span class="detail-value">__BW_DOWNLOADERS__</span>
                    </div>
                    <div class="detail-item">
                        <span class="detail-label">Load %</span>
                        <span class="detail-value">__CPU_LOAD__%</span>
                    </div>
                </div>
            </div>
        </div>

        <div class="chart-section">
            <div class="chart-title">📊 7-Day CPU History</div>
            <div class="chart-container">
                <canvas id="cpuChart"></canvas>
            </div>
        </div>

        <div class="chart-section">
            <div class="chart-title">📊 7-Day Bandwidth History</div>
            <div class="chart-container">
                <canvas id="bandwidthChart"></canvas>
            </div>
        </div>

        <div class="chart-section">
            <div class="chart-title">ℹ️ System Information</div>
            <div class="system-info">
                <div class="info-item">
                    <div class="info-label">Last Updated</div>
                    <div class="info-value">__TIMESTAMP__</div>
                </div>
                <div class="info-item">
                    <div class="info-label">System Uptime</div>
                    <div class="info-value">__UPTIME__</div>
                </div>
                <div class="info-item">
                    <div class="info-label">CPU Cores</div>
                    <div class="info-value">__CPU_CORES__</div>
                </div>
                <div class="info-item">
                    <div class="info-label">Network Interface</div>
                    <div class="info-value">__INTERFACE__</div>
                </div>
            </div>
        </div>

        <footer>
            <p>Load Generator System | Auto-refresh every __HTML_REPORT_INTERVAL__ seconds</p>
            <p style="margin-top: 10px; color: #444;">Generated with ❤️ by Load Generator v1.0</p>
        </footer>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <script>
        // Chart data
        const chartData = __CHART_DATA__;

        // CPU Chart
        const cpuCtx = document.getElementById('cpuChart').getContext('2d');
        new Chart(cpuCtx, {
            type: 'line',
            data: {
                labels: chartData.labels,
                datasets: [
                    {
                        label: 'Total CPU',
                        data: chartData.cpu_total,
                        borderColor: '#00d4ff',
                        backgroundColor: 'rgba(0, 212, 255, 0.1)',
                        borderWidth: 2,
                        tension: 0.4
                    },
                    {
                        label: 'Organic CPU',
                        data: chartData.cpu_organic,
                        borderColor: '#4CAF50',
                        backgroundColor: 'rgba(76, 175, 80, 0.1)',
                        borderWidth: 2,
                        tension: 0.4
                    },
                    {
                        label: 'Synthetic CPU',
                        data: chartData.cpu_synthetic,
                        borderColor: '#ff9800',
                        backgroundColor: 'rgba(255, 152, 0, 0.1)',
                        borderWidth: 2,
                        tension: 0.4
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        display: true,
                        position: 'top',
                        labels: { color: '#e0e0e0', font: { size: 12 } }
                    }
                },
                scales: {
                    y: {
                        beginAtZero: true,
                        max: 100,
                        grid: { color: '#222' },
                        ticks: { color: '#888', callback: value => value + '%' }
                    },
                    x: {
                        grid: { color: '#222' },
                        ticks: { color: '#888', maxRotation: 45, minRotation: 45 }
                    }
                }
            }
        });

        // Bandwidth Chart
        const bwCtx = document.getElementById('bandwidthChart').getContext('2d');
        new Chart(bwCtx, {
            type: 'line',
            data: {
                labels: chartData.labels,
                datasets: [
                    {
                        label: 'Total Bandwidth',
                        data: chartData.bw_total,
                        borderColor: '#00d4ff',
                        backgroundColor: 'rgba(0, 212, 255, 0.1)',
                        borderWidth: 2,
                        tension: 0.4
                    },
                    {
                        label: 'Organic Bandwidth',
                        data: chartData.bw_organic,
                        borderColor: '#4CAF50',
                        backgroundColor: 'rgba(76, 175, 80, 0.1)',
                        borderWidth: 2,
                        tension: 0.4
                    },
                    {
                        label: 'Synthetic Bandwidth',
                        data: chartData.bw_synthetic,
                        borderColor: '#ff9800',
                        backgroundColor: 'rgba(255, 152, 0, 0.1)',
                        borderWidth: 2,
                        tension: 0.4
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        display: true,
                        position: 'top',
                        labels: { color: '#e0e0e0', font: { size: 12 } }
                    }
                },
                scales: {
                    y: {
                        beginAtZero: true,
                        grid: { color: '#222' },
                        ticks: { color: '#888', callback: value => value + ' Mbps' }
                    },
                    x: {
                        grid: { color: '#222' },
                        ticks: { color: '#888', maxRotation: 45, minRotation: 45 }
                    }
                }
            }
        });

        // Auto-refresh page
        setTimeout(() => window.location.reload(), __HTML_REPORT_INTERVAL__ * 1000);
    </script>
</body>
</html>
HTMLEOF

    # Replace placeholders with actual data
    local cpu_cores=$(get_cpu_cores)
    local bw_percent=$(echo "scale=0; ($total_mbps / $BANDWIDTH_TARGET_MBPS) * 100" | bc)
    if [ "$bw_percent" -gt 100 ]; then bw_percent=100; fi

    local total_processes=$((cpu_workers + bw_downloaders))

    sed -i "s/__CPU_TOTAL__/${cpu_total}/g" "$output_file"
    sed -i "s/__CPU_TARGET__/${CPU_TARGET_PERCENT}/g" "$output_file"
    sed -i "s/__CPU_ORGANIC__/${cpu_organic}/g" "$output_file"
    sed -i "s/__CPU_SYNTHETIC__/${cpu_synthetic}/g" "$output_file"
    sed -i "s/__BW_TOTAL__/${total_mbps}/g" "$output_file"
    sed -i "s/__BW_TARGET__/${BANDWIDTH_TARGET_MBPS}/g" "$output_file"
    sed -i "s/__BW_ORGANIC__/${org_mbps}/g" "$output_file"
    sed -i "s/__BW_SYNTHETIC__/${synth_mbps}/g" "$output_file"
    sed -i "s/__BW_PERCENT__/${bw_percent}/g" "$output_file"
    sed -i "s/__CPU_WORKERS__/${cpu_workers}/g" "$output_file"
    sed -i "s/__CPU_LOAD__/${cpu_load}/g" "$output_file"
    sed -i "s/__BW_DOWNLOADERS__/${bw_downloaders}/g" "$output_file"
    sed -i "s/__TOTAL_PROCESSES__/${total_processes}/g" "$output_file"
    sed -i "s/__TIMESTAMP__/${timestamp}/g" "$output_file"
    sed -i "s/__UPTIME__/${uptime_info}/g" "$output_file"
    sed -i "s/__CPU_CORES__/${cpu_cores}/g" "$output_file"
    sed -i "s/__INTERFACE__/${interface}/g" "$output_file"
    sed -i "s/__HTML_REPORT_INTERVAL__/${HTML_REPORT_INTERVAL:-600}/g" "$output_file"
    sed -i "s|__CHART_DATA__|${chart_data}|g" "$output_file"

    log_info "Generated HTML dashboard: $output_file"
}

# Generate chart data from CSV stats (last 7 days)
generate_chart_data() {
    local stats_file="$1"

    if [ ! -f "$stats_file" ]; then
        echo "{\"labels\":[],\"cpu_total\":[],\"cpu_organic\":[],\"cpu_synthetic\":[],\"bw_total\":[],\"bw_organic\":[],\"bw_synthetic\":[]}"
        return
    fi

    # Get data from last 7 days (604800 seconds)
    local seven_days_ago=$(date -d '7 days ago' '+%s' 2>/dev/null || date -v-7d '+%s')
    local current_time=$(date '+%s')

    # Read CSV and extract last 7 days of data (sample every hour for readability)
    # Format: timestamp,cpu_target,cpu_organic,cpu_synthetic,cpu_total,bw_target,bw_organic,bw_synthetic,bw_total

    local labels="["
    local cpu_total_data="["
    local cpu_organic_data="["
    local cpu_synthetic_data="["
    local bw_total_data="["
    local bw_organic_data="["
    local bw_synthetic_data="["

    local count=0
    local last_hour=""

    # Skip header and process data
    tail -n +2 "$stats_file" 2>/dev/null | while IFS=',' read -r ts cpu_tgt cpu_org cpu_syn cpu_tot bw_tgt bw_org bw_syn bw_tot; do
        # Parse timestamp
        local entry_epoch=$(date -d "$ts" '+%s' 2>/dev/null || echo "0")

        # Only include last 7 days
        if [ "$entry_epoch" -ge "$seven_days_ago" ]; then
            # Sample one entry per hour to avoid overcrowding
            local hour=$(date -d "$ts" '+%Y-%m-%d %H:00' 2>/dev/null || echo "$ts")

            if [ "$hour" != "$last_hour" ]; then
                last_hour="$hour"

                local label=$(date -d "$ts" '+%m/%d %H:%M' 2>/dev/null || echo "$ts")

                [ "$count" -gt 0 ] && labels+=","
                labels+="\"$label\""

                [ "$count" -gt 0 ] && cpu_total_data+=","
                cpu_total_data+="$cpu_tot"

                [ "$count" -gt 0 ] && cpu_organic_data+=","
                cpu_organic_data+="$cpu_org"

                [ "$count" -gt 0 ] && cpu_synthetic_data+=","
                cpu_synthetic_data+="$cpu_syn"

                [ "$count" -gt 0 ] && bw_total_data+=","
                bw_total_data+="$bw_tot"

                [ "$count" -gt 0 ] && bw_organic_data+=","
                bw_organic_data+="$bw_org"

                [ "$count" -gt 0 ] && bw_synthetic_data+=","
                bw_synthetic_data+="$bw_syn"

                ((count++))
            fi
        fi
    done | tail -1  # Get last line with accumulated data

    labels+="]"
    cpu_total_data+="]"
    cpu_organic_data+="]"
    cpu_synthetic_data+="]"
    bw_total_data+="]"
    bw_organic_data+="]"
    bw_synthetic_data+="]"

    # Return JSON
    echo "{\"labels\":${labels},\"cpu_total\":${cpu_total_data},\"cpu_organic\":${cpu_organic_data},\"cpu_synthetic\":${cpu_synthetic_data},\"bw_total\":${bw_total_data},\"bw_organic\":${bw_organic_data},\"bw_synthetic\":${bw_synthetic_data}}"
}
