output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "codeartifact_domain" {
  value = aws_codeartifact_domain.this.domain
}

output "codeartifact_domain_owner" {
  value = aws_codeartifact_domain.this.owner
}

output "codeartifact_repository" {
  value = aws_codeartifact_repository.maven_releases.repository
}

output "gha_role_arn" {
  value = aws_iam_role.gha_publisher.arn
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "packer_instance_profile" {
  value = aws_iam_instance_profile.packer.name
}
