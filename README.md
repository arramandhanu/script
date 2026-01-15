# 🛠️ Infrastructure Scripts Collection

[![Shell](https://img.shields.io/badge/Shell-Bash%204.0%2B-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Python](https://img.shields.io/badge/Python-3.6%2B-3776AB?style=flat-square&logo=python&logoColor=white)](https://www.python.org/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-RKE2-326CE5?style=flat-square&logo=kubernetes&logoColor=white)](https://docs.rke2.io/)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)](https://www.linux.org/)

Production-ready automation scripts for DevOps engineers managing **VMware servers** with **RKE2 Kubernetes** clusters.

---

## 📋 Table of Contents

- [Features](#-features)
- [Quick Start](#-quick-start)
- [Scripts Overview](#-scripts-overview)
- [Configuration](#-configuration)
- [Usage Examples](#-usage-examples)
- [Requirements](#-requirements)
- [Contributing](#-contributing)

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🔍 **Health Checks** | Comprehensive cluster and server monitoring |
| 🔧 **Troubleshooting** | Interactive debugging tools for K8s and Linux |
| 🔒 **Security Audit** | CIS benchmark compliance checking |
| 📦 **Storage Management** | OpenEBS and Minio monitoring |
| 🚀 **Deployment** | Rolling patches with K8s awareness |
| 📝 **Logging** | Centralized logging with color output |
| ⚡ **Dry-Run Mode** | Preview changes before applying |
| 🌐 **Remote Execution** | Run scripts on remote hosts via SSH |

---

## 🚀 Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/your-repo/script.git
cd script
```

### 2. Configure Environment

```bash
# Copy sample config
cp config/settings.env.example config/settings.env

# Edit with your values
vim config/settings.env
```

### 3. Make Scripts Executable

```bash
chmod +x kubernetes/*.sh server/*.sh deployment/*.sh monitoring/*.sh monitoring/*.py lib/*.sh
```

### 4. Run Your First Script

```bash
# Check server health
./server/vm-health-check.sh

# Check K8s cluster health
./kubernetes/rke2-cluster-health.sh -e dev
```

---

## 📁 Scripts Overview

### 🐳 Kubernetes

| Script | Description | Usage |
|--------|-------------|-------|
| [`rke2-cluster-health.sh`](kubernetes/rke2-cluster-health.sh) | RKE2 cluster health check | `./kubernetes/rke2-cluster-health.sh -e prod -v` |
| [`k8s-troubleshoot.sh`](kubernetes/k8s-troubleshoot.sh) | Interactive troubleshooting | `./kubernetes/k8s-troubleshoot.sh` |
| [`openebs-storage-audit.sh`](kubernetes/openebs-storage-audit.sh) | OpenEBS storage monitoring | `./kubernetes/openebs-storage-audit.sh -c` |

### 🖥️ Server Management

| Script | Description | Usage |
|--------|-------------|-------|
| [`vm-health-check.sh`](server/vm-health-check.sh) | Server health check | `./server/vm-health-check.sh -r server01` |
| [`server-network-route.sh`](server/server-network-route.sh) | Network route manager | `./server/server-network-route.sh add` |
| [`security-hardening-audit.sh`](server/security-hardening-audit.sh) | CIS security audit | `./server/security-hardening-audit.sh -o report.txt` |

### 🚢 Deployment

| Script | Description | Usage |
|--------|-------------|-------|
| [`rolling-patch.sh`](deployment/rolling-patch.sh) | K8s-aware rolling patches | `./deployment/rolling-patch.sh -t server01 -d` |
| [`ansible-wrapper.sh`](deployment/ansible-wrapper.sh) | Ansible deployment wrapper | `./deployment/ansible-wrapper.sh -e staging deploy.yml` |

### 📊 Monitoring

| Script | Description | Usage |
|--------|-------------|-------|
| [`minio-health.sh`](monitoring/minio-health.sh) | Minio cluster health | `./monitoring/minio-health.sh -v` |
| [`debug-toolkit.py`](monitoring/debug-toolkit.py) | Interactive debug toolkit | `./monitoring/debug-toolkit.py -n default` |

### ☁️ Cloud

| Script | Description | Usage |
|--------|-------------|-------|
| [`cloud-disk-resize.sh`](cloud/cloud-disk-resize.sh) | AWS/GCP disk resize | `./cloud/cloud-disk-resize.sh` |

---

## ⚙️ Configuration

### Environment Variables

Create your configuration file:

```bash
cp config/settings.env.example config/settings.env
```

Key settings:

```bash
# Kubernetes environments
KUBECONFIG_DEV=~/.kube/config-dev
KUBECONFIG_STAGING=~/.kube/config-staging
KUBECONFIG_PROD=~/.kube/config-prod

# Minio
MINIO_ENDPOINT=https://minio.example.com
MINIO_ACCESS_KEY=your-access-key
MINIO_SECRET_KEY=your-secret-key

# Thresholds
CPU_WARN=80
MEM_WARN=80
DISK_WARN=80

# Notifications
WEBHOOK_URL=https://hooks.slack.com/services/xxx
```

### Directory Structure

```
script/
├── 📁 lib/                  # Shared libraries
│   ├── common.sh            # Colors, logging, validation
│   └── k8s-helpers.sh       # K8s/RKE2 helper functions
├── 📁 kubernetes/           # K8s management scripts
├── 📁 server/               # Server management scripts
├── 📁 deployment/           # Deployment automation
├── 📁 monitoring/           # Monitoring and debugging
├── 📁 cloud/                # Cloud provider scripts
├── 📁 config/               # Configuration files
│   ├── settings.env         # Your configuration
│   └── settings.env.example # Sample configuration
└── README.md
```

---

## 📖 Usage Examples

### Health Checks

```bash
# Local server health check
./server/vm-health-check.sh

# Remote server health check
./server/vm-health-check.sh -r server01.example.com

# Kubernetes cluster health (verbose)
./kubernetes/rke2-cluster-health.sh -e prod -v

# Kubernetes cluster health (JSON output)
./kubernetes/rke2-cluster-health.sh -e prod -j
```

### Troubleshooting

```bash
# Interactive K8s troubleshooting
./kubernetes/k8s-troubleshoot.sh -e staging

# Interactive debug toolkit
./monitoring/debug-toolkit.py

# Debug toolkit for specific namespace
./monitoring/debug-toolkit.py -n kube-system
```

### Security Audit

```bash
# Local security audit
./server/security-hardening-audit.sh

# Remote audit with report
./server/security-hardening-audit.sh -r server01 -o audit_$(date +%Y%m%d).txt
```

### Patching

```bash
# Dry-run patch (preview only)
./deployment/rolling-patch.sh -t server01 -d

# Patch single host
./deployment/rolling-patch.sh -t server01

# Patch host group
./deployment/rolling-patch.sh -g webservers

# Patch without reboot
./deployment/rolling-patch.sh -t server01 --skip-reboot
```

### Storage Management

```bash
# OpenEBS storage audit
./kubernetes/openebs-storage-audit.sh -e dev

# OpenEBS cleanup mode (dry-run)
./kubernetes/openebs-storage-audit.sh -c -d

# Minio health check (verbose)
./monitoring/minio-health.sh -v
```

---

## 📦 Requirements

### System Requirements

| Requirement | Version | Required For |
|-------------|---------|--------------|
| Bash | 4.0+ | All scripts |
| Python | 3.6+ | debug-toolkit.py |
| kubectl | Latest | K8s scripts |
| mc | Latest | minio-health.sh |
| jq | 1.6+ | JSON parsing |
| ssh | Any | Remote execution |

### Installation

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install -y jq bc
```

**Rocky/RHEL:**
```bash
sudo yum install -y jq bc
```

**Minio Client:**
```bash
curl -O https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/
```

---

## 🤝 Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/new-script`)
3. Follow the existing code style
4. Use shared library functions from `lib/common.sh`
5. Add help text (Usage section in header)
6. Support dry-run mode where applicable
7. Test on both Ubuntu and Rocky Linux
8. Commit your changes (`git commit -m 'Add new script'`)
9. Push to the branch (`git push origin feature/new-script`)
10. Open a Pull Request

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 👤 Author

**DevOps Infrastructure Team**

- Designed for production environments
- Tested on 71+ VMware servers
- RKE2 Kubernetes ready

---

<p align="center">
  <sub>Built with ❤️ for infrastructure automation</sub>
</p>
