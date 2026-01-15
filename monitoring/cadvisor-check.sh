#!/bin/bash
#
# cadvisor-check.sh - cAdvisor container metrics monitoring
#
# Usage:
#   ./cadvisor-check.sh [command] [options]
#
# Commands:
#   status      cAdvisor status (default)
#   containers  Container metrics
#   machine     Machine info
#
# Options:
#   -u, --url URL       cAdvisor URL (default: http://localhost:8080)
#   -n, --namespace NS  K8s namespace for pods
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
CADVISOR_URL="${CADVISOR_URL:-http://localhost:8080}"
NAMESPACE="${CADVISOR_NAMESPACE:-monitoring}"
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
                CADVISOR_URL="$2"
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
cadvisor_api() {
    local endpoint="$1"
    curl -s "${CADVISOR_URL}/api/v1.3${endpoint}" 2>/dev/null
}

check_cadvisor() {
    if ! curl -s "${CADVISOR_URL}/healthz" 2>/dev/null | grep -q "ok"; then
        log_error "Cannot connect to cAdvisor at $CADVISOR_URL"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "cAdvisor Status"
    print_kv "URL" "$CADVISOR_URL"
    
    # Health check
    local health
    health=$(curl -s "${CADVISOR_URL}/healthz" 2>/dev/null)
    
    if [[ "$health" == "ok" ]]; then
        log_success "cAdvisor is healthy"
    else
        log_error "cAdvisor health check failed"
    fi
    
    # Machine info
    local machine
    machine=$(cadvisor_api "/machine")
    
    echo ""
    print_section "Machine Info"
    
    local cores=$(echo "$machine" | jq -r '.num_cores // "unknown"')
    local memory=$(echo "$machine" | jq -r '.memory_capacity // 0')
    local fs_count=$(echo "$machine" | jq -r '.filesystems | length')
    
    print_kv "CPU Cores" "$cores"
    print_kv "Memory" "$(bytes_to_human $memory)"
    print_kv "Filesystems" "$fs_count"
    
    # Container count
    local containers
    containers=$(cadvisor_api "/containers")
    
    local container_count=$(echo "$containers" | jq -r '[.. | .name? // empty] | length' 2>/dev/null || echo "0")
    print_kv "Containers" "$container_count"
}

show_containers() {
    print_section "Container Metrics"
    
    local containers
    containers=$(cadvisor_api "/containers/docker")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$containers" | jq .
        return
    fi
    
    printf "  %-40s %-12s %-12s %s\n" "CONTAINER" "CPU" "MEMORY" "STATUS"
    printf "  %-40s %-12s %-12s %s\n" "---------" "---" "------" "------"
    
    echo "$containers" | jq -r '.subcontainers[]? | .name' 2>/dev/null | \
    while read -r name; do
        [[ -z "$name" ]] && continue
        
        local stats
        stats=$(cadvisor_api "/containers${name}" 2>/dev/null)
        
        local short_name=$(echo "$name" | awk -F/ '{print $NF}' | cut -c1-40)
        local cpu=$(echo "$stats" | jq -r '.stats[-1].cpu.usage.total // 0' 2>/dev/null)
        local memory=$(echo "$stats" | jq -r '.stats[-1].memory.usage // 0' 2>/dev/null)
        
        local cpu_pct="N/A"
        local mem_human=$(bytes_to_human ${memory:-0})
        
        printf "  %-40s %-12s %-12s %s\n" "$short_name" "$cpu_pct" "$mem_human" "running"
    done | head -20
}

show_machine() {
    print_section "Machine Details"
    
    local machine
    machine=$(cadvisor_api "/machine")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$machine" | jq .
        return
    fi
    
    echo "$machine" | jq -r 'to_entries[] | "  \(.key): \(.value)"' 2>/dev/null | head -30
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_cadvisor
    
    case "$COMMAND" in
        status)     show_status ;;
        containers) show_containers ;;
        machine)    show_machine ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
