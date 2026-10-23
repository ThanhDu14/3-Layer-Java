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

# Repos with immutable OIDC subjects send repo:<owner>@<id>/<name>@<id> instead.
run "gha_trust_policy_immutable_subject" {
  command = plan

  variables {
    github_oidc_subject_prefix = "repo:owner@111/name@222"
  }

  assert {
    condition     = strcontains(aws_iam_role.gha_publisher.assume_role_policy, "repo:owner@111/name@222:ref:refs/heads/main")
    error_message = "GHA role must trust the immutable subject of the main branch"
  }

  assert {
    condition     = !strcontains(aws_iam_role.gha_publisher.assume_role_policy, "refs/heads/*")
    error_message = "GHA role must not trust other branches"
  }
}

run "artifact_bucket" {
  command = plan

  assert {
    condition     = aws_s3_bucket.artifacts.bucket == "java3tier-artifacts-111122223333"
    error_message = "artifact bucket must be java3tier-artifacts-<account_id>"
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.artifacts.block_public_acls,
      aws_s3_bucket_public_access_block.artifacts.block_public_policy,
      aws_s3_bucket_public_access_block.artifacts.ignore_public_acls,
      aws_s3_bucket_public_access_block.artifacts.restrict_public_buckets,
    ])
    error_message = "all four public access block flags must be true"
  }
}

run "gha_publishes_war_to_s3" {
  command = plan

  assert {
    condition = contains(
      [for s in jsondecode(aws_iam_role_policy.gha_publisher.policy).Statement : s.Resource if contains(flatten([s.Action]), "s3:PutObject")],
      "arn:aws:s3:::java3tier-artifacts-111122223333/dptweb/*"
    )
    error_message = "GHA role may only write WARs under dptweb/ in the artifact bucket"
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.gha_publisher.policy, "codeartifact")
    error_message = "CodeArtifact is not available on the AWS Free plan"
  }
}

run "packer_reads_war_from_s3" {
  command = plan

  assert {
    condition = contains(
      flatten([for s in jsondecode(aws_iam_role_policy.packer.policy).Statement : s.Resource if contains(flatten([s.Action]), "s3:GetObject")]),
      "arn:aws:s3:::java3tier-artifacts-111122223333/dptweb/*"
    )
    error_message = "Packer instances must be able to read WARs under dptweb/"
  }
}
