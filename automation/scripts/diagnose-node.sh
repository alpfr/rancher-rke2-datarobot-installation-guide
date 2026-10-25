#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$(id -u)" == "0" ]] || { echo 'Run as root' >&2; exit 1; }
echo '== Cloud-init status =='
cloud-init status --long || true
echo '== Bootstrap output =='
tail -n 100 /var/log/rke2-bootstrap.log 2>/dev/null || true
echo '== Service states =='
for svc in rke2-server rke2-agent rancher-system-agent; do
  systemctl is-active "$svc" 2>/dev/null || true
  journalctl -u "$svc" -n 50 --no-pager 2>/dev/null || true
done
echo '== RKE2 config with secrets redacted =='
if [[ -r /etc/rancher/rke2/config.yaml ]]; then
  sed -E 's/^(token:[[:space:]]*).*/\1[REDACTED]/' /etc/rancher/rke2/config.yaml
fi
echo '== Listening ports =='
ss -lntp | grep -E ':(9345|6443|80|443)\b' || true
