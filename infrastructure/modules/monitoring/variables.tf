# Monitoring Module

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "rds_instance_id" {
  description = "RDS instance ID"
  type        = string
}

variable "asg_name" {
  description = "Auto Scaling Group name"
  type        = string
}
