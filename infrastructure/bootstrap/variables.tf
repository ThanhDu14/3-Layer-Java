variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "alert_email" {
  description = "Receives Budget and SNS alert emails"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository allowed to publish, as owner/name"
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repo))
    error_message = "github_repo must look like owner/name."
  }
}
