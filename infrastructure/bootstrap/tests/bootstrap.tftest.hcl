# Plan-only against a mocked provider: no AWS credentials needed.
mock_provider "aws" {}

override_data {
  target          = data.aws_caller_identity.current
  override_during = plan
  values = {
    account_id = "111122223333"
  }
}

# The trust policy embeds this ARN, so it has to be known at plan time.
override_resource {
  target          = aws_iam_openid_connect_provider.github
  override_during = plan
  values = {
    arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
  }
}

variables {
  alert_email = "alerts@example.com"
  github_repo = "owner/name"
}

run "state_bucket" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "java3tier-tfstate-111122223333"
    error_message = "state bucket must be java3tier-tfstate-<account_id>"
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "all four public access block flags must be true"
  }
}

run "budget_thresholds" {
  command = plan

  assert {
    condition     = toset([for n in aws_budgets_budget.monthly.notification : n.threshold]) == toset([20, 50, 100])
    error_message = "budget must alert at 20, 50 and 100 percent"
  }
}

run "gha_trust_policy" {
  command = plan

  assert {
    condition     = strcontains(aws_iam_role.gha_publisher.assume_role_policy, "repo:owner/name:ref:refs/heads/main")
    error_message = "GHA role must trust only the main branch of github_repo"
  }
}

run "codeartifact_repository" {
  command = plan

  assert {
    condition     = aws_codeartifact_repository.maven_releases.repository == "maven-releases"
    error_message = "repository must be maven-releases"
  }

  assert {
    condition     = aws_codeartifact_repository.maven_releases.domain == "java3tier"
    error_message = "repository must belong to domain java3tier"
  }
}
