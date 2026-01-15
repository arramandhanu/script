#!/bin/bash
#
# security-hardening-audit.sh - Security hardening audit based on CIS benchmarks
#
# Checks common security configurations for Ubuntu and Rocky Linux servers.
#
# Usage:
#   ./security-hardening-audit.sh [options]
#
# Options:
#   -r, --remote HOST   Run audit on remote host via SSH
#   -o, --output FILE   Save report to file
#   -f, --fix           Attempt to fix issues (requires confirmation)
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
REMOTE_HOST=""
OUTPUT_FILE=""
FIX_MODE=false

# Tracking
TOTAL_CHECKS=0
PASSED=0
FAILED=0
WARNINGS=0

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
            -f|--fix)
                FIX_MODE=true
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
# Remote execution
# -----------------------------------------------------------------------------
run_check() {
    if [[ -n "$REMOTE_HOST" ]]; then
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "$1" 2>/dev/null
    else
        eval "$1"
    fi
}

# -----------------------------------------------------------------------------
# Result tracking
# -----------------------------------------------------------------------------
check_result() {
    local name="$1"
    local status="$2"  # PASS, FAIL, WARN
    local message="${3:-}"
    
    ((TOTAL_CHECKS++))
    
    case "$status" in
        PASS)
            ((PASSED++))
            echo -e "  ${GREEN}[PASS]${RESET} $name"
            ;;
        FAIL)
            ((FAILED++))
            echo -e "  ${RED}[FAIL]${RESET} $name"
            [[ -n "$message" ]] && echo "         $message"
            ;;
        WARN)
            ((WARNINGS++))
            echo -e "  ${YELLOW}[WARN]${RESET} $name"
            [[ -n "$message" ]] && echo "         $message"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# SSH Configuration Checks
# -----------------------------------------------------------------------------
check_ssh() {
    print_section "SSH Configuration"
    
    local sshd_config="/etc/ssh/sshd_config"
    
    # Check if SSH config exists
    if ! run_check "test -f $sshd_config && echo yes"; then
        check_result "SSHD Config" "FAIL" "Config file not found"
        return
    fi
    
    # Root login
    local root_login=$(run_check "grep -E '^PermitRootLogin' $sshd_config | awk '{print \$2}'" || echo "not set")
    if [[ "$root_login" == "no" ]]; then
        check_result "SSH Root Login Disabled" "PASS"
    elif [[ "$root_login" == "prohibit-password" ]]; then
        check_result "SSH Root Login" "WARN" "Root login allowed with key only"
    else
        check_result "SSH Root Login Disabled" "FAIL" "Currently: $root_login"
    fi
    
    # Password authentication
    local pass_auth=$(run_check "grep -E '^PasswordAuthentication' $sshd_config | awk '{print \$2}'" || echo "not set")
    if [[ "$pass_auth" == "no" ]]; then
        check_result "SSH Password Auth Disabled" "PASS"
    else
        check_result "SSH Password Auth Disabled" "WARN" "Consider using key-only auth"
    fi
    
    # Empty passwords
    local empty_pass=$(run_check "grep -E '^PermitEmptyPasswords' $sshd_config | awk '{print \$2}'" || echo "no")
    if [[ "$empty_pass" == "no" || -z "$empty_pass" ]]; then
        check_result "SSH Empty Passwords Denied" "PASS"
    else
        check_result "SSH Empty Passwords Denied" "FAIL"
    fi
    
    # Protocol version (for older systems)
    local protocol=$(run_check "grep -E '^Protocol' $sshd_config | awk '{print \$2}'" || echo "2")
    if [[ "$protocol" == "2" || -z "$protocol" ]]; then
        check_result "SSH Protocol 2 Only" "PASS"
    else
        check_result "SSH Protocol 2 Only" "FAIL"
    fi
    
    # X11 Forwarding
    local x11=$(run_check "grep -E '^X11Forwarding' $sshd_config | awk '{print \$2}'" || echo "yes")
    if [[ "$x11" == "no" ]]; then
        check_result "SSH X11 Forwarding Disabled" "PASS"
    else
        check_result "SSH X11 Forwarding Disabled" "WARN" "Enabled but may not be needed"
    fi
    
    # Max auth tries
    local max_auth=$(run_check "grep -E '^MaxAuthTries' $sshd_config | awk '{print \$2}'" || echo "6")
    if [[ "$max_auth" =~ ^[0-9]+$ ]] && (( max_auth <= 4 )); then
        check_result "SSH MaxAuthTries" "PASS" "Set to $max_auth"
    else
        check_result "SSH MaxAuthTries" "WARN" "Currently $max_auth (recommended: 4)"
    fi
}

# -----------------------------------------------------------------------------
# User Account Checks
# -----------------------------------------------------------------------------
check_users() {
    print_section "User Accounts"
    
    # Users with empty passwords
    local empty_pass=$(run_check "awk -F: '(\$2 == \"\" || \$2 == \"!\") {print \$1}' /etc/shadow 2>/dev/null | grep -v '^$' | wc -l" || echo "0")
    if (( empty_pass == 0 )); then
        check_result "No Empty Passwords" "PASS"
    else
        check_result "No Empty Passwords" "FAIL" "Found $empty_pass accounts"
    fi
    
    # Users with UID 0 (besides root)
    local uid0_users=$(run_check "awk -F: '\$3 == 0 && \$1 != \"root\" {print \$1}' /etc/passwd")
    if [[ -z "$uid0_users" ]]; then
        check_result "Only Root has UID 0" "PASS"
    else
        check_result "Only Root has UID 0" "FAIL" "Other users: $uid0_users"
    fi
    
    # Check for accounts without password aging
    local no_aging=$(run_check "awk -F: '\$4 < 1 || \$5 > 99999' /etc/shadow 2>/dev/null | wc -l" || echo "0")
    if (( no_aging <= 2 )); then  # Allow for system accounts
        check_result "Password Aging Configured" "PASS"
    else
        check_result "Password Aging Configured" "WARN" "$no_aging accounts without proper aging"
    fi
    
    # Inactive accounts
    local inactive=$(run_check "lastlog -b 90 2>/dev/null | tail -n +2 | grep -v 'Never logged in' | wc -l" || echo "0")
    check_result "Active User Audit" "WARN" "$inactive users inactive 90+ days"
    
    # Check sudo group members
    local sudo_users=$(run_check "getent group sudo wheel 2>/dev/null | cut -d: -f4")
    if [[ -n "$sudo_users" ]]; then
        check_result "Sudo Users" "WARN" "Review members: $sudo_users"
    fi
}

# -----------------------------------------------------------------------------
# File Permission Checks
# -----------------------------------------------------------------------------
check_permissions() {
    print_section "File Permissions"
    
    # /etc/passwd permissions
    local passwd_perm=$(run_check "stat -c '%a' /etc/passwd 2>/dev/null")
    if [[ "$passwd_perm" == "644" ]]; then
        check_result "/etc/passwd Permissions" "PASS"
    else
        check_result "/etc/passwd Permissions" "FAIL" "Currently $passwd_perm (should be 644)"
    fi
    
    # /etc/shadow permissions
    local shadow_perm=$(run_check "stat -c '%a' /etc/shadow 2>/dev/null")
    if [[ "$shadow_perm" == "000" || "$shadow_perm" == "640" || "$shadow_perm" == "600" ]]; then
        check_result "/etc/shadow Permissions" "PASS"
    else
        check_result "/etc/shadow Permissions" "FAIL" "Currently $shadow_perm"
    fi
    
    # /etc/gshadow permissions
    local gshadow_perm=$(run_check "stat -c '%a' /etc/gshadow 2>/dev/null" || echo "N/A")
    if [[ "$gshadow_perm" == "000" || "$gshadow_perm" == "640" || "$gshadow_perm" == "600" || "$gshadow_perm" == "N/A" ]]; then
        check_result "/etc/gshadow Permissions" "PASS"
    else
        check_result "/etc/gshadow Permissions" "FAIL" "Currently $gshadow_perm"
    fi
    
    # World-writable files (excluding /tmp)
    local world_writable=$(run_check "find /etc /usr /var -type f -perm -0002 2>/dev/null | wc -l" || echo "0")
    if (( world_writable == 0 )); then
        check_result "No World-Writable Files" "PASS"
    else
        check_result "No World-Writable Files" "FAIL" "Found $world_writable files"
    fi
    
    # SUID binaries audit
    local suid_count=$(run_check "find /usr /bin /sbin -type f -perm -4000 2>/dev/null | wc -l" || echo "0")
    check_result "SUID Binaries" "WARN" "$suid_count files with SUID bit (review recommended)"
}

# -----------------------------------------------------------------------------
# Network Security Checks
# -----------------------------------------------------------------------------
check_network() {
    print_section "Network Security"
    
    # IP forwarding disabled
    local ip_forward=$(run_check "sysctl -n net.ipv4.ip_forward 2>/dev/null" || echo "0")
    if [[ "$ip_forward" == "0" ]]; then
        check_result "IP Forwarding Disabled" "PASS"
    else
        check_result "IP Forwarding Disabled" "WARN" "Enabled (expected for routers/k8s nodes)"
    fi
    
    # ICMP redirects
    local icmp_redirect=$(run_check "sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null" || echo "0")
    if [[ "$icmp_redirect" == "0" ]]; then
        check_result "ICMP Redirects Disabled" "PASS"
    else
        check_result "ICMP Redirects Disabled" "WARN" "Consider disabling"
    fi
    
    # Source routing
    local source_route=$(run_check "sysctl -n net.ipv4.conf.all.accept_source_route 2>/dev/null" || echo "0")
    if [[ "$source_route" == "0" ]]; then
        check_result "Source Routing Disabled" "PASS"
    else
        check_result "Source Routing Disabled" "FAIL"
    fi
    
    # Syn cookies
    local syncookies=$(run_check "sysctl -n net.ipv4.tcp_syncookies 2>/dev/null" || echo "1")
    if [[ "$syncookies" == "1" ]]; then
        check_result "SYN Cookies Enabled" "PASS"
    else
        check_result "SYN Cookies Enabled" "FAIL"
    fi
    
    # Open ports audit
    local open_ports=$(run_check "ss -tlnp | tail -n +2 | wc -l" || echo "0")
    check_result "Open Ports" "WARN" "$open_ports TCP ports listening (review recommended)"
}

# -----------------------------------------------------------------------------
# Firewall Checks
# -----------------------------------------------------------------------------
check_firewall() {
    print_section "Firewall"
    
    # Check for iptables/nftables/firewalld
    local fw_active=false
    
    # Check firewalld
    if run_check "systemctl is-active firewalld" &>/dev/null 2>&1; then
        check_result "Firewalld Active" "PASS"
        fw_active=true
    fi
    
    # Check ufw
    if run_check "ufw status 2>/dev/null | grep -q 'Status: active'"; then
        check_result "UFW Active" "PASS"
        fw_active=true
    fi
    
    # Check iptables rules
    local iptables_rules=$(run_check "iptables -L -n 2>/dev/null | grep -v '^Chain\|^target\|^$' | wc -l" || echo "0")
    if (( iptables_rules > 0 )); then
        check_result "IPTables Rules" "PASS" "$iptables_rules rules configured"
        fw_active=true
    fi
    
    if [[ "$fw_active" == "false" ]]; then
        check_result "Firewall" "FAIL" "No active firewall detected"
    fi
}

# -----------------------------------------------------------------------------
# Kernel Hardening Checks
# -----------------------------------------------------------------------------
check_kernel() {
    print_section "Kernel Hardening"
    
    # ASLR
    local aslr=$(run_check "sysctl -n kernel.randomize_va_space 2>/dev/null" || echo "2")
    if [[ "$aslr" == "2" ]]; then
        check_result "ASLR Enabled" "PASS"
    else
        check_result "ASLR Enabled" "FAIL" "Currently: $aslr (should be 2)"
    fi
    
    # Core dumps
    local core_pattern=$(run_check "sysctl -n kernel.core_pattern 2>/dev/null" || echo "")
    if [[ "$core_pattern" == "|/bin/false" || -z "$core_pattern" ]]; then
        check_result "Core Dumps Restricted" "PASS"
    else
        check_result "Core Dumps Restricted" "WARN" "Core dumps may be enabled"
    fi
    
    # Dmesg restriction
    local dmesg_restrict=$(run_check "sysctl -n kernel.dmesg_restrict 2>/dev/null" || echo "0")
    if [[ "$dmesg_restrict" == "1" ]]; then
        check_result "Dmesg Restricted" "PASS"
    else
        check_result "Dmesg Restricted" "WARN" "Non-root users can read kernel logs"
    fi
    
    # Ptrace scope
    local ptrace=$(run_check "sysctl -n kernel.yama.ptrace_scope 2>/dev/null" || echo "0")
    if [[ "$ptrace" -ge "1" ]]; then
        check_result "Ptrace Restricted" "PASS"
    else
        check_result "Ptrace Restricted" "WARN" "Consider enabling ptrace restrictions"
    fi
}

# -----------------------------------------------------------------------------
# Service Checks
# -----------------------------------------------------------------------------
check_services() {
    print_section "Services"
    
    # Unnecessary services
    local risky_services=("telnet" "rsh" "rlogin" "tftp" "vsftpd" "xinetd")
    
    for svc in "${risky_services[@]}"; do
        if run_check "systemctl is-active $svc" &>/dev/null 2>&1; then
            check_result "Service: $svc" "WARN" "Running (consider disabling)"
        fi
    done
    
    # Check for automatic updates
    if is_ubuntu; then
        if run_check "systemctl is-active unattended-upgrades" &>/dev/null 2>&1; then
            check_result "Automatic Updates" "PASS"
        else
            check_result "Automatic Updates" "WARN" "Not enabled"
        fi
    fi
    
    # NTP/Chrony
    if run_check "systemctl is-active chronyd" &>/dev/null 2>&1 || \
       run_check "systemctl is-active systemd-timesyncd" &>/dev/null 2>&1 || \
       run_check "systemctl is-active ntpd" &>/dev/null 2>&1; then
        check_result "Time Sync Service" "PASS"
    else
        check_result "Time Sync Service" "FAIL" "No NTP service active"
    fi
}

# -----------------------------------------------------------------------------
# Audit/Logging Checks
# -----------------------------------------------------------------------------
check_logging() {
    print_section "Logging and Auditing"
    
    # Rsyslog/journald
    if run_check "systemctl is-active rsyslog" &>/dev/null 2>&1 || \
       run_check "systemctl is-active systemd-journald" &>/dev/null 2>&1; then
        check_result "System Logging" "PASS"
    else
        check_result "System Logging" "FAIL"
    fi
    
    # Auditd
    if run_check "systemctl is-active auditd" &>/dev/null 2>&1; then
        check_result "Audit Daemon" "PASS"
    else
        check_result "Audit Daemon" "WARN" "Not running (recommended for compliance)"
    fi
    
    # Check log permissions
    local auth_log_perm=$(run_check "stat -c '%a' /var/log/auth.log 2>/dev/null || stat -c '%a' /var/log/secure 2>/dev/null" || echo "N/A")
    if [[ "$auth_log_perm" == "640" || "$auth_log_perm" == "600" ]]; then
        check_result "Auth Log Permissions" "PASS"
    elif [[ "$auth_log_perm" != "N/A" ]]; then
        check_result "Auth Log Permissions" "WARN" "Currently $auth_log_perm"
    fi
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
    echo ""
    print_section "Audit Summary"
    echo ""
    print_kv "Total Checks" "$TOTAL_CHECKS"
    echo -e "  ${GREEN}Passed${RESET}        : $PASSED"
    echo -e "  ${YELLOW}Warnings${RESET}      : $WARNINGS"
    echo -e "  ${RED}Failed${RESET}        : $FAILED"
    echo ""
    
    local score=$((PASSED * 100 / TOTAL_CHECKS))
    print_kv "Security Score" "${score}%"
    
    if (( FAILED == 0 )); then
        echo -e "\n${GREEN}System passes basic security audit${RESET}"
    elif (( FAILED <= 3 )); then
        echo -e "\n${YELLOW}Minor security improvements recommended${RESET}"
    else
        echo -e "\n${RED}Security improvements required${RESET}"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    # Output redirection
    if [[ -n "$OUTPUT_FILE" ]]; then
        exec > >(tee "$OUTPUT_FILE")
    fi
    
    local target="${REMOTE_HOST:-localhost}"
    
    print_header "Security Hardening Audit"
    print_kv "Target" "$target"
    print_kv "OS" "$(run_check 'cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2' | tr -d '\"')"
    print_kv "Timestamp" "$(date)"
    
    # Run all checks
    check_ssh
    check_users
    check_permissions
    check_network
    check_firewall
    check_kernel
    check_services
    check_logging
    
    print_summary
    
    # Exit code based on failures
    if (( FAILED > 5 )); then
        exit 2  # Critical
    elif (( FAILED > 0 )); then
        exit 1  # Warning
    fi
    exit 0
}

main "$@"
