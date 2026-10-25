variable "aws_region" {
  type = string
  default = "us-east-1"
}
variable "project" {
  type = string
  default = "rancher-rke2"
}
variable "environment" {
  type = string
  default = "dev"
}
variable "vpc_id" {
  type = string
  description = "Existing VPC, not created by this Terraform configuration."
  validation {
    condition = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "Provide an existing valid vpc-... ID."
  }
}
variable "private_subnet_ids" {
  type = list(string)
  description = "Existing private subnets: first 3 must be in different AZs."
  validation {
    condition = length(var.private_subnet_ids) >= 3 && length(distinct(var.private_subnet_ids)) == length(var.private_subnet_ids) && alltrue([for id in var.private_subnet_ids : can(regex("^subnet-[0-9a-f]{8,17}$", id))])
    error_message = "Provide at least 3 distinct valid subnet-... IDs."
  }
}
variable "ami_id" {
  type = string
  default = null
  description = "Use a region-matched, approved x86_64 Linux AMI; null selects AWS AL2023."
  validation {
    condition = var.ami_id == null || can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must be null or a valid ami-... ID."
  }
}
variable "management_instance_type" {
  type = string
  default = "m6i.xlarge"
}
variable "downstream_control_plane_instance_type" {
  type = string
  default = "m6i.xlarge"
}
variable "downstream_worker_instance_type" {
  type = string
  default = "m5.4xlarge"
}
variable "downstream_worker_count" {
  type = number
  default = 2
  validation {
    condition = var.downstream_worker_count >= 1 && var.downstream_worker_count <= 30 && floor(var.downstream_worker_count) == var.downstream_worker_count
    error_message = "Choose between 1 and 30 workers (integer)."
  }
}
variable "management_root_volume_gb" {
  type = number
  default = 100
}
variable "downstream_control_plane_root_volume_gb" {
  type = number
  default = 100
}
variable "downstream_worker_root_volume_gb" {
  type = number
  default = 200
}
variable "delete_root_volume_on_termination" {
  type = bool
  default = true
}
variable "management_ingress_cidrs" {
  type = list(string)
  default = []
  description = "Approved IPv4 client/LB source CIDRs for Rancher ingress 80/443. Empty = closed."
}
variable "management_api_cidrs" {
  type = list(string)
  default = []
}
variable "downstream_api_cidrs" {
  type = list(string)
  default = []
}
