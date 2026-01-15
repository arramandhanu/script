#!/bin/bash
#
# ssl-cert-manager.sh - SSL certificate monitoring and management
#
# Usage:
#   ./ssl-cert-manager.sh [command] [options]
#
# Commands:
#   scan        Scan for certificates (default)
#   check       Check specific certificate
#   expiry      Show expiring certificates
#   k8s         Scan K8s TLS secrets
#
# Options:
#   -d, --days DAYS     Warn if expiring within days (default: 30)
#   -p, --path PATH     Path to scan for certificates
#   -r, --remote HOST   Scan remote host
#   -o, --output FILE   Save report to file
#   -j, --json          JSON output
#   -h, --help          Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
WARN_DAYS="${WARN_DAYS:-30}"
SCAN_PATHS=("/etc/ssl" "/etc/pki" "/etc/nginx/ssl" "/etc/apache2/ssl" "/etc/letsencrypt/live")
REMOTE_HOST=""
OUTPUT_FILE=""
COMMAND="${1:-scan}"
JSON_OUTPUT=false

# Results
declare -a CERT_RESULTS

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
            -d|--days)
                WARN_DAYS="$2"
                shift 2
                ;;
            -p|--path)
                SCAN_PATHS=("$2")
                shift 2
                ;;
            -r|--remote)
                REMOTE_HOST="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -j|--json)
                JSON_OUTPUT=true
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
# Remote execution
# -----------------------------------------------------------------------------
run_remote() {
    if [[ -n "$REMOTE_HOST" ]]; then
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$REMOTE_HOST" "$1" 2>/dev/null
    else
        eval "$1"
    fi
}

# -----------------------------------------------------------------------------
# Certificate analysis
# -----------------------------------------------------------------------------

# Check single certificate file
check_cert_file() {
    local cert_file="$1"
    
    # Get certificate info
    local info
    info=$(run_remote "openssl x509 -in '$cert_file' -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null")
    
    if [[ -z "$info" ]]; then
        return 1
    fi
    
    # Parse expiry
    local not_after
    not_after=$(echo "$info" | grep "notAfter=" | cut -d= -f2)
    
    local expiry_epoch
    expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %H:%M:%S %Y %Z" "$not_after" +%s 2>/dev/null)
    
    local now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    
    # Parse subject
    local subject
    subject=$(echo "$info" | grep "subject=" | sed 's/subject=//' | xargs)
    
    # Determine status
    local status="OK"
    if (( days_left < 0 )); then
        status="EXPIRED"
    elif (( days_left < WARN_DAYS )); then
        status="WARNING"
    fi
    
    # Output
    echo "${cert_file}|${subject}|${not_after}|${days_left}|${status}"
}

# Scan for certificates in path
scan_path() {
    local path="$1"
    
    run_remote "find '$path' -type f \( -name '*.crt' -o -name '*.pem' -o -name '*.cer' \) 2>/dev/null" | \
    while read -r cert_file; do
        [[ -z "$cert_file" ]] && continue
        check_cert_file "$cert_file"
    done
}

# Check certificate from remote server
check_remote_cert() {
    local host="$1"
    local port="${2:-443}"
    
    local info
    info=$(echo | openssl s_client -servername "$host" -connect "${host}:${port}" 2>/dev/null | \
        openssl x509 -noout -subject -dates 2>/dev/null)
    
    if [[ -z "$info" ]]; then
        return 1
    fi
    
    local not_after
    not_after=$(echo "$info" | grep "notAfter=" | cut -d= -f2)
    
    local expiry_epoch
    expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || echo 0)
    
    local now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    
    local subject
    subject=$(echo "$info" | grep "subject=" | sed 's/subject=//' | xargs)
    
    local status="OK"
    if (( days_left < 0 )); then
        status="EXPIRED"
    elif (( days_left < WARN_DAYS )); then
        status="WARNING"
    fi
    
    echo "${host}:${port}|${subject}|${not_after}|${days_left}|${status}"
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

do_scan() {
    print_header "SSL Certificate Scan"
    
    local target="${REMOTE_HOST:-localhost}"
    print_kv "Target" "$target"
    print_kv "Warning Threshold" "$WARN_DAYS days"
    
    echo ""
    print_section "Scanning Certificates"
    
    local total=0
    local expired=0
    local warning=0
    local ok=0
    
    printf "  %-50s %-12s %-8s %s\n" "CERTIFICATE" "EXPIRES" "DAYS" "STATUS"
    printf "  %-50s %-12s %-8s %s\n" "-----------" "-------" "----" "------"
    
    for path in "${SCAN_PATHS[@]}"; do
        if ! run_remote "test -d '$path'" 2>/dev/null; then
            continue
        fi
        
        while IFS='|' read -r file subject expiry days status; do
            [[ -z "$file" ]] && continue
            ((total++))
            
            local status_color="${GREEN}"
            case "$status" in
                EXPIRED) status_color="${RED}"; ((expired++)) ;;
                WARNING) status_color="${YELLOW}"; ((warning++)) ;;
                OK) ((ok++)) ;;
            esac
            
            local short_file=$(basename "$file")
            printf "  %-50s %-12s %-8s ${status_color}%s${RESET}\n" \
                "$short_file" "$(echo "$expiry" | cut -d' ' -f1-3)" "$days" "$status"
        done < <(scan_path "$path")
    done
    
    echo ""
    print_section "Summary"
    print_kv "Total Certificates" "$total"
    print_kv "OK" "$ok"
    print_kv "Expiring Soon" "$warning"
    print_kv "Expired" "$expired"
    
    if [[ $expired -gt 0 ]]; then
        log_error "$expired certificates have expired"
    elif [[ $warning -gt 0 ]]; then
        log_warn "$warning certificates expiring within $WARN_DAYS days"
    else
        log_success "All certificates are valid"
    fi
}

do_check() {
    print_section "Check Certificate"
    
    local target
    read -p "Certificate path or host:port: " target
    
    if [[ "$target" == *":"* || "$target" == *"."* && ! -f "$target" ]]; then
        # Remote host
        local host="${target%:*}"
        local port="${target#*:}"
        [[ "$port" == "$host" ]] && port=443
        
        log "Connecting to ${host}:${port}..."
        
        local result
        result=$(check_remote_cert "$host" "$port")
        
        if [[ -n "$result" ]]; then
            IFS='|' read -r endpoint subject expiry days status <<< "$result"
            
            print_kv "Endpoint" "$endpoint"
            print_kv "Subject" "$subject"
            print_kv "Expires" "$expiry"
            print_kv "Days Left" "$days"
            print_kv "Status" "$status"
            
            # Show full chain
            echo ""
            echo "Certificate chain:"
            echo | openssl s_client -servername "$host" -connect "${host}:${port}" 2>/dev/null | \
                grep -E "^\s+\d+\s+s:|^Certificate chain"
        else
            log_error "Cannot retrieve certificate"
        fi
    else
        # Local file
        if [[ ! -f "$target" ]]; then
            log_error "File not found: $target"
            return 1
        fi
        
        local result
        result=$(check_cert_file "$target")
        
        if [[ -n "$result" ]]; then
            IFS='|' read -r file subject expiry days status <<< "$result"
            
            print_kv "File" "$file"
            print_kv "Subject" "$subject"
            print_kv "Expires" "$expiry"
            print_kv "Days Left" "$days"
            print_kv "Status" "$status"
            
            # Show SANs
            echo ""
            echo "Subject Alternative Names:"
            openssl x509 -in "$target" -noout -ext subjectAltName 2>/dev/null | grep -v "X509v3"
        fi
    fi
}

do_expiry() {
    print_section "Expiring Certificates (within $WARN_DAYS days)"
    
    local found=0
    
    for path in "${SCAN_PATHS[@]}"; do
        if ! run_remote "test -d '$path'" 2>/dev/null; then
            continue
        fi
        
        while IFS='|' read -r file subject expiry days status; do
            [[ -z "$file" ]] && continue
            [[ "$status" != "WARNING" && "$status" != "EXPIRED" ]] && continue
            
            ((found++))
            
            local status_color="${YELLOW}"
            [[ "$status" == "EXPIRED" ]] && status_color="${RED}"
            
            echo ""
            echo -e "  ${status_color}[$status]${RESET} $file"
            echo "    Subject: $subject"
            echo "    Expires: $expiry ($days days)"
        done < <(scan_path "$path")
    done
    
    if [[ $found -eq 0 ]]; then
        log_success "No certificates expiring within $WARN_DAYS days"
    fi
}

do_k8s() {
    print_section "Kubernetes TLS Secrets"
    
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found"
        return 1
    fi
    
    local namespace="${1:---all-namespaces}"
    
    echo ""
    printf "  %-30s %-30s %-12s %s\n" "NAMESPACE" "SECRET" "EXPIRES" "STATUS"
    printf "  %-30s %-30s %-12s %s\n" "---------" "------" "-------" "------"
    
    kubectl get secrets $namespace -o json 2>/dev/null | \
        jq -r '.items[] | select(.type == "kubernetes.io/tls") | "\(.metadata.namespace)|\(.metadata.name)|\(.data."tls.crt")"' 2>/dev/null | \
    while IFS='|' read -r ns name cert_b64; do
        [[ -z "$cert_b64" ]] && continue
        
        # Decode and check cert
        local expiry
        expiry=$(echo "$cert_b64" | base64 -d | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
        
        if [[ -z "$expiry" ]]; then
            continue
        fi
        
        local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        local now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        
        local status="OK"
        local status_color="${GREEN}"
        
        if (( days_left < 0 )); then
            status="EXPIRED"
            status_color="${RED}"
        elif (( days_left < WARN_DAYS )); then
            status="WARNING"
            status_color="${YELLOW}"
        fi
        
        printf "  %-30s %-30s %-12s ${status_color}%s${RESET} (%d days)\n" \
            "$ns" "$name" "$(echo "$expiry" | cut -d' ' -f1-3)" "$status" "$days_left"
    done
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    case "$COMMAND" in
        scan)   do_scan ;;
        check)  do_check ;;
        expiry) do_expiry ;;
        k8s)    do_k8s "$2" ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
