#!/bin/bash
#
# helm-manager.sh - Helm releases management and troubleshooting
#
# Usage:
#   ./helm-manager.sh [command] [options]
#
# Commands:
#   list        List releases (default)
#   status      Release status
#   history     Release history
#   values      Show values
#   diff        Diff pending changes
#   rollback    Rollback release
#
# Options:
#   -n, --namespace NS  Kubernetes namespace
#   -a, --all           All namespaces
#   -r, --release NAME  Release name
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
NAMESPACE="${HELM_NAMESPACE:-default}"
ALL_NAMESPACES=false
RELEASE=""
COMMAND="${1:-list}"
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
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -a|--all)
                ALL_NAMESPACES=true
                shift
                ;;
            -r|--release)
                RELEASE="$2"
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
# Check helm
# -----------------------------------------------------------------------------
check_helm() {
    if ! command -v helm &>/dev/null; then
        log_error "helm not found"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

list_releases() {
    print_header "Helm Releases"
    
    local ns_flag="-n $NAMESPACE"
    [[ "$ALL_NAMESPACES" == "true" ]] && ns_flag="--all-namespaces"
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        helm list $ns_flag -o json
        return
    fi
    
    # Get releases
    local releases
    releases=$(helm list $ns_flag 2>/dev/null)
    
    echo "$releases"
    
    # Summary
    echo ""
    local deployed=$(echo "$releases" | grep -c "deployed" || echo "0")
    local failed=$(echo "$releases" | grep -c "failed" || echo "0")
    local pending=$(echo "$releases" | grep -c "pending" || echo "0")
    
    print_kv "Deployed" "$deployed"
    print_kv "Failed" "$failed"
    print_kv "Pending" "$pending"
    
    if [[ $failed -gt 0 ]]; then
        echo ""
        log_warn "Failed releases:"
        echo "$releases" | grep "failed"
    fi
}

show_status() {
    if [[ -z "$RELEASE" ]]; then
        read -p "Release name: " RELEASE
    fi
    
    print_section "Release Status: $RELEASE"
    
    helm status "$RELEASE" -n "$NAMESPACE" 2>/dev/null
    
    echo ""
    print_section "Resources"
    
    helm get manifest "$RELEASE" -n "$NAMESPACE" 2>/dev/null | \
        grep "kind:" | sort | uniq -c | while read -r count kind; do
            echo "  $kind: $count"
        done
}

show_history() {
    if [[ -z "$RELEASE" ]]; then
        read -p "Release name: " RELEASE
    fi
    
    print_section "Release History: $RELEASE"
    
    helm history "$RELEASE" -n "$NAMESPACE" 2>/dev/null
}

show_values() {
    if [[ -z "$RELEASE" ]]; then
        read -p "Release name: " RELEASE
    fi
    
    print_section "Values: $RELEASE"
    
    echo "User-supplied values:"
    helm get values "$RELEASE" -n "$NAMESPACE" 2>/dev/null
    
    echo ""
    echo "For all values, run: helm get values $RELEASE -n $NAMESPACE --all"
}

show_diff() {
    if [[ -z "$RELEASE" ]]; then
        log_error "Release name required (-r)"
        return 1
    fi
    
    if ! command -v helm-diff &>/dev/null && ! helm plugin list 2>/dev/null | grep -q diff; then
        log_error "helm-diff plugin not installed"
        log "Install with: helm plugin install https://github.com/databus23/helm-diff"
        return 1
    fi
    
    print_section "Pending Changes: $RELEASE"
    
    # This requires the chart path
    log "Run manually: helm diff upgrade $RELEASE <chart> -n $NAMESPACE"
}

do_rollback() {
    if [[ -z "$RELEASE" ]]; then
        read -p "Release name: " RELEASE
    fi
    
    print_section "Rollback: $RELEASE"
    
    # Show history first
    helm history "$RELEASE" -n "$NAMESPACE" 2>/dev/null
    
    echo ""
    local revision
    read -p "Revision to rollback to: " revision
    
    if [[ -z "$revision" ]]; then
        log_error "Revision required"
        return 1
    fi
    
    if ! confirm "Rollback $RELEASE to revision $revision?"; then
        log "Cancelled"
        return 0
    fi
    
    helm rollback "$RELEASE" "$revision" -n "$NAMESPACE"
    
    log_success "Rollback initiated"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_helm
    
    case "$COMMAND" in
        list)     list_releases ;;
        status)   show_status ;;
        history)  show_history ;;
        values)   show_values ;;
        diff)     show_diff ;;
        rollback) do_rollback ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
