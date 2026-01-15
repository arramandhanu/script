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
[![Grafana](https://img.shields.io/badge/Loki-Logging-F46800?style=for-the-badge&logo=grafana&logoColor=white)](https://grafana.com/oss/loki/)
[![Tempo](https://img.shields.io/badge/Tempo-Tracing-F46800?style=for-the-badge&logo=grafana&logoColor=white)](https://grafana.com/oss/tempo/)

---

Production-ready automation scripts for DevOps engineers managing Linux infrastructure.

> **Note:** This script collection is based on real-world production environments for government projects in Indonesia. Tested on both on-premise and cloud infrastructure.

---

## 📋 Table of Contents

- [Quick Start](#-quick-start)
- [Scripts Overview](#-scripts-overview)
- [Configuration](#-configuration)
- [Usage Examples](#-usage-examples)
- [Requirements](#-requirements)

---

## 🚀 Quick Start

```bash
# Clone
git clone https://github.com/your-repo/script.git && cd script

# Configure
cp config/settings.env.example config/settings.env
vim config/settings.env

# Make executable
chmod +x **/*.sh monitoring/*.py
```

---

## 📁 Scripts Overview

### 🐳 Kubernetes & RKE2

| Script | Description |
|--------|-------------|
| [`rke2-cluster-health.sh`](kubernetes/rke2-cluster-health.sh) | RKE2 cluster health check |
| [`k8s-troubleshoot.sh`](kubernetes/k8s-troubleshoot.sh) | Interactive troubleshooting |
| [`openebs-storage-audit.sh`](kubernetes/openebs-storage-audit.sh) | OpenEBS storage monitoring |

### 🗄️ Database

| Script | Description |
|--------|-------------|
| [`patroni-cluster.sh`](database/patroni-cluster.sh) | PostgreSQL/Patroni cluster management |
| [`clickhouse-health.sh`](database/clickhouse-health.sh) | ClickHouse cluster monitoring |
| [`cassandra-health.sh`](database/cassandra-health.sh) | Cassandra cluster status |

### 💾 Storage

| Script | Description |
|--------|-------------|
| [`ceph-health.sh`](storage/ceph-health.sh) | Ceph cluster health (OSD, PG, pools) |

### 🔧 Infrastructure

| Script | Description |
|--------|-------------|
| [`etcd-health.sh`](infrastructure/etcd-health.sh) | etcd cluster health |
| [`haproxy-status.sh`](infrastructure/haproxy-status.sh) | HAProxy backend/VIP status |

### 📨 Messaging

| Script | Description |
|--------|-------------|
| [`kafka-strimzi-health.sh`](messaging/kafka-strimzi-health.sh) | Kafka/Strimzi cluster health |

### 🖥️ Server

| Script | Description |
|--------|-------------|
| [`vm-health-check.sh`](server/vm-health-check.sh) | Server health check |
| [`server-network-route.sh`](server/server-network-route.sh) | Network route manager |
| [`security-hardening-audit.sh`](server/security-hardening-audit.sh) | CIS security audit |
| [`ssl-cert-manager.sh`](server/ssl-cert-manager.sh) | SSL certificate monitoring |
| [`incident-response.sh`](server/incident-response.sh) | Incident data collection |

### 🚢 Deployment

| Script | Description |
|--------|-------------|
| [`rolling-patch.sh`](deployment/rolling-patch.sh) | K8s-aware rolling patches |
| [`ansible-wrapper.sh`](deployment/ansible-wrapper.sh) | Ansible deployment wrapper |

### 📊 Monitoring

| Script | Description |
|--------|-------------|
| [`minio-health.sh`](monitoring/minio-health.sh) | Minio cluster health |
| [`observability-check.sh`](monitoring/observability-check.sh) | Loki/Tempo health |
| [`debug-toolkit.py`](monitoring/debug-toolkit.py) | Interactive debug toolkit |

### ☁️ Cloud

| Script | Description |
|--------|-------------|
| [`cloud-disk-resize.sh`](cloud/cloud-disk-resize.sh) | AWS/GCP disk resize |

---

## ⚙️ Configuration

```bash
# config/settings.env

# Kubernetes
KUBECONFIG_DEV=~/.kube/config-dev
KUBECONFIG_STAGING=~/.kube/config-staging
KUBECONFIG_PROD=~/.kube/config-prod

# Patroni
PATRONI_HOST=patroni.example.com
PATRONI_PORT=8008

# etcd
ETCD_ENDPOINTS=https://etcd1:2379,https://etcd2:2379

# Kafka
KAFKA_BOOTSTRAP=kafka:9092

# ClickHouse
CLICKHOUSE_HOST=clickhouse.example.com

# Minio
MINIO_ENDPOINT=https://minio.example.com

# Observability
LOKI_URL=http://loki:3100
TEMPO_URL=http://tempo:3200

# Thresholds
CPU_WARN=80
MEM_WARN=80
DISK_WARN=80
CERT_WARN_DAYS=30
```

---

## 📖 Usage Examples

### Database

```bash
# Patroni cluster status
./database/patroni-cluster.sh status

# Patroni replication lag
./database/patroni-cluster.sh lag

# Patroni switchover
./database/patroni-cluster.sh switchover
```

### Storage

```bash
# Ceph cluster status
./storage/ceph-health.sh status

# Ceph OSD details
./storage/ceph-health.sh osd
```

### Infrastructure

```bash
# etcd health
./infrastructure/etcd-health.sh status

# HAProxy backend status
./infrastructure/haproxy-status.sh status

# HAProxy VIP check
./infrastructure/haproxy-status.sh vip -v 10.0.0.100
```

### Messaging

```bash
# Kafka cluster status
./messaging/kafka-strimzi-health.sh status

# Consumer lag
./messaging/kafka-strimzi-health.sh lag

# Strimzi operator status
./messaging/kafka-strimzi-health.sh strimzi
```

### Incident Response

```bash
# Quick collection
./server/incident-response.sh -q

# Full collection with K8s
./server/incident-response.sh -k

# Remote collection
./server/incident-response.sh -r server01 -t 120
```

### SSL Certificates

```bash
# Scan local certs
./server/ssl-cert-manager.sh scan

# Check expiring certs
./server/ssl-cert-manager.sh expiry -d 60

# Scan K8s TLS secrets
./server/ssl-cert-manager.sh k8s
```

---

## 📦 Requirements

| Tool | Version | Scripts |
|------|---------|---------|
| Bash | 4.0+ | All |
| Python | 3.6+ | debug-toolkit.py |
| kubectl | Latest | K8s scripts |
| jq | 1.6+ | JSON parsing |
| curl | Any | API calls |
| socat | Any | HAProxy socket |
| openssl | Any | SSL scripts |

---

## 📁 Directory Structure

```
script/
├── lib/             # Shared libraries
├── database/        # Patroni, ClickHouse, Cassandra
├── storage/         # Ceph
├── infrastructure/  # etcd, HAProxy
├── messaging/       # Kafka/Strimzi
├── kubernetes/      # RKE2, K8s, OpenEBS
├── server/          # Health, security, SSL, incident
├── deployment/      # Patching, Ansible
├── monitoring/      # Minio, Loki/Tempo, debug
├── cloud/           # AWS/GCP
└── config/          # Settings
```

---

## 👤 Author

Developed based on production experience managing government infrastructure projects in Indonesia.

---

## 📄 License

MIT License

---

<p align="center">
  <sub>Built for infrastructure automation - Tested on on-premise and cloud environments</sub>
</p>
