# Rancher and RKE2 installation without Terraform

**Preferred workflow:** manually provision AWS EC2 Linux instances (or use your existing fleet), install a **separate Rancher management cluster** with RKE2 shell scripts, install Rancher via Helm, and use **Rancher's own Custom RKE2 provisioning** to register the DataRobot downstream cluster. **Terraform is not required.**

## Architecture and implementation order

| Phase | Target | Installation action | Gate |
|---|---|---|---|
| 1 | AWS EC2 | Provision 3 management RKE2 control-plane hosts, a stable **private** TCP NLB for ports 9345/6443, and a **public** ingress load balancer and Rancher DNS | Instances, routes, security groups, SSM/SSH access and TLS DNS reachable |
| 2 | Management cp-01 | Execute `scripts/install-management-rke2.sh init-server` | rke2-server running; join token available |
| 3 | Management cp-02/03 | Copy join token securely; run `scripts/install-management-rke2.sh join-server` | Three management control-plane nodes Ready |
| 4 | Management cluster | Configure supported ingress controller and route external LB 80/443 to ingress; verify ingress and DNS | `kubectl get ingressclass`, LB health and DNS checks pass |
| 5 | Management cp-01 | Install Helm 3, run `scripts/install-rancher.sh` with pinned compatible chart versions | cert-manager/Rancher Ready, valid TLS, Rancher URL loads |
| 6 | Fresh downstream EC2 | Provision **3 control-plane and 2/3 worker** instances with no RKE2 present | Network reachability, no preinstalled RKE2 |
| 7 | Rancher UI | Cluster Management → Create → Custom (RKE2); choose version | Cluster registration commands issued |
| 8 | Downstream cp-01/02/03 | Register with **etcd + controlplane** flags from Rancher | Control plane initialized and Ready |
| 9 | Downstream worker nodes | Register with **worker** flag from Rancher | All workers Ready |
| 10 | Management + downstream | Run validation, configure DataRobot prereqs, storage, image registry and backups | Rancher Active, application ready |

Rancher's management RKE2 nodes become the **local** cluster automatically. **Do not register them again with Rancher System Agent.** Downstream nodes configured via Rancher Custom RKE2 **must not** be preinstalled with RKE2; the system agent installs RKE2 itself.

## Example management RKE2 commands (on clean EC2 instances)

Choose and explicitly pin one version supported by the target Rancher release; do not change it casually on existing nodes. For instance, substitute `vX.Y.Z+rke2rN` with your approved version. The private NLB DNS must be stable and resolvable from all management nodes.

On management cp-01:

~~~bash
sudo bash scripts/install-management-rke2.sh init-server rke2-mgmt.internal 'vX.Y.Z+rke2rN'
sudo systemctl status rke2-server --no-pager -l
sudo cat /var/lib/rancher/rke2/server/node-token
~~~

**Keep the join token secret.** Place it securely in `/root/rke2-join-token` on cp-02 and cp-03 with permissions `0600`; never commit it or store it in shell history.

On each additional management control-plane node:

~~~bash
sudo bash scripts/install-management-rke2.sh join-server rke2-mgmt.internal 'vX.Y.Z+rke2rN' /root/rke2-join-token
~~~

Optional management worker node, if one was separately provisioned:

~~~bash
sudo bash scripts/install-management-rke2.sh agent rke2-mgmt.internal 'vX.Y.Z+rke2rN' /root/rke2-join-token
~~~

Check nodes on management cp-01:

~~~bash
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes -o wide
~~~

## Install Rancher on management cluster

Before installing, configure an ingress controller compatible with your RKE2 release (the script expects ingress class **traefik**), a publicly resolvable Rancher hostname, LB routes and ports 80/443. Confirm ingress health; installation alone does not provision an external LB. Install Helm 3 on management cp-01.

~~~bash
sudo bash scripts/install-rancher.sh rancher.example.com admin@example.com 2.x.y v1.x.y
sudo bash scripts/check-status.sh
~~~

Replace the placeholder Helm chart versions with explicitly approved and compatible Rancher/cert-manager versions. Ensure public DNS and the ACME HTTP-01 challenge can reach the ingress before choosing Let's Encrypt.

## Register downstream RKE2 nodes

From Rancher **Cluster Management → Create → Custom → RKE2**, create a new downstream cluster and obtain its per-role registration commands.

- Register cp-01, cp-02, cp-03 with `--etcd --controlplane`.
- Register workers with `--worker`.
- Use the exact Rancher-generated server URL, CA checksum and cluster token. **Do not paste sensitive tokens into Git, user-data or shell history**.
- See [the downstream registration runbook](../automation/rancher-node-registration/README.md) and [guarded registration helper](../automation/rancher-node-registration/register-node.sh).

If downstream RKE2 is **already installed**, use Rancher **Import Existing** instead. Importing discovers its Kubernetes nodes. Do not mix import with custom provisioning.

## AWS network requirements

The management cluster needs connectivity between the three servers on TCP 9345, 6443, 2379-2380 and other Kubernetes control-plane/kubelet requirements. Nodes also need the overlay/CNI-specific ports (for example, RKE2 Canal commonly uses **UDP 8472** for VXLAN, not UDP 4789). Allow worker traffic to control-plane supervisor 9345/API 6443. Rancher custom downstream nodes need outbound HTTPS 443 to the Rancher hostname.

Restrict incoming access to trusted networks; only public ingress 80/443 should be reachable from the Internet if publicly deployed. The AWS load balancers, DNS, routing, IAM and firewall settings are **manual prerequisites** under this preferred deployment model.

## Troubleshooting

~~~bash
sudo systemctl status rke2-server --no-pager -l
sudo journalctl -u rke2-server -n 100 --no-pager
sudo systemctl status rancher-system-agent --no-pager -l
sudo journalctl -u rancher-system-agent -n 100 --no-pager
~~~

Use `rke2-server` on management servers and `rancher-system-agent` on custom-provisioned downstream nodes. Rancher errors like **"Waiting for cluster control plane to be initialized"** and **"failure while applying plan"** generally require inspecting the downstream agent logs, RKE2 logs, connectivity, TLS trust and selected Kubernetes version before attempting recovery.

**This repository contains examples; no live EC2 provisioning or installation has been performed.** Validate script compatibility and test a disposable nonproduction cluster first.

## Legacy material

The historical [Terraform automation](../automation/README.md) remains in GitHub for reference, but **is not part of this recommended installation path**.
