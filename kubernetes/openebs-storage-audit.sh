#!/bin/bash
#
# openebs-storage-audit.sh - OpenEBS storage monitoring and cleanup
#
# Usage:
#   ./openebs-storage-audit.sh [options]
#
# Options:
#   -e, --env ENV       Target environment (dev|staging|prod)
#   -c, --cleanup       Run cleanup mode (remove orphaned volumes)
#   -d, --dry-run       Preview cleanup without making changes
#   -v, --verbose       Show detailed output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/k8s-helpers.sh"

# Configuration
CLEANUP_MODE=false
HOSTPATH_DIR="/var/openebs/local"
WARN_THRESHOLD_PCT=80

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--env)
                set_k8s_env "$2" || exit 1
                shift 2
                ;;
            -c|--cleanup)
                CLEANUP_MODE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -v|--verbose)
                VERBOSE="true"
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
# Storage checks
# -----------------------------------------------------------------------------

# Check OpenEBS installation
check_openebs_status() {
    print_section "OpenEBS Status"
    
    if ! kubectl get ns openebs &>/dev/null; then
        log_warn "OpenEBS namespace not found"
        return 1
    fi
    
    # Check OpenEBS pods
    local running=$(kubectl get pods -n openebs --no-headers 2>/dev/null | grep -c "Running")
    local total=$(kubectl get pods -n openebs --no-headers 2>/dev/null | wc -l)
    
    print_kv "OpenEBS Pods" "${running}/${total} running"
    
    # Check storage classes
    echo ""
    echo "Storage Classes:"
    kubectl get sc 2>/dev/null | grep -E "NAME|openebs" || echo "  No OpenEBS storage classes found"
    
    return 0
}

# Get storage utilization summary
show_storage_summary() {
    print_section "Storage Summary"
    
    # PV Summary
    local pv_total=$(kubectl get pv --no-headers 2>/dev/null | wc -l)
    local pv_bound=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Bound")
    local pv_available=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Available")
    local pv_released=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Released")
    local pv_failed=$(kubectl get pv --no-headers 2>/dev/null | grep -c "Failed")
    
    echo ""
    echo "Persistent Volumes:"
    print_kv "  Total" "$pv_total"
    print_kv "  Bound" "$pv_bound"
    print_kv "  Available" "$pv_available"
    print_kv "  Released" "$pv_released"
    print_kv "  Failed" "$pv_failed"
    
    # PVC Summary
    local pvc_total=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)
    local pvc_bound=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c "Bound")
    local pvc_pending=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep -c "Pending")
    
    echo ""
    echo "Persistent Volume Claims:"
    print_kv "  Total" "$pvc_total"
    print_kv "  Bound" "$pvc_bound"
    print_kv "  Pending" "$pvc_pending"
    
    # Capacity by storage class
    echo ""
    echo "Capacity by Storage Class:"
    kubectl get pv -o json 2>/dev/null | \
        jq -r '.items | group_by(.spec.storageClassName) | 
               .[] | 
               {sc: .[0].spec.storageClassName, count: length, 
                total: [.[].spec.capacity.storage | gsub("[A-Za-z]";"") | tonumber] | add} | 
               "\(.sc): \(.count) volumes, \(.total)Gi total"' 2>/dev/null | \
        while read -r line; do
            echo "  $line"
        done
}

# Check hostpath disk usage per node
check_hostpath_usage() {
    print_section "Hostpath Disk Usage"
    
    echo ""
    echo "Checking $HOSTPATH_DIR on each node..."
    echo ""
    
    local issues=0
    
    for node in $(get_nodes); do
        # Try to get disk usage via SSH (adjust if using different method)
        local usage
        usage=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$node" \
            "df -h $HOSTPATH_DIR 2>/dev/null | tail -1 | awk '{print \$5}'" 2>/dev/null || echo "N/A")
        
        if [[ "$usage" == "N/A" ]]; then
            log_debug "Cannot connect to $node via SSH"
            continue
        fi
        
        local pct=${usage%\%}
        
        if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= WARN_THRESHOLD_PCT )); then
            log_warn "$node: $usage used"
            ((issues++))
        else
            echo "  $node: $usage used"
        fi
    done
    
    if [[ $issues -gt 0 ]]; then
        log_warn "$issues nodes above ${WARN_THRESHOLD_PCT}% threshold"
    fi
}

# Find orphaned PVs (Released but not deleted)
find_orphaned_pvs() {
    print_section "Orphaned Volumes"
    
    # Get Released PVs
    local released_pvs
    released_pvs=$(kubectl get pv -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase == "Released") | 
               "\(.metadata.name) \(.spec.capacity.storage) \(.spec.claimRef.namespace)/\(.spec.claimRef.name)"')
    
    if [[ -z "$released_pvs" ]]; then
        log_success "No orphaned (Released) volumes found"
        return 0
    fi
    
    echo ""
    echo "Released PVs (orphaned):"
    echo ""
    printf "  %-40s %-10s %s\n" "PV Name" "Size" "Previous Claim"
    echo "  $(printf '%.0s-' {1..70})"
    
    while read -r pv size claim; do
        printf "  %-40s %-10s %s\n" "$pv" "$size" "$claim"
    done <<< "$released_pvs"
    
    local count=$(echo "$released_pvs" | wc -l)
    echo ""
    log_warn "Found $count orphaned volumes"
    
    return $count
}

# Find PVCs without matching pods
find_unused_pvcs() {
    print_section "Unused PVCs"
    
    echo ""
    echo "Checking for PVCs not mounted by any pod..."
    echo ""
    
    local unused_count=0
    
    # Get all PVCs
    kubectl get pvc --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
    while read -r ns pvc; do
        # Check if any pod uses this PVC
        local pods_using
        pods_using=$(kubectl get pods -n "$ns" -o json 2>/dev/null | \
            jq -r --arg pvc "$pvc" \
            '.items[] | select(.spec.volumes[]? | 
             select(.persistentVolumeClaim.claimName == $pvc)) | 
             .metadata.name' 2>/dev/null)
        
        if [[ -z "$pods_using" ]]; then
            echo "  $ns/$pvc - not mounted"
            ((unused_count++))
        fi
    done
    
    if [[ $unused_count -eq 0 ]]; then
        log_success "All PVCs are in use"
    else
        log_warn "Found $unused_count unused PVCs"
    fi
}

# Check for failed PVCs
check_failed_pvcs() {
    print_section "PVC Issues"
    
    # Pending PVCs
    local pending
    pending=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | grep "Pending")
    
    if [[ -z "$pending" ]]; then
        log_success "No pending PVCs"
    else
        echo ""
        echo "Pending PVCs:"
        echo "$pending" | while read -r line; do
            echo "  $line"
        done
        
        echo ""
        log_warn "Check storage class and provisioner status"
    fi
    
    # Failed PVs
    local failed
    failed=$(kubectl get pv --no-headers 2>/dev/null | grep "Failed")
    
    if [[ -n "$failed" ]]; then
        echo ""
        echo "Failed PVs:"
        echo "$failed" | while read -r line; do
            echo "  $line"
        done
    fi
}

# -----------------------------------------------------------------------------
# Cleanup functions
# -----------------------------------------------------------------------------

cleanup_released_pvs() {
    print_section "Cleanup Released PVs"
    
    local released_pvs
    released_pvs=$(kubectl get pv -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.phase == "Released") | .metadata.name')
    
    if [[ -z "$released_pvs" ]]; then
        log "No Released PVs to clean up"
        return 0
    fi
    
    local count=$(echo "$released_pvs" | wc -l)
    log "Found $count Released PVs"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would delete the following PVs:"
        echo "$released_pvs" | while read -r pv; do
            echo "  $pv"
        done
        return 0
    fi
    
    if ! confirm "Delete $count Released PVs?"; then
        log "Cleanup cancelled"
        return 0
    fi
    
    echo "$released_pvs" | while read -r pv; do
        log "Deleting PV: $pv"
        kubectl delete pv "$pv" 2>/dev/null && \
            log_success "Deleted: $pv" || \
            log_error "Failed to delete: $pv"
    done
}

# Clean up orphaned hostpath directories
cleanup_hostpath_dirs() {
    print_section "Cleanup Orphaned Hostpath Directories"
    
    log "This requires SSH access to nodes"
    log "Checking for directories without matching PVs..."
    
    # Get list of valid PV paths
    local valid_paths
    valid_paths=$(kubectl get pv -o json 2>/dev/null | \
        jq -r '.items[] | select(.spec.local.path != null) | .spec.local.path')
    
    # This would need to run on each node
    # For now, just list what we would check
    for node in $(get_nodes); do
        echo ""
        echo "Node: $node"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY-RUN: Would check $HOSTPATH_DIR on $node"
        else
            log_debug "Would SSH to $node and compare directories"
        fi
    done
    
    log "Manual cleanup recommended - review directories before deletion"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    # Check cluster connection
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Not connected to any cluster"
        exit 1
    fi
    
    print_header "OpenEBS Storage Audit"
    print_kv "Cluster" "$(get_cluster_name)"
    print_kv "Timestamp" "$(date)"
    
    if [[ "$CLEANUP_MODE" == "true" ]]; then
        print_kv "Mode" "Cleanup"
        [[ "$DRY_RUN" == "true" ]] && print_kv "Dry Run" "Enabled"
    else
        print_kv "Mode" "Audit"
    fi
    
    # Run audit checks
    check_openebs_status
    show_storage_summary
    check_hostpath_usage
    find_orphaned_pvs
    find_unused_pvcs
    check_failed_pvcs
    
    # Run cleanup if requested
    if [[ "$CLEANUP_MODE" == "true" ]]; then
        echo ""
        print_section "Running Cleanup"
        cleanup_released_pvs
        cleanup_hostpath_dirs
    fi
    
    echo ""
    log_success "Audit complete"
}

main "$@"
