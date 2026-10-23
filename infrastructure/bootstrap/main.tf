data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  github_oidc = "token.actions.githubusercontent.com"
  # Both subject formats, so the role keeps working if the repo toggles immutable subjects.
  github_subject_prefixes = compact(["repo:${var.github_repo}", var.github_oidc_subject_prefix])
  artifacts_arn           = "arn:aws:s3:::${aws_s3_bucket.artifacts.bucket}"
  # WARs live at dptweb/<version>/dptweb.war
  war_objects = "${local.artifacts_arn}/dptweb/*"
}

# --- Terraform state for live/ (S3 native locking, use_lockfile) ---

resource "aws_s3_bucket" "state" {
  bucket = "java3tier-tfstate-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Cost guard ---

resource "aws_budgets_budget" "monthly" {
  name         = "java3tier-monthly"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [20, 50, 100]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}

# --- Alerts (CloudWatch alarms in live/ publish here) ---

resource "aws_sns_topic" "alerts" {
  name = "java3tier-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- WAR artifacts (CodeArtifact is not available on the AWS Free plan) ---

resource "aws_s3_bucket" "artifacts" {
  bucket = "java3tier-artifacts-${local.account_id}"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- GitHub Actions publisher (OIDC, no stored keys) ---

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.github_oidc}"
  client_id_list = ["sts.amazonaws.com"]
}

resource "aws_iam_role" "gha_publisher" {
  name = "java3tier-gha-publisher"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "${local.github_oidc}:aud" = "sts.amazonaws.com"
          "${local.github_oidc}:sub" = [for prefix in local.github_subject_prefixes : "${prefix}:ref:refs/heads/main"]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "gha_publisher" {
  name = "publish-war"
  role = aws_iam_role.gha_publisher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = local.war_objects
    }]
  })
}

# --- Packer build instances: pull the WAR from S3 ---

resource "aws_iam_role" "packer" {
  name = "java3tier-packer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "packer" {
  name = "read-war"
  role = aws_iam_role.packer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = local.war_objects
      },
      {
        # Without ListBucket a missing version answers 403 instead of 404.
        Effect    = "Allow"
        Action    = "s3:ListBucket"
        Resource  = local.artifacts_arn
        Condition = { StringLike = { "s3:prefix" = "dptweb/*" } }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "packer" {
  name = "java3tier-packer"
  role = aws_iam_role.packer.name
}
