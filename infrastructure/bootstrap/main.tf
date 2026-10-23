data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  github_oidc  = "token.actions.githubusercontent.com"
  package_arns = "arn:aws:codeartifact:${var.aws_region}:${local.account_id}:package/${aws_codeartifact_domain.this.domain}/${aws_codeartifact_repository.maven_releases.repository}/*"
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

# --- Maven repository for the WAR ---

resource "aws_codeartifact_domain" "this" {
  domain = "java3tier"
}

resource "aws_codeartifact_repository" "maven_releases" {
  repository = "maven-releases"
  domain     = aws_codeartifact_domain.this.domain
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
          "${local.github_oidc}:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "gha_publisher" {
  name = "codeartifact-publish"
  role = aws_iam_role.gha_publisher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["codeartifact:GetAuthorizationToken"]
        Resource = aws_codeartifact_domain.this.arn
      },
      {
        Effect   = "Allow"
        Action   = ["codeartifact:GetRepositoryEndpoint", "codeartifact:ReadFromRepository"]
        Resource = aws_codeartifact_repository.maven_releases.arn
      },
      {
        Effect   = "Allow"
        Action   = ["codeartifact:PublishPackageVersion", "codeartifact:PutPackageMetadata", "codeartifact:ReadFromRepository"]
        Resource = local.package_arns
      },
      {
        Effect    = "Allow"
        Action    = "sts:GetServiceBearerToken"
        Resource  = "*"
        Condition = { StringEquals = { "sts:AWSServiceName" = "codeartifact.amazonaws.com" } }
      },
    ]
  })
}

# --- Packer build instances: pull the WAR from CodeArtifact ---

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
  name = "codeartifact-read"
  role = aws_iam_role.packer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["codeartifact:GetAuthorizationToken"]
        Resource = aws_codeartifact_domain.this.arn
      },
      {
        Effect   = "Allow"
        Action   = ["codeartifact:GetRepositoryEndpoint", "codeartifact:ReadFromRepository"]
        Resource = [aws_codeartifact_repository.maven_releases.arn, local.package_arns]
      },
      {
        Effect    = "Allow"
        Action    = "sts:GetServiceBearerToken"
        Resource  = "*"
        Condition = { StringEquals = { "sts:AWSServiceName" = "codeartifact.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "packer" {
  name = "java3tier-packer"
  role = aws_iam_role.packer.name
}
