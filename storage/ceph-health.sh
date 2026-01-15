#!/bin/bash
#
# ceph-health.sh - Ceph cluster health monitoring
#
# Usage:
#   ./ceph-health.sh [command] [options]
#
# Commands:
#   status      Overall cluster status (default)
#   osd         OSD status and utilization
#   pg          Placement group status
#   pool        Pool usage and stats
#   mon         Monitor status
#   health      Health warnings and errors
#
# Options:
#   -w, --watch     Continuous monitoring
#   -j, --json      JSON output
#   -v, --verbose   Detailed output
#   -h, --help      Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
COMMAND="${1:-status}"
WATCH_MODE=false
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
            -w|--watch)
                WATCH_MODE=true
                shift
                ;;
            -j|--json)
                JSON_OUTPUT=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
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
# Check prerequisites
# -----------------------------------------------------------------------------
check_ceph() {
    if ! command -v ceph &>/dev/null; then
        log_error "ceph command not found"
        log "Install ceph-common or run on a ceph node"
        exit 1
    fi
    
    if ! ceph health &>/dev/null; then
        log_error "Cannot connect to ceph cluster"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Status commands
# -----------------------------------------------------------------------------

show_status() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        ceph status -f json-pretty 2>/dev/null
        return
    fi
    
    print_header "Ceph Cluster Status"
    
    # Health
    local health=$(ceph health 2>/dev/null)
    local health_color="${GREEN}"
    
    case "$health" in
        HEALTH_OK*) health_color="${GREEN}" ;;
        HEALTH_WARN*) health_color="${YELLOW}" ;;
        HEALTH_ERR*) health_color="${RED}" ;;
    esac
    
    echo -e "  Health: ${health_color}${health}${RESET}"
    echo ""
    
    # Cluster ID
    local fsid=$(ceph fsid 2>/dev/null)
    print_kv "Cluster ID" "$fsid"
    
    # Mon status
    local mon_quorum=$(ceph quorum_status 2>/dev/null | jq -r '.quorum_names | join(", ")' 2>/dev/null)
    print_kv "Mon Quorum" "$mon_quorum"
    
    # OSD summary
    local osd_stat=$(ceph osd stat 2>/dev/null)
    print_kv "OSDs" "$osd_stat"
    
    # PG summary
    local pg_stat=$(ceph pg stat 2>/dev/null)
    print_kv "PGs" "$pg_stat"
    
    # Usage
    echo ""
    print_section "Storage Usage"
    ceph df 2>/dev/null | head -10
}

show_osd() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        ceph osd tree -f json-pretty 2>/dev/null
        return
    fi
    
    print_section "OSD Status"
    
    # OSD tree
    echo ""
    ceph osd tree 2>/dev/null
    
    # OSD utilization
    echo ""
    print_section "OSD Utilization"
    ceph osd df 2>/dev/null | head -20
    
    # Check for full/nearfull
    local nearfull=$(ceph osd df 2>/dev/null | awk '$7 > 80 {print $1}' | wc -l)
    if [[ $nearfull -gt 0 ]]; then
        echo ""
        log_warn "$nearfull OSDs above 80% utilization"
    fi
}

show_pg() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        ceph pg stat -f json-pretty 2>/dev/null
        return
    fi
    
    print_section "Placement Group Status"
    
    # PG summary
    ceph pg stat 2>/dev/null
    echo ""
    
    # PG states
    print_section "PG States"
    ceph pg dump_stuck 2>/dev/null | head -20 || echo "No stuck PGs"
    
    # Degraded PGs
    local degraded=$(ceph pg dump 2>/dev/null | grep -c "degraded" || echo "0")
    if [[ $degraded -gt 0 ]]; then
        echo ""
        log_warn "$degraded degraded PGs"
    fi
}

show_pool() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        ceph df -f json-pretty 2>/dev/null
        return
    fi
    
    print_section "Pool Status"
    
    # Pool list with usage
    ceph df detail 2>/dev/null
    
    echo ""
    print_section "Pool Statistics"
    ceph osd pool stats 2>/dev/null | head -30
}

show_mon() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        ceph mon dump -f json-pretty 2>/dev/null
        return
    fi
    
    print_section "Monitor Status"
    
    # Mon quorum
    echo "Quorum:"
    ceph quorum_status 2>/dev/null | jq -r '.quorum_names[]' 2>/dev/null | while read -r mon; do
        echo "  $mon"
    done
    
    echo ""
    
    # Mon stat
    ceph mon stat 2>/dev/null
    
    echo ""
    print_section "Monitor Details"
    ceph mon dump 2>/dev/null | grep -E "^[0-9]|elected"
}

show_health() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        ceph health detail -f json-pretty 2>/dev/null
        return
    fi
    
    print_section "Health Details"
    
    local health=$(ceph health 2>/dev/null)
    
    case "$health" in
        HEALTH_OK*)
            log_success "Cluster is healthy"
            ;;
        HEALTH_WARN*)
            log_warn "Cluster has warnings"
            echo ""
            ceph health detail 2>/dev/null
            ;;
        HEALTH_ERR*)
            log_error "Cluster has errors"
            echo ""
            ceph health detail 2>/dev/null
            ;;
    esac
    
    # Slow requests
    echo ""
    print_section "Slow Requests"
    local slow=$(ceph daemon osd.0 dump_historic_slow_ops 2>/dev/null | jq '.num_ops' 2>/dev/null || echo "N/A")
    print_kv "Slow ops" "$slow"
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
    check_ceph
    
    if [[ "$WATCH_MODE" == "true" ]]; then
        watch_status
        exit 0
    fi
    
    case "$COMMAND" in
        status)  show_status ;;
        osd)     show_osd ;;
        pg)      show_pg ;;
        pool)    show_pool ;;
        mon)     show_mon ;;
        health)  show_health ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
