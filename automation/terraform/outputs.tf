output "rancher_url" { value = "https://${var.rancher_hostname}" }
output "rancher_load_balancer_dns" { value = aws_lb.rancher.dns_name }
output "rke2_registration_endpoint" { value = "https://${aws_lb.registration.dns_name}:9345" }
output "rke2_api_endpoint" { value = "https://${aws_lb.registration.dns_name}:6443" }
output "server_instance_ids" { value = aws_instance.server[*].id }
output "agent_instance_ids" { value = aws_instance.agent[*].id }
output "rke2_version" { value = var.rke2_version }
output "aws_region" { value = var.aws_region }
