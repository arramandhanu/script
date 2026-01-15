#!/bin/bash
#
# kafka-strimzi-health.sh - Kafka/Strimzi cluster monitoring
#
# Usage:
#   ./kafka-strimzi-health.sh [command] [options]
#
# Commands:
#   status      Cluster status (default)
#   topics      List topics
#   groups      Consumer groups
#   lag         Consumer lag
#   strimzi     Strimzi operator status
#
# Options:
#   -b, --bootstrap HOST:PORT  Kafka bootstrap server
#   -n, --namespace NS         Kubernetes namespace for Strimzi
#   -j, --json                 JSON output
#   -h, --help                 Show this help
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/k8s-helpers.sh"

# Configuration
BOOTSTRAP="${KAFKA_BOOTSTRAP:-localhost:9092}"
NAMESPACE="${STRIMZI_NAMESPACE:-kafka}"
COMMAND="${1:-status}"
JSON_OUTPUT=false

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
            -b|--bootstrap)
                BOOTSTRAP="$2"
                shift 2
                ;;
            -n|--namespace)
                NAMESPACE="$2"
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
# Kafka CLI detection
# -----------------------------------------------------------------------------
kafka_cmd() {
    local cmd="$1"
    shift
    
    # Try different kafka command locations
    if command -v "kafka-${cmd}.sh" &>/dev/null; then
        "kafka-${cmd}.sh" "$@"
    elif command -v "kafka-${cmd}" &>/dev/null; then
        "kafka-${cmd}" "$@"
    elif [[ -d "/opt/kafka/bin" ]]; then
        "/opt/kafka/bin/kafka-${cmd}.sh" "$@"
    else
        log_error "Kafka CLI not found"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

show_status() {
    print_header "Kafka Cluster Status"
    print_kv "Bootstrap" "$BOOTSTRAP"
    
    # Check broker connectivity
    print_section "Broker Status"
    
    local brokers
    brokers=$(kafka_cmd metadata --bootstrap-server "$BOOTSTRAP" --snapshot 2>/dev/null || true)
    
    if [[ -z "$brokers" ]]; then
        # Fallback: try to list topics as connectivity check
        if kafka_cmd topics --bootstrap-server "$BOOTSTRAP" --list &>/dev/null; then
            log_success "Connected to Kafka cluster"
        else
            log_error "Cannot connect to Kafka cluster"
            return 1
        fi
    else
        echo "$brokers" | head -20
    fi
    
    # Topic count
    local topic_count
    topic_count=$(kafka_cmd topics --bootstrap-server "$BOOTSTRAP" --list 2>/dev/null | wc -l)
    print_kv "Topic Count" "$topic_count"
    
    # Consumer group count
    local group_count
    group_count=$(kafka_cmd consumer-groups --bootstrap-server "$BOOTSTRAP" --list 2>/dev/null | wc -l)
    print_kv "Consumer Groups" "$group_count"
    
    # Under-replicated partitions
    echo ""
    print_section "Partition Health"
    
    local under_replicated
    under_replicated=$(kafka_cmd topics --bootstrap-server "$BOOTSTRAP" --describe \
        --under-replicated-partitions 2>/dev/null | wc -l)
    
    if [[ $under_replicated -eq 0 ]]; then
        log_success "No under-replicated partitions"
    else
        log_warn "$under_replicated under-replicated partitions"
        kafka_cmd topics --bootstrap-server "$BOOTSTRAP" --describe \
            --under-replicated-partitions 2>/dev/null | head -10
    fi
    
    # Offline partitions
    local offline
    offline=$(kafka_cmd topics --bootstrap-server "$BOOTSTRAP" --describe \
        --unavailable-partitions 2>/dev/null | wc -l)
    
    if [[ $offline -eq 0 ]]; then
        log_success "No offline partitions"
    else
        log_error "$offline offline partitions"
    fi
}

show_topics() {
    print_section "Topics"
    
    local topics
    topics=$(kafka_cmd topics --bootstrap-server "$BOOTSTRAP" --list 2>/dev/null)
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        echo "$topics" | jq -R -s 'split("\n") | map(select(length > 0))'
        return
    fi
    
    local count=$(echo "$topics" | wc -l)
    echo "Total topics: $count"
    echo ""
    
    echo "$topics" | while read -r topic; do
        [[ -z "$topic" ]] && continue
        
        # Get partition count
        local partitions
        partitions=$(kafka_cmd topics --bootstrap-server "$BOOTSTRAP" \
            --describe --topic "$topic" 2>/dev/null | grep -c "Partition:" || echo "0")
        
        printf "  %-40s %s partitions\n" "$topic" "$partitions"
    done | head -30
    
    if [[ $count -gt 30 ]]; then
        echo "  ... and $((count - 30)) more topics"
    fi
}

show_groups() {
    print_section "Consumer Groups"
    
    local groups
    groups=$(kafka_cmd consumer-groups --bootstrap-server "$BOOTSTRAP" --list 2>/dev/null)
    
    echo "$groups" | while read -r group; do
        [[ -z "$group" ]] && continue
        
        # Get group state
        local state
        state=$(kafka_cmd consumer-groups --bootstrap-server "$BOOTSTRAP" \
            --describe --group "$group" 2>/dev/null | grep -oP "STATE\s+\K\S+" | head -1 || echo "Unknown")
        
        local state_color="${GREEN}"
        case "$state" in
            Stable) state_color="${GREEN}" ;;
            Empty|Dead) state_color="${YELLOW}" ;;
            *) state_color="${BLUE}" ;;
        esac
        
        printf "  %-40s ${state_color}%s${RESET}\n" "$group" "$state"
    done | head -30
}

show_lag() {
    print_section "Consumer Lag"
    
    local group
    
    if [[ -z "${2:-}" ]]; then
        # List groups first
        echo "Consumer groups:"
        kafka_cmd consumer-groups --bootstrap-server "$BOOTSTRAP" --list 2>/dev/null | head -10
        echo ""
        read -p "Select group: " group
    else
        group="$2"
    fi
    
    if [[ -z "$group" ]]; then
        log_error "Group name required"
        return 1
    fi
    
    kafka_cmd consumer-groups --bootstrap-server "$BOOTSTRAP" \
        --describe --group "$group" 2>/dev/null
    
    # Calculate total lag
    local total_lag
    total_lag=$(kafka_cmd consumer-groups --bootstrap-server "$BOOTSTRAP" \
        --describe --group "$group" 2>/dev/null | \
        awk 'NR>1 && $5 ~ /^[0-9]+$/ {sum += $5} END {print sum}')
    
    echo ""
    print_kv "Total Lag" "${total_lag:-0}"
    
    if [[ ${total_lag:-0} -gt 10000 ]]; then
        log_warn "High consumer lag detected"
    fi
}

show_strimzi() {
    print_section "Strimzi Operator Status"
    print_kv "Namespace" "$NAMESPACE"
    
    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found"
        return 1
    fi
    
    # Strimzi operator pod
    echo ""
    echo "Strimzi Operator:"
    kubectl get pods -n "$NAMESPACE" -l strimzi.io/kind=cluster-operator 2>/dev/null || \
        kubectl get pods -n "$NAMESPACE" -l name=strimzi-cluster-operator 2>/dev/null || \
        echo "  Operator not found"
    
    # Kafka clusters
    echo ""
    echo "Kafka Clusters:"
    kubectl get kafka -n "$NAMESPACE" 2>/dev/null || echo "  No Kafka resources found"
    
    # Kafka topics (CRDs)
    echo ""
    echo "KafkaTopic CRDs:"
    local topic_count
    topic_count=$(kubectl get kafkatopics -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    print_kv "KafkaTopic count" "$topic_count"
    
    # Kafka users
    echo ""
    echo "Kafka Users:"
    kubectl get kafkausers -n "$NAMESPACE" --no-headers 2>/dev/null | head -10 || echo "  No users found"
    
    # Kafka Connect (if used)
    echo ""
    echo "Kafka Connect:"
    kubectl get kafkaconnect -n "$NAMESPACE" 2>/dev/null || echo "  No Connect clusters"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    case "$COMMAND" in
        status)  show_status ;;
        topics)  show_topics ;;
        groups)  show_groups ;;
        lag)     show_lag "$@" ;;
        strimzi) show_strimzi ;;
        *)
            log_error "Unknown command: $COMMAND"
            exit 1
            ;;
    esac
}

main "$@"
