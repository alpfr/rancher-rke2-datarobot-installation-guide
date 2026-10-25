
data "aws_availability_zones" "available" { state = "available" }
data "aws_ssm_parameter" "al2023" { name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" }
locals { azs = slice(data.aws_availability_zones.available.names,0,3) }

resource "aws_vpc" "main" { cidr_block=var.vpc_cidr enable_dns_support=true enable_dns_hostnames=true }
resource "aws_internet_gateway" "main" { vpc_id=aws_vpc.main.id }
resource "aws_subnet" "public" {
  count=3
  vpc_id=aws_vpc.main.id
  cidr_block=cidrsubnet(var.vpc_cidr,8,count.index)
  availability_zone=local.azs[count.index]
}
resource "aws_subnet" "private" {
  count=3
  vpc_id=aws_vpc.main.id
  cidr_block=cidrsubnet(var.vpc_cidr,8,count.index+10)
  availability_zone=local.azs[count.index]
}
resource "aws_eip" "nat" { domain="vpc" }
resource "aws_nat_gateway" "main" {
  allocation_id=aws_eip.nat.id
  subnet_id=aws_subnet.public[0].id
  depends_on=[aws_internet_gateway.main]
}
resource "aws_route_table" "public" { vpc_id=aws_vpc.main.id }
resource "aws_route" "public" {
  route_table_id=aws_route_table.public.id
  destination_cidr_block="0.0.0.0/0"
  gateway_id=aws_internet_gateway.main.id
}
resource "aws_route_table_association" "public" {
  count=3
  subnet_id=aws_subnet.public[count.index].id
  route_table_id=aws_route_table.public.id
}
resource "aws_route_table" "private" { vpc_id=aws_vpc.main.id }
resource "aws_route" "nat" {
  route_table_id=aws_route_table.private.id
  destination_cidr_block="0.0.0.0/0"
  nat_gateway_id=aws_nat_gateway.main.id
}
resource "aws_route_table_association" "private" {
  count=3
  subnet_id=aws_subnet.private[count.index].id
  route_table_id=aws_route_table.private.id
}
resource "aws_security_group" "nodes" {
  name_prefix="rke2-nodes-"
  vpc_id=aws_vpc.main.id
}
resource "aws_security_group_rule" "self" {
  type="ingress"
  security_group_id=aws_security_group.nodes.id
  protocol="-1"
  from_port=0
  to_port=0
  self=true
}
resource "aws_security_group_rule" "control_ports" {
  for_each=toset(["6443","9345"])
  type="ingress"
  security_group_id=aws_security_group.nodes.id
  from_port=tonumber(each.key)
  to_port=tonumber(each.key)
  protocol="tcp"
  cidr_blocks=[var.vpc_cidr]
}
resource "aws_security_group_rule" "ingress_ports" {
  for_each=toset(["80","443"])
  type="ingress"
  security_group_id=aws_security_group.nodes.id
  from_port=tonumber(each.key)
  to_port=tonumber(each.key)
  protocol="tcp"
  cidr_blocks=["0.0.0.0/0"]
}
resource "aws_security_group_rule" "egress" {
  type="egress"
  security_group_id=aws_security_group.nodes.id
  protocol="-1"
  from_port=0
  to_port=0
  cidr_blocks=["0.0.0.0/0"]
}
resource "aws_iam_role" "nodes" {
  name_prefix="rke2-node-"
  assume_role_policy=jsonencode({
    Version="2012-10-17"
    Statement=[{Action="sts:AssumeRole",Effect="Allow",Principal={Service="ec2.amazonaws.com"}}]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role=aws_iam_role.nodes.name
  policy_arn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "random_password" "rke2_token" { length=48 special=false }
resource "aws_ssm_parameter" "token" {
  name="/${var.project}/rke2/node-token"
  type="SecureString"
  value=random_password.rke2_token.result
}
resource "aws_iam_role_policy" "token" {
  role=aws_iam_role.nodes.id
  policy=jsonencode({
    Version="2012-10-17"
    Statement=[{Effect="Allow",Action=["ssm:GetParameter"],Resource=aws_ssm_parameter.token.arn}]
  })
}
resource "aws_iam_instance_profile" "nodes" { role=aws_iam_role.nodes.name }
resource "aws_lb" "registration" {
  name="rke2-reg-${substr(md5(var.project),0,6)}"
  internal=true
  load_balancer_type="network"
  subnets=aws_subnet.private[*].id
}
resource "aws_lb" "rancher" {
  name="rancher-${substr(md5(var.project),0,6)}"
  internal=false
  load_balancer_type="network"
  subnets=aws_subnet.public[*].id
}
resource "aws_lb_target_group" "supervisor" {
  name="rke2-sup-${substr(md5(var.project),0,6)}"
  port=9345
  protocol="TCP"
  target_type="instance"
  vpc_id=aws_vpc.main.id
}
resource "aws_lb_target_group" "api" {
  name="rke2-api-${substr(md5(var.project),0,6)}"
  port=6443
  protocol="TCP"
  target_type="instance"
  vpc_id=aws_vpc.main.id
}
resource "aws_lb_target_group" "http" {
  name="rancher-80-${substr(md5(var.project),0,6)}"
  port=80
  protocol="TCP"
  target_type="instance"
  vpc_id=aws_vpc.main.id
}
resource "aws_lb_target_group" "https" {
  name="rancher-443-${substr(md5(var.project),0,6)}"
  port=443
  protocol="TCP"
  target_type="instance"
  vpc_id=aws_vpc.main.id
}
resource "aws_lb_listener" "supervisor" {
  load_balancer_arn=aws_lb.registration.arn
  port=9345
  protocol="TCP"
  default_action { type="forward" target_group_arn=aws_lb_target_group.supervisor.arn }
}
resource "aws_lb_listener" "api" {
  load_balancer_arn=aws_lb.registration.arn
  port=6443
  protocol="TCP"
  default_action { type="forward" target_group_arn=aws_lb_target_group.api.arn }
}
resource "aws_lb_listener" "http" {
  load_balancer_arn=aws_lb.rancher.arn
  port=80
  protocol="TCP"
  default_action { type="forward" target_group_arn=aws_lb_target_group.http.arn }
}
resource "aws_lb_listener" "https" {
  load_balancer_arn=aws_lb.rancher.arn
  port=443
  protocol="TCP"
  default_action { type="forward" target_group_arn=aws_lb_target_group.https.arn }
}
resource "aws_instance" "server" {
  count=3
  ami=data.aws_ssm_parameter.al2023.value
  instance_type=var.server_instance_type
  subnet_id=aws_subnet.private[count.index].id
  vpc_security_group_ids=[aws_security_group.nodes.id]
  iam_instance_profile=aws_iam_instance_profile.nodes.name
  metadata_options { http_tokens="required" }
  root_block_device { volume_size=var.root_volume_gb volume_type="gp3" encrypted=true }
  user_data_replace_on_change=true
  user_data=templatefile("${path.module}/templates/user-data.sh.tftpl", {
    bootstrap_script_b64=base64encode(file("${path.module}/../scripts/install-rke2.sh"))
    role=count.index==0 ? "init-server" : "join-server"
    region=var.aws_region
    version=var.rke2_version
    endpoint=aws_lb.registration.dns_name
    token_parameter=aws_ssm_parameter.token.name
  })
  tags={Name="${var.project}-server-${count.index+1}"}
  depends_on=[aws_route.nat,aws_route_table_association.private,aws_route_table_association.public,aws_iam_role_policy.token]
}
resource "aws_instance" "agent" {
  count=2
  ami=data.aws_ssm_parameter.al2023.value
  instance_type=var.agent_instance_type
  subnet_id=aws_subnet.private[count.index].id
  vpc_security_group_ids=[aws_security_group.nodes.id]
  iam_instance_profile=aws_iam_instance_profile.nodes.name
  metadata_options { http_tokens="required" }
  root_block_device { volume_size=var.root_volume_gb volume_type="gp3" encrypted=true }
  user_data_replace_on_change=true
  user_data=templatefile("${path.module}/templates/user-data.sh.tftpl", {
    bootstrap_script_b64=base64encode(file("${path.module}/../scripts/install-rke2.sh"))
    role="agent"
    region=var.aws_region
    version=var.rke2_version
    endpoint=aws_lb.registration.dns_name
    token_parameter=aws_ssm_parameter.token.name
  })
  tags={Name="${var.project}-agent-${count.index+1}"}
  depends_on=[aws_route.nat,aws_route_table_association.private,aws_route_table_association.public,aws_iam_role_policy.token]
}
resource "aws_lb_target_group_attachment" "supervisor" {
  count=3
  target_group_arn=aws_lb_target_group.supervisor.arn
  target_id=aws_instance.server[count.index].id
  port=9345
}
resource "aws_lb_target_group_attachment" "api" {
  count=3
  target_group_arn=aws_lb_target_group.api.arn
  target_id=aws_instance.server[count.index].id
  port=6443
}
resource "aws_lb_target_group_attachment" "http" {
  count=2
  target_group_arn=aws_lb_target_group.http.arn
  target_id=aws_instance.agent[count.index].id
  port=80
}
resource "aws_lb_target_group_attachment" "https" {
  count=2
  target_group_arn=aws_lb_target_group.https.arn
  target_id=aws_instance.agent[count.index].id
  port=443
}
resource "aws_route53_record" "rancher" {
  zone_id=var.route53_zone_id
  name=var.rancher_hostname
  type="A"
  alias {
    name=aws_lb.rancher.dns_name
    zone_id=aws_lb.rancher.zone_id
    evaluate_target_health=false
  }
}
