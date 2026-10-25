# Terraform automation: separate Rancher/RKE2 management cluster

This folder contains an **optional new management-cluster** Terraform reference. It provisions 3 RKE2 server EC2 nodes, 2 RKE2 agent EC2 nodes, private RKE2 registration/API NLB, public Rancher ingress NLB, AWS SSM access, and Route 53. This does **not** deploy DataRobot or modify an existing Rancher-managed downstream cluster.

**Do not use this to repair or replace an existing production cluster.** This is a lab starter, not a proven production deployment. Verify pinned Rancher/RKE2/cert-manager compatibility, Traefik HelmChartConfig behavior, AWS quotas and ingress health before use. One NAT gateway is a single point of failure. Terraform state contains a sensitive RKE2 node token: use protected, encrypted remote state in production.

## Implementation order

| # | Phase | Run from | Pass condition |
|---|---|---|---|
| 1 | Validate AWS credentials, account, Route 53 public hosted zone, 3 AZs, EC2 quota and tooling | Workstation | Correct AWS account, zone and prerequisites |
| 2 | Customize Terraform variables | Workstation | Real DNS name, zone ID and selected RKE2 version |
| 3 | Initialize, format, validate and review Terraform plan | Workstation | Reviewed and approved plan |
| 4 | Apply Terraform; automatic RKE2 bootstrap begins in EC2 user data | Workstation | Infrastructure provisioned |
| 5 | Check bootstrap on first RKE2 server using SSM | server-1 | rke2-server active and Kubernetes API reachable |
| 6 | Verify all 3 control-plane and 2 agent nodes | server-1 | All 5 nodes Ready |
| 7 | Validate Traefik ingress, NLB target health, DNS and ports 80/443 | server-1 + workstation | Healthy ingress targets and DNS |
| 8 | Manually install cert-manager and Rancher via Helm | server-1 | Rancher workloads Ready |
| 9 | Verify HTTPS certificate and Rancher first login | Browser + server-1 | Valid TLS and working login |
| 10 | Final validation and security/backup handover | Operators | Backups and access controls reviewed |

Stop at a failed gate; Terraform apply completion does not imply RKE2 bootstrap success.

### 1. Workstation prerequisites

Install Terraform >=1.6, AWS CLI and Session Manager plugin. Confirm AWS identity and Route 53 hosted zone:

~~~bash
aws sts get-caller-identity
aws ec2 describe-availability-zones --region us-east-1 --filters Name=state,Values=available
terraform version
~~~

### 2–4. Configure, validate, provision

~~~bash
cd automation/terraform
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=rke2.plan
terraform show rke2.plan
terraform apply rke2.plan
terraform output
~~~

Replace example hostname and hosted zone ID with real values. This workflow creates billable AWS resources. Do not commit tfvars, Terraform state, or secrets.

### 5–7. Validate automatic RKE2 bootstrap

Connect to the first EC2 control-plane instance using SSM Session Manager. Check bootstrap and node status:

~~~bash
sudo cloud-init status --long
sudo tail -n 100 /var/log/rke2-bootstrap.log
sudo systemctl status rke2-server --no-pager -l
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes -o wide
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n kube-system get pods,daemonsets -o wide
~~~

Ensure all five nodes are Ready, the ingress DaemonSet is deployed onto both agents, and all load-balancer target groups are healthy. **Validate ingress controller chart settings first: these can vary across RKE2 and Traefik releases.**

### 8. Manually install cert-manager and Rancher

The EC2 user data runs only `install-rke2.sh`. Transfer the install-rancher script to the first RKE2 server using an approved secure method, then execute:

~~~bash
sudo bash install-rancher.sh rancher.example.com admin@example.com
~~~

Substitute your real DNS name and certificate email. Rancher installation must not run until the preceding checks pass.

### 9–10. Check application availability and harden

~~~bash
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml -n cattle-system get pods,ingress,certificate
curl -I https://rancher.example.com
~~~

Transfer `scripts/validate-cluster.sh` and `scripts/diagnose-node.sh` to the appropriate nodes before running them. For control-plane errors inspect `rke2-server` and cloud-init logs. `rancher-system-agent` diagnostics apply to separately Rancher-provisioned downstream nodes, not the management nodes provisioned here.

Review HA networking, backup and restore of etcd and Rancher, network restrictions, and protected remote Terraform state before production.

## Directory

~~~text
automation/
  README.md
  .gitignore
  terraform/
    versions.tf
    variables.tf
    main.tf
    outputs.tf
    terraform.tfvars.example
    templates/user-data.sh.tftpl
  scripts/
    install-rke2.sh       (automatic: EC2 user data)
    install-rancher.sh    (manual: first server)
    validate-cluster.sh   (manual)
    diagnose-node.sh      (manual)
~~~
