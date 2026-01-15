#!/bin/bash
#
# gitops-sync.sh - GitOps repository sync and status checker
#
# Usage:
#   ./gitops-sync.sh [command] [options]
#
# Commands:
#   status      Check sync status (default)
#   diff        Show pending changes
#   sync        Trigger sync (ArgoCD/Flux)
#   history     Deployment history
#
# Options:
#   -r, --repo PATH     Git repository path
#   -b, --branch NAME   Branch name (default: main)
#   -t, --tool NAME     GitOps tool (argocd|flux)
#   -n, --namespace NS  Namespace
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
REPO_PATH="${GITOPS_REPO:-.}"
BRANCH="${GITOPS_BRANCH:-main}"
GITOPS_TOOL="${GITOPS_TOOL:-argocd}"
NAMESPACE="${GITOPS_NAMESPACE:-argocd}"
COMMAND="${1:-status}"

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
            -r|--repo)
                REPO_PATH="$2"
                shift 2
                ;;
            -b|--branch)
                BRANCH="$2"
                shift 2
                ;;
            -t|--tool)
                GITOPS_TOOL="$2"
                shift 2
                ;;
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
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
# Git helpers
# -----------------------------------------------------------------------------
git_cmd() {
    git -C "$REPO_PATH" "$@" 2>/dev/null
}

check_repo() {
    if [[ ! -d "$REPO_PATH/.git" ]]; then
        log_error "Not a git repository: $REPO_PATH"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "GitOps Status"
    
    print_kv "Repository" "$REPO_PATH"
    print_kv "Branch" "$BRANCH"
    print_kv "Tool" "$GITOPS_TOOL"
    
    # Git status
    echo ""
    print_section "Git Status"
    
    local current_branch=$(git_cmd rev-parse --abbrev-ref HEAD)
    local local_commit=$(git_cmd rev-parse --short HEAD)
    
    print_kv "Current Branch" "$current_branch"
    print_kv "Local Commit" "$local_commit"
    
    # Check if up to date with remote
    git_cmd fetch origin "$BRANCH" &>/dev/null || true
    
    local remote_commit=$(git_cmd rev-parse --short "origin/$BRANCH" 2>/dev/null || echo "unknown")
    print_kv "Remote Commit" "$remote_commit"
    
    local behind=$(git_cmd rev-list --count HEAD.."origin/$BRANCH" 2>/dev/null || echo "0")
    local ahead=$(git_cmd rev-list --count "origin/$BRANCH"..HEAD 2>/dev/null || echo "0")
    
    if [[ $behind -gt 0 ]]; then
        log_warn "Local is $behind commits behind remote"
    elif [[ $ahead -gt 0 ]]; then
        log_warn "Local is $ahead commits ahead of remote"
    else
        log_success "Local is up to date with remote"
    fi
    
    # Uncommitted changes
    local changes=$(git_cmd status --porcelain | wc -l)
    if [[ $changes -gt 0 ]]; then
        echo ""
        log_warn "$changes uncommitted changes"
        git_cmd status --short | head -10
    fi
    
    # Cluster sync status
    echo ""
    print_section "Cluster Sync Status"
    
    case "$GITOPS_TOOL" in
        argocd)
            kubectl get applications -n "$NAMESPACE" -o wide 2>/dev/null | head -10 || echo "  Cannot check ArgoCD apps"
            ;;
        flux)
            kubectl get kustomizations -A 2>/dev/null | head -10 || echo "  Cannot check Flux kustomizations"
            ;;
    esac
}

show_diff() {
    print_section "Pending Changes"
    
    # Local changes
    echo "Uncommitted changes:"
    git_cmd diff --stat
    
    # Commits not pushed
    echo ""
    echo "Unpushed commits:"
    git_cmd log --oneline "origin/$BRANCH"..HEAD 2>/dev/null | head -10 || echo "  (none)"
    
    # Commits not pulled
    echo ""
    echo "Remote commits not pulled:"
    git_cmd fetch origin "$BRANCH" &>/dev/null || true
    git_cmd log --oneline HEAD.."origin/$BRANCH" 2>/dev/null | head -10 || echo "  (none)"
}

do_sync() {
    print_section "Trigger Sync"
    
    case "$GITOPS_TOOL" in
        argocd)
            log "Syncing ArgoCD applications..."
            
            local apps
            apps=$(kubectl get applications -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
            
            if [[ -z "$apps" ]]; then
                log_error "No applications found"
                return 1
            fi
            
            echo "Applications: $apps"
            
            if ! confirm "Sync all applications?"; then
                log "Cancelled"
                return 0
            fi
            
            for app in $apps; do
                log "Syncing $app..."
                if command -v argocd &>/dev/null; then
                    argocd app sync "$app" --prune 2>/dev/null || log_warn "Sync failed for $app"
                else
                    kubectl patch application "$app" -n "$NAMESPACE" --type merge \
                        -p '{"operation":{"sync":{"prune":true}}}' 2>/dev/null || true
                fi
            done
            
            log_success "Sync triggered"
            ;;
        flux)
            log "Reconciling Flux kustomizations..."
            
            local kustomizations
            kustomizations=$(kubectl get kustomizations -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
            
            if ! confirm "Reconcile all kustomizations?"; then
                log "Cancelled"
                return 0
            fi
            
            echo "$kustomizations" | while IFS='/' read -r ns name; do
                [[ -z "$name" ]] && continue
                log "Reconciling $name..."
                flux reconcile kustomization "$name" -n "$ns" 2>/dev/null || true
            done
            
            log_success "Reconciliation triggered"
            ;;
    esac
}

show_history() {
    print_section "Deployment History"
    
    # Git log
    echo "Recent commits:"
    git_cmd log --oneline --decorate -20
    
    # Tags
    echo ""
    echo "Recent tags:"
    git_cmd tag --sort=-creatordate | head -10 || echo "  (no tags)"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    check_repo
    
    case "$COMMAND" in
        status)  show_status ;;
        diff)    show_diff ;;
        sync)    do_sync ;;
        history) show_history ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
