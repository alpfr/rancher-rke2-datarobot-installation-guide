# Registering RKE2 control-plane and worker nodes with Rancher

This guide explains the missing Rancher-registration step for the AWS architecture. **Choose exactly one** of the two paths below. Nodes in the management cluster (where Rancher itself runs) are automatically visible as the Rancher local cluster.

## Decision matrix

| Cluster being managed | Method | Who installs RKE2? | How nodes appear |
| --- | --- | --- | --- |
| Existing Rancher management RKE2 cluster (manual installation) | Nothing else required | RKE2 Bash installation scripts | Rancher local cluster |
| Separate, already-running RKE2 cluster | Rancher Cluster Management -> Import Existing | You / Terraform | Import the entire cluster; Rancher discovers all nodes |
| New downstream RKE2 cluster with fresh EC2 instances | Rancher Cluster Management -> Create -> Custom (RKE2) | Rancher System Agent | Register each fresh node with a role-specific command |

**Never register a pre-installed RKE2 server or agent using the new custom-node workflow.** Do not execute a Rancher System Agent registration command against an already imported cluster unless Rancher explicitly provisions that cluster.

## Path A: Existing independently installed RKE2 cluster

1. In Rancher go to Cluster Management -> Import Existing, select the appropriate generic/RKE2 option and provide a cluster name.
2. Rancher displays a **cluster-specific kubectl command**. Do not guess the import manifest URL. Copy the exact command.
3. On a host with admin kubeconfig for that RKE2 cluster, verify its context:

~~~bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml  # when executing on an RKE2 server
/var/lib/rancher/rke2/bin/kubectl get nodes -o wide
# Then execute only the exact registration command shown in the Rancher UI.
~~~

4. Confirm outbound HTTPS 443 from cluster nodes/pods to Rancher and that Rancher's TLS CA is trusted.
5. In Rancher wait for the cluster to change from Pending to Active; inspect all control-plane and worker nodes.
6. To add more control-plane/worker nodes later, join them to RKE2 with the **same RKE2 version**, a valid token, and a stable supervisor endpoint. Rancher automatically observes new Kubernetes nodes. Do not separately install System Agent via the custom-node path.
7. Decide deliberately whether to enable imported RKE2 version management under Rancher to avoid conflicting upgrade controllers.

## Path B: New Rancher-provisioned RKE2 custom cluster

**Use clean nodes**, not the management-cluster EC2 nodes running Rancher. Those already have RKE2 and belong to the Rancher local cluster.

### Step-by-step implementation order

| Step | Location | Action | Gate |
| --- | --- | --- | --- |
| 1 | EC2-only Terraform / existing EC2 fleet | Provision fresh Linux hosts, 3 control-plane + 2 workers, private IPs, time sync, DNS, SSM/IAM, storage and networking | New instances running, no existing RKE2 |
| 2 | Network security | Allow node outbound 443 to Rancher; RKE2 registration 9345 and API 6443; etcd peer 2379/2380; CNI-specific overlay, kubelet 10250 | All needed connectivity verified |
| 3 | Rancher UI | Cluster Management -> Create -> Custom -> RKE2; choose supported Kubernetes version; configure cluster | Registration page displayed |
| 4 | Rancher UI | Select etcd + Control Plane (no worker) on Registration screen, copy *this cluster's* command | Correct role and server CA |
| 5 | Nodes cp-01/02/03 | Run Rancher-generated command on each fresh control-plane node, one at a time | System Agent active; control plane initializing |
| 6 | Rancher UI | Select Worker only, copy refreshed command for that role | Worker-only roles |
| 7 | Nodes worker-01/02 | Run generated worker command on each clean worker node | System Agent active; agents join |
| 8 | Rancher UI | Review Provisioning -> Updating -> Active | All five nodes reported Ready |
| 9 | Nodes & Rancher UI | Inspect services, control-plane health and workloads | Cluster and application healthy |

### Node role plan

| Host example | Rancher registration role flags | Expected RKE2 systemd unit |
| --- | --- | --- |
| rke2-cp-01 | --etcd --controlplane | rke2-server |
| rke2-cp-02 | --etcd --controlplane | rke2-server |
| rke2-cp-03 | --etcd --controlplane | rke2-server |
| rke2-worker-01 | --worker | rke2-agent |
| rke2-worker-02 | --worker | rke2-agent |

### Option 1: Recommended — run the exact command from Rancher

Rancher generates a unique command containing the proper server URL, cluster registration token, CA checksum (when needed), and role flags. Use that exact command rather than copying a token from another cluster. Registration tokens are secrets: never commit them or add them to user data, logs, public CI variables or shell history. For private EC2 networks you can set the private IP in Advanced options or add the --internal-address flag if appropriate.

### Option 2: Registration helper (for clean nodes only)

This repository also includes [register-node.sh](register-node.sh). The script verifies that RKE2 or Rancher System Agent is not already installed, securely downloads Rancher's System Agent installer with certificate validation, prompts interactively for the actual registration token, and applies the selected role flags.

Copy the script to each **new** EC2 node first, then run:

~~~bash
# On cp-01, cp-02, cp-03 (replace IP for each node):
sudo bash register-node.sh control-plane https://rancher.example.com 10.42.10.11

# On worker-01 and worker-02 (replace IP for each node):
sudo bash register-node.sh worker https://rancher.example.com 10.42.11.11
~~~

The helper does not create the Rancher cluster or retrieve a token automatically; these must be completed in Rancher first. If Rancher generated different options for your environment, use its exact command instead. In a private CA environment, install the CA in OS trust first; never disable TLS verification.

The relevant node-registration commands use the Rancher System Agent installer with either:

~~~bash
# EXAMPLE FLAGS ONLY; get a valid URL, token and optional CA checksum from Rancher.
--server https://rancher.example.com --token '<FROM_RANCHER>' --etcd --controlplane
--server https://rancher.example.com --token '<FROM_RANCHER>' --worker
~~~

## Verification and Rancher provisioning troubleshooting

Run on any new node:

~~~bash
sudo systemctl status rancher-system-agent --no-pager -l
sudo journalctl -u rancher-system-agent -n 100 --no-pager
# After Rancher has applied its provisioning plan:
sudo systemctl status rke2-server --no-pager -l  # control-plane only
sudo systemctl status rke2-agent --no-pager -l   # workers only
~~~

From a host with the resulting RKE2 cluster's admin kubeconfig:

~~~bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get --raw='/readyz?verbose'
~~~

If Rancher shows "Waiting for cluster control plane to be initialized" or "failure while applying plan":

1. Check that the System Agent can reach Rancher over HTTPS 443 and validates the server CA.
2. Inspect journalctl for rancher-system-agent and the correct rke2 service, especially plan failures.
3. Check the cluster's selected RKE2 version across all new nodes; don't attempt ad hoc upgrades during initialization.
4. Check stable control-plane endpoint, DNS, AWS security groups, port 9345/6443, etcd ports 2379/2380 and host disk/time availability.
5. Check the CNI-selected pod network. No single overlay port is universal to all CNIs.
6. If a node has belonged to another cluster, do not simply re-run registration. Follow official removal/cleanup guidance and preserve any needed etcd snapshots.

**Networking:** Rancher's publicly accessible hostname is not an RKE2 supervisor endpoint. New custom cluster nodes must reach the Rancher URL over 443, and they must also have the intra-cluster connectivity required by RKE2.

## References

- Rancher custom cluster registration: https://ranchermanager.docs.rancher.com/reference-guides/cluster-configuration/rancher-server-configuration/use-existing-nodes
- Rancher existing cluster import: https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-clusters-in-rancher-setup/register-existing-clusters
- Rancher port requirements: https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/installation-requirements/port-requirements
- Rancher System Agent installer flags: https://github.com/rancher/system-agent/blob/main/install.sh
