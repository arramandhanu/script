#!/bin/bash
#
# patroni-cluster.sh - PostgreSQL/Patroni cluster management
#
# Usage:
#   ./patroni-cluster.sh [command] [options]
#
# Commands:
#   status      Show cluster status (default)
#   lag         Show replication lag
#   switchover  Initiate switchover to replica
#   failover    Initiate failover (force)
#   reinit      Reinitialize a replica
#
# Options:
#   -H, --host HOST     Patroni REST API host
#   -p, --port PORT     Patroni REST API port (default: 8008)
#   -a, --all           Show all nodes
#   -w, --watch         Continuous monitoring
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/db-helpers.sh"

# Configuration
PATRONI_HOST="${PATRONI_HOST:-localhost}"
PATRONI_PORT="${PATRONI_PORT:-8008}"
COMMAND="${1:-status}"
WATCH_MODE=false
JSON_OUTPUT=false
SHOW_ALL=false

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    # First arg is command if not starting with -
    if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
        COMMAND="$1"
        shift
    fi
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -H|--host)
                PATRONI_HOST="$2"
                shift 2
                ;;
            -p|--port)
                PATRONI_PORT="$2"
                shift 2
                ;;
            -a|--all)
                SHOW_ALL=true
                shift
                ;;
            -w|--watch)
                WATCH_MODE=true
                shift
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
# API helpers
# -----------------------------------------------------------------------------

api_call() {
    local endpoint="$1"
    curl -s "http://${PATRONI_HOST}:${PATRONI_PORT}${endpoint}" 2>/dev/null
}

get_cluster() {
    api_call "/cluster"
}

get_leader() {
    api_call "/leader"
}

get_config() {
    api_call "/config"
}

# -----------------------------------------------------------------------------
# Status display
# -----------------------------------------------------------------------------

show_status() {
    local cluster_data
    cluster_data=$(get_cluster)
    
    if [[ -z "$cluster_data" ]]; then
        log_error "Cannot connect to Patroni at ${PATRONI_HOST}:${PATRONI_PORT}"
        return 1
    fi
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$cluster_data" | jq .
        return
    fi
    
    print_header "Patroni Cluster Status"
    
    # Parse cluster info
    local cluster_name=$(echo "$cluster_data" | jq -r '.name // "unknown"')
    local scope=$(echo "$cluster_data" | jq -r '.scope // "unknown"')
    
    print_kv "Cluster" "$cluster_name"
    print_kv "Scope" "$scope"
    print_kv "Endpoint" "${PATRONI_HOST}:${PATRONI_PORT}"
    
    echo ""
    print_section "Members"
    
    # Table header
    printf "  %-20s %-10s %-12s %-15s %s\n" "NAME" "ROLE" "STATE" "HOST" "LAG"
    printf "  %-20s %-10s %-12s %-15s %s\n" "----" "----" "-----" "----" "---"
    
    # Parse members
    echo "$cluster_data" | jq -r '.members[] | "\(.name)|\(.role)|\(.state)|\(.host)|\(.lag // "0")"' 2>/dev/null | \
    while IFS='|' read -r name role state host lag; do
        local role_color=""
        case "$role" in
            leader|master) role_color="${GREEN}" ;;
            replica|sync_standby) role_color="${BLUE}" ;;
            *) role_color="${YELLOW}" ;;
        esac
        
        local state_color=""
        case "$state" in
            running) state_color="${GREEN}" ;;
            stopped|crashed) state_color="${RED}" ;;
            *) state_color="${YELLOW}" ;;
        esac
        
        printf "  %-20s ${role_color}%-10s${RESET} ${state_color}%-12s${RESET} %-15s %s\n" \
            "$name" "$role" "$state" "$host" "${lag}B"
    done
    
    # Timeline info
    echo ""
    local timeline=$(echo "$cluster_data" | jq -r '.members[0].timeline // "unknown"')
    print_kv "Timeline" "$timeline"
}

# -----------------------------------------------------------------------------
# Replication lag
# -----------------------------------------------------------------------------

show_lag() {
    local cluster_data
    cluster_data=$(get_cluster)
    
    if [[ -z "$cluster_data" ]]; then
        log_error "Cannot connect to Patroni"
        return 1
    fi
    
    print_section "Replication Lag"
    
    echo "$cluster_data" | jq -r '.members[] | "\(.name)|\(.role)|\(.lag // 0)"' 2>/dev/null | \
    while IFS='|' read -r name role lag; do
        if [[ "$role" != "leader" && "$role" != "master" ]]; then
            local lag_human
            if [[ $lag -gt 1073741824 ]]; then
                lag_human="$((lag / 1073741824))GB"
            elif [[ $lag -gt 1048576 ]]; then
                lag_human="$((lag / 1048576))MB"
            elif [[ $lag -gt 1024 ]]; then
                lag_human="$((lag / 1024))KB"
            else
                lag_human="${lag}B"
            fi
            
            local status="${GREEN}OK${RESET}"
            if [[ $lag -gt 104857600 ]]; then  # 100MB
                status="${RED}HIGH${RESET}"
            elif [[ $lag -gt 10485760 ]]; then  # 10MB
                status="${YELLOW}WARN${RESET}"
            fi
            
            printf "  %-20s %10s  %b\n" "$name" "$lag_human" "$status"
        fi
    done
}

# -----------------------------------------------------------------------------
# Switchover
# -----------------------------------------------------------------------------

do_switchover() {
    print_section "Switchover"
    
    # Get current cluster state
    local cluster_data
    cluster_data=$(get_cluster)
    
    local current_leader=$(echo "$cluster_data" | jq -r '.members[] | select(.role == "leader" or .role == "master") | .name')
    
    log "Current leader: $current_leader"
    
    # List available replicas
    echo ""
    echo "Available replicas:"
    echo "$cluster_data" | jq -r '.members[] | select(.role == "replica" or .role == "sync_standby") | "  \(.name) (\(.host))"'
    echo ""
    
    local candidate
    read -p "Target replica (leave empty for auto): " candidate
    
    if ! confirm "Initiate switchover from $current_leader?"; then
        log "Switchover cancelled"
        return 0
    fi
    
    log "Initiating switchover..."
    
    local payload="{\"leader\":\"$current_leader\""
    [[ -n "$candidate" ]] && payload="$payload,\"candidate\":\"$candidate\""
    payload="$payload}"
    
    local response
    response=$(curl -s -X POST "http://${PATRONI_HOST}:${PATRONI_PORT}/switchover" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null)
    
    if echo "$response" | grep -qi "success\|switchover"; then
        log_success "Switchover initiated"
        echo "$response"
    else
        log_error "Switchover failed"
        echo "$response"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Reinitialize replica
# -----------------------------------------------------------------------------

do_reinit() {
    print_section "Reinitialize Replica"
    
    # List replicas
    local cluster_data
    cluster_data=$(get_cluster)
    
    echo "Replicas:"
    echo "$cluster_data" | jq -r '.members[] | select(.role != "leader" and .role != "master") | "  \(.name)"'
    echo ""
    
    local replica
    read -p "Replica to reinitialize: " replica
    
    if [[ -z "$replica" ]]; then
        log_error "Replica name required"
        return 1
    fi
    
    log_warn "This will wipe the replica and resync from leader"
    
    if ! confirm "Reinitialize $replica?"; then
        log "Cancelled"
        return 0
    fi
    
    local response
    response=$(curl -s -X POST "http://${PATRONI_HOST}:${PATRONI_PORT}/reinitialize" \
        -H "Content-Type: application/json" \
        -d "{\"member\":\"$replica\"}" 2>/dev/null)
    
    echo "$response"
}

# -----------------------------------------------------------------------------
# Watch mode
# -----------------------------------------------------------------------------

watch_status() {
    while true; do
        clear
        show_status
        echo ""
        echo "Refreshing every 5s... (Ctrl+C to exit)"
        sleep 5
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    if [[ "$WATCH_MODE" == "true" ]]; then
        watch_status
        exit 0
    fi
    
    case "$COMMAND" in
        status)     show_status ;;
        lag)        show_lag ;;
        switchover) do_switchover ;;
        failover)   
            log_warn "Failover is destructive - use switchover if possible"
            do_switchover
            ;;
        reinit)     do_reinit ;;
        config)     get_config | jq . ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
