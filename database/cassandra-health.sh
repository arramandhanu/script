#!/bin/bash
#
# cassandra-health.sh - Cassandra cluster monitoring
#
# Usage:
#   ./cassandra-health.sh [command] [options]
#
# Commands:
#   status      Cluster status (default)
#   ring        Token ring info
#   repair      Repair status
#   compaction  Compaction status
#   keyspaces   List keyspaces
#
# Options:
#   -H, --host HOST     Cassandra host
#   -p, --port PORT     JMX port (default: 7199)
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
CASS_HOST="${CASSANDRA_HOST:-localhost}"
JMX_PORT="${CASSANDRA_JMX_PORT:-7199}"
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
            -H|--host)
                CASS_HOST="$2"
                shift 2
                ;;
            -p|--port)
                JMX_PORT="$2"
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
# nodetool wrapper
# -----------------------------------------------------------------------------
nodetool_cmd() {
    nodetool -h "$CASS_HOST" -p "$JMX_PORT" "$@" 2>/dev/null
}

check_nodetool() {
    if ! command -v nodetool &>/dev/null; then
        log_error "nodetool not found"
        exit 1
    fi
    
    if ! nodetool_cmd info &>/dev/null; then
        log_error "Cannot connect to Cassandra at ${CASS_HOST}:${JMX_PORT}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "Cassandra Cluster Status"
    print_kv "Host" "${CASS_HOST}"
    
    # Node info
    print_section "Node Info"
    
    local info
    info=$(nodetool_cmd info)
    
    echo "$info" | grep -E "^(ID|Load|Generation|Uptime|Heap)" | while read -r line; do
        local key=$(echo "$line" | cut -d: -f1 | xargs)
        local value=$(echo "$line" | cut -d: -f2- | xargs)
        print_kv "$key" "$value"
    done
    
    # Cluster status
    echo ""
    print_section "Cluster Nodes"
    
    local status
    status=$(nodetool_cmd status)
    
    # Parse and colorize status
    echo "$status" | while read -r line; do
        if echo "$line" | grep -qE "^UN "; then
            echo -e "  ${GREEN}$line${RESET}"
        elif echo "$line" | grep -qE "^DN "; then
            echo -e "  ${RED}$line${RESET}"
        elif echo "$line" | grep -qE "^UJ |^UL "; then
            echo -e "  ${YELLOW}$line${RESET}"
        else
            echo "  $line"
        fi
    done
    
    # Count nodes by status
    local up_nodes=$(echo "$status" | grep -cE "^UN " || echo "0")
    local down_nodes=$(echo "$status" | grep -cE "^DN " || echo "0")
    
    echo ""
    print_kv "Nodes UP" "$up_nodes"
    print_kv "Nodes DOWN" "$down_nodes"
    
    if [[ $down_nodes -gt 0 ]]; then
        log_warn "$down_nodes nodes are DOWN"
    fi
}

show_ring() {
    print_section "Token Ring"
    
    nodetool_cmd ring | head -50
    
    local total=$(nodetool_cmd ring | grep -cE "^\w" || echo "0")
    if [[ $total -gt 50 ]]; then
        echo "... and more entries (total: $total)"
    fi
}

show_repair() {
    print_section "Repair Status"
    
    # Check for active repairs
    local active_repairs
    active_repairs=$(nodetool_cmd netstats 2>/dev/null | grep -i "repair" || echo "")
    
    if [[ -z "$active_repairs" ]]; then
        log_success "No active repairs"
    else
        echo "$active_repairs"
    fi
    
    # Thread pool status
    echo ""
    print_section "Thread Pools"
    nodetool_cmd tpstats | grep -E "Repair|Anti" | head -10 || echo "No repair threads"
    
    # Pending tasks
    echo ""
    print_section "Pending Tasks"
    nodetool_cmd tpstats | grep -v "^$" | awk '$2 > 0 || $3 > 0 {print "  " $0}'
}

show_compaction() {
    print_section "Compaction Status"
    
    local compactions
    compactions=$(nodetool_cmd compactionstats 2>/dev/null)
    
    echo "$compactions"
    
    # Pending compactions per keyspace
    echo ""
    print_section "Pending Compactions"
    nodetool_cmd compactionstats 2>/dev/null | grep -i pending || echo "  No pending compactions"
}

show_keyspaces() {
    print_section "Keyspaces"
    
    # List keyspaces with size
    local keyspaces
    keyspaces=$(nodetool_cmd cfstats 2>/dev/null | grep -E "^Keyspace :" | awk '{print $3}')
    
    for ks in $keyspaces; do
        local size
        size=$(nodetool_cmd cfstats "$ks" 2>/dev/null | grep "Space used (total)" | head -1 | awk '{print $NF}')
        printf "  %-30s %s\n" "$ks" "${size:-N/A}"
    done
    
    # Table count
    echo ""
    local table_count
    table_count=$(nodetool_cmd cfstats 2>/dev/null | grep -c "Table:" || echo "0")
    print_kv "Total Tables" "$table_count"
}

show_gossip() {
    print_section "Gossip Info"
    nodetool_cmd gossipinfo | head -50
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_nodetool
    
    case "$COMMAND" in
        status)     show_status ;;
        ring)       show_ring ;;
        repair)     show_repair ;;
        compaction) show_compaction ;;
        keyspaces)  show_keyspaces ;;
        gossip)     show_gossip ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
