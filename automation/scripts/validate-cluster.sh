#!/usr/bin/env bash
set -Eeuo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
export PATH="/var/lib/rancher/rke2/bin:$PATH"
echo '== Versions and nodes =='
kubectl version
kubectl get nodes -o wide
echo '== Health of cluster system =='
kubectl get pods -n kube-system -o wide
echo '== Ingress DaemonSet =='
kubectl get daemonset -n kube-system
echo '== cert-manager =='
kubectl get pods -n cert-manager -o wide || true
echo '== Rancher =='
kubectl get deploy,pods,svc,ingress,certificate -n cattle-system || true
echo '== RKE2 nodes with ingress label =='
kubectl get nodes -l ingress-ready=true --show-labels
