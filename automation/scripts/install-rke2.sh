#!/usr/bin/env bash
# Executed by EC2 cloud-init; can also be run manually with ROLE/AWS_REGION/etc set.
set -Eeuo pipefail
trap 'echo "RKE2 setup failed on line ${LINENO}" >&2' ERR
: "${ROLE:?Set ROLE to init-server, join-server, or agent}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${RKE2_VERSION:?Set RKE2_VERSION}"
: "${SERVER_ENDPOINT:?Set SERVER_ENDPOINT}"
: "${TOKEN_PARAMETER:?Set TOKEN_PARAMETER}"
[[ "$(id -u)" == "0" ]] || { echo "Run as root" >&2; exit 1; }
case "$ROLE" in init-server|join-server|agent) ;; *) echo "Invalid ROLE: $ROLE" >&2; exit 1 ;; esac

echo "[$(date -Is)] Starting role=$ROLE RKE2=$RKE2_VERSION"
if [[ -f /etc/rancher/rke2/config.yaml ]]; then
  echo "Existing RKE2 config detected; refusing to overwrite. Check service status manually."
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  dnf install -y awscli-2 || dnf install -y awscli
fi
dnf install -y curl tar gzip iptables conntrack-tools
swapoff -a || true
modprobe br_netfilter || true
cat >/etc/sysctl.d/99-rke2.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
SYSCTL
sysctl --system >/dev/null

# SSM SecureString keeps the join token out of user-data/cloud-init templates.
TOKEN=""
for attempt in $(seq 1 24); do
  if TOKEN="$(aws ssm get-parameter --region "$AWS_REGION" --name "$TOKEN_PARAMETER" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)" && [[ -n "$TOKEN" ]]; then
    break
  fi
  sleep 5
done
[[ "$TOKEN" =~ ^[a-zA-Z0-9]+$ ]] || { echo "Unexpected token format" >&2; exit 1; }
install -d -m 0700 /etc/rancher/rke2
umask 077

if [[ "$ROLE" == "init-server" ]]; then
  cat >/etc/rancher/rke2/config.yaml <<CONFIG
token: "$TOKEN"
tls-san:
  - "$SERVER_ENDPOINT"
write-kubeconfig-mode: "0600"
ingress-controller: traefik
CONFIG
  # RKE2 HelmChartConfig: expose Traefik via hostPorts on both agent nodes.
  install -d -m 0755 /var/lib/rancher/rke2/server/manifests
  cat >/var/lib/rancher/rke2/server/manifests/rke2-traefik-config.yaml <<'TRAEFIK'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-traefik
  namespace: kube-system
spec:
  valuesContent: |-
    deployment:
      kind: DaemonSet
    nodeSelector:
      ingress-ready: "true"
    ports:
      web:
        hostPort: 80
      websecure:
        hostPort: 443
    service:
      enabled: false
TRAEFIK
elif [[ "$ROLE" == "join-server" ]]; then
  cat >/etc/rancher/rke2/config.yaml <<CONFIG
server: "https://$SERVER_ENDPOINT:9345"
token: "$TOKEN"
tls-san:
  - "$SERVER_ENDPOINT"
write-kubeconfig-mode: "0600"
ingress-controller: traefik
CONFIG
else
  cat >/etc/rancher/rke2/config.yaml <<CONFIG
server: "https://$SERVER_ENDPOINT:9345"
token: "$TOKEN"
node-label:
  - "ingress-ready=true"
CONFIG
fi
chmod 0600 /etc/rancher/rke2/config.yaml

if [[ "$ROLE" != "init-server" ]]; then
  echo "Waiting for registration LB port 9345 to become reachable..."
  ready=0
  for attempt in $(seq 1 120); do
    if timeout 3 bash -c "echo > /dev/tcp/$SERVER_ENDPOINT/9345" 2>/dev/null; then
      ready=1; break
    fi
    sleep 10
  done
  [[ "$ready" == "1" ]] || { echo "Registration endpoint unavailable after retries" >&2; exit 1; }
fi

case "$ROLE" in init-server|join-server) INSTALL_RKE2_TYPE=server ;; agent) INSTALL_RKE2_TYPE=agent ;; esac
curl -fsSL https://get.rke2.io -o /tmp/rke2-install.sh
INSTALL_RKE2_VERSION="$RKE2_VERSION" INSTALL_RKE2_TYPE="$INSTALL_RKE2_TYPE" sh /tmp/rke2-install.sh
rm -f /tmp/rke2-install.sh
systemctl daemon-reload
systemctl enable --now "rke2-${INSTALL_RKE2_TYPE}.service"
echo "[$(date -Is)] Started rke2-${INSTALL_RKE2_TYPE}.service"
