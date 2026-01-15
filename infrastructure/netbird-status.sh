#!/bin/bash
#
# netbird-status.sh - Netbird VPN status monitoring
#
# Usage:
#   ./netbird-status.sh [command] [options]
#
# Commands:
#   status      Connection status (default)
#   peers       List connected peers
#   routes      Show routes
#   dns         DNS configuration
#
# Options:
#   -j, --json      JSON output
#   -h, --help      Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

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
# Check netbird
# -----------------------------------------------------------------------------
check_netbird() {
    if ! command -v netbird &>/dev/null; then
        log_error "netbird command not found"
        log "Install from: https://netbird.io"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "Netbird Status"
    
    local status
    status=$(netbird status 2>/dev/null)
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        netbird status --json 2>/dev/null
        return
    fi
    
    # Parse status
    local daemon_status=$(echo "$status" | grep -i "daemon" | head -1)
    local mgmt=$(echo "$status" | grep -i "management" | head -1)
    local signal=$(echo "$status" | grep -i "signal" | head -1)
    local relays=$(echo "$status" | grep -i "relays" | head -1)
    local ip=$(echo "$status" | grep -i "netbird ip" | head -1)
    local interface=$(echo "$status" | grep -i "interface" | head -1)
    
    # Connection status
    if echo "$status" | grep -qi "connected"; then
        log_success "Netbird is connected"
    else
        log_warn "Netbird is not connected"
    fi
    
    echo ""
    print_section "Connection Details"
    
    [[ -n "$daemon_status" ]] && echo "  $daemon_status"
    [[ -n "$mgmt" ]] && echo "  $mgmt"
    [[ -n "$signal" ]] && echo "  $signal"
    [[ -n "$relays" ]] && echo "  $relays"
    [[ -n "$ip" ]] && echo "  $ip"
    [[ -n "$interface" ]] && echo "  $interface"
    
    # Peer count
    local peer_count=$(echo "$status" | grep -c "Peer" || echo "0")
    echo ""
    print_kv "Peers" "$peer_count"
}

show_peers() {
    print_section "Connected Peers"
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        netbird status --json 2>/dev/null | jq '.peers // []'
        return
    fi
    
    local status
    status=$(netbird status 2>/dev/null)
    
    # Extract peer info
    echo "$status" | grep -A5 "Peers:" | tail -n +2 | while read -r line; do
        [[ -z "$line" ]] && continue
        echo "  $line"
    done
    
    if ! echo "$status" | grep -q "Peer"; then
        log "No peers connected"
    fi
}

show_routes() {
    print_section "Routes"
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        netbird status --json 2>/dev/null | jq '.routes // []'
        return
    fi
    
    local status
    status=$(netbird status 2>/dev/null)
    
    echo "$status" | grep -i "route" | while read -r line; do
        echo "  $line"
    done
    
    # Also show system routes for netbird interface
    echo ""
    print_section "System Routes (wt0)"
    ip route show dev wt0 2>/dev/null | while read -r line; do
        echo "  $line"
    done || echo "  No system routes found for wt0"
}

show_dns() {
    print_section "DNS Configuration"
    
    local status
    status=$(netbird status 2>/dev/null)
    
    echo "$status" | grep -iE "dns|nameserver" | while read -r line; do
        echo "  $line"
    done
    
    # Check resolved conf
    if [[ -f /etc/resolv.conf ]]; then
        echo ""
        echo "  System resolv.conf:"
        grep nameserver /etc/resolv.conf | head -5 | while read -r line; do
            echo "    $line"
        done
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_netbird
    
    case "$COMMAND" in
        status) show_status ;;
        peers)  show_peers ;;
        routes) show_routes ;;
        dns)    show_dns ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
