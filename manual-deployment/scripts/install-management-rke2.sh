#!/usr/bin/env bash
# Install RKE2 on a clean, separately provisioned Rancher MANAGEMENT cluster EC2 host.
# First control plane: sudo bash install-management-rke2.sh init-server rke2-mgmt.internal 'vX.Y.Z+rke2rN'
# Other control planes: sudo bash install-management-rke2.sh join-server rke2-mgmt.internal 'vX.Y.Z+rke2rN' /root/rke2-join-token
# Optional management worker: sudo bash install-management-rke2.sh agent rke2-mgmt.internal 'vX.Y.Z+rke2rN' /root/rke2-join-token
set -Eeuo pipefail
set +x
umask 077
trap 'echo "RKE2 setup failed at line ${LINENO}" >&2' ERR

[[ "$EUID" -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
if [[ "$#" -lt 3 || "$#" -gt 4 ]]; then
  echo "Usage: sudo bash $0 init-server|join-server|agent LB_DNS RKE2_VERSION [TOKEN_FILE]" >&2
  exit 2
fi
role="$1"
endpoint="$2"
version="$3"
token_file="${4:-}"
case "$role" in init-server|join-server|agent) ;; *) echo "Unknown role: $role" >&2; exit 2 ;; esac
[[ "$endpoint" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+$ ]] || { echo "Invalid NLB hostname" >&2; exit 2; }
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+rke2r[0-9]+$ ]] || { echo "Pin a full RKE2 version, e.g. v1.36.5+rke2r1" >&2; exit 2; }
if [[ "$role" != init-server ]]; then
  [[ -f "$token_file" && -r "$token_file" ]] || { echo "Readable root-protected token file required for joining." >&2; exit 2; }
fi

if [[ -e /etc/rancher/rke2/config.yaml || -e /var/lib/rancher/rke2/server/node-token ]] ||
   systemctl list-unit-files rke2-server.service rke2-agent.service --no-legend 2>/dev/null | grep -q -E '^(rke2-server|rke2-agent)\.service'; then
  echo "Existing RKE2 configuration detected; refusing to modify an installed node." >&2
  exit 1
fi
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v systemctl >/dev/null || { echo "systemd is required" >&2; exit 1; }
install -d -m 0700 /etc/rancher/rke2
config=/etc/rancher/rke2/config.yaml
if [[ "$role" == init-server ]]; then
  # The bootstrap node will generate /var/lib/rancher/rke2/server/node-token.
  printf 'tls-san:\n  - "%s"\nwrite-kubeconfig-mode: "0600"\n' "$endpoint" > "$config"
else
  token="$(head -n 1 "$token_file")"
  [[ "$token" =~ ^[A-Za-z0-9:_=-]+$ ]] || { echo "Invalid token format in token file." >&2; exit 1; }
  printf 'server: "https://%s:9345"\ntoken: "%s"\n' "$endpoint" "$token" > "$config"
  if [[ "$role" == join-server ]]; then
    printf 'tls-san:\n  - "%s"\nwrite-kubeconfig-mode: "0600"\n' "$endpoint" >> "$config"
  fi
  unset token
fi
chmod 0600 "$config"
if [[ "$role" == agent ]]; then
  install_type=agent
else
  install_type=server
fi

installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT
curl -fsSL --retry 3 https://get.rke2.io -o "$installer"
INSTALL_RKE2_VERSION="$version" INSTALL_RKE2_TYPE="$install_type" sh "$installer"
systemctl daemon-reload
systemctl enable --now "rke2-$install_type.service"
echo "RKE2 $version service started: rke2-$install_type"
echo 'Run: sudo systemctl status rke2-server --no-pager -l (server) or rke2-agent (worker)'
if [[ "$role" == init-server ]]; then
  echo "After bootstrap, copy the token from /var/lib/rancher/rke2/server/node-token"
  echo "to a root-only file on each joining MANAGEMENT node using a secure channel."
fi
