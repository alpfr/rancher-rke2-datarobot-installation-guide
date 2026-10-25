#!/usr/bin/env bash
# Register a FRESH EC2 node in a Rancher-created custom RKE2 cluster.
# Do not run this on Rancher's "local" management-cluster nodes or on imported RKE2 nodes.
# Usage: sudo bash register-node.sh control-plane https://rancher.example.com [private_ip]
#        sudo bash register-node.sh worker https://rancher.example.com [private_ip]
set -Eeuo pipefail
set +x
umask 077
trap 'echo "Registration failed on line ${LINENO}" >&2' ERR

[[ "$EUID" -eq 0 ]] || { echo "Run as root (sudo bash ...)" >&2; exit 1; }
[[ "$#" -ge 2 && "$#" -le 3 ]] || {
  echo "Usage: sudo bash $0 control-plane|worker https://rancher.example.com [private_ip]" >&2
  exit 2
}
role="$1"
rancher_url="${2%/}"
internal_ip="${3:-}"
case "$role" in
  control-plane|worker) ;;
  *) echo "Unknown role: $role" >&2; exit 2 ;;
esac
[[ "$rancher_url" =~ ^https://[a-zA-Z0-9][a-zA-Z0-9.-]+(:443)?$ ]] || {
  echo "Provide the trusted HTTPS Rancher URL with no path, e.g. https://rancher.example.com" >&2
  exit 2
}
if [[ -n "$internal_ip" ]] && ! [[ "$internal_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
  echo "Expected an IPv4 private IP address" >&2; exit 2
fi

# Never co-install the provisioning agent over a pre-existing RKE2 installation.
if [[ -e /etc/rancher/rke2/config.yaml || -d /var/lib/rancher/rke2 || -e /etc/rancher/agent/config.yaml ]] || \
   systemctl list-unit-files rancher-system-agent.service rke2-server.service rke2-agent.service --no-legend 2>/dev/null | grep -q -E '^(rancher-system-agent|rke2-server|rke2-agent)\.service'; then
  echo "Existing RKE2 or Rancher agent detected. Refusing to install. See the imported-cluster path in README.md." >&2
  exit 1
fi
command -v curl >/dev/null || { echo "Install curl first" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "This helper expects a systemd Linux node" >&2; exit 1; }
echo "Registering role=$role with $rancher_url"
echo "Get a token for this exact cluster from Rancher > Cluster Management > Custom Cluster > Registration."
echo "The token is sensitive. It will not be written to a file or echoed."
if [[ ! -r /dev/tty ]]; then
  echo "An interactive terminal is required to enter the registration token." >&2
  exit 1
fi
read -r -s -p "Paste the Rancher-generated node registration token: " rancher_token </dev/tty
printf '\n' >/dev/tty
[[ -n "$rancher_token" ]] || { echo "Empty registration token" >&2; exit 1; }
read -r -p "CA checksum from Rancher command (leave blank for publicly trusted TLS): " ca_checksum </dev/tty
if [[ -n "$ca_checksum" && ! "$ca_checksum" =~ ^[A-Fa-f0-9]{64}$ ]]; then
  echo "CA checksum should be a 64-character SHA256 hex digest" >&2; exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"; unset rancher_token' EXIT
# TLS validation is mandatory. Import your corporate CA into the system trust store before retrying.
curl --fail --silent --show-error --location --retry 3 \
  "$rancher_url/system-agent-install.sh" \
  --output "$tmp_dir/system-agent-install.sh"
[[ -s "$tmp_dir/system-agent-install.sh" ]] || { echo "Empty Rancher installer" >&2; exit 1; }
args=(--server "$rancher_url" --token "$rancher_token")
if [[ -n "$ca_checksum" ]]; then args+=(--ca-checksum "$ca_checksum"); fi
if [[ -n "$internal_ip" ]]; then args+=(--internal-address "$internal_ip"); fi
case "$role" in
  control-plane) args+=(--etcd --controlplane) ;;
  worker) args+=(--worker) ;;
esac
# This installs Rancher System Agent. Rancher later creates rke2-server/rke2-agent.
sh "$tmp_dir/system-agent-install.sh" "${args[@]}"
echo "Installation initiated. Rancher should reconcile the provisioning plan."
systemctl status rancher-system-agent --no-pager -l || true
echo "Check Rancher Cluster Management for cluster status (Provisioning -> Active)."
echo "On this node: sudo journalctl -u rancher-system-agent -f"
