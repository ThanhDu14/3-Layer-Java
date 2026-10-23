terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local state on purpose: this stack creates the bucket that live/ keeps its state in.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "java3tier"
      Environment = "dev"
    }
  }
}
