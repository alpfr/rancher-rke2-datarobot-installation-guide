# Deploying DataRobot on AWS EC2 using Rancher and RKE2

This repository contains architectural blueprints, configuration files, and step-by-step guidelines for deploying the DataRobot Enterprise AI Platform on self-managed **RKE2 (Rancher Kubernetes Engine 2)** clusters running on **AWS EC2** instances, managed via **SUSE Rancher**.

---

## 1. High-Level Architecture Overview

In an enterprise-grade AWS deployment, the management plane (Rancher) is separated from the application workloads (DataRobot) to minimize the blast radius and ensure operational stability.

```
                           ┌────────────────────────┐
                           │      BASTION HOST      │
                           │  • SSH Tunneling       │
                           │  • kubectl / helm      │
                           │  • Rancher Server      │
                           └────────────────────────┘
                                       │
                         Provisions & Manages Cluster
                                       │
                                       ▼
┌────────────────────────────────────────────────────────────────────────┐
│                        RKE2 DEV CLUSTER (AWS EC2)                      │
│                                                                        │
│  ┌───────────────────────┐                  ┌───────────────────────┐  │
│  │     CONTROL PLANE     │                  │     WORKER NODES      │  │
│  │ (3x EC2: HA Control)  │                  │ (3x EC2: Workloads)   │  │
│  │ • rke2-server         │                  │ • rke2-agent          │  │
│  │ • etcd                │                  │ • DataRobot Pods only │  │
│  └───────────────────────┘                  └───────────────────────┘  │
└────────────────────────────────────────────────────────────────────────┘
```

### RKE2 vs. Rancher Roles
*   **RKE2:** The underlying Kubernetes distribution running directly on the EC2 instances. Hardened by default (aligned with CIS Benchmarks and DISA STIG).
*   **Rancher:** The management dashboard. It runs as a controller (either on the Bastion or a separate system cluster) to orchestrate cluster deployment, upgrades, and RBAC.

---

## 2. Infrastructure Prerequisites (AWS)

Before initializing RKE2, ensure your AWS security groups and routing are configured.

### 2.1 Security Group Configuration
Open the following ports on the respective RKE2 instances:

| Port / Protocol | Source | Purpose | Required Nodes |
| :--- | :--- | :--- | :--- |
| **`6443` (TCP)** | Bastion, NLB, Workers | Kubernetes API Server | Control Plane Nodes |
| **`9345` (TCP)** | NLB, Workers, Control Plane | RKE2 Node Supervisor API | Control Plane Nodes |
| **`2379-2380` (TCP)** | Control Plane Nodes | `etcd` peer communication | Control Plane Nodes only |
| **`10250` (TCP)** | Control Plane Nodes | Kubelet metrics / logs | All Nodes |
| **`4789` (UDP)** | All Nodes | Canal/Calico VXLAN overlay network | All Nodes |

### 2.2 AWS Network Load Balancer (NLB)
Create an internal AWS NLB to proxy traffic to your 3 Control Plane nodes:
*   **Listener 1:** TCP `6443` (targets: 3 Control Plane IPs)
*   **Listener 2:** TCP `9345` (targets: 3 Control Plane IPs)
*   *Assumption DNS:* `rke2-api.dev.internal`

### 2.3 IAM Instance Profile Requirements
Ensure the EC2 instances have an IAM Role attached permitting out-of-tree AWS integrations:
*   **Cloud Controller Manager (CCM):** Permissions for EC2 queries, target group attachments, and ELB provisioning.
*   **EBS CSI Driver:** Permissions to create, attach, detach, and delete EBS volumes (`gp3`).
*   **AWS Resource Tag:** Ensure all VPC, Subnet, and EC2 resources are tagged:
    *   *Key:* `kubernetes.io/cluster/<cluster-id>`
    *   *Value:* `owned` (or `shared`)

---

## 3. RKE2 Cluster Sizing & Node Pools

For a standard Dev environment, deploy across 6 nodes + 1 Bastion:

*   **Bastion Host (1x):** Used for running administration tools (`kubectl`, `helm`, `aws-cli`) and hosting the Rancher Server container.
*   **Control Plane / Master Nodes (3x):** `m5.xlarge` or `m5.2xlarge` instances running `rke2-server` with etcd replication.
*   **Worker Nodes (3x):** `m5.4xlarge` or `r5.4xlarge` instances running `rke2-agent` to host the resource-intensive DataRobot workloads.

---

## 4. Step-by-Step RKE2 Cluster Provisioning

### 4.1 Initialize the Primary Control Plane Node (`cp-1`)
1. Create the configuration directory:
   ```bash
   sudo mkdir -p /etc/rancher/rke2/
   ```
2. Write the configuration `/etc/rancher/rke2/config.yaml`:
   ```yaml
   token: "DevSecretTokenRKE2-9988"
   tls-san:
     - "rke2-api.dev.internal"  # Load Balancer DNS
     - "10.0.1.11"               # Local IP of cp-1
   cloud-provider-name: "external"
   ```
3. Run the installer:
   ```bash
   curl -sfL https://get.rke2.io | sh -
   ```
4. Start the service:
   ```bash
   sudo systemctl enable rke2-server.service
   sudo systemctl start rke2-server.service
   ```

### 4.2 Join Nodes 2 & 3 (`cp-2` & `cp-3`) to the Control Plane
1. Write the configuration `/etc/rancher/rke2/config.yaml` on `cp-2` and `cp-3`:
   ```yaml
   server: "https://10.0.1.11:9345" # Initializing node IP or NLB DNS
   token: "DevSecretTokenRKE2-9988"
   tls-san:
     - "rke2-api.dev.internal"
     - "10.0.1.12"                  # (Use 10.0.1.13 on cp-3)
   cloud-provider-name: "external"
   ```
2. Install and run:
   ```bash
   curl -sfL https://get.rke2.io | sh -
   sudo systemctl enable rke2-server.service
   sudo systemctl start rke2-server.service
   ```

### 4.3 Join the Worker Nodes
1. Write `/etc/rancher/rke2/config.yaml` on each worker node:
   ```yaml
   server: "https://rke2-api.dev.internal:9345" # Points to Load Balancer
   token: "DevSecretTokenRKE2-9988"
   cloud-provider-name: "external"
   ```
2. Install the RKE2 **agent**:
   ```bash
   curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" sh -
   ```
3. Start the agent:
   ```bash
   sudo systemctl enable rke2-agent.service
   sudo systemctl start rke2-agent.service
   ```

---

## 5. DataRobot Helm Deployment Guide

Once the RKE2 cluster is verified and running, deploy the DataRobot platform from your Bastion host.

### 5.1 Configure Kubernetes Secrets
Create the required namespace and secret files:
```bash
kubectl create namespace datarobot

# 1. Platform License (from DataRobot SA)
kubectl -n datarobot create secret generic datarobot-license \
  --from-file=license=./license.key

# 2. Image Registry Pull Secret
kubectl -n datarobot create secret docker-registry datarobot-regcred \
  --docker-server=registry-1.docker.io \
  --docker-username="<YOUR_DOCKERHUB_USERNAME>" \
  --docker-password="<YOUR_DOCKERHUB_PASSWORD>"
```

### 5.2 Download the Helm Chart
DataRobot's Helm chart is distributed via OCI on Docker Hub.

1. Authenticate Helm:
   ```bash
   echo "<YOUR_DOCKERHUB_PASSWORD>" | helm registry login registry-1.docker.io \
     -u "<YOUR_DOCKERHUB_USERNAME>" \
     --password-stdin
   ```
2. Pull the chart locally:
   ```bash
   helm pull oci://registry-1.docker.io/datarobot/datarobot --version 11.11.0
   tar -zxvf datarobot-11.11.0.tgz
   ```

### 5.3 Configure Helm `values.yaml`
Modify your `values.yaml` to point to the AWS storage integrations:

```yaml
global:
  imageRegistry: "registry-1.docker.io"
  imagePullSecrets:
    - name: "datarobot-regcred"

# AWS Storage Configuration
storageClass: "datarobot-gp3"  # Created using EBS CSI Driver

# AWS S3 for Object Storage
blobStorage:
  gcs:
    enabled: false
  s3:
    enabled: true
    bucket: "datarobot-artifacts-bucket"
    region: "us-east-1"
```

### 5.4 Install
```bash
helm upgrade --install datarobot ./datarobot \
  --namespace datarobot \
  -f my-values.yaml
```

---

## 6. Workarounds for Restricted/Air-Gapped Environments

If your EC2 instances cannot access the internet to download the Helm chart, binary files, or container images:

### Option A: Local Download & SFTP Transit
1. Run `helm pull` on an internet-enabled local laptop.
2. Transfer the `.tgz` file to the Bastion host via `scp`:
   ```bash
   scp -i key.pem datarobot-11.11.0.tgz ec2-user@<bastion-ip>:/home/ec2-user/
   ```
3. Deploy directly on RKE2 using the local file.

### Option B: HTTP Forward Proxy Config
Export the proxy details on your RKE2 nodes so the installer and Helm can route traffic:
```bash
export HTTP_PROXY="http://proxy.internal:8080"
export HTTPS_PROXY="http://proxy.internal:8080"
export NO_PROXY="localhost,127.0.0.1,169.254.169.254,10.0.0.0/8,.internal"
```

### Option C: S3-Based Private Helm Repository
Host the Helm chart internally in a private S3 bucket:
1. Initialize the S3 Helm plugin on the Bastion:
   ```bash
   helm plugin install https://github.com/hypnoglow/helm-s3.git
   ```
2. Add the bucket as a repo:
   ```bash
   helm repo add company-charts s3://company-private-helm-repo/charts
   ```
3. Fetch updates and install:
   ```bash
   helm repo update
   helm upgrade --install datarobot company-charts/datarobot -n datarobot -f my-values.yaml
   ```

### Option D: JFrog Artifactory Repository Mirror (Restricted Outbound curl)
If you cannot download the RKE2 binaries from GitHub/get.rke2.io, you can host them in an internal JFrog Artifactory Generic Repository and use it as a mirror.

#### 1. Upload RKE2 Binaries to JFrog Generic Repository
In JFrog Artifactory, create a Generic repository (e.g., `rke2-generic-local`). Upload the following files matching RKE2's structure (available on an internet-connected host from the RKE2 releases page):
```text
rke2-generic-local/
  └── v1.28.4+rke2r1/
        ├── rke2.linux-amd64.tar.gz
        └── sha256sum-amd64.txt
```
Also upload the `install.sh` installation script (originally retrieved from `https://get.rke2.io`) to `rke2-generic-local/install.sh`.

#### 2. Execute RKE2 Installation on EC2 from JFrog
On your restricted EC2 instance, execute the installer pointing to your JFrog Artifactory endpoints:

```bash
# 1. Download the install.sh script from your JFrog instance
curl -u <jfrog_username>:<jfrog_api_key> \
  -L "https://artifactory.company.internal/artifactory/rke2-generic-local/install.sh" \
  -o install.sh

# 2. Execute RKE2 install, forcing the script to download binaries from your JFrog repository
export INSTALL_RKE2_ARTIFACT_URL="https://artifactory.company.internal/artifactory/rke2-generic-local"
sudo -E sh install.sh
```

#### 3. JFrog Artifactory Docker Registry Mirroring for RKE2 & DataRobot Images
Configure your RKE2 cluster to mirror public container registries (Docker Hub, etc.) to your private JFrog Docker repository:

1. Create `/etc/rancher/rke2/registries.yaml` on all nodes:
   ```yaml
   mirrors:
     docker.io:
       endpoint:
         - "https://artifactory.company.internal/artifactory/api/docker/docker-local/"
     registry-1.docker.io:
       endpoint:
         - "https://artifactory.company.internal/artifactory/api/docker/docker-local/"
   
   configs:
     "artifactory.company.internal":
       auth:
         username: "<YOUR_JFROG_USERNAME>"
         password: "<YOUR_JFROG_API_KEY>"
   ```
2. Restart the RKE2 service to apply the registry configuration:
   ```bash
   sudo systemctl restart rke2-server  # (or rke2-agent on worker nodes)
   ```

