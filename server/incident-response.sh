#!/bin/bash
#
# incident-response.sh - Rapid data collection for incident analysis
#
# Collects system state, logs, and diagnostic info for post-incident analysis.
#
# Usage:
#   ./incident-response.sh [options]
#
# Options:
#   -o, --output DIR    Output directory (default: /tmp/incident-TIMESTAMP)
#   -t, --time MINS     Collect logs from last N minutes (default: 60)
#   -r, --remote HOST   Collect from remote host
#   -k, --k8s           Include Kubernetes data
#   -q, --quick         Quick collection (skip slow operations)
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
OUTPUT_DIR=""
TIME_RANGE=60
REMOTE_HOST=""
INCLUDE_K8S=false
QUICK_MODE=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -t|--time)
                TIME_RANGE="$2"
                shift 2
                ;;
            -r|--remote)
                REMOTE_HOST="$2"
                shift 2
                ;;
            -k|--k8s)
                INCLUDE_K8S=true
                shift
                ;;
            -q|--quick)
                QUICK_MODE=true
                shift
                ;;
            -h|--help)
                grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //' | sed 's/^#//'
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Set default output dir
    if [[ -z "$OUTPUT_DIR" ]]; then
        OUTPUT_DIR="/tmp/incident-${TIMESTAMP}"
    fi
}

# -----------------------------------------------------------------------------
# Remote execution
# -----------------------------------------------------------------------------
run_cmd() {
    if [[ -n "$REMOTE_HOST" ]]; then
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "$1" 2>/dev/null
    else
        eval "$1" 2>/dev/null
    fi
}

save_output() {
    local filename="$1"
    local cmd="$2"
    
    log "  Collecting: $filename"
    run_cmd "$cmd" > "${OUTPUT_DIR}/${filename}" 2>&1 || true
}

# -----------------------------------------------------------------------------
# Collection functions
# -----------------------------------------------------------------------------

collect_system_info() {
    log "Collecting system information..."
    
    save_output "hostname.txt" "hostname -f"
    save_output "uname.txt" "uname -a"
    save_output "uptime.txt" "uptime"
    save_output "os-release.txt" "cat /etc/os-release"
    save_output "date.txt" "date"
    save_output "timezone.txt" "timedatectl"
}

collect_processes() {
    log "Collecting process information..."
    
    save_output "ps-aux.txt" "ps aux"
    save_output "ps-tree.txt" "pstree -p"
    save_output "top.txt" "top -bn1"
    save_output "pgrep-zombie.txt" "ps aux | awk '\$8 ~ /Z/'"
}

collect_memory() {
    log "Collecting memory information..."
    
    save_output "free.txt" "free -h"
    save_output "meminfo.txt" "cat /proc/meminfo"
    save_output "vmstat.txt" "vmstat 1 5"
    save_output "slabinfo.txt" "cat /proc/slabinfo"
}

collect_disk() {
    log "Collecting disk information..."
    
    save_output "df.txt" "df -h"
    save_output "df-inodes.txt" "df -i"
    save_output "mount.txt" "mount"
    save_output "lsblk.txt" "lsblk"
    save_output "iostat.txt" "iostat -x 1 3"
}

collect_network() {
    log "Collecting network information..."
    
    save_output "ip-addr.txt" "ip addr"
    save_output "ip-route.txt" "ip route"
    save_output "ss-tulnp.txt" "ss -tulnp"
    save_output "ss-s.txt" "ss -s"
    save_output "netstat-stats.txt" "netstat -s"
    save_output "iptables.txt" "iptables -L -n -v"
    save_output "conntrack.txt" "conntrack -L 2>/dev/null | head -100"
}

collect_services() {
    log "Collecting service information..."
    
    save_output "systemctl-failed.txt" "systemctl --failed"
    save_output "systemctl-status.txt" "systemctl status"
    save_output "service-list.txt" "systemctl list-units --type=service"
}

collect_logs() {
    log "Collecting logs (last ${TIME_RANGE} minutes)..."
    
    local since="${TIME_RANGE} minutes ago"
    
    save_output "journalctl.txt" "journalctl --since '$since' --no-pager"
    save_output "journalctl-errors.txt" "journalctl --since '$since' -p err --no-pager"
    save_output "dmesg.txt" "dmesg -T"
    
    # Specific log files
    for logfile in /var/log/messages /var/log/syslog /var/log/auth.log /var/log/secure; do
        if run_cmd "test -f $logfile"; then
            local name=$(basename "$logfile")
            save_output "log-${name}" "tail -5000 $logfile"
        fi
    done
}

collect_users() {
    log "Collecting user information..."
    
    save_output "who.txt" "who"
    save_output "w.txt" "w"
    save_output "last.txt" "last -n 50"
    save_output "lastlog.txt" "lastlog"
    save_output "passwd.txt" "cat /etc/passwd"
    save_output "group.txt" "cat /etc/group"
}

collect_cron() {
    log "Collecting scheduled tasks..."
    
    save_output "crontab-root.txt" "crontab -l"
    save_output "etc-crontab.txt" "cat /etc/crontab"
    save_output "cron-d.txt" "ls -la /etc/cron.d/"
}

collect_docker() {
    log "Collecting Docker information..."
    
    if run_cmd "command -v docker &>/dev/null"; then
        save_output "docker-ps.txt" "docker ps -a"
        save_output "docker-stats.txt" "docker stats --no-stream"
        save_output "docker-images.txt" "docker images"
        
        if [[ "$QUICK_MODE" != "true" ]]; then
            save_output "docker-logs.txt" "docker ps -q | xargs -I{} docker logs --tail 100 {} 2>&1"
        fi
    fi
}

collect_kubernetes() {
    log "Collecting Kubernetes information..."
    
    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found, skipping K8s collection"
        return
    fi
    
    mkdir -p "${OUTPUT_DIR}/k8s"
    
    kubectl get nodes -o wide > "${OUTPUT_DIR}/k8s/nodes.txt" 2>&1
    kubectl get pods --all-namespaces -o wide > "${OUTPUT_DIR}/k8s/pods.txt" 2>&1
    kubectl get events --all-namespaces --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/k8s/events.txt" 2>&1
    kubectl top nodes > "${OUTPUT_DIR}/k8s/top-nodes.txt" 2>&1 || true
    kubectl top pods --all-namespaces > "${OUTPUT_DIR}/k8s/top-pods.txt" 2>&1 || true
    
    # Failing pods
    kubectl get pods --all-namespaces --field-selector status.phase!=Running,status.phase!=Succeeded \
        -o wide > "${OUTPUT_DIR}/k8s/failing-pods.txt" 2>&1
    
    if [[ "$QUICK_MODE" != "true" ]]; then
        # Pod logs for failing pods
        kubectl get pods --all-namespaces --field-selector status.phase=Failed -o json 2>/dev/null | \
            jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read -r ns name; do
            kubectl logs "$name" -n "$ns" --tail=200 > "${OUTPUT_DIR}/k8s/log-${ns}-${name}.txt" 2>&1
        done
    fi
}

collect_performance() {
    log "Collecting performance data..."
    
    if [[ "$QUICK_MODE" == "true" ]]; then
        log "  Skipping (quick mode)"
        return
    fi
    
    save_output "sar.txt" "sar -A 2>/dev/null"
    save_output "mpstat.txt" "mpstat -P ALL 1 3"
    save_output "pidstat.txt" "pidstat 1 3"
}

create_manifest() {
    log "Creating manifest..."
    
    cat > "${OUTPUT_DIR}/MANIFEST.txt" << EOF
Incident Response Collection
============================
Timestamp: $(date)
Hostname: $(run_cmd "hostname -f")
Collected by: $(whoami)
Remote host: ${REMOTE_HOST:-local}
Time range: Last ${TIME_RANGE} minutes

Files collected:
$(ls -la "${OUTPUT_DIR}" | tail -n +2)

Chain of custody:
- Collection started: ${TIMESTAMP}
- Collection completed: $(date +%Y%m%d_%H%M%S)
EOF
}

create_archive() {
    local archive="${OUTPUT_DIR}.tar.gz"
    
    log "Creating archive: $archive"
    
    tar -czf "$archive" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"
    
    log_success "Archive created: $archive"
    log "Size: $(du -h "$archive" | cut -f1)"
    
    # Generate checksum
    sha256sum "$archive" > "${archive}.sha256"
    log "Checksum: ${archive}.sha256"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    print_header "Incident Response Collection"
    
    local target="${REMOTE_HOST:-localhost}"
    print_kv "Target" "$target"
    print_kv "Output" "$OUTPUT_DIR"
    print_kv "Time Range" "${TIME_RANGE} minutes"
    print_kv "Quick Mode" "$QUICK_MODE"
    
    echo ""
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Collect data
    collect_system_info
    collect_processes
    collect_memory
    collect_disk
    collect_network
    collect_services
    collect_logs
    collect_users
    collect_cron
    collect_docker
    
    if [[ "$INCLUDE_K8S" == "true" ]]; then
        collect_kubernetes
    fi
    
    collect_performance
    
    # Finalize
    create_manifest
    create_archive
    
    echo ""
    log_success "Collection complete"
    log "Review data in: $OUTPUT_DIR"
}

main "$@"
