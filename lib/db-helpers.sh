#!/bin/bash
#
# db-helpers.sh - Database helper functions
# Source this file after common.sh
#

# -----------------------------------------------------------------------------
# PostgreSQL / Patroni
# -----------------------------------------------------------------------------

# Default Patroni REST API port
PATRONI_PORT="${PATRONI_PORT:-8008}"

# Get Patroni cluster status via REST API
patroni_cluster_status() {
    local host="${1:-localhost}"
    local port="${2:-$PATRONI_PORT}"
    
    curl -s "http://${host}:${port}/cluster" 2>/dev/null
}

# Get Patroni node status
patroni_node_status() {
    local host="${1:-localhost}"
    local port="${2:-$PATRONI_PORT}"
    
    curl -s "http://${host}:${port}/patroni" 2>/dev/null
}

# Check if node is leader
is_patroni_leader() {
    local host="${1:-localhost}"
    local port="${2:-$PATRONI_PORT}"
    
    local role=$(curl -s "http://${host}:${port}/patroni" 2>/dev/null | jq -r '.role' 2>/dev/null)
    [[ "$role" == "master" || "$role" == "leader" ]]
}

# Get replication lag in bytes
get_replication_lag() {
    local host="$1"
    local port="${2:-5432}"
    local user="${PG_USER:-postgres}"
    
    psql -h "$host" -p "$port" -U "$user" -t -c \
        "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;" 2>/dev/null
}

# -----------------------------------------------------------------------------
# etcd
# -----------------------------------------------------------------------------

ETCD_ENDPOINTS="${ETCD_ENDPOINTS:-http://localhost:2379}"
ETCD_CACERT="${ETCD_CACERT:-}"
ETCD_CERT="${ETCD_CERT:-}"
ETCD_KEY="${ETCD_KEY:-}"

# Build etcdctl command with auth
etcdctl_cmd() {
    local cmd="etcdctl --endpoints=$ETCD_ENDPOINTS"
    
    [[ -n "$ETCD_CACERT" ]] && cmd="$cmd --cacert=$ETCD_CACERT"
    [[ -n "$ETCD_CERT" ]] && cmd="$cmd --cert=$ETCD_CERT"
    [[ -n "$ETCD_KEY" ]] && cmd="$cmd --key=$ETCD_KEY"
    
    echo "$cmd"
}

# Get etcd cluster health
etcd_health() {
    $(etcdctl_cmd) endpoint health --cluster 2>/dev/null
}

# Get etcd member list
etcd_members() {
    $(etcdctl_cmd) member list 2>/dev/null
}

# Get etcd leader
etcd_leader() {
    $(etcdctl_cmd) endpoint status --cluster -w json 2>/dev/null | \
        jq -r '.[] | select(.Status.leader == .Status.header.member_id) | .Endpoint' 2>/dev/null
}

# -----------------------------------------------------------------------------
# Ceph
# -----------------------------------------------------------------------------

# Check ceph command availability
has_ceph_cli() {
    command -v ceph &>/dev/null
}

# Get ceph health status
ceph_health() {
    ceph health 2>/dev/null
}

# Get ceph status (detailed)
ceph_status() {
    ceph status 2>/dev/null
}

# Get OSD tree
ceph_osd_tree() {
    ceph osd tree 2>/dev/null
}

# Get pool usage
ceph_pool_usage() {
    ceph df 2>/dev/null
}

# Get PG status summary
ceph_pg_status() {
    ceph pg stat 2>/dev/null
}

# -----------------------------------------------------------------------------
# Cassandra
# -----------------------------------------------------------------------------

CASSANDRA_HOST="${CASSANDRA_HOST:-localhost}"

# Run nodetool command
nodetool_cmd() {
    local cmd="$1"
    nodetool -h "$CASSANDRA_HOST" "$cmd" 2>/dev/null
}

# Get Cassandra node status
cassandra_status() {
    nodetool_cmd "status"
}

# Get Cassandra ring info
cassandra_ring() {
    nodetool_cmd "ring"
}

# Check if Cassandra is up
is_cassandra_up() {
    nodetool_cmd "info" &>/dev/null
}

# -----------------------------------------------------------------------------
# ClickHouse
# -----------------------------------------------------------------------------

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-}"

# Run ClickHouse query
clickhouse_query() {
    local query="$1"
    local format="${2:-TabSeparated}"
    
    local auth=""
    [[ -n "$CLICKHOUSE_PASSWORD" ]] && auth="--password $CLICKHOUSE_PASSWORD"
    
    clickhouse-client -h "$CLICKHOUSE_HOST" --port 9000 \
        -u "$CLICKHOUSE_USER" $auth \
        --query "$query" 2>/dev/null
}

# Check ClickHouse is alive
is_clickhouse_up() {
    curl -s "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/ping" 2>/dev/null | grep -q "Ok"
}

# Get ClickHouse cluster info
clickhouse_clusters() {
    clickhouse_query "SELECT cluster, host_name, port FROM system.clusters"
}

# -----------------------------------------------------------------------------
# Kafka
# -----------------------------------------------------------------------------

KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-localhost:9092}"

# Check if kafka-topics.sh is available
has_kafka_cli() {
    command -v kafka-topics.sh &>/dev/null || command -v kafka-topics &>/dev/null
}

# Get Kafka topics
kafka_topics() {
    if command -v kafka-topics.sh &>/dev/null; then
        kafka-topics.sh --bootstrap-server "$KAFKA_BOOTSTRAP" --list 2>/dev/null
    elif command -v kafka-topics &>/dev/null; then
        kafka-topics --bootstrap-server "$KAFKA_BOOTSTRAP" --list 2>/dev/null
    fi
}

# Get consumer group lag
kafka_consumer_lag() {
    local group="$1"
    
    if command -v kafka-consumer-groups.sh &>/dev/null; then
        kafka-consumer-groups.sh --bootstrap-server "$KAFKA_BOOTSTRAP" \
            --describe --group "$group" 2>/dev/null
    elif command -v kafka-consumer-groups &>/dev/null; then
        kafka-consumer-groups --bootstrap-server "$KAFKA_BOOTSTRAP" \
            --describe --group "$group" 2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# HAProxy
# -----------------------------------------------------------------------------

HAPROXY_SOCKET="${HAPROXY_SOCKET:-/var/run/haproxy/admin.sock}"
HAPROXY_STATS_URL="${HAPROXY_STATS_URL:-}"

# Get HAProxy stats via socket
haproxy_stats_socket() {
    echo "show stat" | socat stdio "$HAPROXY_SOCKET" 2>/dev/null
}

# Get HAProxy stats via HTTP
haproxy_stats_http() {
    curl -s "$HAPROXY_STATS_URL" 2>/dev/null
}

# Get HAProxy info
haproxy_info() {
    echo "show info" | socat stdio "$HAPROXY_SOCKET" 2>/dev/null
}

# Get backend status
haproxy_backends() {
    echo "show stat" | socat stdio "$HAPROXY_SOCKET" 2>/dev/null | \
        awk -F, '$2 != "FRONTEND" && $2 != "stats" && NR>1 {print $1, $2, $18}'
}
