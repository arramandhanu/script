#!/bin/bash
#
# ansible-wrapper.sh - Standardized wrapper for Ansible deployments
#
# Provides pre-flight checks, logging, and rollback support for Ansible playbooks.
#
# Usage:
#   ./ansible-wrapper.sh [options] <playbook>
#
# Options:
#   -e, --env ENV          Target environment (dev|staging|prod)
#   -t, --tags TAGS        Ansible tags to run
#   -l, --limit HOSTS      Limit to specific hosts
#   --check                Run in check mode (dry-run)
#   --diff                 Show file differences
#   --extra-vars VARS      Extra variables (key=value)
#   -h, --help             Show this help
#
# Examples:
#   ./ansible-wrapper.sh -e staging deploy.yml
#   ./ansible-wrapper.sh -e prod -t nginx --limit webservers deploy.yml
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
ANSIBLE_DIR="${ANSIBLE_DIR:-/opt/ansible}"
INVENTORY_DIR="${INVENTORY_DIR:-$ANSIBLE_DIR/inventory}"
LOG_DIR="${LOG_DIR:-/var/log/ansible}"
PLAYBOOK=""
ENVIRONMENT=""
TAGS=""
LIMIT=""
EXTRA_VARS=""
CHECK_MODE=false
DIFF_MODE=false
WEBHOOK_URL="${WEBHOOK_URL:-}"

# Execution tracking
RUN_ID=$(date +%Y%m%d_%H%M%S)
RUN_LOG="${LOG_DIR}/run_${RUN_ID}.log"

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--env)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -t|--tags)
                TAGS="$2"
                shift 2
                ;;
            -l|--limit)
                LIMIT="$2"
                shift 2
                ;;
            --check)
                CHECK_MODE=true
                shift
                ;;
            --diff)
                DIFF_MODE=true
                shift
                ;;
            --extra-vars)
                EXTRA_VARS="$2"
                shift 2
                ;;
            -h|--help)
                grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# //' | sed 's/^#//'
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                PLAYBOOK="$1"
                shift
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Environment management
# -----------------------------------------------------------------------------

select_environment() {
    echo ""
    echo "Select environment:"
    echo "  1) Development"
    echo "  2) Staging"
    echo "  3) Production"
    echo ""
    
    local choice
    read -p "Enter choice [1-3]: " choice
    
    case "$choice" in
        1) ENVIRONMENT="dev" ;;
        2) ENVIRONMENT="staging" ;;
        3) ENVIRONMENT="prod" ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
}

get_inventory_file() {
    local env="$1"
    local inv_file="${INVENTORY_DIR}/${env}"
    
    # Try different naming conventions
    for suffix in "" ".yml" ".yaml" "/hosts" "/inventory"; do
        if [[ -f "${inv_file}${suffix}" || -d "${inv_file}${suffix}" ]]; then
            echo "${inv_file}${suffix}"
            return 0
        fi
    done
    
    log_error "Inventory not found for environment: $env"
    return 1
}

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

preflight_check() {
    print_section "Pre-flight Checks"
    
    local errors=0
    
    # Check ansible is installed
    if ! command -v ansible-playbook &>/dev/null; then
        log_error "ansible-playbook not found"
        ((errors++))
    else
        log_success "Ansible installed: $(ansible --version | head -1)"
    fi
    
    # Check playbook exists
    local playbook_path="$PLAYBOOK"
    if [[ ! -f "$playbook_path" ]]; then
        playbook_path="${ANSIBLE_DIR}/${PLAYBOOK}"
    fi
    
    if [[ -f "$playbook_path" ]]; then
        log_success "Playbook found: $playbook_path"
        PLAYBOOK="$playbook_path"
    else
        log_error "Playbook not found: $PLAYBOOK"
        ((errors++))
    fi
    
    # Check inventory
    local inventory
    inventory=$(get_inventory_file "$ENVIRONMENT") || ((errors++))
    if [[ -n "$inventory" ]]; then
        log_success "Inventory found: $inventory"
    fi
    
    # Syntax check
    if [[ $errors -eq 0 ]]; then
        log "Running syntax check..."
        if ansible-playbook --syntax-check -i "$inventory" "$PLAYBOOK" &>/dev/null; then
            log_success "Syntax check passed"
        else
            log_error "Syntax check failed"
            ((errors++))
        fi
    fi
    
    # Create log directory
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    return $errors
}

# -----------------------------------------------------------------------------
# Notification
# -----------------------------------------------------------------------------

send_notification() {
    local status="$1"
    local message="$2"
    
    # Desktop notification
    notify_desktop "Ansible Deployment" "$message"
    
    # Webhook notification
    if [[ -n "$WEBHOOK_URL" ]]; then
        local color="good"
        [[ "$status" == "FAILED" ]] && color="danger"
        
        local payload=$(cat <<EOF
{
    "text": "*Ansible Deployment - $status*",
    "attachments": [{
        "color": "$color",
        "fields": [
            {"title": "Environment", "value": "$ENVIRONMENT", "short": true},
            {"title": "Playbook", "value": "$(basename "$PLAYBOOK")", "short": true},
            {"title": "Run ID", "value": "$RUN_ID", "short": true},
            {"title": "Status", "value": "$status", "short": true}
        ],
        "footer": "$message"
    }]
}
EOF
)
        curl -s -X POST -H 'Content-type: application/json' \
            --data "$payload" "$WEBHOOK_URL" &>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# Execution
# -----------------------------------------------------------------------------

run_playbook() {
    local inventory
    inventory=$(get_inventory_file "$ENVIRONMENT")
    
    # Build ansible command
    local cmd="ansible-playbook"
    cmd="$cmd -i $inventory"
    cmd="$cmd $PLAYBOOK"
    
    # Add options
    [[ -n "$TAGS" ]] && cmd="$cmd --tags '$TAGS'"
    [[ -n "$LIMIT" ]] && cmd="$cmd --limit '$LIMIT'"
    [[ -n "$EXTRA_VARS" ]] && cmd="$cmd --extra-vars '$EXTRA_VARS'"
    [[ "$CHECK_MODE" == "true" ]] && cmd="$cmd --check"
    [[ "$DIFF_MODE" == "true" ]] && cmd="$cmd --diff"
    
    print_section "Executing Playbook"
    echo ""
    echo "Command: $cmd"
    echo "Log: $RUN_LOG"
    echo ""
    
    # Confirmation for production
    if [[ "$ENVIRONMENT" == "prod" && "$CHECK_MODE" != "true" ]]; then
        log_warn "PRODUCTION DEPLOYMENT"
        if ! confirm "Are you sure you want to deploy to production?"; then
            log "Deployment cancelled"
            return 1
        fi
    fi
    
    send_notification "STARTED" "Deployment started"
    
    # Execute with logging
    local start_time=$(date +%s)
    local exit_code=0
    
    echo "--- Ansible Deployment Log ---" > "$RUN_LOG"
    echo "Run ID: $RUN_ID" >> "$RUN_LOG"
    echo "Environment: $ENVIRONMENT" >> "$RUN_LOG"
    echo "Playbook: $PLAYBOOK" >> "$RUN_LOG"
    echo "Started: $(date)" >> "$RUN_LOG"
    echo "Command: $cmd" >> "$RUN_LOG"
    echo "---" >> "$RUN_LOG"
    echo "" >> "$RUN_LOG"
    
    # Run playbook
    eval "$cmd" 2>&1 | tee -a "$RUN_LOG" || exit_code=$?
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo "" >> "$RUN_LOG"
    echo "---" >> "$RUN_LOG"
    echo "Finished: $(date)" >> "$RUN_LOG"
    echo "Duration: ${duration}s" >> "$RUN_LOG"
    echo "Exit Code: $exit_code" >> "$RUN_LOG"
    
    return $exit_code
}

# -----------------------------------------------------------------------------
# History
# -----------------------------------------------------------------------------

show_history() {
    print_section "Recent Deployments"
    
    echo ""
    ls -lt "$LOG_DIR"/run_*.log 2>/dev/null | head -10 | while read -r line; do
        local log_file=$(echo "$line" | awk '{print $NF}')
        local run_id=$(basename "$log_file" | sed 's/run_//' | sed 's/.log//')
        local status="UNKNOWN"
        
        if grep -q "Exit Code: 0" "$log_file" 2>/dev/null; then
            status="${GREEN}SUCCESS${RESET}"
        elif grep -q "Exit Code:" "$log_file" 2>/dev/null; then
            status="${RED}FAILED${RESET}"
        fi
        
        local env=$(grep "^Environment:" "$log_file" 2>/dev/null | cut -d: -f2 | xargs)
        local playbook=$(grep "^Playbook:" "$log_file" 2>/dev/null | cut -d: -f2 | xargs)
        
        echo -e "  $run_id | $env | $(basename "$playbook" 2>/dev/null) | $status"
    done
    
    echo ""
}

view_log() {
    local run_id
    read -p "Enter Run ID: " run_id
    
    local log_file="${LOG_DIR}/run_${run_id}.log"
    
    if [[ -f "$log_file" ]]; then
        less "$log_file"
    else
        log_error "Log not found: $log_file"
    fi
}

# -----------------------------------------------------------------------------
# Interactive menu
# -----------------------------------------------------------------------------

show_menu() {
    print_header "Ansible Deployment Wrapper"
    
    echo "Environment: ${ENVIRONMENT:-not set}"
    echo ""
    echo "Options:"
    echo "  1) Select environment"
    echo "  2) Run playbook"
    echo "  3) Run playbook (check mode)"
    echo "  4) View deployment history"
    echo "  5) View deployment log"
    echo "  q) Quit"
    echo ""
}

interactive_run() {
    if [[ -z "$ENVIRONMENT" ]]; then
        select_environment
    fi
    
    # List available playbooks
    print_section "Available Playbooks"
    
    local playbooks=()
    local i=1
    
    for pb in "$ANSIBLE_DIR"/*.yml "$ANSIBLE_DIR"/*.yaml; do
        if [[ -f "$pb" ]]; then
            playbooks+=("$pb")
            echo "  $i) $(basename "$pb")"
            ((i++))
        fi
    done
    
    if [[ ${#playbooks[@]} -eq 0 ]]; then
        read -p "Playbook path: " PLAYBOOK
    else
        echo ""
        local choice
        read -p "Select playbook [1-${#playbooks[@]}]: " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#playbooks[@]} )); then
            PLAYBOOK="${playbooks[$((choice-1))]}"
        else
            log_error "Invalid choice"
            return 1
        fi
    fi
    
    # Optional: tags
    read -p "Tags (optional): " TAGS
    
    # Optional: limit
    read -p "Limit hosts (optional): " LIMIT
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    # If playbook specified, run directly
    if [[ -n "$PLAYBOOK" ]]; then
        if [[ -z "$ENVIRONMENT" ]]; then
            log_error "Environment required (-e dev|staging|prod)"
            exit 1
        fi
        
        if ! preflight_check; then
            log_error "Pre-flight checks failed"
            exit 1
        fi
        
        if run_playbook; then
            log_success "Deployment completed successfully"
            send_notification "SUCCESS" "Deployment completed"
            exit 0
        else
            log_error "Deployment failed"
            send_notification "FAILED" "Deployment failed - check logs"
            exit 1
        fi
    fi
    
    # Interactive mode
    while true; do
        show_menu
        
        local choice
        read -p "Enter choice: " choice
        
        case "$choice" in
            1) select_environment ;;
            2)
                interactive_run || continue
                if preflight_check; then
                    run_playbook
                fi
                ;;
            3)
                interactive_run || continue
                CHECK_MODE=true
                if preflight_check; then
                    run_playbook
                fi
                ;;
            4) show_history ;;
            5) view_log ;;
            q|Q) exit 0 ;;
            *) log_warn "Invalid option" ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

main "$@"
