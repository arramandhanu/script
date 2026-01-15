#!/bin/bash
#
# grafana-health.sh - Grafana server health and dashboard monitoring
#
# Usage:
#   ./grafana-health.sh [command] [options]
#
# Commands:
#   status      Server status (default)
#   dashboards  List dashboards
#   datasources Data sources status
#   alerts      Alert rules
#   users       User list
#
# Options:
#   -u, --url URL         Grafana URL
#   -t, --token TOKEN     API token
#   -j, --json            JSON output
#   -h, --help            Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_TOKEN="${GRAFANA_TOKEN:-}"
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
                GRAFANA_URL="$2"
                shift 2
                ;;
            -t|--token)
                GRAFANA_TOKEN="$2"
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
grafana_api() {
    local endpoint="$1"
    local auth_header=""
    
    if [[ -n "$GRAFANA_TOKEN" ]]; then
        auth_header="-H 'Authorization: Bearer $GRAFANA_TOKEN'"
    fi
    
    eval curl -s $auth_header "${GRAFANA_URL}/api${endpoint}" 2>/dev/null
}

check_grafana() {
    local health
    health=$(curl -s "${GRAFANA_URL}/api/health" 2>/dev/null)
    
    if ! echo "$health" | jq -e '.database == "ok"' &>/dev/null; then
        log_error "Cannot connect to Grafana at $GRAFANA_URL"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "Grafana Status"
    print_kv "URL" "$GRAFANA_URL"
    
    # Health check
    local health
    health=$(curl -s "${GRAFANA_URL}/api/health" 2>/dev/null)
    
    local db_status=$(echo "$health" | jq -r '.database // "unknown"')
    
    if [[ "$db_status" == "ok" ]]; then
        log_success "Server is healthy"
    else
        log_error "Database status: $db_status"
    fi
    
    local version=$(echo "$health" | jq -r '.version // "unknown"')
    print_kv "Version" "$version"
    
    local commit=$(echo "$health" | jq -r '.commit // "unknown"' | cut -c1-8)
    print_kv "Commit" "$commit"
    
    # Stats (requires auth)
    if [[ -n "$GRAFANA_TOKEN" ]]; then
        echo ""
        print_section "Statistics"
        
        local stats
        stats=$(grafana_api "/admin/stats" 2>/dev/null)
        
        if [[ -n "$stats" ]]; then
            local dashboards=$(echo "$stats" | jq -r '.dashboards // 0')
            local datasources=$(echo "$stats" | jq -r '.datasources // 0')
            local users=$(echo "$stats" | jq -r '.users // 0')
            local alerts=$(echo "$stats" | jq -r '.alerts // 0')
            
            print_kv "Dashboards" "$dashboards"
            print_kv "Data Sources" "$datasources"
            print_kv "Users" "$users"
            print_kv "Alerts" "$alerts"
        fi
    else
        log "Set GRAFANA_TOKEN for detailed stats"
    fi
}

show_dashboards() {
    print_section "Dashboards"
    
    local dashboards
    dashboards=$(grafana_api "/search?type=dash-db")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$dashboards" | jq .
        return
    fi
    
    local count=$(echo "$dashboards" | jq 'length')
    print_kv "Total" "$count"
    
    echo ""
    printf "  %-40s %-20s %s\n" "TITLE" "FOLDER" "UID"
    printf "  %-40s %-20s %s\n" "-----" "------" "---"
    
    echo "$dashboards" | jq -r '.[] | "\(.title)|\(.folderTitle // "General")|\(.uid)"' | \
    while IFS='|' read -r title folder uid; do
        printf "  %-40s %-20s %s\n" "${title:0:40}" "${folder:0:20}" "$uid"
    done | head -30
}

show_datasources() {
    print_section "Data Sources"
    
    local datasources
    datasources=$(grafana_api "/datasources")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$datasources" | jq .
        return
    fi
    
    printf "  %-25s %-15s %-10s %s\n" "NAME" "TYPE" "DEFAULT" "URL"
    printf "  %-25s %-15s %-10s %s\n" "----" "----" "-------" "---"
    
    echo "$datasources" | jq -r '.[] | "\(.name)|\(.type)|\(.isDefault)|\(.url)"' | \
    while IFS='|' read -r name type is_default url; do
        local default_str="no"
        [[ "$is_default" == "true" ]] && default_str="yes"
        
        printf "  %-25s %-15s %-10s %s\n" "${name:0:25}" "$type" "$default_str" "${url:0:40}"
    done
    
    # Test connections
    echo ""
    print_section "Connection Test"
    
    echo "$datasources" | jq -r '.[] | "\(.id)|\(.name)"' | \
    while IFS='|' read -r id name; do
        local test_result
        test_result=$(grafana_api "/datasources/$id/health" 2>/dev/null)
        
        local status=$(echo "$test_result" | jq -r '.status // "error"')
        
        if [[ "$status" == "OK" ]]; then
            log_success "$name: Connected"
        else
            log_error "$name: $status"
        fi
    done
}

show_alerts() {
    print_section "Alert Rules"
    
    local alerts
    alerts=$(grafana_api "/v1/provisioning/alert-rules" 2>/dev/null)
    
    if [[ -z "$alerts" || "$alerts" == "null" ]]; then
        # Try legacy endpoint
        alerts=$(grafana_api "/alerts" 2>/dev/null)
    fi
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$alerts" | jq .
        return
    fi
    
    local count=$(echo "$alerts" | jq 'length' 2>/dev/null || echo "0")
    print_kv "Total Rules" "$count"
    
    if [[ $count -gt 0 ]]; then
        echo ""
        echo "$alerts" | jq -r '.[] | "  - \(.title // .name): \(.state // "unknown")"' 2>/dev/null | head -20
    fi
}

show_users() {
    print_section "Users"
    
    local users
    users=$(grafana_api "/org/users")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$users" | jq .
        return
    fi
    
    printf "  %-30s %-20s %s\n" "LOGIN" "EMAIL" "ROLE"
    printf "  %-30s %-20s %s\n" "-----" "-----" "----"
    
    echo "$users" | jq -r '.[] | "\(.login)|\(.email)|\(.role)"' | \
    while IFS='|' read -r login email role; do
        printf "  %-30s %-20s %s\n" "$login" "${email:0:20}" "$role"
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_grafana
    
    case "$COMMAND" in
        status)      show_status ;;
        dashboards)  show_dashboards ;;
        datasources) show_datasources ;;
        alerts)      show_alerts ;;
        users)       show_users ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
