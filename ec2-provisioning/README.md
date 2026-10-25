# Terraform EC2 provisioning only (Rancher + RKE2 installed separately)

**Preferred infrastructure workflow:** Terraform creates the EC2 instances, two cluster-specific security groups, and SSM IAM instance profile. It **does not install Rancher, RKE2, or DataRobot**, and it does not create DNS or load balancers. The existing VPC and three private subnets (different AZs) must already exist, with functional outbound internet/NAT or suitable mirrors/VPC endpoints. **No Route 53 hosted-zone ID is needed.**

## Implementation order

| Order | Action | Tool | Checkpoint |
|---|---|---|---|
| 1 | Select AWS account, region, existing VPC, three private subnets across AZs | AWS CLI/console | Network, NAT/egress, DNS, SSM and EC2 capacity verified |
| 2 | Set real VPC/subnet IDs and instance sizes in terraform.tfvars | Text editor | All placeholder IDs replaced |
| 3 | Validate/plan, review cost and security groups | Terraform | Approved plan |
| 4 | Provision **3 management CP, 3 DataRobot CP, and 2 DataRobot workers** | Terraform | 8 running EC2 instances, private IPs, SSM availability |
| 5 | Create internal management API/registration NLB (6443/9345); Rancher ingress LB/DNS separately | AWS console/CLI | Stable LB DNS, endpoint routing and security groups verified |
| 6 | Install management RKE2 on first and remaining control-plane nodes | Bash | Three management nodes Ready |
| 7 | Configure ingress; install cert-manager + Rancher | Helm/Bash | Rancher management local cluster Active, valid HTTPS |
| 8 | Rancher: Create **Custom RKE2** downstream cluster | Rancher UI | Registration commands generated |
| 9 | Register fresh downstream EC2 CP and worker nodes by role | Rancher System Agent | All downstream nodes Ready and Rancher Active |
| 10 | Verify services, storage, backups, image registry, DataRobot prerequisites | kubectl/Helm | Workloads healthy |

## First-time setup (macOS / any Terraform workstation)

~~~bash
git clone https://github.com/alpfr/rancher-rke2-datarobot-installation-guide.git
cd rancher-rke2-datarobot-installation-guide/ec2-provisioning
cp terraform.tfvars.example terraform.tfvars

aws sts get-caller-identity
aws ec2 describe-vpcs --region us-east-1 --output table
aws ec2 describe-subnets --region us-east-1 --filters Name=vpc-id,Values=vpc-YOURID --output table

vi terraform.tfvars
terraform init
terraform fmt -check
terraform validate
terraform plan -out=ec2.plan
terraform show ec2.plan
terraform apply ec2.plan
terraform output
terraform output -json downstream_workers
terraform output ssm_first_management_node
~~~

**Replace** `vpc-YOURID`, subnet placeholders and region with real values. `terraform.tfvars` and state files must remain private; use an encrypted remote state backend with locking for shared teams. Terraform 1.12.2 satisfies this project's version constraint. The AWS CLI and Terraform version-update notices do not explain the earlier Route 53 error: this module has **no hosted-zone references**.

## Instance sizing and distribution

- **Management:** 3 `m6i.xlarge` RKE2 control-plane/etcd nodes, 100 GiB encrypted gp3 roots, one per AZ.
- **Downstream DataRobot:** 3 `m6i.xlarge` control-plane/etcd nodes, 100 GiB roots, one per AZ.
- **Downstream workers:** 2 `m5.4xlarge` instances by default, 200 GiB roots. Increase the worker count/types for real DataRobot requirements.

These are **example** sizes, not approved DataRobot production sizing. The default is AWS SSM's latest Amazon Linux 2023 x86_64 AMI; use `ami_id` to pin an approved compatible OS/AMI. Moving to a newly resolved AMI on a subsequent plan may require instance replacement: review plans carefully.

## Important AWS prerequisites

This project uses **existing** networking. Verify subnets route out via NAT or have the required endpoints and registry access. The Terraform IAM role only grants `AmazonSSMManagedInstanceCore`; add workload-specific IAM roles, EBS CSI roles and cloud-controller integration permissions separately, based on what you install. Enable and verify SSM Agent on the chosen AMI. Security groups permit node-peer traffic **within each cluster only**. Client Rancher ingress 80/443 and outside API ingress 6443 are closed unless you explicitly set trusted CIDRs; allow only the appropriate LB/client sources after checking NLB client-IP preservation.

You must separately configure a stable **internal NLB on TCP 9345 and 6443** for management RKE2, an ingress controller and LB for Rancher HTTPS, and DNS from your existing provider. This is deliberately not a complete HA network-stack module.

## Scripts after infrastructure is provisioned

- [Manual management RKE2 and Rancher install](../manual-deployment/README.md)
- [Downstream control-plane/worker node registration](../automation/rancher-node-registration/README.md)

**Do not execute the old `automation/terraform` directory to provision EC2-only**; that legacy implementation also bootstraps RKE2 and configures Route 53. This new `ec2-provisioning/` directory is intentionally independent.

## Safety

Terraform state, private IP addresses and IAM configuration may be sensitive. Review all resources and costs before `terraform apply`. Do not run `terraform destroy` against a live cluster without full backup and change approval. No live AWS provisioning or integration test has been performed.
