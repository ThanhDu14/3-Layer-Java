output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "artifact_bucket" {
  value = aws_s3_bucket.artifacts.bucket
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
