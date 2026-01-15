#!/bin/bash
#
# k8s-troubleshoot.sh - Interactive Kubernetes troubleshooting toolkit
#
# Usage:
#   ./k8s-troubleshoot.sh [options]
#
# Options:
#   -e, --env ENV       Target environment (dev|staging|prod)
#   -n, --namespace NS  Target namespace (default: all)
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/k8s-helpers.sh"

# Configuration
TARGET_NS=""
INTERACTIVE=true

# -----------------------------------------------------------------------------
# Menu functions
# -----------------------------------------------------------------------------

show_menu() {
    print_header "Kubernetes Troubleshooting"
    
    echo "Environment: ${K8S_ENV:-$(get_cluster_name)}"
    echo "Namespace:   ${TARGET_NS:-all}"
    echo ""
    echo "Select an option:"
    echo ""
    echo "  [Pod Issues]"
    echo "    1) List failing pods"
    echo "    2) Show pods with high restarts"
    echo "    3) Get pod logs"
    echo "    4) Describe pod"
    echo "    5) Exec into pod"
    echo ""
    echo "  [Events & Resources]"
    echo "    6) Show recent warning events"
    echo "    7) Show resource usage (top)"
    echo "    8) Check OOMKilled / Evicted pods"
    echo ""
    echo "  [Storage]"
    echo "    9) List pending PVCs"
    echo "   10) Check storage class issues"
    echo ""
    echo "  [Network]"
    echo "   11) Check service endpoints"
    echo "   12) DNS resolution test"
    echo ""
    echo "  [Utilities]"
    echo "   13) Change namespace"
    echo "   14) Change environment"
    echo "    q) Quit"
    echo ""
}

# Prompt for input
prompt() {
    local msg="$1"
    local var_name="$2"
    local default="${3:-}"
    
    if [[ -n "$default" ]]; then
        read -p "$msg [$default]: " value
        value="${value:-$default}"
    else
        read -p "$msg: " value
    fi
    
    eval "$var_name=\"$value\""
}

# Get namespace filter
ns_flag() {
    if [[ -n "$TARGET_NS" ]]; then
        echo "-n $TARGET_NS"
    else
        echo "--all-namespaces"
    fi
}

# -----------------------------------------------------------------------------
# Troubleshooting functions
# -----------------------------------------------------------------------------

# 1. List failing pods
list_failing_pods() {
    print_section "Failing Pods"
    
    local pods
    pods=$(get_unhealthy_pods "$TARGET_NS")
    
    if [[ -z "$pods" ]]; then
        log_success "No failing pods found"
        return
    fi
    
    echo "$pods" | while read -r line; do
        echo "  $line"
    done
    
    echo ""
    local count=$(echo "$pods" | wc -l)
    log_warn "Found $count pods not in Running/Completed state"
}

# 2. Show pods with high restarts
show_high_restarts() {
    print_section "Pods with High Restart Count"
    
    local threshold
    prompt "Restart threshold" threshold "5"
    
    local pods
    pods=$(get_restarting_pods "$threshold")
    
    if [[ -z "$pods" ]]; then
        log_success "No pods with >$threshold restarts"
        return
    fi
    
    echo ""
    echo "$pods"
    echo ""
    
    # Offer to describe the pod
    read -p "Would you like to see events for a pod? [y/N]: " answer
    if [[ "$answer" =~ ^[yY] ]]; then
        local ns pod
        prompt "Namespace" ns
        prompt "Pod name" pod
        kubectl describe pod -n "$ns" "$pod" 2>/dev/null | grep -A 50 "Events:"
    fi
}

# 3. Get pod logs
get_pod_logs() {
    print_section "Pod Logs"
    
    local ns pod container opts
    
    if [[ -n "$TARGET_NS" ]]; then
        ns="$TARGET_NS"
    else
        prompt "Namespace" ns
    fi
    
    # List pods in namespace
    echo ""
    echo "Available pods:"
    kubectl get pods -n "$ns" --no-headers 2>/dev/null | head -20
    echo ""
    
    prompt "Pod name" pod
    
    # Check if multiple containers
    local containers
    containers=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    
    if [[ $(echo "$containers" | wc -w) -gt 1 ]]; then
        echo "Containers: $containers"
        prompt "Container" container
        opts="-c $container"
    else
        opts=""
    fi
    
    # Options
    echo ""
    echo "Log options:"
    echo "  1) Last 100 lines"
    echo "  2) Last 500 lines"
    echo "  3) Since 1h"
    echo "  4) Since 24h"
    echo "  5) Previous container logs"
    echo "  6) Follow (stream)"
    echo ""
    
    local choice
    prompt "Choice" choice "1"
    
    case "$choice" in
        1) kubectl logs "$pod" -n "$ns" $opts --tail=100 ;;
        2) kubectl logs "$pod" -n "$ns" $opts --tail=500 ;;
        3) kubectl logs "$pod" -n "$ns" $opts --since=1h ;;
        4) kubectl logs "$pod" -n "$ns" $opts --since=24h ;;
        5) kubectl logs "$pod" -n "$ns" $opts --previous --tail=200 ;;
        6) kubectl logs "$pod" -n "$ns" $opts -f ;;
        *) kubectl logs "$pod" -n "$ns" $opts --tail=100 ;;
    esac
}

# 4. Describe pod
describe_pod() {
    print_section "Describe Pod"
    
    local ns pod
    
    if [[ -n "$TARGET_NS" ]]; then
        ns="$TARGET_NS"
    else
        prompt "Namespace" ns
    fi
    
    echo ""
    echo "Available pods:"
    kubectl get pods -n "$ns" --no-headers 2>/dev/null | head -20
    echo ""
    
    prompt "Pod name" pod
    
    kubectl describe pod "$pod" -n "$ns" 2>/dev/null | less
}

# 5. Exec into pod
exec_into_pod() {
    print_section "Exec into Pod"
    
    local ns pod container shell
    
    if [[ -n "$TARGET_NS" ]]; then
        ns="$TARGET_NS"
    else
        prompt "Namespace" ns
    fi
    
    echo ""
    kubectl get pods -n "$ns" --no-headers 2>/dev/null | head -20
    echo ""
    
    prompt "Pod name" pod
    
    # Check containers
    local containers
    containers=$(kubectl get pod "$pod" -n "$ns" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null)
    
    local container_opt=""
    if [[ $(echo "$containers" | wc -w) -gt 1 ]]; then
        echo "Containers: $containers"
        prompt "Container" container
        container_opt="-c $container"
    fi
    
    prompt "Shell" shell "/bin/sh"
    
    echo ""
    log "Connecting to $pod..."
    kubectl exec -it "$pod" -n "$ns" $container_opt -- "$shell"
}

# 6. Show recent warning events
show_warning_events() {
    print_section "Warning Events"
    
    local ns_opt
    if [[ -n "$TARGET_NS" ]]; then
        ns_opt="-n $TARGET_NS"
    else
        ns_opt="--all-namespaces"
    fi
    
    echo ""
    kubectl get events $ns_opt --field-selector type=Warning \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -30
}

# 7. Show resource usage
show_resource_usage() {
    print_section "Resource Usage"
    
    echo ""
    echo "Nodes:"
    kubectl top nodes 2>/dev/null || log_warn "metrics-server not available"
    
    echo ""
    echo "Pods:"
    if [[ -n "$TARGET_NS" ]]; then
        kubectl top pods -n "$TARGET_NS" 2>/dev/null | head -20
    else
        kubectl top pods --all-namespaces 2>/dev/null | head -20
    fi
}

# 8. Check OOMKilled / Evicted pods
check_oom_evicted() {
    print_section "OOMKilled and Evicted Pods"
    
    echo ""
    echo "OOMKilled pods (checking last termination reason):"
    kubectl get pods $(ns_flag) -o json 2>/dev/null | \
        jq -r '.items[] | 
            select(.status.containerStatuses[]?.lastState.terminated.reason == "OOMKilled") | 
            "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "  None found (or jq not installed)"
    
    echo ""
    echo "Evicted pods:"
    kubectl get pods $(ns_flag) --field-selector status.phase=Failed 2>/dev/null | \
        grep -i evicted || echo "  None found"
}

# 9. List pending PVCs
list_pending_pvcs() {
    print_section "Pending PVCs"
    
    local pending
    pending=$(get_pending_pvcs)
    
    if [[ -z "$pending" ]]; then
        log_success "All PVCs are bound"
        return
    fi
    
    echo "$pending"
    echo ""
    
    # Show events for pending PVCs
    read -p "Show events for a PVC? [y/N]: " answer
    if [[ "$answer" =~ ^[yY] ]]; then
        local ns pvc
        prompt "Namespace" ns
        prompt "PVC name" pvc
        kubectl describe pvc "$pvc" -n "$ns" 2>/dev/null | grep -A 20 "Events:"
    fi
}

# 10. Check storage class issues
check_storage_issues() {
    print_section "Storage Information"
    
    echo "Storage Classes:"
    kubectl get sc 2>/dev/null
    
    echo ""
    echo "PVC Summary:"
    local total=$(kubectl get pvc $(ns_flag) --no-headers 2>/dev/null | wc -l)
    local bound=$(kubectl get pvc $(ns_flag) --no-headers 2>/dev/null | grep -c "Bound")
    echo "  Total PVCs: $total"
    echo "  Bound: $bound"
    echo "  Pending: $((total - bound))"
    
    echo ""
    echo "PV Summary:"
    kubectl get pv 2>/dev/null | head -20
}

# 11. Check service endpoints
check_endpoints() {
    print_section "Service Endpoints"
    
    local ns svc
    
    if [[ -n "$TARGET_NS" ]]; then
        ns="$TARGET_NS"
    else
        prompt "Namespace" ns
    fi
    
    echo ""
    echo "Services:"
    kubectl get svc -n "$ns" 2>/dev/null
    echo ""
    
    prompt "Service name (or 'all')" svc "all"
    
    if [[ "$svc" == "all" ]]; then
        echo ""
        echo "Endpoints:"
        kubectl get endpoints -n "$ns" 2>/dev/null
    else
        echo ""
        kubectl describe endpoints "$svc" -n "$ns" 2>/dev/null
        
        # Check if endpoints are empty
        local ep_count
        ep_count=$(kubectl get endpoints "$svc" -n "$ns" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
        
        if [[ $ep_count -eq 0 ]]; then
            log_warn "Service has no endpoints - check pod labels and selectors"
        else
            log_success "Service has $ep_count endpoints"
        fi
    fi
}

# 12. DNS resolution test
dns_test() {
    print_section "DNS Resolution Test"
    
    local test_pod="dns-test-$(date +%s)"
    local test_ns="${TARGET_NS:-default}"
    
    echo "Creating test pod..."
    kubectl run "$test_pod" \
        --namespace="$test_ns" \
        --image=busybox:1.28 \
        --restart=Never \
        --command -- sleep 300 2>/dev/null
    
    # Wait for pod to be ready
    sleep 3
    kubectl wait --for=condition=ready pod/"$test_pod" -n "$test_ns" --timeout=30s 2>/dev/null || true
    
    echo ""
    echo "Testing DNS resolution..."
    echo ""
    
    # Test common DNS names
    local tests=("kubernetes.default" "kubernetes.default.svc" "google.com")
    for t in "${tests[@]}"; do
        echo -n "  $t: "
        if kubectl exec "$test_pod" -n "$test_ns" -- nslookup "$t" &>/dev/null; then
            echo -e "${GREEN}OK${RESET}"
        else
            echo -e "${RED}FAILED${RESET}"
        fi
    done
    
    echo ""
    echo "Cleaning up test pod..."
    kubectl delete pod "$test_pod" -n "$test_ns" --grace-period=0 --force 2>/dev/null
    
    log_success "DNS test complete"
}

# 13. Change namespace
change_namespace() {
    print_section "Change Namespace"
    
    echo "Available namespaces:"
    kubectl get ns --no-headers 2>/dev/null | awk '{print "  " $1}'
    echo ""
    
    local ns
    prompt "Namespace (or 'all' for all namespaces)" ns "all"
    
    if [[ "$ns" == "all" ]]; then
        TARGET_NS=""
        log_success "Switched to all namespaces"
    else
        TARGET_NS="$ns"
        log_success "Switched to namespace: $ns"
    fi
}

# 14. Change environment
change_environment() {
    select_k8s_env
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--env)
                set_k8s_env "$2" || exit 1
                shift 2
                ;;
            -n|--namespace)
                TARGET_NS="$2"
                shift 2
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

main() {
    parse_args "$@"
    
    # Check cluster connection
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Not connected to any cluster"
        select_k8s_env || exit 1
    fi
    
    while true; do
        show_menu
        
        local choice
        read -p "Enter choice: " choice
        
        case "$choice" in
            1)  list_failing_pods ;;
            2)  show_high_restarts ;;
            3)  get_pod_logs ;;
            4)  describe_pod ;;
            5)  exec_into_pod ;;
            6)  show_warning_events ;;
            7)  show_resource_usage ;;
            8)  check_oom_evicted ;;
            9)  list_pending_pvcs ;;
            10) check_storage_issues ;;
            11) check_endpoints ;;
            12) dns_test ;;
            13) change_namespace ;;
            14) change_environment ;;
            q|Q) log "Goodbye"; exit 0 ;;
            *)  log_warn "Invalid option" ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

main "$@"
