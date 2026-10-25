# EC2 ONLY: This project does not install RKE2, Rancher, DataRobot, DNS, or load balancers.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
data "aws_subnet" "private" {
  for_each = toset(var.private_subnet_ids)
  id       = each.key
}
locals {
  selected_ami = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.al2023.value
  first_three_azs = [for id in slice(var.private_subnet_ids, 0, 3) : data.aws_subnet.private[id].availability_zone]
}

resource "aws_security_group" "management" {
  name_prefix = "rke2-mgmt-"
  vpc_id      = var.vpc_id
  description = "RKE2 Rancher management cluster"
  tags = { Name = format("%s-%s-management", var.project, var.environment) }
}
resource "aws_security_group" "downstream" {
  name_prefix = "rke2-data-"
  vpc_id      = var.vpc_id
  description = "DataRobot RKE2 downstream cluster"
  tags = { Name = format("%s-%s-downstream", var.project, var.environment) }
}
# All node-to-node traffic *only within each SG*; narrow ports further as needed.
resource "aws_vpc_security_group_ingress_rule" "management_peer" {
  security_group_id            = aws_security_group.management.id
  referenced_security_group_id = aws_security_group.management.id
  ip_protocol                  = "-1"
}
resource "aws_vpc_security_group_ingress_rule" "downstream_peer" {
  security_group_id            = aws_security_group.downstream.id
  referenced_security_group_id = aws_security_group.downstream.id
  ip_protocol                  = "-1"
}
resource "aws_vpc_security_group_egress_rule" "management" {
  security_group_id = aws_security_group.management.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_vpc_security_group_egress_rule" "downstream" {
  security_group_id = aws_security_group.downstream.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_vpc_security_group_ingress_rule" "rancher_http" {
  for_each = toset(var.management_ingress_cidrs)
  security_group_id = aws_security_group.management.id
  cidr_ipv4 = each.key
  ip_protocol = "tcp"
  from_port = 80
  to_port = 80
}
resource "aws_vpc_security_group_ingress_rule" "rancher_https" {
  for_each = toset(var.management_ingress_cidrs)
  security_group_id = aws_security_group.management.id
  cidr_ipv4 = each.key
  ip_protocol = "tcp"
  from_port = 443
  to_port = 443
}
resource "aws_vpc_security_group_ingress_rule" "mgmt_api" {
  for_each = toset(var.management_api_cidrs)
  security_group_id = aws_security_group.management.id
  cidr_ipv4 = each.key
  ip_protocol = "tcp"
  from_port = 6443
  to_port = 6443
}
resource "aws_vpc_security_group_ingress_rule" "data_api" {
  for_each = toset(var.downstream_api_cidrs)
  security_group_id = aws_security_group.downstream.id
  cidr_ipv4 = each.key
  ip_protocol = "tcp"
  from_port = 6443
  to_port = 6443
}

resource "aws_iam_role" "ssm" {
  name_prefix = "rke2-node-ssm-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "ssm" {
  name_prefix = "rke2-node-ssm-"
  role = aws_iam_role.ssm.name
}

resource "aws_instance" "management" {
  count = 3
  ami = local.selected_ami
  instance_type = var.management_instance_type
  subnet_id = var.private_subnet_ids[count.index]
  vpc_security_group_ids = [aws_security_group.management.id]
  iam_instance_profile = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = false
  metadata_options {
    http_tokens = "required"
    http_endpoint = "enabled"
  }
  root_block_device {
    volume_type = "gp3"
    volume_size = var.management_root_volume_gb
    encrypted = true
    delete_on_termination = var.delete_root_volume_on_termination
  }
  lifecycle {
    precondition {
      condition = length(distinct(local.first_three_azs)) == 3
      error_message = "The first three subnets must be in distinct Availability Zones."
    }
    precondition {
      condition = alltrue([for id in var.private_subnet_ids : data.aws_subnet.private[id].vpc_id == var.vpc_id])
      error_message = "All subnets must belong to vpc_id."
    }
  }
  tags = {
    Name = format("%s-%s-mgmt-cp-%02d", var.project, var.environment, count.index + 1)
    NodeRole = "control-plane-etcd"
    Cluster = "rancher-management"
  }
}
resource "aws_instance" "data_control_plane" {
  count = 3
  ami = local.selected_ami
  instance_type = var.downstream_control_plane_instance_type
  subnet_id = var.private_subnet_ids[count.index]
  vpc_security_group_ids = [aws_security_group.downstream.id]
  iam_instance_profile = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = false
  metadata_options {
    http_tokens = "required"
    http_endpoint = "enabled"
  }
  root_block_device {
    volume_type = "gp3"
    volume_size = var.downstream_control_plane_root_volume_gb
    encrypted = true
    delete_on_termination = var.delete_root_volume_on_termination
  }
  tags = {
    Name = format("%s-%s-data-cp-%02d", var.project, var.environment, count.index + 1)
    NodeRole = "control-plane-etcd"
    Cluster = "datarobot-downstream"
  }
  depends_on = [aws_instance.management]
}
resource "aws_instance" "data_worker" {
  count = var.downstream_worker_count
  ami = local.selected_ami
  instance_type = var.downstream_worker_instance_type
  subnet_id = var.private_subnet_ids[count.index % length(var.private_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.downstream.id]
  iam_instance_profile = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = false
  metadata_options {
    http_tokens = "required"
    http_endpoint = "enabled"
  }
  root_block_device {
    volume_type = "gp3"
    volume_size = var.downstream_worker_root_volume_gb
    encrypted = true
    delete_on_termination = var.delete_root_volume_on_termination
  }
  tags = {
    Name = format("%s-%s-data-worker-%02d", var.project, var.environment, count.index + 1)
    NodeRole = "worker"
    Cluster = "datarobot-downstream"
  }
  depends_on = [aws_instance.management]
}
