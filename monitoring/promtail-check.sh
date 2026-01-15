#!/bin/bash
#
# promtail-check.sh - Promtail agent health monitoring
#
# Usage:
#   ./promtail-check.sh [command] [options]
#
# Commands:
#   status      Agent status (default)
#   targets     Scrape targets
#   labels      Active labels
#
# Options:
#   -u, --url URL       Promtail URL (default: http://localhost:9080)
#   -n, --namespace NS  K8s namespace for pods
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
PROMTAIL_URL="${PROMTAIL_URL:-http://localhost:9080}"
NAMESPACE="${PROMTAIL_NAMESPACE:-monitoring}"
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
                PROMTAIL_URL="$2"
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
# API helpers
# -----------------------------------------------------------------------------
promtail_api() {
    local endpoint="$1"
    curl -s "${PROMTAIL_URL}${endpoint}" 2>/dev/null
}

check_promtail() {
    if ! curl -s "${PROMTAIL_URL}/ready" 2>/dev/null | grep -qi "ready"; then
        log_error "Cannot connect to Promtail at $PROMTAIL_URL"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "Promtail Status"
    print_kv "URL" "$PROMTAIL_URL"
    
    # Ready check
    local ready
    ready=$(curl -s "${PROMTAIL_URL}/ready" 2>/dev/null)
    
    if echo "$ready" | grep -qi "ready"; then
        log_success "Agent is ready"
    else
        log_error "Agent not ready"
    fi
    
    # Metrics
    local metrics
    metrics=$(curl -s "${PROMTAIL_URL}/metrics" 2>/dev/null)
    
    local lines_read=$(echo "$metrics" | grep "promtail_read_lines_total" | grep -v "^#" | awk '{sum += $2} END {print sum}')
    local bytes_read=$(echo "$metrics" | grep "promtail_read_bytes_total" | grep -v "^#" | awk '{sum += $2} END {print sum}')
    local sent_entries=$(echo "$metrics" | grep "promtail_sent_entries_total" | grep -v "^#" | awk '{sum += $2} END {print sum}')
    
    echo ""
    print_section "Metrics"
    print_kv "Lines Read" "${lines_read:-0}"
    print_kv "Bytes Read" "$(bytes_to_human ${bytes_read:-0})"
    print_kv "Entries Sent" "${sent_entries:-0}"
    
    # K8s pods if available
    if command -v kubectl &>/dev/null; then
        echo ""
        print_section "Promtail Pods ($NAMESPACE)"
        kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=promtail 2>/dev/null | head -10
    fi
}

show_targets() {
    print_section "Scrape Targets"
    
    local targets
    targets=$(promtail_api "/targets")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$targets"
        return
    fi
    
    if [[ -z "$targets" ]]; then
        log "No targets available"
        return
    fi
    
    echo "$targets" | head -50
}

show_labels() {
    print_section "Active Labels"
    
    local labels
    labels=$(promtail_api "/service-discovery")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$labels"
        return
    fi
    
    if [[ -n "$labels" ]]; then
        echo "$labels" | head -30
    else
        log "No labels available"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_promtail
    
    case "$COMMAND" in
        status)  show_status ;;
        targets) show_targets ;;
        labels)  show_labels ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
