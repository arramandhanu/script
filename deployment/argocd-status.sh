#!/bin/bash
#
# argocd-status.sh - ArgoCD application status and sync monitoring
#
# Usage:
#   ./argocd-status.sh [command] [options]
#
# Commands:
#   status      Overall status (default)
#   apps        List applications
#   sync        Sync status
#   health      Health summary
#   diff        Show diff for app
#
# Options:
#   -s, --server URL    ArgoCD server URL
#   -a, --app NAME      Application name
#   -n, --namespace NS  Namespace (default: argocd)
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
ARGOCD_SERVER="${ARGOCD_SERVER:-}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME=""
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
            -s|--server)
                ARGOCD_SERVER="$2"
                shift 2
                ;;
            -a|--app)
                APP_NAME="$2"
                shift 2
                ;;
            -n|--namespace)
                ARGOCD_NAMESPACE="$2"
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
# Check ArgoCD CLI
# -----------------------------------------------------------------------------
has_argocd_cli() {
    command -v argocd &>/dev/null
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "ArgoCD Status"
    
    # Check ArgoCD pods
    print_section "ArgoCD Components"
    
    kubectl get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/part-of=argocd 2>/dev/null | \
    while read -r line; do
        if echo "$line" | grep -q "Running"; then
            echo -e "  ${GREEN}$line${RESET}"
        elif echo "$line" | grep -qE "Error|CrashLoop"; then
            echo -e "  ${RED}$line${RESET}"
        else
            echo "  $line"
        fi
    done
    
    # Application summary
    echo ""
    print_section "Application Summary"
    
    local apps
    apps=$(kubectl get applications -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)
    
    local total=$(echo "$apps" | jq '.items | length')
    local synced=$(echo "$apps" | jq '[.items[] | select(.status.sync.status == "Synced")] | length')
    local healthy=$(echo "$apps" | jq '[.items[] | select(.status.health.status == "Healthy")] | length')
    local degraded=$(echo "$apps" | jq '[.items[] | select(.status.health.status == "Degraded")] | length')
    local outofsync=$(echo "$apps" | jq '[.items[] | select(.status.sync.status == "OutOfSync")] | length')
    
    print_kv "Total Apps" "$total"
    print_kv "Synced" "$synced"
    print_kv "Healthy" "$healthy"
    print_kv "Degraded" "$degraded"
    print_kv "Out of Sync" "$outofsync"
    
    if [[ $degraded -gt 0 || $outofsync -gt 0 ]]; then
        echo ""
        log_warn "Some applications need attention"
    else
        echo ""
        log_success "All applications healthy and synced"
    fi
}

list_apps() {
    print_section "Applications"
    
    local apps
    apps=$(kubectl get applications -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$apps" | jq '.items'
        return
    fi
    
    printf "  %-30s %-15s %-12s %-15s %s\n" "NAME" "NAMESPACE" "SYNC" "HEALTH" "REPO"
    printf "  %-30s %-15s %-12s %-15s %s\n" "----" "---------" "----" "------" "----"
    
    echo "$apps" | jq -r '.items[] | "\(.metadata.name)|\(.spec.destination.namespace)|\(.status.sync.status)|\(.status.health.status)|\(.spec.source.repoURL)"' | \
    while IFS='|' read -r name ns sync health repo; do
        local sync_color="${GREEN}"
        [[ "$sync" == "OutOfSync" ]] && sync_color="${YELLOW}"
        [[ "$sync" == "Unknown" ]] && sync_color="${RED}"
        
        local health_color="${GREEN}"
        [[ "$health" == "Degraded" ]] && health_color="${RED}"
        [[ "$health" == "Progressing" ]] && health_color="${YELLOW}"
        [[ "$health" == "Missing" ]] && health_color="${RED}"
        
        local short_repo=$(echo "$repo" | awk -F/ '{print $NF}' | sed 's/.git$//')
        
        printf "  %-30s %-15s ${sync_color}%-12s${RESET} ${health_color}%-15s${RESET} %s\n" \
            "$name" "$ns" "$sync" "$health" "$short_repo"
    done
}

show_sync() {
    print_section "Sync Status"
    
    local apps
    apps=$(kubectl get applications -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)
    
    # Out of sync apps
    local outofsync
    outofsync=$(echo "$apps" | jq -r '.items[] | select(.status.sync.status != "Synced") | .metadata.name')
    
    if [[ -z "$outofsync" ]]; then
        log_success "All applications are synced"
        return
    fi
    
    log_warn "Out of sync applications:"
    echo ""
    
    for app in $outofsync; do
        local app_data
        app_data=$(echo "$apps" | jq -r --arg name "$app" '.items[] | select(.metadata.name == $name)')
        
        local revision=$(echo "$app_data" | jq -r '.status.sync.revision // "unknown"' | cut -c1-8)
        local target=$(echo "$app_data" | jq -r '.spec.source.targetRevision // "HEAD"')
        
        echo "  $app"
        echo "    Current: $revision"
        echo "    Target: $target"
        echo ""
    done
}

show_health() {
    print_section "Health Summary"
    
    local apps
    apps=$(kubectl get applications -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)
    
    # Group by health status
    echo "By health status:"
    echo "$apps" | jq -r '.items[] | "\(.status.health.status)|\(.metadata.name)"' | \
        sort | while IFS='|' read -r status name; do
            local color="${GREEN}"
            case "$status" in
                Healthy) color="${GREEN}" ;;
                Degraded) color="${RED}" ;;
                Progressing) color="${YELLOW}" ;;
                *) color="${BLUE}" ;;
            esac
            printf "  ${color}%-15s${RESET} %s\n" "$status" "$name"
        done
    
    # Unhealthy apps details
    local unhealthy
    unhealthy=$(echo "$apps" | jq -r '.items[] | select(.status.health.status != "Healthy") | .metadata.name')
    
    if [[ -n "$unhealthy" ]]; then
        echo ""
        print_section "Unhealthy Applications"
        
        for app in $unhealthy; do
            echo "  $app:"
            kubectl get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.resources[?(@.health.status!="Healthy")]}' 2>/dev/null | \
                jq -r '. | "    \(.kind)/\(.name): \(.health.status) - \(.health.message // "no message")"' 2>/dev/null | head -5
        done
    fi
}

show_diff() {
    if [[ -z "$APP_NAME" ]]; then
        read -p "Application name: " APP_NAME
    fi
    
    print_section "Diff: $APP_NAME"
    
    if has_argocd_cli; then
        argocd app diff "$APP_NAME" 2>/dev/null || log "No differences found"
    else
        # Use kubectl
        local app
        app=$(kubectl get application "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o json 2>/dev/null)
        
        if [[ -z "$app" ]]; then
            log_error "Application not found"
            return 1
        fi
        
        local sync_status=$(echo "$app" | jq -r '.status.sync.status')
        local revision=$(echo "$app" | jq -r '.status.sync.revision // "unknown"' | cut -c1-12)
        
        print_kv "Sync Status" "$sync_status"
        print_kv "Revision" "$revision"
        
        if [[ "$sync_status" == "Synced" ]]; then
            log_success "Application is in sync"
        else
            log_warn "Application is out of sync"
            log "Use ArgoCD CLI for detailed diff: argocd app diff $APP_NAME"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    case "$COMMAND" in
        status) show_status ;;
        apps)   list_apps ;;
        sync)   show_sync ;;
        health) show_health ;;
        diff)   show_diff ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
