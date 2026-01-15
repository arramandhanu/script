#!/bin/bash
#
# minio-health.sh - Minio health and performance check
#
# Usage:
#   ./minio-health.sh [options]
#
# Options:
#   -e, --endpoint URL    Minio endpoint (default: from env)
#   -a, --access-key KEY  Access key (default: from env)
#   -s, --secret-key KEY  Secret key (default: from env)
#   -v, --verbose         Show detailed output
#   -j, --json            Output as JSON
#   -h, --help            Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration from environment or arguments
MINIO_ENDPOINT="${MINIO_ENDPOINT:-}"
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-}"
MINIO_ALIAS="${MINIO_ALIAS:-myminio}"
OUTPUT_FORMAT="text"

# Results tracking
CHECKS=()
ISSUES=0

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--endpoint)
                MINIO_ENDPOINT="$2"
                shift 2
                ;;
            -a|--access-key)
                MINIO_ACCESS_KEY="$2"
                shift 2
                ;;
            -s|--secret-key)
                MINIO_SECRET_KEY="$2"
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
# Prerequisites
# -----------------------------------------------------------------------------

check_prerequisites() {
    # Check for mc (minio client)
    if ! command -v mc &>/dev/null; then
        log_error "Minio client (mc) not found"
        log "Install with: https://min.io/docs/minio/linux/reference/minio-mc.html"
        return 1
    fi
    
    # Check credentials
    if [[ -z "$MINIO_ENDPOINT" ]]; then
        log_error "Minio endpoint not set"
        log "Set MINIO_ENDPOINT or use --endpoint"
        return 1
    fi
    
    return 0
}

configure_mc() {
    # Configure mc alias if credentials provided
    if [[ -n "$MINIO_ACCESS_KEY" && -n "$MINIO_SECRET_KEY" ]]; then
        log_debug "Configuring mc alias"
        mc alias set "$MINIO_ALIAS" "$MINIO_ENDPOINT" "$MINIO_ACCESS_KEY" "$MINIO_SECRET_KEY" &>/dev/null
    else
        # Check if alias already exists
        if ! mc alias ls "$MINIO_ALIAS" &>/dev/null; then
            log_error "Minio credentials not configured"
            return 1
        fi
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Check functions
# -----------------------------------------------------------------------------

record_check() {
    local name="$1"
    local status="$2"
    local message="$3"
    
    CHECKS+=("{\"name\":\"$name\",\"status\":\"$status\",\"message\":\"$message\"}")
    
    if [[ "$OUTPUT_FORMAT" == "text" ]]; then
        case "$status" in
            pass) log_success "$name: $message" ;;
            fail) log_error "$name: $message"; ((ISSUES++)) ;;
            warn) log_warn "$name: $message"; ((ISSUES++)) ;;
        esac
    fi
}

# Check cluster connectivity
check_connectivity() {
    print_section "Cluster Connectivity"
    
    if mc admin info "$MINIO_ALIAS" &>/dev/null; then
        record_check "Connection" "pass" "Connected to $MINIO_ENDPOINT"
    else
        record_check "Connection" "fail" "Cannot connect to Minio"
        return 1
    fi
}

# Check server health
check_server_health() {
    print_section "Server Health"
    
    local health_output
    health_output=$(mc admin info "$MINIO_ALIAS" --json 2>/dev/null) || {
        record_check "Health Info" "fail" "Cannot retrieve health info"
        return 1
    }
    
    # Parse health info
    local mode=$(echo "$health_output" | jq -r '.info.mode' 2>/dev/null || echo "unknown")
    local region=$(echo "$health_output" | jq -r '.info.region' 2>/dev/null || echo "default")
    
    print_kv "Mode" "$mode"
    print_kv "Region" "$region"
    
    # Check each server
    local servers=$(echo "$health_output" | jq -r '.info.servers[]?.endpoint' 2>/dev/null)
    local total_servers=$(echo "$servers" | wc -l)
    
    if [[ $total_servers -gt 0 ]]; then
        record_check "Servers" "pass" "$total_servers server(s) in cluster"
    fi
    
    # Check drives
    local online_drives=$(echo "$health_output" | jq -r '[.info.servers[].drives[] | select(.state == "ok")] | length' 2>/dev/null || echo "0")
    local total_drives=$(echo "$health_output" | jq -r '[.info.servers[].drives[]] | length' 2>/dev/null || echo "0")
    
    if [[ $online_drives -eq $total_drives && $total_drives -gt 0 ]]; then
        record_check "Drives" "pass" "All $total_drives drives healthy"
    elif [[ $online_drives -gt 0 ]]; then
        record_check "Drives" "warn" "$online_drives/$total_drives drives online"
    else
        record_check "Drives" "fail" "No drives online"
    fi
}

# Check disk usage
check_disk_usage() {
    print_section "Disk Usage"
    
    local info
    info=$(mc admin info "$MINIO_ALIAS" --json 2>/dev/null) || return 1
    
    local used_space=$(echo "$info" | jq -r '.info.usage.size' 2>/dev/null || echo "0")
    local total_space=$(echo "$info" | jq -r '.info.usage.capacity' 2>/dev/null || echo "0")
    
    if [[ $total_space -gt 0 ]]; then
        local used_pct=$((used_space * 100 / total_space))
        local used_human=$(bytes_to_human $used_space)
        local total_human=$(bytes_to_human $total_space)
        
        print_kv "Used" "$used_human"
        print_kv "Total" "$total_human"
        print_kv "Usage" "${used_pct}%"
        
        if (( used_pct >= 90 )); then
            record_check "Disk Space" "fail" "Critical: ${used_pct}% used"
        elif (( used_pct >= 80 )); then
            record_check "Disk Space" "warn" "Warning: ${used_pct}% used"
        else
            record_check "Disk Space" "pass" "${used_pct}% used"
        fi
    fi
}

# List buckets
check_buckets() {
    print_section "Buckets"
    
    local buckets
    buckets=$(mc ls "$MINIO_ALIAS" --json 2>/dev/null) || {
        record_check "Buckets" "fail" "Cannot list buckets"
        return 1
    }
    
    local count=$(echo "$buckets" | jq -s 'length' 2>/dev/null || echo "0")
    
    echo ""
    echo "  Bucket Summary:"
    
    local total_size=0
    local total_objects=0
    
    # List each bucket with size
    mc ls "$MINIO_ALIAS" 2>/dev/null | while read -r line; do
        local bucket_name=$(echo "$line" | awk '{print $NF}' | tr -d '/')
        [[ -z "$bucket_name" ]] && continue
        
        echo "    $bucket_name"
    done
    
    echo ""
    record_check "Buckets" "pass" "$count bucket(s) found"
}

# Check access keys
check_access_keys() {
    print_section "Access Keys Audit"
    
    local users
    users=$(mc admin user ls "$MINIO_ALIAS" --json 2>/dev/null) || {
        log_debug "Cannot list users (may require admin privileges)"
        return 0
    }
    
    local user_count=$(echo "$users" | jq -s 'length' 2>/dev/null || echo "0")
    
    print_kv "Total Users" "$user_count"
    
    if [[ "$VERBOSE" == "true" ]]; then
        echo ""
        echo "  Users:"
        mc admin user ls "$MINIO_ALIAS" 2>/dev/null | while read -r line; do
            echo "    $line"
        done
    fi
    
    record_check "Users" "pass" "$user_count access key(s)"
}

# Check replication (if configured)
check_replication() {
    print_section "Replication Status"
    
    local replication
    replication=$(mc admin replicate status "$MINIO_ALIAS" 2>/dev/null) || {
        log "No replication configured"
        return 0
    }
    
    if [[ -n "$replication" ]]; then
        echo "$replication" | head -10
    fi
}

# Performance test
run_performance_test() {
    print_section "Performance Test"
    
    log "Running quick performance test..."
    
    local test_bucket="${MINIO_ALIAS}/health-test-$(date +%s)"
    local temp_file="/tmp/minio_test_$$.dat"
    
    # Create test file (1MB)
    dd if=/dev/urandom of="$temp_file" bs=1M count=1 2>/dev/null
    
    # Upload test
    local start_time=$(date +%s%3N)
    if mc cp "$temp_file" "$test_bucket" &>/dev/null; then
        local upload_time=$(( $(date +%s%3N) - start_time ))
        print_kv "Upload (1MB)" "${upload_time}ms"
    else
        log_warn "Upload test failed"
    fi
    
    # Download test
    start_time=$(date +%s%3N)
    if mc cp "${test_bucket}/$(basename $temp_file)" "/tmp/minio_dl_$$.dat" &>/dev/null; then
        local download_time=$(( $(date +%s%3N) - start_time ))
        print_kv "Download (1MB)" "${download_time}ms"
    fi
    
    # Cleanup
    mc rm -r --force "${test_bucket}" &>/dev/null || true
    rm -f "$temp_file" "/tmp/minio_dl_$$.dat" 2>/dev/null
    
    record_check "Performance" "pass" "Test completed"
}

# Check for healing operations
check_healing() {
    print_section "Healing Status"
    
    local healing
    healing=$(mc admin heal "$MINIO_ALIAS" --json 2>/dev/null | head -1) || {
        log_debug "Cannot check healing status"
        return 0
    }
    
    local status=$(echo "$healing" | jq -r '.healStatus' 2>/dev/null || echo "unknown")
    
    if [[ "$status" == "finished" || "$status" == "unknown" ]]; then
        record_check "Healing" "pass" "No active healing operations"
    else
        record_check "Healing" "warn" "Healing in progress"
    fi
}

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------

output_json() {
    local checks_array=$(IFS=,; echo "${CHECKS[*]}")
    
    cat <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "endpoint": "$MINIO_ENDPOINT",
  "issues": $ISSUES,
  "checks": [$checks_array]
}
EOF
}

print_summary() {
    echo ""
    print_section "Summary"
    
    if (( ISSUES == 0 )); then
        echo -e "${GREEN}Minio cluster is healthy${RESET}"
    else
        echo -e "${YELLOW}Found $ISSUES issue(s)${RESET}"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    
    if ! check_prerequisites; then
        exit 1
    fi
    
    if ! configure_mc; then
        exit 1
    fi
    
    if [[ "$OUTPUT_FORMAT" == "text" ]]; then
        print_header "Minio Health Check"
        print_kv "Endpoint" "$MINIO_ENDPOINT"
        print_kv "Timestamp" "$(date)"
    fi
    
    # Run checks
    check_connectivity || exit 1
    check_server_health
    check_disk_usage
    check_buckets
    check_access_keys
    check_healing
    check_replication
    
    # Optional performance test
    if [[ "$VERBOSE" == "true" ]]; then
        run_performance_test
    fi
    
    # Output
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        output_json
    else
        print_summary
    fi
    
    exit $ISSUES
}

main "$@"
