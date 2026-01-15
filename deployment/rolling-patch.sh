#!/bin/bash
#
# rolling-patch.sh - Rolling patch manager with Kubernetes awareness
#
# Orchestrates OS patching with minimal downtime for K8s nodes.
#
# Usage:
#   ./rolling-patch.sh [options]
#
# Options:
#   -t, --target HOST     Target host to patch
#   -g, --group GROUP     Patch hosts in group (from inventory)
#   -e, --env ENV         Target environment (dev|staging|prod)
#   -d, --dry-run         Preview without making changes
#   --skip-reboot         Skip reboot even if required
#   --skip-drain          Skip K8s node drain
#   -h, --help            Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
TARGET_HOST=""
HOST_GROUP=""
SKIP_REBOOT=false
SKIP_DRAIN=false
INVENTORY_FILE="${INVENTORY_FILE:-/etc/ansible/hosts}"
PRE_PATCH_SCRIPT=""
POST_PATCH_SCRIPT=""

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -t|--target)
                TARGET_HOST="$2"
                shift 2
                ;;
            -g|--group)
                HOST_GROUP="$2"
                shift 2
                ;;
            -e|--env)
                K8S_ENV="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            --skip-reboot)
                SKIP_REBOOT=true
                shift
                ;;
            --skip-drain)
                SKIP_DRAIN=true
                shift
                ;;
            -h|--help)
                grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //' | sed 's/^#//'
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Host management
# -----------------------------------------------------------------------------

# Get hosts from group
get_hosts_from_group() {
    local group="$1"
    
    if [[ -f "$INVENTORY_FILE" ]]; then
        # Simple inventory parsing (for INI format)
        awk -v group="[$group]" '
            $0 == group {found=1; next}
            /^\[/ {found=0}
            found && NF && !/^#/ {print $1}
        ' "$INVENTORY_FILE"
    else
        log_error "Inventory file not found: $INVENTORY_FILE"
        return 1
    fi
}

# Run command on remote host
run_remote() {
    local host="$1"
    local cmd="$2"
    
    ssh -o ConnectTimeout=30 -o BatchMode=yes "$host" "$cmd" 2>/dev/null
}

# Check if host is reachable
check_host() {
    local host="$1"
    
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" "echo ok" &>/dev/null; then
        return 0
    fi
    return 1
}

# Detect OS on host
detect_host_os() {
    local host="$1"
    run_remote "$host" "cat /etc/os-release | grep '^ID=' | cut -d= -f2 | tr -d '\"'"
}

# Check if host is a K8s node
is_k8s_node() {
    local host="$1"
    run_remote "$host" "test -f /var/lib/rancher/rke2/bin/kubectl && echo yes" || echo "no"
}

# -----------------------------------------------------------------------------
# Pre-patch checks
# -----------------------------------------------------------------------------

pre_patch_check() {
    local host="$1"
    
    print_section "Pre-patch Check: $host"
    
    # Check connectivity
    if ! check_host "$host"; then
        log_error "Cannot connect to $host"
        return 1
    fi
    log_success "Host is reachable"
    
    # Check disk space
    local root_usage=$(run_remote "$host" "df / | tail -1 | awk '{print \$5}' | tr -d '%'")
    if (( root_usage > 90 )); then
        log_error "Insufficient disk space (${root_usage}% used)"
        return 1
    fi
    log_success "Disk space OK (${root_usage}% used)"
    
    # Check for running updates
    local os=$(detect_host_os "$host")
    case "$os" in
        ubuntu|debian)
            if run_remote "$host" "pgrep -x apt-get || pgrep -x dpkg" &>/dev/null; then
                log_error "Another package manager is running"
                return 1
            fi
            ;;
        rocky|centos|rhel)
            if run_remote "$host" "pgrep -x yum || pgrep -x dnf" &>/dev/null; then
                log_error "Another package manager is running"
                return 1
            fi
            ;;
    esac
    log_success "No package manager locks"
    
    # Custom pre-patch script
    if [[ -n "$PRE_PATCH_SCRIPT" && -f "$PRE_PATCH_SCRIPT" ]]; then
        log "Running pre-patch script"
        if ! "$PRE_PATCH_SCRIPT" "$host"; then
            log_error "Pre-patch script failed"
            return 1
        fi
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Kubernetes operations
# -----------------------------------------------------------------------------

drain_k8s_node() {
    local host="$1"
    
    if [[ "$SKIP_DRAIN" == "true" ]]; then
        log "Skipping K8s drain (--skip-drain)"
        return 0
    fi
    
    # Get node name (might differ from hostname)
    local node_name=$(run_remote "$host" "hostname -s")
    
    log "Draining K8s node: $node_name"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would drain node $node_name"
        return 0
    fi
    
    # Drain with reasonable timeout
    kubectl drain "$node_name" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=300s 2>&1 | while read -r line; do
            log "  $line"
        done
    
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Failed to drain node"
        return 1
    fi
    
    log_success "Node drained successfully"
}

uncordon_k8s_node() {
    local host="$1"
    
    if [[ "$SKIP_DRAIN" == "true" ]]; then
        return 0
    fi
    
    local node_name=$(run_remote "$host" "hostname -s")
    
    log "Uncordoning K8s node: $node_name"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would uncordon node $node_name"
        return 0
    fi
    
    kubectl uncordon "$node_name"
    log_success "Node uncordoned"
}

# -----------------------------------------------------------------------------
# Patching functions
# -----------------------------------------------------------------------------

update_packages() {
    local host="$1"
    local os=$(detect_host_os "$host")
    
    log "Updating packages on $host ($os)"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would update packages"
        return 0
    fi
    
    case "$os" in
        ubuntu|debian)
            run_remote "$host" "DEBIAN_FRONTEND=noninteractive apt-get update && \
                DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" | while read -r line; do
                log_debug "  $line"
            done
            ;;
        rocky|centos|rhel|almalinux)
            run_remote "$host" "yum update -y" | while read -r line; do
                log_debug "  $line"
            done
            ;;
        *)
            log_error "Unsupported OS: $os"
            return 1
            ;;
    esac
    
    log_success "Package update completed"
}

check_reboot_required() {
    local host="$1"
    local os=$(detect_host_os "$host")
    
    case "$os" in
        ubuntu|debian)
            if run_remote "$host" "test -f /var/run/reboot-required && echo yes" | grep -q yes; then
                return 0
            fi
            ;;
        rocky|centos|rhel|almalinux)
            if run_remote "$host" "needs-restarting -r &>/dev/null; echo \$?" | grep -q 1; then
                return 0
            fi
            ;;
    esac
    return 1
}

reboot_host() {
    local host="$1"
    
    if [[ "$SKIP_REBOOT" == "true" ]]; then
        log "Skipping reboot (--skip-reboot)"
        return 0
    fi
    
    log "Rebooting $host"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would reboot host"
        return 0
    fi
    
    run_remote "$host" "shutdown -r +1 'System patching - scheduled reboot'" || true
    
    log "Waiting for host to go down..."
    sleep 70
    
    # Wait for host to come back
    local max_wait=300
    local waited=0
    
    while ! check_host "$host"; do
        sleep 10
        ((waited += 10))
        
        if (( waited >= max_wait )); then
            log_error "Host did not come back after reboot"
            return 1
        fi
        
        log "Waiting for host... (${waited}s)"
    done
    
    log_success "Host is back online"
}

# -----------------------------------------------------------------------------
# Post-patch validation
# -----------------------------------------------------------------------------

post_patch_check() {
    local host="$1"
    
    print_section "Post-patch Validation: $host"
    
    # Check host is up
    if ! check_host "$host"; then
        log_error "Host is not reachable"
        return 1
    fi
    log_success "Host is reachable"
    
    # Check services
    local failed_services=$(run_remote "$host" "systemctl --failed --no-legend | wc -l")
    if (( failed_services > 0 )); then
        log_warn "$failed_services failed services"
        run_remote "$host" "systemctl --failed --no-legend"
    else
        log_success "All services running"
    fi
    
    # Check K8s node if applicable
    if [[ $(is_k8s_node "$host") == "yes" ]]; then
        local node_name=$(run_remote "$host" "hostname -s")
        
        # Wait for node to be Ready
        local max_wait=120
        local waited=0
        
        while true; do
            local status=$(kubectl get node "$node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
            
            if [[ "$status" == "True" ]]; then
                log_success "K8s node is Ready"
                break
            fi
            
            sleep 10
            ((waited += 10))
            
            if (( waited >= max_wait )); then
                log_error "Node did not become Ready"
                return 1
            fi
            
            log "Waiting for node to be Ready... (${waited}s)"
        done
    fi
    
    # Custom post-patch script
    if [[ -n "$POST_PATCH_SCRIPT" && -f "$POST_PATCH_SCRIPT" ]]; then
        log "Running post-patch script"
        if ! "$POST_PATCH_SCRIPT" "$host"; then
            log_warn "Post-patch script reported issues"
        fi
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# Main patch function
# -----------------------------------------------------------------------------

patch_host() {
    local host="$1"
    local is_k8s=$(is_k8s_node "$host")
    
    print_header "Patching: $host"
    
    # Pre-patch checks
    if ! pre_patch_check "$host"; then
        log_error "Pre-patch checks failed, skipping host"
        return 1
    fi
    
    # Drain K8s node if applicable
    if [[ "$is_k8s" == "yes" ]]; then
        if ! drain_k8s_node "$host"; then
            log_error "Failed to drain K8s node"
            return 1
        fi
    fi
    
    # Update packages
    if ! update_packages "$host"; then
        log_error "Package update failed"
        [[ "$is_k8s" == "yes" ]] && uncordon_k8s_node "$host"
        return 1
    fi
    
    # Reboot if required
    if check_reboot_required "$host"; then
        log "Reboot is required"
        if ! reboot_host "$host"; then
            log_error "Reboot failed"
            return 1
        fi
    else
        log "No reboot required"
    fi
    
    # Uncordon K8s node
    if [[ "$is_k8s" == "yes" ]]; then
        uncordon_k8s_node "$host"
    fi
    
    # Post-patch validation
    if ! post_patch_check "$host"; then
        log_error "Post-patch checks failed"
        return 1
    fi
    
    log_success "Patching complete: $host"
    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    local hosts=()
    
    # Determine target hosts
    if [[ -n "$TARGET_HOST" ]]; then
        hosts+=("$TARGET_HOST")
    elif [[ -n "$HOST_GROUP" ]]; then
        mapfile -t hosts < <(get_hosts_from_group "$HOST_GROUP")
    else
        # Interactive mode
        print_header "Rolling Patch Manager"
        echo ""
        echo "Options:"
        echo "  1) Patch single host"
        echo "  2) Patch host group"
        echo "  q) Quit"
        echo ""
        
        local choice
        read -p "Enter choice: " choice
        
        case "$choice" in
            1)
                read -p "Hostname: " TARGET_HOST
                hosts+=("$TARGET_HOST")
                ;;
            2)
                read -p "Host group: " HOST_GROUP
                mapfile -t hosts < <(get_hosts_from_group "$HOST_GROUP")
                ;;
            q|Q)
                exit 0
                ;;
        esac
    fi
    
    if [[ ${#hosts[@]} -eq 0 ]]; then
        log_error "No hosts to patch"
        exit 1
    fi
    
    print_header "Rolling Patch"
    echo "Hosts to patch: ${hosts[*]}"
    echo "Dry run: $DRY_RUN"
    echo ""
    
    if ! confirm "Proceed with patching?"; then
        log "Cancelled"
        exit 0
    fi
    
    # Patch hosts one by one
    local success=0
    local failed=0
    
    for host in "${hosts[@]}"; do
        if patch_host "$host"; then
            ((success++))
        else
            ((failed++))
            
            if ! confirm "Continue with remaining hosts?"; then
                break
            fi
        fi
        
        # Brief pause between hosts
        sleep 5
    done
    
    # Summary
    echo ""
    print_section "Summary"
    print_kv "Total Hosts" "${#hosts[@]}"
    print_kv "Successful" "$success"
    print_kv "Failed" "$failed"
    
    [[ $failed -eq 0 ]] && exit 0 || exit 1
}

main "$@"
