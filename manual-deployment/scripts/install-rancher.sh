#!/usr/bin/env bash
# Install Rancher by Helm on the *dedicated, healthy RKE2 management cluster*.
# sudo bash install-rancher.sh rancher.example.com admin@example.com RANCHER_CHART_VERSION CERT_MANAGER_CHART_VERSION
set -Eeuo pipefail
set +x
[[ "$EUID" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ "$#" -eq 4 ]] || {
  echo "Usage: sudo bash $0 RANCHER_FQDN ACME_EMAIL RANCHER_CHART_VERSION CERT_MANAGER_CHART_VERSION" >&2
  exit 2
}
hostname="$1"; email="$2"; rancher_version="$3"; cert_version="$4"
[[ "$hostname" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "Invalid public Rancher DNS hostname" >&2; exit 2; }
[[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo "Invalid ACME email" >&2; exit 2; }
[[ "$rancher_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Rancher version must be pinned (e.g. 2.x.y)" >&2; exit 2; }
[[ "$cert_version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "cert-manager version must be pinned (e.g. v1.x.y)" >&2; exit 2; }
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="/var/lib/rancher/rke2/bin:$PATH"
command -v helm >/dev/null || { echo "Install Helm v3 and place helm on PATH first" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found: check RKE2 management cluster" >&2; exit 1; }
kubectl cluster-info
kubectl get nodes -o wide
ready_servers="$(kubectl get nodes --no-headers | awk '$2=="Ready" && $3 ~ /control-plane/ {c++} END{print c+0}')"
[[ "$ready_servers" -ge 3 ]] || { echo "Need three Ready management control-plane nodes before Rancher deployment; found $ready_servers" >&2; exit 1; }

echo "Checking ingress class and load balancer. Operator must have verified host 80/443 routing and DNS."
kubectl get ingressclass
kubectl get ingressclass traefik >/dev/null 2>&1 || { echo "This script expects Traefik ingress class. Adjust for your supported ingress controller." >&2; exit 1; }

helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
helm repo update jetstack rancher-stable

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "$cert_version" \
  --set crds.enabled=true --wait --timeout 15m
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=10m

helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system --create-namespace \
  --version "$rancher_version" \
  --set-string "hostname=$hostname" \
  --set-string ingress.ingressClassName=traefik \
  --set-string ingress.tls.source=letsEncrypt \
  --set-string "letsEncrypt.email=$email" \
  --set-string letsEncrypt.ingress.class=traefik \
  --set replicas=3 --wait --timeout 20m

kubectl -n cattle-system rollout status deployment/rancher --timeout=15m
kubectl -n cattle-system get pods,ingress,certificate
echo "Open https://$hostname only after certificate validation succeeds."
echo "To retrieve Rancher's initial password, consult the Rancher installation docs and bootstrap-secret."
