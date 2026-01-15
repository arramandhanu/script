#!/bin/bash
#
# prometheus-health.sh - Prometheus server health and targets monitoring
#
# Usage:
#   ./prometheus-health.sh [command] [options]
#
# Commands:
#   status      Server status (default)
#   targets     Show scrape targets
#   alerts      Active alerts
#   rules       Alert rules status
#   tsdb        TSDB statistics
#
# Options:
#   -u, --url URL       Prometheus URL (default: http://localhost:9090)
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
PROM_URL="${PROMETHEUS_URL:-http://localhost:9090}"
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
            -u|--url)
                PROM_URL="$2"
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
# API helpers
# -----------------------------------------------------------------------------
prom_api() {
    local endpoint="$1"
    curl -s "${PROM_URL}/api/v1${endpoint}" 2>/dev/null
}

check_prometheus() {
    if ! curl -s "${PROM_URL}/-/ready" 2>/dev/null | grep -q "ready"; then
        log_error "Cannot connect to Prometheus at $PROM_URL"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "Prometheus Status"
    print_kv "URL" "$PROM_URL"
    
    # Ready check
    local ready
    ready=$(curl -s -w "%{http_code}" -o /dev/null "${PROM_URL}/-/ready" 2>/dev/null)
    
    if [[ "$ready" == "200" ]]; then
        log_success "Server is ready"
    else
        log_error "Server not ready (code: $ready)"
    fi
    
    # Build info
    local build_info
    build_info=$(prom_api "/status/buildinfo")
    
    local version=$(echo "$build_info" | jq -r '.data.version // "unknown"')
    print_kv "Version" "$version"
    
    # Runtime info
    local runtime
    runtime=$(prom_api "/status/runtimeinfo")
    
    local uptime=$(echo "$runtime" | jq -r '.data.startTime // "unknown"')
    print_kv "Started" "$uptime"
    
    local storage_retention=$(echo "$runtime" | jq -r '.data.storageRetention // "unknown"')
    print_kv "Retention" "$storage_retention"
    
    # TSDB stats
    echo ""
    print_section "TSDB Stats"
    
    local tsdb
    tsdb=$(prom_api "/status/tsdb")
    
    local series=$(echo "$tsdb" | jq -r '.data.headStats.numSeries // "unknown"')
    local chunks=$(echo "$tsdb" | jq -r '.data.headStats.numChunks // "unknown"')
    
    print_kv "Active Series" "$series"
    print_kv "Chunks" "$chunks"
}

show_targets() {
    print_section "Scrape Targets"
    
    local targets
    targets=$(prom_api "/targets")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$targets" | jq .
        return
    fi
    
    # Count by state
    local up=$(echo "$targets" | jq '[.data.activeTargets[] | select(.health == "up")] | length')
    local down=$(echo "$targets" | jq '[.data.activeTargets[] | select(.health == "down")] | length')
    local unknown=$(echo "$targets" | jq '[.data.activeTargets[] | select(.health == "unknown")] | length')
    
    print_kv "Up" "$up"
    print_kv "Down" "$down"
    print_kv "Unknown" "$unknown"
    
    echo ""
    printf "  %-30s %-15s %-10s %s\n" "JOB" "INSTANCE" "STATE" "LAST SCRAPE"
    printf "  %-30s %-15s %-10s %s\n" "---" "--------" "-----" "-----------"
    
    echo "$targets" | jq -r '.data.activeTargets[] | "\(.labels.job)|\(.labels.instance)|\(.health)|\(.lastScrape)"' | \
    while IFS='|' read -r job instance health last_scrape; do
        local state_color="${GREEN}"
        case "$health" in
            up) state_color="${GREEN}" ;;
            down) state_color="${RED}" ;;
            *) state_color="${YELLOW}" ;;
        esac
        
        local short_instance=$(echo "$instance" | cut -d: -f1 | cut -c1-15)
        local scrape_time=$(echo "$last_scrape" | cut -dT -f2 | cut -d. -f1)
        
        printf "  %-30s %-15s ${state_color}%-10s${RESET} %s\n" \
            "$job" "$short_instance" "$health" "$scrape_time"
    done | head -30
    
    if [[ $down -gt 0 ]]; then
        echo ""
        log_warn "$down targets are DOWN"
    fi
}

show_alerts() {
    print_section "Active Alerts"
    
    local alerts
    alerts=$(prom_api "/alerts")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$alerts" | jq .
        return
    fi
    
    local count=$(echo "$alerts" | jq '.data.alerts | length')
    
    if [[ $count -eq 0 ]]; then
        log_success "No active alerts"
        return
    fi
    
    print_kv "Active Alerts" "$count"
    echo ""
    
    echo "$alerts" | jq -r '.data.alerts[] | "\(.labels.alertname)|\(.labels.severity // "unknown")|\(.state)|\(.labels.instance // "N/A")"' | \
    while IFS='|' read -r name severity state instance; do
        local severity_color="${YELLOW}"
        case "$severity" in
            critical) severity_color="${RED}" ;;
            warning) severity_color="${YELLOW}" ;;
            *) severity_color="${BLUE}" ;;
        esac
        
        echo -e "  ${severity_color}[$severity]${RESET} $name"
        echo "    Instance: $instance"
        echo "    State: $state"
        echo ""
    done | head -40
}

show_rules() {
    print_section "Alert Rules"
    
    local rules
    rules=$(prom_api "/rules")
    
    local total=$(echo "$rules" | jq '[.data.groups[].rules[]] | length')
    local firing=$(echo "$rules" | jq '[.data.groups[].rules[] | select(.state == "firing")] | length')
    local pending=$(echo "$rules" | jq '[.data.groups[].rules[] | select(.state == "pending")] | length')
    
    print_kv "Total Rules" "$total"
    print_kv "Firing" "$firing"
    print_kv "Pending" "$pending"
    
    if [[ $firing -gt 0 ]]; then
        echo ""
        echo "Firing rules:"
        echo "$rules" | jq -r '.data.groups[].rules[] | select(.state == "firing") | "  - \(.name)"'
    fi
}

show_tsdb() {
    print_section "TSDB Statistics"
    
    local tsdb
    tsdb=$(prom_api "/status/tsdb")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$tsdb" | jq .
        return
    fi
    
    echo "$tsdb" | jq -r '.data | to_entries[] | "  \(.key): \(.value)"' 2>/dev/null | head -20
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_prometheus
    
    case "$COMMAND" in
        status)  show_status ;;
        targets) show_targets ;;
        alerts)  show_alerts ;;
        rules)   show_rules ;;
        tsdb)    show_tsdb ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
