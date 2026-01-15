#!/bin/bash
#
# kustomize-helper.sh - Kustomize build and diff utilities
#
# Usage:
#   ./kustomize-helper.sh [command] [options]
#
# Commands:
#   build       Build kustomization (default)
#   diff        Diff against cluster
#   validate    Validate manifests
#   resources   List resources
#   apply       Apply to cluster
#
# Options:
#   -p, --path PATH     Kustomization path
#   -n, --namespace NS  Target namespace
#   -d, --dry-run       Dry-run mode
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
KUSTOMIZE_PATH="${KUSTOMIZE_PATH:-.}"
NAMESPACE="${NAMESPACE:-default}"
DRY_RUN=false
COMMAND="${1:-build}"

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
            -p|--path)
                KUSTOMIZE_PATH="$2"
                shift 2
                ;;
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
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
# Check prerequisites
# -----------------------------------------------------------------------------
check_kustomize() {
    if ! command -v kustomize &>/dev/null && ! kubectl kustomize --help &>/dev/null 2>&1; then
        log_error "kustomize not found"
        log "Install: https://kubectl.docs.kubernetes.io/installation/kustomize/"
        exit 1
    fi
}

kustomize_cmd() {
    if command -v kustomize &>/dev/null; then
        kustomize "$@"
    else
        kubectl kustomize "$@"
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

do_build() {
    print_section "Build Kustomization"
    print_kv "Path" "$KUSTOMIZE_PATH"
    
    if [[ ! -f "$KUSTOMIZE_PATH/kustomization.yaml" && ! -f "$KUSTOMIZE_PATH/kustomization.yml" ]]; then
        log_error "No kustomization.yaml found in $KUSTOMIZE_PATH"
        return 1
    fi
    
    echo ""
    kustomize_cmd build "$KUSTOMIZE_PATH"
}

do_diff() {
    print_section "Diff Against Cluster"
    print_kv "Path" "$KUSTOMIZE_PATH"
    print_kv "Namespace" "$NAMESPACE"
    
    local manifest
    manifest=$(kustomize_cmd build "$KUSTOMIZE_PATH")
    
    echo ""
    echo "$manifest" | kubectl diff -n "$NAMESPACE" -f - 2>/dev/null || {
        local exit_code=$?
        if [[ $exit_code -eq 1 ]]; then
            log "Changes detected (shown above)"
        else
            log_success "No changes detected"
        fi
    }
}

do_validate() {
    print_section "Validate Manifests"
    print_kv "Path" "$KUSTOMIZE_PATH"
    
    local manifest
    manifest=$(kustomize_cmd build "$KUSTOMIZE_PATH" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        log_error "Build failed:"
        echo "$manifest"
        return 1
    fi
    
    log_success "Build successful"
    
    # Dry-run apply
    echo ""
    log "Running server-side validation..."
    
    if echo "$manifest" | kubectl apply --dry-run=server -f - &>/dev/null; then
        log_success "Server-side validation passed"
    else
        log_error "Server-side validation failed"
        echo "$manifest" | kubectl apply --dry-run=server -f - 2>&1 | head -20
    fi
    
    # Count resources
    echo ""
    print_section "Resources"
    echo "$manifest" | grep "^kind:" | sort | uniq -c | while read -r count kind; do
        echo "  $kind: $count"
    done
}

list_resources() {
    print_section "Resources in Kustomization"
    print_kv "Path" "$KUSTOMIZE_PATH"
    
    if [[ ! -f "$KUSTOMIZE_PATH/kustomization.yaml" ]]; then
        log_error "No kustomization.yaml found"
        return 1
    fi
    
    echo ""
    echo "Direct resources:"
    grep -A100 "^resources:" "$KUSTOMIZE_PATH/kustomization.yaml" 2>/dev/null | \
        grep "^  -" | sed 's/^  - /  /' | head -20
    
    echo ""
    echo "Bases:"
    grep -A100 "^bases:" "$KUSTOMIZE_PATH/kustomization.yaml" 2>/dev/null | \
        grep "^  -" | sed 's/^  - /  /' | head -10 || echo "  (none)"
    
    echo ""
    echo "Patches:"
    grep -E "patches|patchesStrategicMerge" "$KUSTOMIZE_PATH/kustomization.yaml" 2>/dev/null | head -5 || echo "  (none)"
}

do_apply() {
    print_section "Apply Kustomization"
    print_kv "Path" "$KUSTOMIZE_PATH"
    print_kv "Namespace" "$NAMESPACE"
    print_kv "Dry-Run" "$DRY_RUN"
    
    local manifest
    manifest=$(kustomize_cmd build "$KUSTOMIZE_PATH")
    
    # Show what will be applied
    echo ""
    echo "Resources to apply:"
    echo "$manifest" | grep -E "^kind:|^  name:" | paste - - | head -20
    
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "Dry-run mode - no changes will be made"
        echo "$manifest" | kubectl apply --dry-run=client -f - 2>&1
    else
        if ! confirm "Apply to namespace $NAMESPACE?"; then
            log "Cancelled"
            return 0
        fi
        
        echo "$manifest" | kubectl apply -n "$NAMESPACE" -f -
        log_success "Applied to cluster"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_kustomize
    
    case "$COMMAND" in
        build)     do_build ;;
        diff)      do_diff ;;
        validate)  do_validate ;;
        resources) list_resources ;;
        apply)     do_apply ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
