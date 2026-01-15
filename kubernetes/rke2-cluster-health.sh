#!/bin/bash
#
# rke2-cluster-health.sh - Comprehensive health check for RKE2 clusters
#
# Usage:
#   ./rke2-cluster-health.sh [options]
#
# Options:
#   -e, --env ENV       Target environment (dev|staging|prod)
#   -v, --verbose       Show detailed output
#   -j, --json          Output results as JSON
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/k8s-helpers.sh"

# Configuration
OUTPUT_FORMAT="text"
CHECK_RESULTS=()
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARN_CHECKS=0

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
show_help() {
    grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //' | sed 's/^#//'
    exit 0
}

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
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -j|--json)
                OUTPUT_FORMAT="json"
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Check functions
# -----------------------------------------------------------------------------

# Record a check result
record_check() {
    local name="$1"
    local status="$2"  # pass, fail, warn
    local message="$3"
    
    ((TOTAL_CHECKS++))
    
    case "$status" in
        pass) ((PASSED_CHECKS++)); log_success "$name: $message" ;;
        fail) ((FAILED_CHECKS++)); log_error "$name: $message" ;;
        warn) ((WARN_CHECKS++)); log_warn "$name: $message" ;;
    esac
    
    CHECK_RESULTS+=("{\"name\":\"$name\",\"status\":\"$status\",\"message\":\"$message\"}")
}

# Check cluster connectivity
check_connectivity() {
    print_section "Cluster Connectivity"
    
    if kubectl cluster-info &>/dev/null; then
        local server=$(kubectl cluster-info 2>/dev/null | head -1 | awk '{print $NF}')
        record_check "API Server" "pass" "Connected to cluster"
    else
        record_check "API Server" "fail" "Cannot connect to cluster"
        return 1
    fi
}

# Check node health
check_nodes() {
    print_section "Node Health"
    
    local total_nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready ")
    local not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready " | awk '{print $1}' | tr '\n' ', ')
    
    if [[ $ready_nodes -eq $total_nodes ]]; then
        record_check "Nodes" "pass" "All $total_nodes nodes are Ready"
    else
        record_check "Nodes" "fail" "$ready_nodes/$total_nodes nodes Ready. Not ready: $not_ready"
    fi
    
    # Show node details if verbose
    if [[ "$VERBOSE" == "true" ]]; then
        echo ""
        kubectl get nodes -o wide 2>/dev/null
    fi
}

# Check control plane components
check_control_plane() {
    print_section "Control Plane Components"
    
    local ns="kube-system"
    local components=("kube-apiserver" "kube-controller-manager" "kube-scheduler")
    
    for component in "${components[@]}"; do
        local running=$(kubectl get pods -n "$ns" -l "component=$component" --no-headers 2>/dev/null | grep -c "Running")
        local total=$(kubectl get pods -n "$ns" -l "component=$component" --no-headers 2>/dev/null | wc -l)
        
        if [[ $total -eq 0 ]]; then
            # RKE2 uses different labels, try tier label
            running=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep "$component" | grep -c "Running")
            total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -c "$component")
        fi
        
        if [[ $running -gt 0 && $running -eq $total ]]; then
            record_check "$component" "pass" "$running/$total running"
        elif [[ $running -gt 0 ]]; then
            record_check "$component" "warn" "$running/$total running"
        else
            record_check "$component" "fail" "No pods running"
        fi
    done
}

# Check etcd cluster
check_etcd() {
    print_section "etcd Cluster"
    
    # Check etcd pods
    local etcd_pods=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "etcd.*Running")
    
    if [[ $etcd_pods -ge 1 ]]; then
        record_check "etcd pods" "pass" "$etcd_pods etcd pods running"
    else
        record_check "etcd pods" "fail" "No etcd pods found"
    fi
    
    # Check if we can run etcd health check locally (on server node)
    if [[ -x "/var/lib/rancher/rke2/bin/etcdctl" ]]; then
        if check_etcd_health &>/dev/null; then
            record_check "etcd health" "pass" "etcd endpoint healthy"
        else
            record_check "etcd health" "fail" "etcd endpoint unhealthy"
        fi
    fi
}

# Check core system pods
check_system_pods() {
    print_section "System Pods"
    
    local ns="kube-system"
    local unhealthy=$(get_unhealthy_pods "$ns" | wc -l)
    local total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l)
    
    if [[ $unhealthy -eq 0 ]]; then
        record_check "System Pods" "pass" "All $total pods healthy"
    else
        record_check "System Pods" "warn" "$unhealthy/$total pods not running"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "Unhealthy pods:"
            get_unhealthy_pods "$ns" | head -10
        fi
    fi
}

# Check for pods with high restart counts
check_restarts() {
    print_section "Pod Restarts"
    
    local threshold=5
    local restarting=$(get_restarting_pods $threshold | wc -l)
    
    if [[ $restarting -eq 0 ]]; then
        record_check "Pod Restarts" "pass" "No pods with >$threshold restarts"
    else
        record_check "Pod Restarts" "warn" "$restarting pods with >$threshold restarts"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "Pods with high restarts:"
            get_restarting_pods $threshold | head -10
        fi
    fi
}

# Check node resources
check_resources() {
    print_section "Resource Usage"
    
    # Check if metrics-server is available
    if ! kubectl top nodes &>/dev/null; then
        record_check "Resource Metrics" "warn" "metrics-server not available"
        return
    fi
    
    local high_cpu=0
    local high_mem=0
    
    while read -r node cpu_pct mem_pct; do
        # Remove % sign
        cpu_pct=${cpu_pct%\%}
        mem_pct=${mem_pct%\%}
        
        if [[ $cpu_pct -gt 80 ]]; then
            ((high_cpu++))
            log_warn "Node $node: CPU at ${cpu_pct}%"
        fi
        if [[ $mem_pct -gt 80 ]]; then
            ((high_mem++))
            log_warn "Node $node: Memory at ${mem_pct}%"
        fi
    done < <(kubectl top nodes --no-headers 2>/dev/null | awk '{print $1, $3, $5}')
    
    if [[ $high_cpu -eq 0 && $high_mem -eq 0 ]]; then
        record_check "Resources" "pass" "All nodes within limits"
    else
        record_check "Resources" "warn" "$high_cpu nodes high CPU, $high_mem nodes high memory"
    fi
}

# Check storage classes
check_storage() {
    print_section "Storage"
    
    # Check storage classes exist
    local sc_count=$(kubectl get sc --no-headers 2>/dev/null | wc -l)
    if [[ $sc_count -gt 0 ]]; then
        record_check "Storage Classes" "pass" "$sc_count storage classes configured"
    else
        record_check "Storage Classes" "fail" "No storage classes found"
    fi
    
    # Check for pending PVCs
    local pending_pvcs=$(get_pending_pvcs | wc -l)
    if [[ $pending_pvcs -eq 0 ]]; then
        record_check "PVCs" "pass" "All PVCs bound"
    else
        record_check "PVCs" "warn" "$pending_pvcs PVCs pending"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "Pending PVCs:"
            get_pending_pvcs | head -5
        fi
    fi
}

# Check certificates
check_certificates() {
    print_section "Certificates"
    
    # Only check if running on a server node
    if [[ ! -d "/var/lib/rancher/rke2/server/tls" ]]; then
        log "Skipping cert check (not a server node)"
        return
    fi
    
    local expired=0
    local expiring=0
    local cert_dir="/var/lib/rancher/rke2/server/tls"
    
    for cert in $(find "$cert_dir" -name "*.crt" 2>/dev/null | head -20); do
        local expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        local now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        
        if (( days_left < 0 )); then
            ((expired++))
        elif (( days_left < 30 )); then
            ((expiring++))
        fi
    done
    
    if [[ $expired -gt 0 ]]; then
        record_check "Certificates" "fail" "$expired certificates expired"
    elif [[ $expiring -gt 0 ]]; then
        record_check "Certificates" "warn" "$expiring certificates expiring within 30 days"
    else
        record_check "Certificates" "pass" "All certificates valid"
    fi
}

# Check recent events
check_events() {
    print_section "Recent Events"
    
    local warnings=$(kubectl get events --all-namespaces --field-selector type=Warning \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -n +2 | wc -l)
    
    if [[ $warnings -eq 0 ]]; then
        record_check "Events" "pass" "No warning events"
    elif [[ $warnings -lt 10 ]]; then
        record_check "Events" "warn" "$warnings warning events in cluster"
    else
        record_check "Events" "fail" "$warnings warning events (high count)"
    fi
    
    if [[ "$VERBOSE" == "true" && $warnings -gt 0 ]]; then
        echo "Recent warnings:"
        kubectl get events --all-namespaces --field-selector type=Warning \
            --sort-by='.lastTimestamp' 2>/dev/null | tail -5
    fi
}

# -----------------------------------------------------------------------------
# Output functions
# -----------------------------------------------------------------------------

print_summary() {
    echo ""
    print_section "Summary"
    echo ""
    print_kv "Total Checks" "$TOTAL_CHECKS"
    print_kv "Passed" "$PASSED_CHECKS"
    print_kv "Warnings" "$WARN_CHECKS"
    print_kv "Failed" "$FAILED_CHECKS"
    echo ""
    
    if [[ $FAILED_CHECKS -eq 0 && $WARN_CHECKS -eq 0 ]]; then
        echo -e "${GREEN}Cluster is healthy${RESET}"
    elif [[ $FAILED_CHECKS -eq 0 ]]; then
        echo -e "${YELLOW}Cluster has warnings, review recommended${RESET}"
    else
        echo -e "${RED}Cluster has failures, action required${RESET}"
    fi
}

output_json() {
    local results=$(IFS=,; echo "${CHECK_RESULTS[*]}")
    cat <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "cluster": "$(get_cluster_name)",
  "environment": "${K8S_ENV:-unknown}",
  "summary": {
    "total": $TOTAL_CHECKS,
    "passed": $PASSED_CHECKS,
    "warnings": $WARN_CHECKS,
    "failed": $FAILED_CHECKS
  },
  "checks": [$results]
}
EOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    # If no environment specified, try to use current context
    if [[ -z "$K8S_ENV" ]]; then
        if ! kubectl cluster-info &>/dev/null; then
            log_error "Not connected to any cluster. Use -e to specify environment."
            exit 1
        fi
        K8S_ENV=$(get_cluster_name)
    fi
    
    if [[ "$OUTPUT_FORMAT" == "text" ]]; then
        print_header "RKE2 Cluster Health Check"
        print_kv "Environment" "$K8S_ENV"
        print_kv "Timestamp" "$(date)"
    fi
    
    # Run all checks
    check_connectivity || exit 1
    check_nodes
    check_control_plane
    check_etcd
    check_system_pods
    check_restarts
    check_resources
    check_storage
    check_certificates
    check_events
    
    # Output results
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        output_json
    else
        print_summary
    fi
    
    # Exit with appropriate code
    [[ $FAILED_CHECKS -eq 0 ]] && exit 0 || exit 1
}

main "$@"
