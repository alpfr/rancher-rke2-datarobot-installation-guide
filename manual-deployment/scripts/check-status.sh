#!/usr/bin/env bash
# Run on a management RKE2 server, after both Rancher and the cluster are installed.
set -Eeuo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
export PATH="/var/lib/rancher/rke2/bin:$PATH"
echo '== RKE2 node health =='
kubectl get nodes -o wide
echo '== System pod health =='
kubectl get pods -n kube-system -o wide
echo '== Ingress class =='
kubectl get ingressclass
echo '== Rancher and cert-manager =='
kubectl get pods -n cert-manager -o wide || true
kubectl get deploy,pods,ingress,certificate -n cattle-system || true
echo '== Kubernetes API readiness =='
kubectl get --raw='/readyz' || true
echo
echo '== Troubleshooting =='
echo 'sudo journalctl -u rke2-server -n 100 --no-pager'
echo 'sudo journalctl -u rancher-system-agent -n 100 --no-pager  # downstream custom nodes'
