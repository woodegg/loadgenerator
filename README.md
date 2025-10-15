# Load Generator System

**Author**: Jun Zhang
**License**: MIT License
**Version**: 1.0

Adaptive CPU and Bandwidth load generator for LXD containers with intelligent monitoring and control.

## Overview

This system generates synthetic CPU and network bandwidth load while monitoring organic system usage. It automatically adjusts synthetic load to maintain target levels without exceeding safety limits.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Load Generator Service                    │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌───────────────┐      ┌──────────────┐     ┌────────────┐│
│  │   Monitor     │─────▶│  Controller  │────▶│  Actuator  ││
│  │   Module      │      │   Module     │     │   Module   ││
│  └───────────────┘      └──────────────┘     └────────────┘│
│         │                      │                     │       │
│         ▼                      ▼                     ▼       │
│  Collect Metrics        Calculate Gap         Generate Load  │
│  - CPU Usage           - Target vs Actual    - stress-ng     │
│  - Bandwidth           - Organic Load        - wget/curl     │
│  - Network I/O         - Needed Synthetic                    │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐  │
│  │              Reporting Module                         │  │
│  │  - Real-time stats                                    │  │
│  │  - Historical data                                    │  │
│  │  - Organic vs Synthetic breakdown                    │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Components

### 1. Monitor Module (`lib/monitor.sh`)
**Responsibilities:**
- Collect system CPU usage from `/proc/stat`
- Collect network bandwidth from `/proc/net/dev`
- Track PIDs of synthetic load generators
- Calculate organic vs synthetic load breakdown

**Key Functions:**
- `get_cpu_usage()` - Returns total CPU percentage
- `get_bandwidth_mbps()` - Returns current network throughput
- `get_organic_load()` - Calculates load excluding synthetic processes

### 2. Controller Module (`lib/controller.sh`)
**Responsibilities:**
- Compare current vs target load
- Calculate required synthetic load adjustments
- Implement safety limits and thresholds
- Decide when to adjust load generators

**Key Functions:**
- `calculate_cpu_gap()` - Determines CPU adjustment needed
- `calculate_bandwidth_gap()` - Determines bandwidth adjustment needed
- `apply_safety_limits()` - Ensures load doesn't exceed maximums
- `should_adjust()` - Determines if adjustment threshold met

**Logic:**
```
gap = target - (organic + current_synthetic)

if gap > threshold:
    increase synthetic load
elif gap < -threshold:
    decrease synthetic load
else:
    maintain current load
```

### 3. Actuator Module (`lib/actuator.sh`)
**Responsibilities:**
- Start/stop/adjust CPU load generators (stress-ng)
- Start/stop/adjust bandwidth generators (wget/curl)
- Track running process PIDs
- Graceful cleanup on shutdown

**Key Functions:**
- `start_cpu_load(workers, load_percent)` - Start stress-ng
- `stop_cpu_load()` - Stop stress-ng processes
- `start_bandwidth_load(rate_mbps, urls)` - Start download loops
- `stop_bandwidth_load()` - Stop bandwidth processes

### 4. Reporter Module (`lib/reporter.sh`)
**Responsibilities:**
- Generate human-readable status reports
- Log CSV statistics for analysis
- Calculate load distribution percentages

**Key Functions:**
- `generate_report()` - Create formatted status report
- `log_stats_csv()` - Append to time-series CSV
- `show_current_status()` - Display real-time stats

### 5. Web Reporter Module (`lib/web_reporter.sh`)
**Responsibilities:**
- Generate cyberpunk-themed HTML dashboard
- Display 7-day historical charts with Chart.js
- Show real-time generator status
- Auto-refresh every 60 seconds

**Key Functions:**
- `generate_html_dashboard()` - Create HTML dashboard
- `generate_chart_data()` - Extract 7-day historical data from CSV

## Configuration

Configuration file: `/etc/loadgen.conf`

```ini
[TARGETS]
CPU_TARGET_PERCENT=50        # Target overall CPU usage %
BANDWIDTH_TARGET_MBPS=100    # Target bandwidth in Mbps

[MONITORING]
MONITOR_INTERVAL=5           # Seconds between monitoring checks
ADJUSTMENT_INTERVAL=10       # Seconds between load adjustments
REPORT_INTERVAL=60          # Seconds between report generation

[SAFETY]
MAX_CPU_PERCENT=90          # Never exceed this CPU%
MAX_BANDWIDTH_MBPS=2000     # Never exceed this bandwidth (tested up to 1800 Mbps)
MIN_ADJUSTMENT_THRESHOLD=5   # Don't adjust if within 5% of target

[BANDWIDTH_SOURCES]
# Public speedtest servers for download testing (space-separated)
# These high-speed servers can deliver 700-900 Mbps each, use multiple for 1000+ Mbps aggregate
DOWNLOAD_URLS="https://speedtest.atlanta.linode.com/1GB-atlanta.bin https://speedtest.newark.linode.com/1GB-newark.bin https://speedtest.dallas.linode.com/1GB-dallas.bin https://speed.cloudflare.com/__down?bytes=1000000000"

[LOGGING]
LOG_LEVEL=INFO
REPORT_FILE=/var/log/loadgen/report.log
STATS_FILE=/var/log/loadgen/stats.csv

[WEB_DASHBOARD]
ENABLE_WEB_DASHBOARD=true   # Enable web dashboard
HTML_REPORT_INTERVAL=60     # Generate HTML every 60 seconds
WEB_ROOT=/var/www/loadgen   # Directory to store HTML files
WEB_PORT=80                 # HTTP server port
```

## Installation

1. Install on container:
```bash
# From host
lxc file push -r ./loadgenerator your-container/root/

# In container
lxc exec your-container -- bash
cd /root/loadgenerator
./install.sh
```

2. Configure targets:
```bash
vim /etc/loadgen.conf
# Edit CPU_TARGET_PERCENT and BANDWIDTH_TARGET_MBPS
```

3. Start services:
```bash
# Start main load generator service
systemctl start loadgen
systemctl enable loadgen

# Start web dashboard (optional, if ENABLE_WEB_DASHBOARD=true)
systemctl start loadgen-web
systemctl enable loadgen-web
```

## Usage

### Service Control
```bash
systemctl start loadgen      # Start load generator
systemctl stop loadgen       # Stop load generator
systemctl restart loadgen    # Restart service
systemctl reload loadgen     # Re-read config without restart
systemctl status loadgen     # Show service status
```

### Monitoring
```bash
loadgen-status              # Show current load breakdown
tail -f /var/log/loadgen/report.log     # Watch reports
tail -f /var/log/loadgen/stats.csv      # Watch CSV stats
journalctl -u loadgen -f    # Watch service logs
```

### Configuration Changes
```bash
vim /etc/loadgen.conf       # Edit configuration
systemctl reload loadgen    # Apply changes
```

### Web Dashboard

If enabled in configuration (`ENABLE_WEB_DASHBOARD=true`):

1. **Access Dashboard:**
   - Direct: `http://<container-ip>:80/`
   - Via reverse proxy: Configure nginx to proxy to container

2. **Features:**
   - Real-time CPU and bandwidth metrics
   - 7-day historical charts with Chart.js
   - Active generator counts and status
   - Auto-refresh every 60 seconds
   - Cyberpunk-themed dark UI

3. **Nginx Reverse Proxy** (for production):
```nginx
location / {
    # CRITICAL: Disable caching for real-time updates
    proxy_cache_bypass 1;
    proxy_no_cache 1;
    add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    add_header Pragma "no-cache" always;
    add_header Expires "0" always;

    proxy_pass http://container-ip:80;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
}
```

## Report Format

```
=== Load Generator Report ===
Timestamp: 2025-10-15 10:00:00

CPU Status:
  Target:    50%
  Organic:   30%  (60% of target)
  Synthetic: 20%  (40% of target)
  Total:     50%  (✓ ON TARGET)

Bandwidth Status:
  Target:    100 Mbps
  Organic:   45 Mbps   (45% of target)
  Synthetic: 50 Mbps   (50% of target)
  Total:     95 Mbps   (95% of target)

Active Generators:
  - stress-ng: 2 workers @ 50% load
  - bandwidth: 3 downloaders @ 16.7 Mbps each

System Health:
  - Load Average: 2.5, 2.3, 2.1
  - Memory: 512MB / 2GB
  - Network: eth0 active
```

## CSV Stats Format

```csv
timestamp,cpu_target,cpu_organic,cpu_synthetic,cpu_total,bw_target,bw_organic,bw_synthetic,bw_total
2025-10-15 10:00:00,50,30,20,50,100,45,50,95
2025-10-15 10:01:00,50,35,15,50,100,60,40,100
```

## File Structure

```
loadgenerator/
├── LICENSE                        # MIT License
├── README.md                      # This file
├── CLAUDE.md                      # Claude Code guidance
├── FAST_SERVERS.md               # High-speed bandwidth server specs
├── TEST_RESULTS.md               # Comprehensive test validation
├── install.sh                     # Installation script
├── loadgen.conf.example           # Example configuration
├── bin/
│   ├── loadgen.sh                # Main service script
│   ├── loadgen-status            # Status utility
│   └── loadgen-webserver         # Web dashboard HTTP server
├── lib/
│   ├── monitor.sh                # Monitoring functions
│   ├── controller.sh             # Control logic
│   ├── actuator.sh               # Load generation
│   ├── reporter.sh               # Reporting functions
│   └── web_reporter.sh           # Web dashboard HTML generation
└── systemd/
    ├── loadgen.service           # Main systemd unit
    └── loadgen-web.service       # Web dashboard systemd unit
```

## Safety Features

1. **Hard Limits**: Never exceed MAX_CPU_PERCENT or MAX_BANDWIDTH_MBPS
2. **Graceful Degradation**: Automatically reduces synthetic load when organic load increases
3. **Threshold Hysteresis**: MIN_ADJUSTMENT_THRESHOLD prevents oscillation
4. **Monitoring Failure Protection**: Shuts down generators if metrics unavailable
5. **Graceful Shutdown**: Properly cleans up all child processes on service stop

## Process Flow

1. **Service Start**
   - Read configuration
   - Initialize monitoring
   - Start with zero synthetic load

2. **Monitoring Loop** (every MONITOR_INTERVAL)
   - Sample CPU usage
   - Sample network bandwidth
   - Identify organic vs synthetic load
   - Update current state

3. **Control Loop** (every ADJUSTMENT_INTERVAL)
   - Get latest metrics
   - Calculate gaps (target - current)
   - Apply safety limits
   - Determine if adjustment needed
   - Send commands to actuator

4. **Actuation**
   - Adjust CPU load (kill old stress-ng, start new)
   - Adjust bandwidth load (kill old wget, start new)

5. **Reporting** (every REPORT_INTERVAL)
   - Generate human-readable report
   - Append CSV statistics
   - Log to files

6. **Loop** back to step 2

## Dependencies

- `stress-ng` - CPU load generation
- `wget` or `curl` - Bandwidth load generation
- `sysstat` (optional) - Enhanced CPU monitoring
- `bc` - Floating point calculations

## Troubleshooting

### Load not reaching target
- Check if safety limits are too low
- Verify network connectivity for bandwidth tests
- Check available CPU cores

### Load exceeding target
- Reduce MIN_ADJUSTMENT_THRESHOLD for faster response
- Check for other processes consuming resources

### Service not starting
- Check logs: `journalctl -u loadgen -xe`
- Verify configuration syntax
- Ensure dependencies installed

## Author & License

**Author**: Jun Zhang

**License**: MIT License - see [LICENSE](LICENSE) file for details

Copyright (c) 2025 Jun Zhang

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

## Documentation

- **README.md**: This file - project overview and usage
- **CLAUDE.md**: Development guidance for Claude Code
- **FAST_SERVERS.md**: Bandwidth server performance specifications
- **TEST_RESULTS.md**: Comprehensive testing and validation results
