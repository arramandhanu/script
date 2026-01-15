#!/bin/bash
#
# etcd-health.sh - etcd cluster health monitoring
#
# Usage:
#   ./etcd-health.sh [command] [options]
#
# Commands:
#   status      Cluster status (default)
#   members     List cluster members
#   leader      Show current leader
#   alarms      Check for alarms
#   defrag      Run defragmentation
#   snapshot    Take a snapshot
#
# Options:
#   --endpoints URL     etcd endpoints (comma-separated)
#   --cacert FILE       CA certificate
#   --cert FILE         Client certificate
#   --key FILE          Client key
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
ENDPOINTS="${ETCD_ENDPOINTS:-http://localhost:2379}"
CACERT="${ETCD_CACERT:-}"
CERT="${ETCD_CERT:-}"
KEY="${ETCD_KEY:-}"
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
            --endpoints)
                ENDPOINTS="$2"
                shift 2
                ;;
            --cacert)
                CACERT="$2"
                shift 2
                ;;
            --cert)
                CERT="$2"
                shift 2
                ;;
            --key)
                KEY="$2"
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
# etcdctl wrapper
# -----------------------------------------------------------------------------
etcdctl_cmd() {
    local cmd="etcdctl --endpoints=$ENDPOINTS"
    
    [[ -n "$CACERT" ]] && cmd="$cmd --cacert=$CACERT"
    [[ -n "$CERT" ]] && cmd="$cmd --cert=$CERT"
    [[ -n "$KEY" ]] && cmd="$cmd --key=$KEY"
    
    $cmd "$@"
}

check_etcdctl() {
    if ! command -v etcdctl &>/dev/null; then
        log_error "etcdctl not found"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        etcdctl_cmd endpoint status --cluster -w json 2>/dev/null | jq .
        return
    fi
    
    print_header "etcd Cluster Status"
    
    # Endpoint health
    print_section "Endpoint Health"
    local health_output
    health_output=$(etcdctl_cmd endpoint health --cluster 2>&1) || true
    
    echo "$health_output" | while read -r line; do
        if echo "$line" | grep -q "is healthy"; then
            log_success "$line"
        elif echo "$line" | grep -q "unhealthy\|failed"; then
            log_error "$line"
        else
            echo "  $line"
        fi
    done
    
    # Endpoint status
    echo ""
    print_section "Endpoint Status"
    printf "  %-30s %-20s %-10s %s\n" "ENDPOINT" "ID" "VERSION" "DB SIZE"
    printf "  %-30s %-20s %-10s %s\n" "--------" "--" "-------" "-------"
    
    etcdctl_cmd endpoint status --cluster -w json 2>/dev/null | \
        jq -r '.[] | "\(.Endpoint)|\(.Status.header.member_id)|\(.Status.version)|\(.Status.dbSize)"' 2>/dev/null | \
    while IFS='|' read -r endpoint id version dbsize; do
        local db_human=$(bytes_to_human "$dbsize")
        printf "  %-30s %-20s %-10s %s\n" "$endpoint" "$id" "$version" "$db_human"
    done
    
    # Leader info
    echo ""
    local leader_id
    leader_id=$(etcdctl_cmd endpoint status --cluster -w json 2>/dev/null | \
        jq -r '.[0].Status.leader' 2>/dev/null)
    print_kv "Leader ID" "$leader_id"
    
    # Alarms
    local alarms
    alarms=$(etcdctl_cmd alarm list 2>/dev/null)
    if [[ -n "$alarms" ]]; then
        echo ""
        log_warn "Active alarms:"
        echo "$alarms"
    fi
}

show_members() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        etcdctl_cmd member list -w json 2>/dev/null | jq .
        return
    fi
    
    print_section "Cluster Members"
    
    printf "  %-20s %-15s %-30s %s\n" "ID" "STATUS" "NAME" "PEER URLs"
    printf "  %-20s %-15s %-30s %s\n" "--" "------" "----" "---------"
    
    etcdctl_cmd member list -w json 2>/dev/null | \
        jq -r '.members[] | "\(.ID)|\(.status)|\(.name)|\(.peerURLs | join(","))"' 2>/dev/null | \
    while IFS='|' read -r id status name peers; do
        local status_display="${GREEN}started${RESET}"
        [[ "$status" != "started" ]] && status_display="${YELLOW}${status}${RESET}"
        
        printf "  %-20s %b  %-30s %s\n" "$id" "$status_display" "$name" "$peers"
    done
}

show_leader() {
    print_section "Current Leader"
    
    local status_json
    status_json=$(etcdctl_cmd endpoint status --cluster -w json 2>/dev/null)
    
    local leader_id
    leader_id=$(echo "$status_json" | jq -r '.[0].Status.leader' 2>/dev/null)
    
    # Find leader endpoint
    local leader_endpoint
    leader_endpoint=$(echo "$status_json" | \
        jq -r --arg lid "$leader_id" '.[] | select(.Status.header.member_id == ($lid | tonumber)) | .Endpoint' 2>/dev/null)
    
    print_kv "Leader ID" "$leader_id"
    print_kv "Leader Endpoint" "$leader_endpoint"
    
    # Raft term
    local raft_term
    raft_term=$(echo "$status_json" | jq -r '.[0].Status.raftTerm' 2>/dev/null)
    print_kv "Raft Term" "$raft_term"
}

show_alarms() {
    print_section "Alarms"
    
    local alarms
    alarms=$(etcdctl_cmd alarm list 2>/dev/null)
    
    if [[ -z "$alarms" ]]; then
        log_success "No active alarms"
    else
        log_warn "Active alarms:"
        echo "$alarms"
        
        echo ""
        if confirm "Disarm all alarms?"; then
            etcdctl_cmd alarm disarm 2>/dev/null
            log_success "Alarms disarmed"
        fi
    fi
}

do_defrag() {
    print_section "Defragmentation"
    
    log_warn "This will defragment all endpoints"
    log_warn "May cause brief service interruption"
    
    if ! confirm "Proceed with defragmentation?"; then
        log "Cancelled"
        return
    fi
    
    log "Running defragmentation..."
    
    etcdctl_cmd defrag --cluster 2>&1 | while read -r line; do
        if echo "$line" | grep -q "Finished"; then
            log_success "$line"
        else
            echo "  $line"
        fi
    done
}

do_snapshot() {
    print_section "Snapshot"
    
    local snapshot_dir="${BACKUP_DIR:-/var/backup/etcd}"
    local snapshot_file="${snapshot_dir}/etcd_$(date +%Y%m%d_%H%M%S).db"
    
    mkdir -p "$snapshot_dir" 2>/dev/null
    
    log "Taking snapshot to $snapshot_file"
    
    if etcdctl_cmd snapshot save "$snapshot_file" 2>/dev/null; then
        log_success "Snapshot saved"
        
        # Show snapshot info
        etcdctl_cmd snapshot status "$snapshot_file" -w table 2>/dev/null
    else
        log_error "Snapshot failed"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_etcdctl
    
    case "$COMMAND" in
        status)   show_status ;;
        members)  show_members ;;
        leader)   show_leader ;;
        alarms)   show_alarms ;;
        defrag)   do_defrag ;;
        snapshot) do_snapshot ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
