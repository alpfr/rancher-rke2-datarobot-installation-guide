#!/usr/bin/env bash
# Run on server-1 after all RKE2 nodes and Traefik are Ready.
# Usage: sudo bash install-rancher.sh rancher.example.com admin@example.com
set -Eeuo pipefail
if [[ "$(id -u)" != "0" ]]; then echo "Run as root" >&2; exit 1; fi
HOSTNAME="${1:?Usage: sudo bash install-rancher.sh FQDN ACME_EMAIL}"
ACME_EMAIL="${2:?Usage: sudo bash install-rancher.sh FQDN ACME_EMAIL}"
RANCHER_VERSION="${RANCHER_VERSION:-2.15.2}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"
HELM_VERSION="${HELM_VERSION:-v3.19.0}"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH="/var/lib/rancher/rke2/bin:$PATH"
command -v kubectl >/dev/null || { echo "kubectl missing; install RKE2 first" >&2; exit 1; }

if ! command -v helm >/dev/null 2>&1; then
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o "$tmpdir/helm.tar.gz"
  tar -xzf "$tmpdir/helm.tar.gz" -C "$tmpdir"
  install -m 0755 "$tmpdir/linux-amd64/helm" /usr/local/bin/helm
fi

kubectl get nodes -o wide
kubectl -n kube-system rollout status daemonset/rke2-traefik --timeout=15m

helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "$CERT_MANAGER_VERSION" \
  --set crds.enabled=true --wait --timeout 15m
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=5m

helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
helm repo update rancher-stable
kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --version "$RANCHER_VERSION" \
  --set-string "hostname=$HOSTNAME" \
  --set-string ingress.ingressClassName=traefik \
  --set ingress.tls.source=letsEncrypt \
  --set-string "letsEncrypt.email=$ACME_EMAIL" \
  --set-string letsEncrypt.ingress.class=traefik \
  --set replicas=3 \
  --wait --timeout 20m
kubectl -n cattle-system rollout status deployment/rancher --timeout=10m
kubectl -n cattle-system get ingress,certificates,pods
printf '\nRancher URL: https://%s\n' "$HOSTNAME"
printf 'To get initial bootstrap password, run:\n'
printf "kubectl -n cattle-system get secret bootstrap-secret -o jsonpath='{.data.bootstrapPassword}' | base64 -d; echo\n"
