variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "project" {
  type    = string
  default = "rke2-rancher"
}
variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}
variable "rancher_hostname" {
  type        = string
  description = "Public DNS hostname, e.g. rancher.example.com"
  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.rancher_hostname))
    error_message = "Provide a public DNS hostname such as rancher.example.com."
  }
}
variable "route53_zone_id" {
  type        = string
  description = "Existing public Route 53 hosted zone ID for rancher_hostname"
}
variable "server_instance_type" {
  type    = string
  default = "m6i.xlarge"
}
variable "agent_instance_type" {
  type    = string
  default = "m6i.large"
}
variable "rke2_version" {
  type    = string
  default = "v1.36.5+rke2r1"
}
variable "root_volume_gb" {
  type    = number
  default = 80
}
