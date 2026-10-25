output "management_control_plane" {
  value = [for n in aws_instance.management : {
    name = n.tags["Name"]
    instance_id = n.id
    private_ip = n.private_ip
    subnet_id = n.subnet_id
    availability_zone = n.availability_zone
  }]
}
output "downstream_control_plane" {
  value = [for n in aws_instance.data_control_plane : {
    name = n.tags["Name"]
    instance_id = n.id
    private_ip = n.private_ip
    subnet_id = n.subnet_id
    availability_zone = n.availability_zone
  }]
}
output "downstream_workers" {
  value = [for n in aws_instance.data_worker : {
    name = n.tags["Name"]
    instance_id = n.id
    private_ip = n.private_ip
    subnet_id = n.subnet_id
    availability_zone = n.availability_zone
  }]
}
output "management_security_group_id" { value = aws_security_group.management.id }
output "downstream_security_group_id" { value = aws_security_group.downstream.id }
output "ssm_instance_profile" { value = aws_iam_instance_profile.ssm.name }
output "total_ec2_instances" { value = 6 + var.downstream_worker_count }
output "ssm_first_management_node" {
  value = format("aws ssm start-session --region %s --target %s", var.aws_region, aws_instance.management[0].id)
}
