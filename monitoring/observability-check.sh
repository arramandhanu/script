#!/bin/bash
#
# observability-check.sh - Loki and Tempo health monitoring
#
# Usage:
#   ./observability-check.sh [command] [options]
#
# Commands:
#   status      Overall status (default)
#   loki        Loki health check
#   tempo       Tempo health check
#   query       Test query
#
# Options:
#   --loki-url URL      Loki URL
#   --tempo-url URL     Tempo URL
#   -n, --namespace NS  Kubernetes namespace
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
LOKI_URL="${LOKI_URL:-http://localhost:3100}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
NAMESPACE="${OBSERVABILITY_NAMESPACE:-monitoring}"
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
            --loki-url)
                LOKI_URL="$2"
                shift 2
                ;;
            --tempo-url)
                TEMPO_URL="$2"
                shift 2
                ;;
            -n|--namespace)
                NAMESPACE="$2"
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
# Health checks
# -----------------------------------------------------------------------------

check_loki_health() {
    local status="unknown"
    local details=""
    
    # Ready endpoint
    local ready
    ready=$(curl -s -w "%{http_code}" -o /dev/null "${LOKI_URL}/ready" 2>/dev/null)
    
    if [[ "$ready" == "200" ]]; then
        status="healthy"
    else
        status="unhealthy"
        details="ready endpoint returned $ready"
    fi
    
    # Get build info
    local build_info
    build_info=$(curl -s "${LOKI_URL}/loki/api/v1/status/buildinfo" 2>/dev/null)
    
    local version="unknown"
    if [[ -n "$build_info" ]]; then
        version=$(echo "$build_info" | jq -r '.version // "unknown"' 2>/dev/null)
    fi
    
    echo "${status}|${version}|${details}"
}

check_tempo_health() {
    local status="unknown"
    local details=""
    
    # Ready endpoint
    local ready
    ready=$(curl -s -w "%{http_code}" -o /dev/null "${TEMPO_URL}/ready" 2>/dev/null)
    
    if [[ "$ready" == "200" ]]; then
        status="healthy"
    else
        status="unhealthy"
        details="ready endpoint returned $ready"
    fi
    
    # Get status
    local status_info
    status_info=$(curl -s "${TEMPO_URL}/status" 2>/dev/null)
    
    echo "${status}|${status_info}|${details}"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "Observability Stack Status"
    
    # Loki
    print_section "Loki"
    print_kv "URL" "$LOKI_URL"
    
    local loki_result
    loki_result=$(check_loki_health)
    
    IFS='|' read -r status version details <<< "$loki_result"
    
    if [[ "$status" == "healthy" ]]; then
        log_success "Loki is healthy"
    else
        log_error "Loki is unhealthy: $details"
    fi
    
    print_kv "Version" "$version"
    
    # Tempo
    echo ""
    print_section "Tempo"
    print_kv "URL" "$TEMPO_URL"
    
    local tempo_result
    tempo_result=$(check_tempo_health)
    
    IFS='|' read -r status info details <<< "$tempo_result"
    
    if [[ "$status" == "healthy" ]]; then
        log_success "Tempo is healthy"
    else
        log_error "Tempo is unhealthy: $details"
    fi
    
    # K8s pods
    if command -v kubectl &>/dev/null; then
        echo ""
        print_section "Pods ($NAMESPACE)"
        
        kubectl get pods -n "$NAMESPACE" -l 'app.kubernetes.io/name in (loki, tempo, promtail)' 2>/dev/null | \
        while read -r line; do
            if echo "$line" | grep -q "Running"; then
                echo -e "  ${GREEN}$line${RESET}"
            elif echo "$line" | grep -qE "Error|CrashLoop|Failed"; then
                echo -e "  ${RED}$line${RESET}"
            else
                echo "  $line"
            fi
        done
    fi
}

check_loki() {
    print_section "Loki Health Check"
    print_kv "URL" "$LOKI_URL"
    
    # Ready
    local ready
    ready=$(curl -s -w "%{http_code}" -o /dev/null "${LOKI_URL}/ready" 2>/dev/null)
    
    if [[ "$ready" == "200" ]]; then
        log_success "Ready endpoint: OK"
    else
        log_error "Ready endpoint: $ready"
    fi
    
    # Config
    local config
    config=$(curl -s "${LOKI_URL}/config" 2>/dev/null | head -20)
    
    if [[ -n "$config" ]]; then
        log_success "Config endpoint: OK"
    else
        log_warn "Config endpoint: Not available"
    fi
    
    # Ring status (for distributed mode)
    echo ""
    print_section "Ring Status"
    
    local ring
    ring=$(curl -s "${LOKI_URL}/ring" 2>/dev/null)
    
    if [[ -n "$ring" ]]; then
        echo "$ring" | head -20
    else
        log "Single instance mode or ring not available"
    fi
    
    # Ingester status
    echo ""
    print_section "Services"
    
    curl -s "${LOKI_URL}/services" 2>/dev/null | head -10 || echo "Services endpoint not available"
}

check_tempo() {
    print_section "Tempo Health Check"
    print_kv "URL" "$TEMPO_URL"
    
    # Ready
    local ready
    ready=$(curl -s -w "%{http_code}" -o /dev/null "${TEMPO_URL}/ready" 2>/dev/null)
    
    if [[ "$ready" == "200" ]]; then
        log_success "Ready endpoint: OK"
    else
        log_error "Ready endpoint: $ready"
    fi
    
    # Status
    echo ""
    print_section "Status"
    curl -s "${TEMPO_URL}/status" 2>/dev/null || echo "Status not available"
    
    # Ingester status
    echo ""
    print_section "Ingester"
    curl -s "${TEMPO_URL}/ingester/flush" 2>/dev/null || echo "Ingester flush endpoint not available"
}

do_query() {
    print_section "Query Test"
    
    echo "Select query type:"
    echo "  1) Loki - Recent logs"
    echo "  2) Tempo - Trace search"
    echo ""
    
    local choice
    read -p "Choice: " choice
    
    case "$choice" in
        1)
            local query
            read -p "LogQL query [{job=~\".+\"}]: " query
            query="${query:-{job=~\".+\"}}"
            
            local limit
            read -p "Limit [100]: " limit
            limit="${limit:-100}"
            
            log "Running Loki query..."
            
            local result
            result=$(curl -s -G "${LOKI_URL}/loki/api/v1/query_range" \
                --data-urlencode "query=${query}" \
                --data-urlencode "limit=${limit}" \
                --data-urlencode "start=$(date -d '1 hour ago' +%s)000000000" \
                --data-urlencode "end=$(date +%s)000000000" 2>/dev/null)
            
            if echo "$result" | jq -e '.status == "success"' &>/dev/null; then
                local count
                count=$(echo "$result" | jq '.data.result | length')
                log_success "Query returned $count streams"
                
                echo ""
                echo "Sample results:"
                echo "$result" | jq -r '.data.result[0].values[:5][]? | .[1]' 2>/dev/null | head -5
            else
                log_error "Query failed"
                echo "$result" | jq .
            fi
            ;;
        2)
            local service
            read -p "Service name: " service
            
            log "Searching traces for $service..."
            
            local result
            result=$(curl -s "${TEMPO_URL}/api/search?tags=service.name=${service}&limit=10" 2>/dev/null)
            
            if [[ -n "$result" ]]; then
                echo "$result" | jq '.traces[:5]' 2>/dev/null || echo "$result"
            else
                log_error "No results"
            fi
            ;;
        *)
            log_error "Invalid choice"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    case "$COMMAND" in
        status) show_status ;;
        loki)   check_loki ;;
        tempo)  check_tempo ;;
        query)  do_query ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
