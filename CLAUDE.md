# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Adaptive CPU and bandwidth load generator for LXD containers running on Oracle Cloud. Generates synthetic load while monitoring organic system usage, automatically adjusting to maintain target levels with real-time web dashboard.

## Architecture

The system uses a **multi-process control loop architecture** with four independent modules:

```
Monitor → Controller → Actuator → (repeat)
    ↓
Reporter (parallel)
Web Reporter (parallel)
```

**Key Design Pattern**: Modules communicate via a **state file** (`/var/lib/loadgen/state`) for inter-process sharing of synthetic load metrics. This enables independent subprocess loops to coordinate without direct IPC.

### Core Modules

1. **Monitor** (`lib/monitor.sh`): Collects CPU from `/proc/stat`, bandwidth from `/proc/net/dev`, tracks synthetic vs organic load
2. **Controller** (`lib/controller.sh`): Calculates gap between target and current load, applies safety limits, makes adjustment decisions
3. **Actuator** (`lib/actuator.sh`): Executes load changes via `stress-ng` (CPU) and `wget` loops (bandwidth)
4. **Reporter** (`lib/reporter.sh`): Generates text logs and CSV time-series data
5. **Web Reporter** (`lib/web_reporter.sh`): Creates cyberpunk-themed HTML dashboard with 7-day Chart.js graphs

### Critical Implementation Details

**State File Pattern** (`lib/actuator.sh:19-32`):
- Actuator writes: `SYNTHETIC_CPU_PERCENT`, `CPU_WORKERS`, `CPU_LOAD_PERCENT`, `BW_DOWNLOADERS`, `BW_RATE_MBPS`
- Web reporter reads these variables to display accurate generator counts
- **MUST** call `save_state()` after starting/stopping any generators

**Dashboard Display Fix** (`lib/web_reporter.sh:20-29`):
- Web reporter loads state file to get controller variables
- Uses `CPU_WORKERS` and `BW_DOWNLOADERS` (not `CURRENT_*` prefixes)
- Recent bug fix: was showing 0 generators because state file wasn't being loaded

**Bandwidth Control Modes** (`lib/actuator.sh:118-196`):
- **Rate-Limited** (< 600 Mbps): Multiple `wget` processes with `--limit-rate`
- **Unlimited** (≥ 600 Mbps): Count-based downloaders with no rate limiting
- Formula: `downloaders = ceil(target / 650 Mbps)` for unlimited mode

**CPU Synthetic Tracking** (`lib/actuator.sh:73-86`):
- Formula: `(workers × load_percent) / num_cores = total_system_cpu_percent`
- Example: 4 workers @ 50% on 4-core = 50% total CPU
- Tracks both process count and load percentage separately

## Installation and Deployment

### Install on LXD Container
```bash
# From host
lxc file push -r ./loadgenerator container-name/root/

# In container
lxc exec container-name -- bash
cd /root/loadgenerator
./install.sh
```

**Installation Steps** (automated by `install.sh`):
1. Installs dependencies: `stress-ng`, `wget`, `bc`, `curl`
2. Copies binaries to `/usr/local/bin/`
3. Copies libraries to `/usr/local/lib/loadgen/`
4. Creates `/etc/loadgen.conf` from example
5. Creates `/var/log/loadgen/` and `/var/lib/loadgen/` directories
6. Installs systemd services: `loadgen.service`, `loadgen-web.service`

### Configuration
Edit `/etc/loadgen.conf`:
```ini
CPU_TARGET_PERCENT=50          # Total system CPU target
BANDWIDTH_TARGET_MBPS=100      # Total bandwidth target
MAX_CPU_PERCENT=90             # Safety limit
MAX_BANDWIDTH_MBPS=2000        # Safety limit (tested to 2500+ Mbps)
MIN_ADJUSTMENT_THRESHOLD=5     # Hysteresis to prevent oscillation
```

**High-Speed Servers** (configured in `DOWNLOAD_URLS`):
- Linode Atlanta: 774 Mbps sustained
- Linode Newark: 737 Mbps sustained
- Cloudflare CDN: 698 Mbps sustained
- System tested to 2591 Mbps aggregate

### Service Management
```bash
systemctl start loadgen          # Start load generator
systemctl start loadgen-web      # Start web dashboard (optional)
systemctl reload loadgen         # Re-read config without restart
loadgen-status                   # Show current status
loadgen-status live              # Live monitoring
```

## Common Operations

### Change Load Targets
```bash
# In container
lxc exec container-name -- sed -i 's/^CPU_TARGET_PERCENT=.*/CPU_TARGET_PERCENT=75/' /etc/loadgen.conf
lxc exec container-name -- systemctl reload loadgen

# Verify change
lxc exec container-name -- journalctl -u loadgen -n 20
```

### Debug Dashboard Display Issues
If dashboard shows 0 generators but processes are running:

1. **Check state file**:
```bash
lxc exec container -- cat /var/lib/loadgen/state
# Should show: CPU_WORKERS=X, BW_DOWNLOADERS=Y
```

2. **Check running processes**:
```bash
lxc exec container -- ps aux | grep -E 'stress-ng|wget'
```

3. **Verify web_reporter loads state** (`lib/web_reporter.sh:20-24`):
```bash
# Must have: source "$state_file" 2>/dev/null
```

4. **Restart service to reload code**:
```bash
lxc exec container -- systemctl restart loadgen
```

### Monitor Real-Time Metrics
```bash
# View state file updates
lxc exec container -- watch -n 1 cat /var/lib/loadgen/state

# Watch service logs
lxc exec container -- journalctl -u loadgen -f

# View HTML dashboard
# Access: https://your-domain.com/ (via nginx reverse proxy)
```

## Nginx Reverse Proxy Integration

For real-time dashboard updates, nginx reverse proxy **MUST** disable caching:

```nginx
location / {
    proxy_cache_bypass 1;
    proxy_no_cache 1;
    add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    add_header Pragma "no-cache" always;
    add_header Expires "0" always;
    proxy_pass http://backend;
}
```

**Critical**: Dashboard updates every 60 seconds. Without cache bypass, users see stale data for up to 1 minute.

## File Structure

```
loadgenerator/
├── bin/
│   ├── loadgen.sh              # Main service orchestrator (runs 4 background loops)
│   ├── loadgen-status          # CLI status utility
│   └── loadgen-webserver       # Python HTTP server for dashboard
├── lib/
│   ├── monitor.sh              # Metrics collection
│   ├── controller.sh           # Control loop logic
│   ├── actuator.sh             # Load generation (CRITICAL: state file management)
│   ├── reporter.sh             # Text/CSV reporting
│   └── web_reporter.sh         # HTML dashboard generation (CRITICAL: loads state)
├── systemd/
│   ├── loadgen.service         # Main service
│   └── loadgen-web.service     # Web dashboard service
├── install.sh                  # Installation automation
├── loadgen.conf.example        # Example configuration
├── README.md                   # Architecture documentation
├── FAST_SERVERS.md            # Bandwidth server performance data
└── TEST_RESULTS.md            # Comprehensive test validation

Deployed locations (after install.sh):
- Binaries: /usr/local/bin/
- Libraries: /usr/local/lib/loadgen/
- Config: /etc/loadgen.conf
- State: /var/lib/loadgen/state
- Logs: /var/log/loadgen/
- Web: /var/www/loadgen/ (if enabled)
```

## Testing

**Comprehensive test suite** documented in `TEST_RESULTS.md`:
- CPU targets: 50%, 80% (PASS)
- Bandwidth targets: 100, 500, 1000 Mbps (PASS)
- Combined load scenarios (PASS)
- Service stability: 2+ minutes continuous operation (PASS)
- Success rate: 100% (7/7 tests)

**Quick validation**:
```bash
# Set low bandwidth target for testing
lxc exec container -- sed -i 's/^BANDWIDTH_TARGET_MBPS=.*/BANDWIDTH_TARGET_MBPS=100/' /etc/loadgen.conf
lxc exec container -- systemctl restart loadgen

# Wait 30 seconds, then check
lxc exec container -- bash -c 'ps aux | grep wget | grep -v grep | wc -l'
# Should show 2-4 downloaders

lxc exec container -- cat /var/lib/loadgen/state
# Should show BW_DOWNLOADERS matching process count
```

## Known Issues and Solutions

### Issue: Dashboard shows "Active Generators: 0"
**Root Cause**: State file variables not exported or web_reporter not loading state
**Solution**:
1. Check `lib/actuator.sh` exports `CPU_WORKERS`, `BW_DOWNLOADERS` before `save_state()`
2. Check `lib/web_reporter.sh` sources state file at line 20-24
3. Restart service after code changes

### Issue: Bandwidth significantly exceeds target
**Expected Behavior**: When target ≥ 600 Mbps, system uses unlimited mode
**Why**: High-speed servers deliver 700-900 Mbps each, multiple downloaders aggregate
**Solution**: For precise control below 600 Mbps, use rate-limited mode

### Issue: CPU target not reached with organic load
**Cause**: System has existing organic CPU usage
**Behavior**: Controller only adds synthetic load for the gap
**Example**: 30% organic + target 50% = 20% synthetic added
**Solution**: This is correct behavior - system adapts to organic load

## Performance Characteristics

| Configuration | Expected Result | Mode |
|--------------|----------------|------|
| 50% CPU | 40-60% actual | Adaptive (depends on organic) |
| 100 Mbps BW | 100-120 Mbps | Rate-limited (3-4 downloaders) |
| 500 Mbps BW | 500-550 Mbps | Rate-limited (4 downloaders) |
| 1000 Mbps BW | 1400-2500 Mbps | Unlimited (2-3 downloaders) |

System is **production-ready** and tested to 2591 Mbps maximum throughput.
