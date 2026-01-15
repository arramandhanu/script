#!/bin/bash
#
# k8s-helpers.sh - Kubernetes helper functions
# Source this file after common.sh
#

# -----------------------------------------------------------------------------
# Environment configuration
# -----------------------------------------------------------------------------

# Default kubeconfig paths for different environments
KUBECONFIG_DEV="${KUBECONFIG_DEV:-$HOME/.kube/config-dev}"
KUBECONFIG_STAGING="${KUBECONFIG_STAGING:-$HOME/.kube/config-staging}"
KUBECONFIG_PROD="${KUBECONFIG_PROD:-$HOME/.kube/config-prod}"

# Current environment
K8S_ENV="${K8S_ENV:-}"

# -----------------------------------------------------------------------------
# Environment selection
# -----------------------------------------------------------------------------

# Set kubectl context for environment
set_k8s_env() {
    local env="$1"
    
    case "$env" in
        dev|development)
            export KUBECONFIG="$KUBECONFIG_DEV"
            K8S_ENV="dev"
            ;;
        staging|stg)
            export KUBECONFIG="$KUBECONFIG_STAGING"
            K8S_ENV="staging"
            ;;
        prod|production)
            export KUBECONFIG="$KUBECONFIG_PROD"
            K8S_ENV="prod"
            ;;
        *)
            log_error "Unknown environment: $env"
            log "Valid options: dev, staging, prod"
            return 1
            ;;
    esac
    
    # Verify connection
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to $env cluster"
        return 1
    fi
    
    log_success "Connected to $K8S_ENV cluster"
    return 0
}

# Interactive environment selector
select_k8s_env() {
    echo ""
    echo "Select Kubernetes environment:"
    echo "  1) Development"
    echo "  2) Staging"
    echo "  3) Production"
    echo ""
    
    local choice
    read -p "Enter choice [1-3]: " choice
    
    case "$choice" in
        1) set_k8s_env "dev" ;;
        2) set_k8s_env "staging" ;;
        3) set_k8s_env "prod" ;;
        *) log_error "Invalid choice"; return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Cluster information
# -----------------------------------------------------------------------------

# Get cluster name
get_cluster_name() {
    kubectl config current-context 2>/dev/null
}

# Get all node names
get_nodes() {
    kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

# Get node count
get_node_count() {
    kubectl get nodes --no-headers 2>/dev/null | wc -l
}

# Get nodes by role
get_nodes_by_role() {
    local role="$1"  # master, worker, etcd
    kubectl get nodes -l "node-role.kubernetes.io/${role}=true" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}

# Check if node is ready
is_node_ready() {
    local node="$1"
    local status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ "$status" == "True" ]]
}

# -----------------------------------------------------------------------------
# Pod operations
# -----------------------------------------------------------------------------

# Get pods in namespace
get_pods() {
    local namespace="${1:---all-namespaces}"
    if [[ "$namespace" == "--all-namespaces" ]]; then
        kubectl get pods --all-namespaces --no-headers 2>/dev/null
    else
        kubectl get pods -n "$namespace" --no-headers 2>/dev/null
    fi
}

# Get pods not in Running state
get_unhealthy_pods() {
    local namespace="${1:---all-namespaces}"
    if [[ "$namespace" == "--all-namespaces" ]]; then
        kubectl get pods --all-namespaces --no-headers 2>/dev/null | \
            awk '$4 != "Running" && $4 != "Completed" {print}'
    else
        kubectl get pods -n "$namespace" --no-headers 2>/dev/null | \
            awk '$3 != "Running" && $3 != "Completed" {print}'
    fi
}

# Get pods with high restart count
get_restarting_pods() {
    local threshold="${1:-5}"
    kubectl get pods --all-namespaces --no-headers 2>/dev/null | \
        awk -v t="$threshold" '$5 > t {print $1, $2, "restarts:", $5}'
}

# Get pod resource usage
get_pod_resources() {
    local namespace="${1:---all-namespaces}"
    if [[ "$namespace" == "--all-namespaces" ]]; then
        kubectl top pods --all-namespaces 2>/dev/null
    else
        kubectl top pods -n "$namespace" 2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# RKE2 specific functions
# -----------------------------------------------------------------------------

# Check RKE2 service status
check_rke2_status() {
    local role="${1:-server}"  # server or agent
    
    if systemctl is-active --quiet "rke2-${role}"; then
        log_success "RKE2 ${role} is running"
        return 0
    else
        log_error "RKE2 ${role} is not running"
        return 1
    fi
}

# Get RKE2 version
get_rke2_version() {
    if command -v rke2 &>/dev/null; then
        rke2 --version 2>/dev/null | head -1
    else
        echo "RKE2 not installed"
    fi
}

# Check etcd health (for RKE2 server nodes)
check_etcd_health() {
    local etcdctl="/var/lib/rancher/rke2/bin/etcdctl"
    local cert_dir="/var/lib/rancher/rke2/server/tls/etcd"
    
    if [[ ! -x "$etcdctl" ]]; then
        log_warn "etcdctl not found"
        return 1
    fi
    
    ETCDCTL_API=3 $etcdctl \
        --cacert="${cert_dir}/server-ca.crt" \
        --cert="${cert_dir}/server-client.crt" \
        --key="${cert_dir}/server-client.key" \
        endpoint health 2>/dev/null
}

# Get RKE2 token (for joining nodes)
get_rke2_token() {
    local token_file="/var/lib/rancher/rke2/server/node-token"
    
    if [[ -f "$token_file" ]]; then
        cat "$token_file"
    else
        log_error "Token file not found"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Storage functions (OpenEBS)
# -----------------------------------------------------------------------------

# Get storage classes
get_storage_classes() {
    kubectl get sc --no-headers 2>/dev/null
}

# Check if OpenEBS is installed
is_openebs_installed() {
    kubectl get ns openebs &>/dev/null
}

# Get PVC status
get_pvc_status() {
    local namespace="${1:---all-namespaces}"
    if [[ "$namespace" == "--all-namespaces" ]]; then
        kubectl get pvc --all-namespaces 2>/dev/null
    else
        kubectl get pvc -n "$namespace" 2>/dev/null
    fi
}

# Get PVCs not in Bound state
get_pending_pvcs() {
    kubectl get pvc --all-namespaces --no-headers 2>/dev/null | \
        awk '$3 != "Bound" {print}'
}

# Get hostpath storage usage per node
get_hostpath_usage() {
    local hostpath_dir="${1:-/var/openebs/local}"
    
    for node in $(get_nodes); do
        local usage=$(ssh "$node" "du -sh $hostpath_dir 2>/dev/null" | cut -f1)
        echo "$node: ${usage:-N/A}"
    done
}

# -----------------------------------------------------------------------------
# Drain and cordon operations
# -----------------------------------------------------------------------------

# Safely drain a node
drain_node() {
    local node="$1"
    local timeout="${2:-300}"
    
    log "Draining node: $node"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRYRUN" "Would drain node: $node"
        return 0
    fi
    
    kubectl drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout="${timeout}s" 2>&1
}

# Uncordon a node
uncordon_node() {
    local node="$1"
    
    log "Uncordoning node: $node"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRYRUN" "Would uncordon node: $node"
        return 0
    fi
    
    kubectl uncordon "$node" 2>&1
}

# Check if node is cordoned
is_node_cordoned() {
    local node="$1"
    kubectl get node "$node" -o jsonpath='{.spec.unschedulable}' 2>/dev/null | grep -q "true"
}

# -----------------------------------------------------------------------------
# Certificate checks
# -----------------------------------------------------------------------------

# Check certificate expiry
check_cert_expiry() {
    local cert_file="$1"
    local warn_days="${2:-30}"
    
    if [[ ! -f "$cert_file" ]]; then
        log_error "Certificate not found: $cert_file"
        return 1
    fi
    
    local expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null)
    local now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    
    if (( days_left < 0 )); then
        log_error "Certificate EXPIRED: $cert_file"
        return 1
    elif (( days_left < warn_days )); then
        log_warn "Certificate expiring in $days_left days: $cert_file"
        return 0
    else
        log_debug "Certificate OK ($days_left days): $cert_file"
        return 0
    fi
}

# Check all RKE2 certificates
check_rke2_certs() {
    local cert_dir="/var/lib/rancher/rke2/server/tls"
    local warn_days="${1:-30}"
    local issues=0
    
    for cert in $(find "$cert_dir" -name "*.crt" 2>/dev/null); do
        check_cert_expiry "$cert" "$warn_days" || ((issues++))
    done
    
    return $issues
}
