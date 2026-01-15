#!/bin/bash
#
# jmx-exporter-check.sh - JMX Exporter health monitoring
#
# Usage:
#   ./jmx-exporter-check.sh [command] [options]
#
# Commands:
#   status      Check exporter status (default)
#   metrics     Show key metrics
#   scan        Scan for JMX exporters in K8s
#
# Options:
#   -u, --url URL       JMX exporter URL
#   -p, --port PORT     JMX exporter port (default: 5556)
#   -n, --namespace NS  K8s namespace
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
JMX_URL="${JMX_EXPORTER_URL:-}"
JMX_PORT="${JMX_PORT:-5556}"
NAMESPACE="${JMX_NAMESPACE:-default}"
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
                JMX_URL="$2"
                shift 2
                ;;
            -p|--port)
                JMX_PORT="$2"
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
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "JMX Exporter Status"
    
    if [[ -z "$JMX_URL" ]]; then
        log "No URL specified, scanning K8s pods..."
        scan_k8s
        return
    fi
    
    print_kv "URL" "$JMX_URL"
    
    # Check connection
    local response
    response=$(curl -s -w "%{http_code}" -o /dev/null "$JMX_URL/metrics" 2>/dev/null)
    
    if [[ "$response" == "200" ]]; then
        log_success "Exporter is responding"
    else
        log_error "Exporter not responding (code: $response)"
        return 1
    fi
    
    # Get metrics count
    local metrics
    metrics=$(curl -s "$JMX_URL/metrics" 2>/dev/null)
    
    local metric_count=$(echo "$metrics" | grep -v "^#" | wc -l)
    print_kv "Metrics Exposed" "$metric_count"
    
    # JVM metrics
    echo ""
    print_section "JVM Metrics"
    
    local heap_used=$(echo "$metrics" | grep "jvm_memory_bytes_used.*area=\"heap\"" | awk '{print $2}')
    local heap_max=$(echo "$metrics" | grep "jvm_memory_bytes_max.*area=\"heap\"" | awk '{print $2}')
    
    if [[ -n "$heap_used" && -n "$heap_max" ]]; then
        print_kv "Heap Used" "$(bytes_to_human ${heap_used%.*})"
        print_kv "Heap Max" "$(bytes_to_human ${heap_max%.*})"
    fi
    
    local threads=$(echo "$metrics" | grep "jvm_threads_current" | awk '{print $2}')
    [[ -n "$threads" ]] && print_kv "Threads" "${threads%.*}"
    
    local gc_count=$(echo "$metrics" | grep "jvm_gc_collection_seconds_count" | awk '{sum += $2} END {print sum}')
    [[ -n "$gc_count" ]] && print_kv "GC Count" "${gc_count%.*}"
}

show_metrics() {
    print_section "JMX Metrics"
    
    if [[ -z "$JMX_URL" ]]; then
        log_error "URL required"
        return 1
    fi
    
    local metrics
    metrics=$(curl -s "$JMX_URL/metrics" 2>/dev/null)
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$metrics"
        return
    fi
    
    # Show metric families
    echo "Metric families:"
    echo "$metrics" | grep "^# HELP" | awk '{print "  " $3}' | sort -u | head -30
}

scan_k8s() {
    print_section "Scanning K8s for JMX Exporters"
    
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found"
        return 1
    fi
    
    # Find pods with JMX port
    echo ""
    echo "Pods with JMX port ($JMX_PORT):"
    
    kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null | \
        jq -r --arg port "$JMX_PORT" '.items[] | 
            select(.spec.containers[].ports[]?.containerPort == ($port | tonumber)) | 
            "\(.metadata.name)|\(.status.podIP)"' 2>/dev/null | \
    while IFS='|' read -r name ip; do
        [[ -z "$name" ]] && continue
        
        # Test connection
        local status="unknown"
        if curl -s --connect-timeout 2 "http://${ip}:${JMX_PORT}/metrics" &>/dev/null; then
            status="${GREEN}UP${RESET}"
        else
            status="${RED}DOWN${RESET}"
        fi
        
        printf "  %-40s %-15s %b\n" "$name" "$ip" "$status"
    done
    
    if [[ -z "$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r --arg port "$JMX_PORT" '.items[] | select(.spec.containers[].ports[]?.containerPort == ($port | tonumber)) | .metadata.name' 2>/dev/null)" ]]; then
        log "No pods found with JMX port $JMX_PORT"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    case "$COMMAND" in
        status)  show_status ;;
        metrics) show_metrics ;;
        scan)    scan_k8s ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
