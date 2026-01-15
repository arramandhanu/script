#!/bin/bash
#
# haproxy-status.sh - HAProxy status and monitoring
#
# Usage:
#   ./haproxy-status.sh [command] [options]
#
# Commands:
#   status      Backend/server status (default)
#   stats       Detailed statistics
#   vip         Check VIP reachability
#   errors      Show error counters
#   sessions    Active session info
#
# Options:
#   -s, --socket PATH   HAProxy admin socket
#   -u, --url URL       HAProxy stats URL
#   -v, --vip IP        VIP address to check
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
HAPROXY_SOCKET="${HAPROXY_SOCKET:-/var/run/haproxy/admin.sock}"
HAPROXY_STATS_URL="${HAPROXY_STATS_URL:-}"
VIP_ADDRESS="${VIP_ADDRESS:-}"
COMMAND="${1:-status}"
JSON_OUTPUT=false

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
        COMMAND="$1"
        shift
    fi
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--socket)
                HAPROXY_SOCKET="$2"
                shift 2
                ;;
            -u|--url)
                HAPROXY_STATS_URL="$2"
                shift 2
                ;;
            -v|--vip)
                VIP_ADDRESS="$2"
                shift 2
                ;;
            -j|--json)
                JSON_OUTPUT=true
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
}

# -----------------------------------------------------------------------------
# HAProxy communication
# -----------------------------------------------------------------------------

haproxy_cmd() {
    local cmd="$1"
    
    if [[ -S "$HAPROXY_SOCKET" ]]; then
        echo "$cmd" | socat stdio "$HAPROXY_SOCKET" 2>/dev/null
    elif [[ -n "$HAPROXY_STATS_URL" ]]; then
        curl -s "$HAPROXY_STATS_URL" 2>/dev/null
    else
        log_error "No HAProxy socket or stats URL configured"
        return 1
    fi
}

check_haproxy() {
    if [[ ! -S "$HAPROXY_SOCKET" && -z "$HAPROXY_STATS_URL" ]]; then
        log_error "HAProxy socket not found and no stats URL configured"
        log "Set HAPROXY_SOCKET or HAPROXY_STATS_URL"
        exit 1
    fi
    
    if ! command -v socat &>/dev/null && [[ -z "$HAPROXY_STATS_URL" ]]; then
        log_error "socat not found (required for socket communication)"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "HAProxy Status"
    
    # Get stats
    local stats
    stats=$(haproxy_cmd "show stat" | tail -n +2)
    
    if [[ -z "$stats" ]]; then
        log_error "Cannot get HAProxy stats"
        return 1
    fi
    
    # Parse and display
    print_section "Backends"
    printf "  %-20s %-15s %-10s %-10s %s\n" "BACKEND" "SERVER" "STATUS" "WEIGHT" "CHECK"
    printf "  %-20s %-15s %-10s %-10s %s\n" "-------" "------" "------" "------" "-----"
    
    echo "$stats" | while IFS=',' read -r pxname svname qcur qmax scur smax slim stot _ _ _ _ status weight _ _ _ _ _ _ _ check_status rest; do
        # Skip FRONTEND entries and stats
        [[ "$svname" == "FRONTEND" || "$pxname" == "stats" ]] && continue
        [[ -z "$pxname" ]] && continue
        
        local status_color="${RED}"
        case "$status" in
            UP|UP*) status_color="${GREEN}" ;;
            DOWN) status_color="${RED}" ;;
            MAINT) status_color="${YELLOW}" ;;
            *) status_color="${BLUE}" ;;
        esac
        
        printf "  %-20s %-15s ${status_color}%-10s${RESET} %-10s %s\n" \
            "$pxname" "$svname" "$status" "$weight" "$check_status"
    done
    
    # Summary
    local total_up=$(echo "$stats" | grep -c ",UP" || echo "0")
    local total_down=$(echo "$stats" | grep -c ",DOWN" || echo "0")
    
    echo ""
    print_kv "Servers UP" "$total_up"
    print_kv "Servers DOWN" "$total_down"
    
    if [[ $total_down -gt 0 ]]; then
        log_warn "$total_down servers are DOWN"
    fi
}

show_stats() {
    print_section "Detailed Statistics"
    
    local info
    info=$(haproxy_cmd "show info")
    
    echo "$info" | grep -E "^(Name|Version|Uptime|CurrConns|CumConns|MaxConn|Tasks|Run_queue)" | while read -r line; do
        local key=$(echo "$line" | cut -d: -f1)
        local value=$(echo "$line" | cut -d: -f2 | xargs)
        print_kv "$key" "$value"
    done
    
    echo ""
    print_section "Connection Stats"
    
    echo "$info" | grep -E "Conn|Sess|Req" | head -10 | while read -r line; do
        echo "  $line"
    done
}

check_vip() {
    print_section "VIP Status"
    
    if [[ -z "$VIP_ADDRESS" ]]; then
        read -p "VIP address: " VIP_ADDRESS
    fi
    
    if [[ -z "$VIP_ADDRESS" ]]; then
        log_error "VIP address required"
        return 1
    fi
    
    print_kv "VIP" "$VIP_ADDRESS"
    
    # Ping test
    if ping -c 3 -W 2 "$VIP_ADDRESS" &>/dev/null; then
        log_success "VIP is reachable"
    else
        log_error "VIP is not reachable"
    fi
    
    # Check which node owns VIP
    local vip_owner
    vip_owner=$(ip addr show 2>/dev/null | grep -B2 "$VIP_ADDRESS" | grep -oP '^\d+: \K[^:]+' || echo "unknown")
    
    if [[ "$vip_owner" != "unknown" ]]; then
        print_kv "VIP Interface" "$vip_owner"
        log_success "This node owns the VIP"
    else
        log "VIP is owned by another node"
    fi
    
    # Check HAProxy is listening on VIP
    local listening
    listening=$(ss -tlnp 2>/dev/null | grep "$VIP_ADDRESS" | head -3)
    
    if [[ -n "$listening" ]]; then
        echo ""
        echo "  Listening ports:"
        echo "$listening" | while read -r line; do
            echo "    $line"
        done
    fi
}

show_errors() {
    print_section "Error Statistics"
    
    local stats
    stats=$(haproxy_cmd "show stat")
    
    # Parse error columns
    echo ""
    printf "  %-20s %-10s %-10s %-10s %-10s\n" "BACKEND" "EREQ" "ECON" "ERESP" "DENIED"
    printf "  %-20s %-10s %-10s %-10s %-10s\n" "-------" "----" "----" "-----" "------"
    
    echo "$stats" | tail -n +2 | while IFS=',' read -r pxname svname _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ ereq econ eresp _ _ dcon rest; do
        [[ "$svname" != "BACKEND" ]] && continue
        [[ -z "$pxname" ]] && continue
        
        local has_errors=false
        [[ "${ereq:-0}" -gt 0 || "${econ:-0}" -gt 0 || "${eresp:-0}" -gt 0 ]] && has_errors=true
        
        if [[ "$has_errors" == "true" ]]; then
            printf "  ${YELLOW}%-20s %-10s %-10s %-10s %-10s${RESET}\n" \
                "$pxname" "${ereq:-0}" "${econ:-0}" "${eresp:-0}" "${dcon:-0}"
        else
            printf "  %-20s %-10s %-10s %-10s %-10s\n" \
                "$pxname" "${ereq:-0}" "${econ:-0}" "${eresp:-0}" "${dcon:-0}"
        fi
    done
}

show_sessions() {
    print_section "Active Sessions"
    
    local info
    info=$(haproxy_cmd "show info")
    
    local curr=$(echo "$info" | grep "^CurrConns:" | awk '{print $2}')
    local max=$(echo "$info" | grep "^MaxConn:" | awk '{print $2}')
    local limit=$(echo "$info" | grep "^Maxsock:" | awk '{print $2}')
    
    print_kv "Current Connections" "$curr"
    print_kv "Max Connections" "$max"
    print_kv "Connection Limit" "$limit"
    
    # Per-backend sessions
    echo ""
    print_section "Sessions per Backend"
    
    local stats
    stats=$(haproxy_cmd "show stat")
    
    echo "$stats" | tail -n +2 | while IFS=',' read -r pxname svname qcur qmax scur smax rest; do
        [[ "$svname" != "BACKEND" ]] && continue
        [[ -z "$pxname" || "$pxname" == "stats" ]] && continue
        
        printf "  %-20s current: %-6s max: %-6s queue: %s\n" "$pxname" "$scur" "$smax" "$qcur"
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_haproxy
    
    case "$COMMAND" in
        status)   show_status ;;
        stats)    show_stats ;;
        vip)      check_vip ;;
        errors)   show_errors ;;
        sessions) show_sessions ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
