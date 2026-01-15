#!/bin/bash
#
# vm-health-check.sh - Comprehensive server health check
#
# Usage:
#   ./vm-health-check.sh [options]
#
# Options:
#   -r, --remote HOST   Run check on remote host via SSH
#   -o, --output FILE   Save report to file
#   -j, --json          Output as JSON
#   -q, --quiet         Only show warnings and errors
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
REMOTE_HOST=""
OUTPUT_FILE=""
OUTPUT_FORMAT="text"
QUIET=false

# Thresholds
CPU_WARN=80
MEM_WARN=80
DISK_WARN=80
LOAD_WARN=2.0  # per core

# Results tracking
ISSUES=0

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--remote)
                REMOTE_HOST="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -j|--json)
                OUTPUT_FORMAT="json"
                shift
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -h|--help)
                grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //' | sed 's/^#//'
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Remote execution wrapper
# -----------------------------------------------------------------------------
run_check() {
    if [[ -n "$REMOTE_HOST" ]]; then
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "$1" 2>/dev/null
    else
        eval "$1"
    fi
}

# Output helper
output() {
    local level="${1:-INFO}"
    local msg="$2"
    
    if [[ "$QUIET" == "true" && "$level" == "INFO" ]]; then
        return
    fi
    
    case "$level" in
        WARN)  log_warn "$msg"; ((ISSUES++)) ;;
        ERROR) log_error "$msg"; ((ISSUES++)) ;;
        OK)    log_success "$msg" ;;
        *)     echo "  $msg" ;;
    esac
}

# -----------------------------------------------------------------------------
# Health check functions
# -----------------------------------------------------------------------------

# System information
check_system_info() {
    print_section "System Information"
    
    local hostname=$(run_check "hostname")
    local os_name=$(run_check "cat /etc/os-release 2>/dev/null | grep '^PRETTY_NAME' | cut -d= -f2 | tr -d '\"'" || echo "Unknown")
    local kernel=$(run_check "uname -r")
    local uptime=$(run_check "uptime -p 2>/dev/null || uptime | awk '{print \$3,\$4}'" | sed 's/,$//')
    
    print_kv "Hostname" "$hostname"
    print_kv "OS" "$os_name"
    print_kv "Kernel" "$kernel"
    print_kv "Uptime" "$uptime"
}

# CPU check
check_cpu() {
    print_section "CPU"
    
    local cores=$(run_check "nproc")
    local model=$(run_check "grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs" || echo "Unknown")
    
    # Get load average
    local load=$(run_check "cat /proc/loadavg | awk '{print \$1}'")
    local load_per_core=$(echo "scale=2; $load / $cores" | bc 2>/dev/null || echo "0")
    
    # Get CPU usage from top
    local cpu_usage=$(run_check "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}' | cut -d. -f1" 2>/dev/null || echo "0")
    
    print_kv "Model" "$model"
    print_kv "Cores" "$cores"
    print_kv "Load Average" "$load (${load_per_core}/core)"
    print_kv "CPU Usage" "${cpu_usage}%"
    
    # Check thresholds
    if [[ "$cpu_usage" =~ ^[0-9]+$ ]] && (( cpu_usage >= CPU_WARN )); then
        output WARN "CPU usage at ${cpu_usage}% (threshold: ${CPU_WARN}%)"
    fi
    
    local load_int=${load_per_core%.*}
    local warn_int=${LOAD_WARN%.*}
    if [[ "$load_int" =~ ^[0-9]+$ ]] && (( load_int >= warn_int )); then
        output WARN "Load per core at ${load_per_core} (threshold: ${LOAD_WARN})"
    fi
}

# Memory check
check_memory() {
    print_section "Memory"
    
    local mem_info=$(run_check "free -m | grep '^Mem:'")
    local mem_total=$(echo "$mem_info" | awk '{print $2}')
    local mem_used=$(echo "$mem_info" | awk '{print $3}')
    local mem_free=$(echo "$mem_info" | awk '{print $4}')
    local mem_available=$(echo "$mem_info" | awk '{print $7}')
    
    local mem_pct=$((mem_used * 100 / mem_total))
    
    print_kv "Total" "${mem_total}MB"
    print_kv "Used" "${mem_used}MB (${mem_pct}%)"
    print_kv "Available" "${mem_available:-$mem_free}MB"
    
    # Swap
    local swap_info=$(run_check "free -m | grep '^Swap:'")
    local swap_total=$(echo "$swap_info" | awk '{print $2}')
    local swap_used=$(echo "$swap_info" | awk '{print $3}')
    
    if [[ "$swap_total" != "0" ]]; then
        local swap_pct=$((swap_used * 100 / swap_total))
        print_kv "Swap Used" "${swap_used}MB / ${swap_total}MB (${swap_pct}%)"
    fi
    
    if (( mem_pct >= MEM_WARN )); then
        output WARN "Memory usage at ${mem_pct}% (threshold: ${MEM_WARN}%)"
    fi
}

# Disk check
check_disk() {
    print_section "Disk Usage"
    
    echo ""
    
    run_check "df -h -x tmpfs -x devtmpfs -x squashfs 2>/dev/null" | \
    while read -r filesystem size used avail pct mount; do
        # Skip header
        [[ "$filesystem" == "Filesystem" ]] && continue
        
        # Get percentage as number
        local pct_num=${pct%\%}
        
        if [[ "$pct_num" =~ ^[0-9]+$ ]]; then
            if (( pct_num >= DISK_WARN )); then
                output WARN "$mount: ${pct} used (${avail} available)"
            else
                output INFO "$mount: ${pct} used (${avail} available)"
            fi
        fi
    done
    
    # Check inode usage
    echo ""
    echo "  Inode Usage:"
    run_check "df -i -x tmpfs -x devtmpfs -x squashfs 2>/dev/null" | \
    while read -r filesystem inodes iused ifree pct mount; do
        [[ "$filesystem" == "Filesystem" ]] && continue
        local pct_num=${pct%\%}
        
        if [[ "$pct_num" =~ ^[0-9]+$ ]] && (( pct_num >= DISK_WARN )); then
            output WARN "$mount: Inode usage at ${pct}"
        fi
    done
}

# Network interfaces
check_network() {
    print_section "Network"
    
    echo ""
    
    # Get interfaces
    run_check "ip -br addr 2>/dev/null" | while read -r iface state addr rest; do
        [[ "$iface" == "lo" ]] && continue
        
        local status="$state"
        if [[ "$state" == "UP" ]]; then
            output OK "$iface: $state - $addr"
        else
            output WARN "$iface: $state"
        fi
    done
    
    # Check default gateway
    local gateway=$(run_check "ip route | grep default | awk '{print \$3}' | head -1")
    if [[ -n "$gateway" ]]; then
        echo ""
        print_kv "Default Gateway" "$gateway"
        
        # Ping test
        if run_check "ping -c 1 -W 2 $gateway &>/dev/null"; then
            output OK "Gateway reachable"
        else
            output WARN "Gateway unreachable"
        fi
    fi
}

# Process check
check_processes() {
    print_section "Processes"
    
    local total=$(run_check "ps aux --no-headers 2>/dev/null | wc -l")
    local zombies=$(run_check "ps aux 2>/dev/null | grep -c ' Z '" || echo "0")
    local running=$(run_check "ps aux 2>/dev/null | grep -c ' R '" || echo "0")
    
    print_kv "Total" "$total"
    print_kv "Running" "$running"
    print_kv "Zombies" "$zombies"
    
    if (( zombies > 0 )); then
        output WARN "Found $zombies zombie processes"
        [[ "$VERBOSE" == "true" ]] && run_check "ps aux | awk '\$8 ~ /Z/ {print \"  PID:\", \$2, \"CMD:\", \$11}'"
    fi
    
    # Top processes by CPU
    echo ""
    echo "  Top CPU consumers:"
    run_check "ps aux --sort=-%cpu 2>/dev/null | head -4 | tail -3 | awk '{printf \"    %-8s %5s%% %s\\n\", \$2, \$3, \$11}'"
    
    # Top processes by memory
    echo ""
    echo "  Top memory consumers:"
    run_check "ps aux --sort=-%mem 2>/dev/null | head -4 | tail -3 | awk '{printf \"    %-8s %5s%% %s\\n\", \$2, \$4, \$11}'"
}

# Service check
check_services() {
    print_section "Services"
    
    # Check for failed systemd services
    local failed=$(run_check "systemctl --failed --no-legend 2>/dev/null | wc -l" || echo "0")
    
    if (( failed > 0 )); then
        output WARN "$failed failed services"
        echo ""
        run_check "systemctl --failed --no-legend 2>/dev/null" | while read -r line; do
            echo "    $line"
        done
    else
        output OK "No failed services"
    fi
    
    # Check critical services
    echo ""
    echo "  Critical Services:"
    local services=("sshd" "chronyd" "systemd-journald")
    
    for svc in "${services[@]}"; do
        if run_check "systemctl is-active $svc &>/dev/null"; then
            output INFO "$svc: running"
        else
            # Try alternative names
            if run_check "systemctl is-active ${svc}.service &>/dev/null 2>&1"; then
                output INFO "$svc: running"
            fi
        fi
    done
}

# Security check (quick audit)
check_security() {
    print_section "Security Quick Check"
    
    # Check for pending security updates (distro-specific)
    local os_type=$(get_os_type)
    
    if is_ubuntu; then
        local sec_updates=$(run_check "apt list --upgradable 2>/dev/null | grep -c security" || echo "0")
        if (( sec_updates > 0 )); then
            output WARN "$sec_updates security updates available"
        else
            output OK "No pending security updates"
        fi
    elif is_rhel_family; then
        local sec_updates=$(run_check "yum check-update --security 2>/dev/null | grep -c 'security'" || echo "0")
        if (( sec_updates > 0 )); then
            output WARN "$sec_updates security updates available"
        else
            output OK "No pending security updates"
        fi
    fi
    
    # Check SSH config
    local root_login=$(run_check "grep '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}'" || echo "unknown")
    print_kv "SSH Root Login" "$root_login"
    
    if [[ "$root_login" == "yes" ]]; then
        output WARN "SSH root login is enabled"
    fi
    
    # Check for users with empty passwords
    local empty_pass=$(run_check "awk -F: '\$2==\"\"' /etc/shadow 2>/dev/null | wc -l" || echo "0")
    if (( empty_pass > 0 )); then
        output WARN "$empty_pass users with empty password"
    fi
    
    # Check listening ports
    echo ""
    echo "  Listening Ports (public):"
    run_check "ss -tlnp 2>/dev/null | grep -v '127.0.0.1' | tail -n +2 | head -10" | while read -r line; do
        echo "    $line"
    done
}

# File descriptor check
check_fd_limits() {
    print_section "File Descriptors"
    
    local max_fd=$(run_check "cat /proc/sys/fs/file-max")
    local used_fd=$(run_check "cat /proc/sys/fs/file-nr | awk '{print \$1}'")
    local used_pct=$((used_fd * 100 / max_fd))
    
    print_kv "Max" "$max_fd"
    print_kv "Used" "$used_fd (${used_pct}%)"
    
    if (( used_pct >= 80 )); then
        output WARN "File descriptor usage at ${used_pct}%"
    fi
}

# Kernel messages
check_kernel() {
    print_section "Kernel Messages (recent errors)"
    
    local errors=$(run_check "dmesg -T --level=err,crit,alert,emerg 2>/dev/null | tail -5" || echo "")
    
    if [[ -z "$errors" ]]; then
        output OK "No recent kernel errors"
    else
        output WARN "Kernel errors found:"
        echo "$errors" | while read -r line; do
            echo "    $line"
        done
    fi
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

print_summary() {
    echo ""
    print_section "Summary"
    
    if (( ISSUES == 0 )); then
        echo ""
        echo -e "${GREEN}Server is healthy - no issues found${RESET}"
    else
        echo ""
        echo -e "${YELLOW}Found $ISSUES issue(s) requiring attention${RESET}"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    # Start output redirect if specified
    if [[ -n "$OUTPUT_FILE" ]]; then
        exec > >(tee "$OUTPUT_FILE")
    fi
    
    local target="${REMOTE_HOST:-localhost}"
    
    print_header "Server Health Check"
    print_kv "Target" "$target"
    print_kv "Timestamp" "$(date)"
    
    # Run all checks
    check_system_info
    check_cpu
    check_memory
    check_disk
    check_network
    check_processes
    check_services
    check_security
    check_fd_limits
    check_kernel
    
    print_summary
    
    exit $ISSUES
}

main "$@"
