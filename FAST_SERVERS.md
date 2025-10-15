# High-Speed Bandwidth Server Configuration

## Speed Test Results

### Connection Capability
- **Maximum tested speed**: 2591 Mbps (4 parallel unlimited downloads)
- **Speedtest result**: 1612 Mbps download, 677 Mbps upload

### Individual Server Performance (1GB files)
1. **Linode Atlanta**: 96.8 MB/s (774 Mbps) - Best US East Coast
2. **Linode Newark**: 92.1 MB/s (737 Mbps) - Best US Northeast
3. **Cloudflare**: 87.2 MB/s (698 Mbps) - Global CDN
4. **Linode Dallas**: 43.1 MB/s (345 Mbps) - US Central

## Updated Configuration

The system now uses these high-speed servers in /etc/loadgen.conf

## Bandwidth Control Strategy

### Rate-Limited Mode (< 600 Mbps targets)
- **When**: Target bandwidth < 600 Mbps
- **How**: Multiple downloaders with wget --limit-rate
- **Example**: 500 Mbps target = 4 downloaders @ 125 Mbps each
- **Measured**: ~380-500 Mbps (stable within threshold)

### Unlimited Mode (>= 600 Mbps targets)
- **When**: Target bandwidth >= 600 Mbps
- **How**: Calculated downloader count, no rate limiting
- **Formula**: downloaders = ceil(target / 650 Mbps)
- **Example**: 1000 Mbps target = 2 downloaders unlimited
- **Measured**: ~1300-1420 Mbps (exceeds target as expected)

## Key Improvements

1. **50x faster** than original speedtest servers (10 Mbps to 500+ Mbps)
2. **Gigabit capable** with multiple parallel unlimited downloads
3. **Adaptive control** switches between rate-limited and unlimited modes
4. **Geographic diversity** with multiple Linode datacenters + Cloudflare CDN
5. System tested up to 2591 Mbps successfully
