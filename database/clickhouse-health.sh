#!/bin/bash
#
# clickhouse-health.sh - ClickHouse cluster monitoring
#
# Usage:
#   ./clickhouse-health.sh [command] [options]
#
# Commands:
#   status      Cluster status (default)
#   queries     Running queries
#   replication Replication status
#   tables      Table sizes
#   merges      Merge operations
#
# Options:
#   -H, --host HOST     ClickHouse host
#   -p, --port PORT     ClickHouse HTTP port (default: 8123)
#   -u, --user USER     Username
#   -P, --password PWD  Password
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
CH_HOST="${CLICKHOUSE_HOST:-localhost}"
CH_PORT="${CLICKHOUSE_PORT:-8123}"
CH_USER="${CLICKHOUSE_USER:-default}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
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
                CH_HOST="$2"
                shift 2
                ;;
            -p|--port)
                CH_PORT="$2"
                shift 2
                ;;
            -u|--user)
                CH_USER="$2"
                shift 2
                ;;
            -P|--password)
                CH_PASSWORD="$2"
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
# Query helper
# -----------------------------------------------------------------------------
ch_query() {
    local query="$1"
    local format="${2:-TabSeparated}"
    
    local auth=""
    [[ -n "$CH_PASSWORD" ]] && auth="--password $CH_PASSWORD"
    
    if command -v clickhouse-client &>/dev/null; then
        clickhouse-client -h "$CH_HOST" --port 9000 \
            -u "$CH_USER" $auth \
            --query "$query" 2>/dev/null
    else
        # Use HTTP interface
        local url="http://${CH_HOST}:${CH_PORT}/?user=${CH_USER}"
        [[ -n "$CH_PASSWORD" ]] && url="${url}&password=${CH_PASSWORD}"
        
        curl -s --data-binary "$query" "$url" 2>/dev/null
    fi
}

check_ch() {
    if ! curl -s "http://${CH_HOST}:${CH_PORT}/ping" 2>/dev/null | grep -q "Ok"; then
        log_error "Cannot connect to ClickHouse at ${CH_HOST}:${CH_PORT}"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "ClickHouse Status"
    print_kv "Host" "${CH_HOST}:${CH_PORT}"
    
    # Version
    local version
    version=$(ch_query "SELECT version()")
    print_kv "Version" "$version"
    
    # Uptime
    local uptime
    uptime=$(ch_query "SELECT formatReadableTimeDelta(uptime())")
    print_kv "Uptime" "$uptime"
    
    # Cluster info
    echo ""
    print_section "Cluster Nodes"
    
    local cluster_info
    cluster_info=$(ch_query "SELECT cluster, host_name, port, is_local FROM system.clusters FORMAT PrettyCompact" 2>/dev/null || echo "No cluster configured")
    echo "$cluster_info"
    
    # Memory usage
    echo ""
    print_section "Memory"
    
    local memory
    memory=$(ch_query "SELECT 
        formatReadableSize(sum(memory_usage)) as memory_usage,
        count() as query_count
    FROM system.processes")
    print_kv "Active Query Memory" "$memory"
    
    # Disk usage
    echo ""
    print_section "Disk Usage"
    
    ch_query "SELECT 
        name,
        formatReadableSize(free_space) as free,
        formatReadableSize(total_space) as total,
        round(100 * (1 - free_space/total_space), 1) as used_pct
    FROM system.disks
    FORMAT PrettyCompact"
}

show_queries() {
    print_section "Running Queries"
    
    local queries
    queries=$(ch_query "SELECT 
        query_id,
        user,
        formatReadableTimeDelta(elapsed) as elapsed,
        formatReadableSize(memory_usage) as memory,
        substr(query, 1, 80) as query
    FROM system.processes
    WHERE query NOT LIKE '%system.processes%'
    ORDER BY elapsed DESC
    LIMIT 20
    FORMAT PrettyCompact")
    
    if [[ -z "$queries" ]]; then
        log_success "No long-running queries"
    else
        echo "$queries"
    fi
    
    # Query statistics
    echo ""
    print_section "Query Statistics (last hour)"
    
    ch_query "SELECT
        type,
        count() as count,
        formatReadableSize(sum(memory_usage)) as memory,
        round(avg(query_duration_ms), 0) as avg_ms
    FROM system.query_log
    WHERE event_time > now() - INTERVAL 1 HOUR
    GROUP BY type
    FORMAT PrettyCompact" 2>/dev/null || echo "Query log not available"
}

show_replication() {
    print_section "Replication Status"
    
    # Replicated tables
    local tables
    tables=$(ch_query "SELECT 
        database,
        table,
        is_leader,
        total_replicas,
        active_replicas,
        queue_size,
        log_pointer
    FROM system.replicas
    ORDER BY queue_size DESC
    FORMAT PrettyCompact" 2>/dev/null)
    
    if [[ -z "$tables" ]]; then
        log "No replicated tables found"
        return
    fi
    
    echo "$tables"
    
    # Check for issues
    local queue_issues
    queue_issues=$(ch_query "SELECT count() FROM system.replicas WHERE queue_size > 100" 2>/dev/null)
    
    if [[ ${queue_issues:-0} -gt 0 ]]; then
        echo ""
        log_warn "Tables with large replication queue:"
        ch_query "SELECT database, table, queue_size 
            FROM system.replicas 
            WHERE queue_size > 100 
            FORMAT PrettyCompact"
    fi
}

show_tables() {
    print_section "Table Sizes"
    
    ch_query "SELECT 
        database,
        table,
        formatReadableSize(sum(bytes)) as size,
        sum(rows) as rows,
        count() as parts
    FROM system.parts
    WHERE active
    GROUP BY database, table
    ORDER BY sum(bytes) DESC
    LIMIT 20
    FORMAT PrettyCompact"
    
    # Total size
    echo ""
    local total
    total=$(ch_query "SELECT formatReadableSize(sum(bytes)) FROM system.parts WHERE active")
    print_kv "Total Data Size" "$total"
}

show_merges() {
    print_section "Merge Operations"
    
    local merges
    merges=$(ch_query "SELECT 
        database,
        table,
        round(progress * 100, 1) as progress_pct,
        formatReadableSize(total_size_bytes_compressed) as size,
        formatReadableTimeDelta(elapsed) as elapsed
    FROM system.merges
    ORDER BY elapsed DESC
    FORMAT PrettyCompact" 2>/dev/null)
    
    if [[ -z "$merges" ]]; then
        log_success "No active merges"
    else
        echo "$merges"
    fi
    
    # Mutations
    echo ""
    print_section "Mutations"
    
    local mutations
    mutations=$(ch_query "SELECT 
        database,
        table,
        mutation_id,
        command,
        parts_to_do
    FROM system.mutations
    WHERE is_done = 0
    FORMAT PrettyCompact" 2>/dev/null)
    
    if [[ -z "$mutations" ]]; then
        log_success "No pending mutations"
    else
        echo "$mutations"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_ch
    
    case "$COMMAND" in
        status)       show_status ;;
        queries)      show_queries ;;
        replication)  show_replication ;;
        tables)       show_tables ;;
        merges)       show_merges ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
