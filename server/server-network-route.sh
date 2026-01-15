#!/bin/bash
#
# server-network-route.sh - Network route manager for Linux VMs
#
# Supports Ubuntu and Rocky Linux. Handles route persistence across reboots.
#
# Usage:
#   ./server-network-route.sh [command] [options]
#
# Commands:
#   list              Show current routes
#   add               Add a new route (interactive)
#   delete            Delete a route (interactive)
#   backup            Backup current routing table
#   restore           Restore routes from backup
#   apply-template    Apply routes from template file
#   test              Test connectivity to a destination
#
# Options:
#   -r, --remote HOST   Run on remote host via SSH
#   -d, --dry-run       Preview changes without applying
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
REMOTE_HOST=""
BACKUP_DIR="${BACKUP_DIR:-/var/backup/routes}"
TEMPLATE_FILE="${TEMPLATE_FILE:-}"

# OS-specific paths
UBUNTU_NETPLAN_DIR="/etc/netplan"
ROCKY_ROUTE_DIR="/etc/sysconfig/network-scripts"

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    COMMAND="${1:-}"
    shift || true
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r|--remote)
                REMOTE_HOST="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -t|--template)
                TEMPLATE_FILE="$2"
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

# -----------------------------------------------------------------------------
# Remote execution
# -----------------------------------------------------------------------------
run_cmd_remote() {
    if [[ -n "$REMOTE_HOST" ]]; then
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "$1" 2>/dev/null
    else
        eval "$1"
    fi
}

copy_to_remote() {
    local src="$1"
    local dest="$2"
    
    if [[ -n "$REMOTE_HOST" ]]; then
        scp "$src" "${REMOTE_HOST}:${dest}"
    else
        cp "$src" "$dest"
    fi
}

# Detect OS on target
detect_os() {
    run_cmd_remote "cat /etc/os-release 2>/dev/null | grep '^ID=' | cut -d= -f2 | tr -d '\"'"
}

# -----------------------------------------------------------------------------
# Route management functions
# -----------------------------------------------------------------------------

# List current routes
list_routes() {
    print_section "Current Routing Table"
    echo ""
    
    run_cmd_remote "ip route show"
    
    echo ""
    print_section "Default Gateway"
    run_cmd_remote "ip route | grep default"
}

# Add a new route
add_route() {
    print_section "Add Route"
    
    local destination gateway interface persist
    
    read -p "Destination network (e.g., 10.0.0.0/24): " destination
    read -p "Gateway IP: " gateway
    read -p "Interface (leave empty for auto): " interface
    read -p "Make persistent? [y/N]: " persist
    
    # Validate inputs
    if [[ -z "$destination" || -z "$gateway" ]]; then
        log_error "Destination and gateway are required"
        return 1
    fi
    
    # Build route command
    local route_cmd="ip route add $destination via $gateway"
    [[ -n "$interface" ]] && route_cmd="$route_cmd dev $interface"
    
    log "Adding route: $destination via $gateway"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would execute: $route_cmd"
    else
        run_cmd_remote "$route_cmd" && log_success "Route added" || log_error "Failed to add route"
        
        # Make persistent if requested
        if [[ "$persist" =~ ^[yY] ]]; then
            persist_route "$destination" "$gateway" "$interface"
        fi
    fi
}

# Persist route based on OS
persist_route() {
    local destination="$1"
    local gateway="$2"
    local interface="${3:-}"
    
    local os=$(detect_os)
    log "Persisting route on $os system"
    
    case "$os" in
        ubuntu)
            persist_route_ubuntu "$destination" "$gateway" "$interface"
            ;;
        rocky|centos|rhel|almalinux)
            persist_route_rocky "$destination" "$gateway" "$interface"
            ;;
        *)
            log_warn "Unknown OS, cannot persist route automatically"
            log "Add manually to your network configuration"
            ;;
    esac
}

# Persist route on Ubuntu (netplan)
persist_route_ubuntu() {
    local destination="$1"
    local gateway="$2"
    local interface="${3:-}"
    
    # Find netplan config file
    local netplan_file
    netplan_file=$(run_cmd_remote "ls ${UBUNTU_NETPLAN_DIR}/*.yaml 2>/dev/null | head -1")
    
    if [[ -z "$netplan_file" ]]; then
        log_error "No netplan configuration found"
        return 1
    fi
    
    log "Updating $netplan_file"
    
    # Create backup
    run_cmd_remote "cp $netplan_file ${netplan_file}.backup.$(date +%Y%m%d)"
    
    # Note: In production, you'd want to properly parse and update the YAML
    log_warn "Please manually add the following to your netplan config:"
    echo ""
    echo "      routes:"
    echo "        - to: $destination"
    echo "          via: $gateway"
    echo ""
    log "Then run: sudo netplan apply"
}

# Persist route on Rocky/RHEL
persist_route_rocky() {
    local destination="$1"
    local gateway="$2"
    local interface="${3:-}"
    
    # Determine interface if not provided
    if [[ -z "$interface" ]]; then
        interface=$(run_cmd_remote "ip route get $gateway 2>/dev/null | head -1 | awk '{print \$3}'")
    fi
    
    if [[ -z "$interface" ]]; then
        log_error "Cannot determine interface"
        return 1
    fi
    
    local route_file="${ROCKY_ROUTE_DIR}/route-${interface}"
    
    log "Adding to $route_file"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would append to $route_file:"
        echo "  $destination via $gateway"
    else
        run_cmd_remote "echo '$destination via $gateway' >> $route_file"
        log_success "Route persisted in $route_file"
    fi
}

# Delete a route
delete_route() {
    print_section "Delete Route"
    
    echo "Current routes:"
    run_cmd_remote "ip route show"
    echo ""
    
    local destination
    read -p "Destination to delete (e.g., 10.0.0.0/24): " destination
    
    if [[ -z "$destination" ]]; then
        log_error "Destination required"
        return 1
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would delete route to $destination"
    else
        if confirm "Delete route to $destination?"; then
            run_cmd_remote "ip route del $destination" && \
                log_success "Route deleted" || \
                log_error "Failed to delete route"
            
            log_warn "Remember to remove from persistent config if applicable"
        fi
    fi
}

# Backup routes
backup_routes() {
    print_section "Backup Routes"
    
    local backup_file="${BACKUP_DIR}/routes_$(date +%Y%m%d_%H%M%S).txt"
    
    # Create backup directory
    run_cmd_remote "mkdir -p $BACKUP_DIR"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY-RUN: Would backup to $backup_file"
    else
        run_cmd_remote "ip route show > $backup_file"
        log_success "Routes backed up to $backup_file"
        
        # Show backup
        echo ""
        run_cmd_remote "cat $backup_file"
    fi
}

# Restore routes from backup
restore_routes() {
    print_section "Restore Routes"
    
    # List available backups
    echo "Available backups:"
    run_cmd_remote "ls -la $BACKUP_DIR/*.txt 2>/dev/null" || {
        log_error "No backups found in $BACKUP_DIR"
        return 1
    }
    echo ""
    
    local backup_file
    read -p "Backup file to restore: " backup_file
    
    if [[ ! -f "$backup_file" ]] && [[ -z "$REMOTE_HOST" ]]; then
        log_error "Backup file not found: $backup_file"
        return 1
    fi
    
    echo ""
    echo "Routes in backup:"
    run_cmd_remote "cat $backup_file"
    echo ""
    
    if ! confirm "Restore these routes?"; then
        log "Restore cancelled"
        return 0
    fi
    
    # Apply routes
    run_cmd_remote "cat $backup_file" | while read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == "default"* ]] && continue  # Skip default route
        
        local dest=$(echo "$line" | awk '{print $1}')
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY-RUN: Would add: $line"
        else
            log "Adding: $dest"
            run_cmd_remote "ip route add $line 2>/dev/null" || true
        fi
    done
    
    log_success "Restore complete"
}

# Apply routes from template
apply_template() {
    print_section "Apply Template"
    
    if [[ -z "$TEMPLATE_FILE" ]]; then
        read -p "Template file path: " TEMPLATE_FILE
    fi
    
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        log_error "Template not found: $TEMPLATE_FILE"
        return 1
    fi
    
    echo "Template contents:"
    cat "$TEMPLATE_FILE"
    echo ""
    
    if ! confirm "Apply these routes?"; then
        log "Cancelled"
        return 0
    fi
    
    # Template format: destination gateway [interface]
    while read -r line; do
        # Skip comments and empty lines
        [[ -z "$line" || "$line" == \#* ]] && continue
        
        local dest=$(echo "$line" | awk '{print $1}')
        local gw=$(echo "$line" | awk '{print $2}')
        local iface=$(echo "$line" | awk '{print $3}')
        
        local cmd="ip route add $dest via $gw"
        [[ -n "$iface" ]] && cmd="$cmd dev $iface"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "DRY-RUN: $cmd"
        else
            log "Adding: $dest via $gw"
            run_cmd_remote "$cmd 2>/dev/null" && log_success "Added" || log_warn "Failed or exists"
        fi
    done < "$TEMPLATE_FILE"
}

# Test connectivity
test_connectivity() {
    print_section "Connectivity Test"
    
    local destination
    read -p "Destination IP or hostname: " destination
    
    echo ""
    echo "Route to $destination:"
    run_cmd_remote "ip route get $destination 2>/dev/null" || echo "No route found"
    
    echo ""
    echo "Ping test:"
    run_cmd_remote "ping -c 3 $destination 2>/dev/null" || log_error "Ping failed"
    
    echo ""
    echo "Traceroute:"
    run_cmd_remote "traceroute -n -m 10 $destination 2>/dev/null" || \
        run_cmd_remote "tracepath -n $destination 2>/dev/null" || \
        log_warn "Traceroute not available"
}

# Show interactive menu
show_menu() {
    print_header "Network Route Manager"
    
    local target="${REMOTE_HOST:-localhost}"
    print_kv "Target" "$target"
    print_kv "OS" "$(detect_os)"
    echo ""
    
    echo "Commands:"
    echo "  1) List routes"
    echo "  2) Add route"
    echo "  3) Delete route"
    echo "  4) Backup routes"
    echo "  5) Restore from backup"
    echo "  6) Apply template"
    echo "  7) Test connectivity"
    echo "  q) Quit"
    echo ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    # If no command, run interactive mode
    if [[ -z "$COMMAND" ]]; then
        while true; do
            show_menu
            
            local choice
            read -p "Enter choice: " choice
            
            case "$choice" in
                1) list_routes ;;
                2) add_route ;;
                3) delete_route ;;
                4) backup_routes ;;
                5) restore_routes ;;
                6) apply_template ;;
                7) test_connectivity ;;
                q|Q) exit 0 ;;
                *) log_warn "Invalid option" ;;
            esac
            
            echo ""
            read -p "Press Enter to continue..."
        done
    else
        # Run specified command
        case "$COMMAND" in
            list)           list_routes ;;
            add)            add_route ;;
            delete|del)     delete_route ;;
            backup)         backup_routes ;;
            restore)        restore_routes ;;
            apply-template) apply_template ;;
            test)           test_connectivity ;;
            *)
                log_error "Unknown command: $COMMAND"
                echo "Run with --help for usage"
                exit 1
                ;;
        esac
    fi
}

main "$@"
