#!/bin/bash
#
# common.sh - Shared functions for infrastructure scripts
# Source this file in your scripts: source "$(dirname "$0")/../lib/common.sh"
#

# -----------------------------------------------------------------------------
# Color definitions
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# -----------------------------------------------------------------------------
# Global settings
# -----------------------------------------------------------------------------
SCRIPT_NAME=$(basename "$0")
LOG_DIR="${LOG_DIR:-/var/log/infra-scripts}"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME%.sh}.log"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"

# -----------------------------------------------------------------------------
# Logging functions
# -----------------------------------------------------------------------------

# Create log directory if it doesn't exist
init_logging() {
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
        LOG_FILE="${LOG_DIR}/${SCRIPT_NAME%.sh}.log"
    fi
}

# Main logging function
# Usage: log "message" or log "INFO" "message"
log() {
    local level="INFO"
    local message="$1"
    
    if [[ $# -eq 2 ]]; then
        level="$1"
        message="$2"
    fi
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"
    
    # Write to log file
    echo "$log_line" >> "$LOG_FILE" 2>/dev/null
    
    # Print to stdout with colors
    case "$level" in
        ERROR)   echo -e "${RED}[ERROR]${RESET} $message" ;;
        WARN)    echo -e "${YELLOW}[WARN]${RESET} $message" ;;
        SUCCESS) echo -e "${GREEN}[OK]${RESET} $message" ;;
        DEBUG)   [[ "$VERBOSE" == "true" ]] && echo -e "${CYAN}[DEBUG]${RESET} $message" ;;
        *)       echo -e "${BLUE}[INFO]${RESET} $message" ;;
    esac
}

log_error() { log "ERROR" "$1"; }
log_warn() { log "WARN" "$1"; }
log_success() { log "SUCCESS" "$1"; }
log_debug() { log "DEBUG" "$1"; }

# -----------------------------------------------------------------------------
# Display functions
# -----------------------------------------------------------------------------

# Print a header box
print_header() {
    local title="$1"
    local width=50
    local padding=$(( (width - ${#title}) / 2 ))
    
    echo ""
    echo -e "${CYAN}$(printf '=%.0s' $(seq 1 $width))${RESET}"
    printf "${BOLD}%*s%s%*s${RESET}\n" $padding "" "$title" $padding ""
    echo -e "${CYAN}$(printf '=%.0s' $(seq 1 $width))${RESET}"
    echo ""
}

# Print a section divider
print_section() {
    local title="$1"
    echo ""
    echo -e "${BOLD}--- $title ---${RESET}"
}

# Print key-value pair
print_kv() {
    local key="$1"
    local value="$2"
    printf "  %-25s : %s\n" "$key" "$value"
}

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

# Check if value is a positive integer
is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Check if value is a valid IP address
is_valid_ip() {
    local ip="$1"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ $ip =~ $regex ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            (( octet > 255 )) && return 1
        done
        return 0
    fi
    return 1
}

# Check if value is a valid hostname
is_valid_hostname() {
    local hostname="$1"
    [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

# Prompt for confirmation
confirm() {
    local prompt="${1:-Are you sure?}"
    local response
    
    read -p "$prompt [y/N]: " response
    case "$response" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# OS detection
# -----------------------------------------------------------------------------

get_os_type() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$ID"
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

get_os_version() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$VERSION_ID"
    else
        echo "unknown"
    fi
}

is_ubuntu() {
    [[ "$(get_os_type)" == "ubuntu" ]]
}

is_rocky() {
    [[ "$(get_os_type)" == "rocky" ]]
}

is_rhel_family() {
    local os=$(get_os_type)
    [[ "$os" == "rocky" || "$os" == "rhel" || "$os" == "centos" || "$os" == "almalinux" ]]
}

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------

# Check if command exists
require_command() {
    local cmd="$1"
    local install_hint="${2:-}"
    
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd"
        [[ -n "$install_hint" ]] && log "Install with: $install_hint"
        return 1
    fi
    return 0
}

# Check if running as root
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Check if file exists
require_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_error "Required file not found: $file"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Dry run support
# -----------------------------------------------------------------------------

# Execute command with dry-run support
run_cmd() {
    local cmd="$*"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRYRUN" "Would execute: $cmd"
        return 0
    fi
    
    log_debug "Executing: $cmd"
    eval "$cmd"
}

# -----------------------------------------------------------------------------
# Notification support
# -----------------------------------------------------------------------------

# Send desktop notification (works on Linux and macOS)
notify_desktop() {
    local title="$1"
    local message="$2"
    
    if command -v notify-send &>/dev/null; then
        notify-send "$title" "$message" 2>/dev/null
    elif command -v osascript &>/dev/null; then
        osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null
    fi
}

# Send webhook notification (Slack/Teams compatible)
notify_webhook() {
    local webhook_url="$1"
    local message="$2"
    
    [[ -z "$webhook_url" ]] && return 1
    
    curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"$message\"}" \
        "$webhook_url" &>/dev/null
}

# -----------------------------------------------------------------------------
# Utility functions
# -----------------------------------------------------------------------------

# Convert bytes to human readable
bytes_to_human() {
    local bytes=$1
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    
    while (( bytes > 1024 && unit < 4 )); do
        bytes=$((bytes / 1024))
        ((unit++))
    done
    
    echo "${bytes}${units[$unit]}"
}

# Get timestamp for file naming
get_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

# Create backup of a file
backup_file() {
    local file="$1"
    local backup="${file}.backup.$(get_timestamp)"
    
    if [[ -f "$file" ]]; then
        cp "$file" "$backup"
        log "Created backup: $backup"
        echo "$backup"
    fi
}

# Wait for process with timeout
wait_with_timeout() {
    local pid=$1
    local timeout=${2:-60}
    local count=0
    
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        ((count++))
        if (( count >= timeout )); then
            return 1
        fi
    done
    return 0
}

# Initialize logging on source
init_logging
