# 🛠️ Infrastructure Scripts Collection

[![Shell](https://img.shields.io/badge/Shell-Bash%204.0%2B-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Python](https://img.shields.io/badge/Python-3.6%2B-3776AB?style=flat-square&logo=python&logoColor=white)](https://www.python.org/)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)](https://www.linux.org/)
[![Tested](https://img.shields.io/badge/Tested-On--Premise%20%26%20Cloud-blue?style=flat-square)](/)

### Stack Compatibility

[![Kubernetes](https://img.shields.io/badge/Kubernetes-RKE2-326CE5?style=for-the-badge&logo=kubernetes&logoColor=white)](https://docs.rke2.io/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-Patroni-4169E1?style=for-the-badge&logo=postgresql&logoColor=white)](https://patroni.readthedocs.io/)
[![Ceph](https://img.shields.io/badge/Ceph-Storage-EF5C55?style=for-the-badge&logo=ceph&logoColor=white)](https://ceph.io/)
[![etcd](https://img.shields.io/badge/etcd-Cluster-419EDA?style=for-the-badge&logo=etcd&logoColor=white)](https://etcd.io/)
[![Kafka](https://img.shields.io/badge/Kafka-Strimzi-231F20?style=for-the-badge&logo=apachekafka&logoColor=white)](https://strimzi.io/)
[![ClickHouse](https://img.shields.io/badge/ClickHouse-Analytics-FFCC01?style=for-the-badge&logo=clickhouse&logoColor=black)](https://clickhouse.com/)
[![Cassandra](https://img.shields.io/badge/Cassandra-NoSQL-1287B1?style=for-the-badge&logo=apachecassandra&logoColor=white)](https://cassandra.apache.org/)
[![Minio](https://img.shields.io/badge/Minio-Object%20Storage-C72E49?style=for-the-badge&logo=minio&logoColor=white)](https://min.io/)
[![HAProxy](https://img.shields.io/badge/HAProxy-Load%20Balancer-106DA9?style=for-the-badge&logo=haproxy&logoColor=white)](https://www.haproxy.org/)
[![Prometheus](https://img.shields.io/badge/Prometheus-Monitoring-E6522C?style=for-the-badge&logo=prometheus&logoColor=white)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-Dashboards-F46800?style=for-the-badge&logo=grafana&logoColor=white)](https://grafana.com/)
[![Loki](https://img.shields.io/badge/Loki-Logging-F46800?style=for-the-badge&logo=grafana&logoColor=white)](https://grafana.com/oss/loki/)
[![Tempo](https://img.shields.io/badge/Tempo-Tracing-F46800?style=for-the-badge&logo=grafana&logoColor=white)](https://grafana.com/oss/tempo/)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-EF7B4D?style=for-the-badge&logo=argo&logoColor=white)](https://argoproj.github.io/cd/)
[![Helm](https://img.shields.io/badge/Helm-Charts-0F1689?style=for-the-badge&logo=helm&logoColor=white)](https://helm.sh/)
[![Netbird](https://img.shields.io/badge/Netbird-VPN-4B32C3?style=for-the-badge&logo=wireguard&logoColor=white)](https://netbird.io/)

---

Production-ready automation scripts for DevOps engineers managing Linux infrastructure.

> **Note:** This script collection is based on real-world production environments for government projects in Indonesia. Tested on both on-premise and cloud infrastructure.

---

## 📋 Table of Contents

- [Quick Start](#-quick-start)
- [Scripts Overview](#-scripts-overview)
- [Configuration](#-configuration)
- [Usage](#-usage)
- [Requirements](#-requirements)

---

## 🚀 Quick Start

```bash
git clone https://github.com/your-repo/script.git && cd script
cp config/settings.env.example config/settings.env
chmod +x **/*.sh monitoring/*.py
```

---

## 📁 Scripts Overview (33 Scripts)

### 🐳 Kubernetes & RKE2

Scripts for managing RKE2 clusters, storage, and troubleshooting.

| Script | Description |
|--------|-------------|
| `rke2-cluster-health.sh` | RKE2 cluster health check |
| `k8s-troubleshoot.sh` | Interactive troubleshooting |
| `openebs-storage-audit.sh` | OpenEBS storage monitoring |

### 🗄️ Database

Database cluster management for PostgreSQL, ClickHouse, and Cassandra.

| Script | Description |
|--------|-------------|
| `patroni-cluster.sh` | PostgreSQL/Patroni: status, lag, switchover, reinit |
| `clickhouse-health.sh` | ClickHouse: queries, replication, tables, merges |
| `cassandra-health.sh` | Cassandra: nodetool status, ring, repair, compaction |

### 💾 Storage

Ceph distributed storage monitoring.

| Script | Description |
|--------|-------------|
| `ceph-health.sh` | OSD status, PG states, pools, monitors |

### 🔧 Infrastructure

Core infrastructure components.

| Script | Description |
|--------|-------------|
| `etcd-health.sh` | etcd cluster: members, leader, alarms, defrag, snapshot |
| `haproxy-status.sh` | Backend status, VIP check, sessions, errors |
| `netbird-status.sh` | Netbird VPN: peers, routes, DNS |

### 📨 Messaging

Kafka message queue monitoring.

| Script | Description |
|--------|-------------|
| `kafka-strimzi-health.sh` | Brokers, topics, consumer lag, Strimzi CRDs |

### 📊 Monitoring

Metrics and observability stack.

| Script | Description |
|--------|-------------|
| `prometheus-health.sh` | Targets, alerts, rules, TSDB stats |
| `grafana-health.sh` | Dashboards, data sources, alerts, users |
| `promtail-check.sh` | Agent status, targets, metrics |
| `observability-check.sh` | Loki/Tempo health and queries |
| `minio-health.sh` | Minio cluster, buckets, disk usage |
| `jmx-exporter-check.sh` | JVM metrics, K8s pod scanning |
| `cadvisor-check.sh` | Container metrics, machine info |
| `debug-toolkit.py` | Interactive debug toolkit (Python) |

### 🖥️ Server

Linux server management and security.

| Script | Description |
|--------|-------------|
| `vm-health-check.sh` | CPU, memory, disk, network, services |
| `server-network-route.sh` | Route management: add, delete, backup |
| `security-hardening-audit.sh` | CIS benchmark security audit |
| `ssl-cert-manager.sh` | Certificate scanning, expiry, K8s secrets |
| `incident-response.sh` | Rapid data collection for incidents |

### 🚢 Deployment & GitOps

Deployment automation and GitOps workflows.

| Script | Description |
|--------|-------------|
| `rolling-patch.sh` | K8s-aware rolling patches |
| `ansible-wrapper.sh` | Ansible deployment wrapper |
| `helm-manager.sh` | Helm: list, status, history, rollback |
| `kustomize-helper.sh` | Build, diff, validate, apply |
| `argocd-status.sh` | Apps, sync status, health, diff |
| `gitops-sync.sh` | Git sync status, ArgoCD/Flux support |

### ☁️ Cloud

Cloud provider utilities.

| Script | Description |
|--------|-------------|
| `cloud-disk-resize.sh` | AWS/GCP disk resize |

---

## ⚙️ Configuration

```bash
# config/settings.env

# Kubernetes
KUBECONFIG_PROD=~/.kube/config-prod

# Databases
PATRONI_HOST=patroni.example.com
CLICKHOUSE_HOST=clickhouse.example.com
CASSANDRA_HOST=cassandra.example.com

# Infrastructure
ETCD_ENDPOINTS=https://etcd1:2379
HAPROXY_SOCKET=/var/run/haproxy/admin.sock

# Monitoring
PROMETHEUS_URL=http://prometheus:9090
GRAFANA_URL=http://grafana:3000
LOKI_URL=http://loki:3100

# Messaging
KAFKA_BOOTSTRAP=kafka:9092

# GitOps
ARGOCD_NAMESPACE=argocd

# Thresholds
CPU_WARN=80
DISK_WARN=80
CERT_WARN_DAYS=30
```

---

## 📖 Usage

### Database

```bash
./database/patroni-cluster.sh status        # Cluster status
./database/patroni-cluster.sh switchover    # Initiate switchover
./database/clickhouse-health.sh replication # Replication status
```

### Monitoring

```bash
./monitoring/prometheus-health.sh targets   # Scrape targets
./monitoring/grafana-health.sh datasources  # Data source status
./monitoring/promtail-check.sh status       # Promtail agent
```

### GitOps

```bash
./deployment/argocd-status.sh apps          # List all apps
./deployment/argocd-status.sh sync          # Check sync status
./deployment/helm-manager.sh list           # Helm releases
./deployment/gitops-sync.sh status          # Git/cluster sync
```

### Incident Response

```bash
./server/incident-response.sh -k            # Collect with K8s data
./server/ssl-cert-manager.sh expiry         # Expiring certificates
```

---

## 📦 Requirements

| Tool | Scripts |
|------|---------|
| Bash 4.0+ | All shell scripts |
| Python 3.6+ | debug-toolkit.py |
| kubectl | K8s scripts |
| helm | helm-manager.sh |
| jq | JSON parsing |
| curl | API calls |

---

## 📁 Directory Structure

```
script/
├── lib/             # common.sh, k8s-helpers.sh, db-helpers.sh
├── database/        # Patroni, ClickHouse, Cassandra
├── storage/         # Ceph
├── infrastructure/  # etcd, HAProxy, Netbird
├── messaging/       # Kafka/Strimzi
├── kubernetes/      # RKE2, K8s, OpenEBS
├── server/          # Health, security, SSL, incident
├── deployment/      # Helm, Kustomize, ArgoCD, GitOps
├── monitoring/      # Prometheus, Grafana, Loki, Tempo
├── cloud/           # AWS/GCP
└── config/          # settings.env
```

---

## 👤 Author

Developed based on production experience managing government infrastructure projects in Indonesia.

---

## 📄 License

MIT License
