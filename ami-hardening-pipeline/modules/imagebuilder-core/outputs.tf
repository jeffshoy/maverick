output "instance_profile_name" {
  description = "Name of the IAM instance profile for Image Builder infrastructure configurations"
  value       = aws_iam_instance_profile.imagebuilder.name
}

output "instance_role_arn" {
  description = "ARN of the IAM role assumed by Image Builder build instances"
  value       = aws_iam_role.imagebuilder.arn
}

output "logs_bucket_name" {
  description = "Name of the S3 bucket storing CIS compliance evidence"
  value       = aws_s3_bucket.logs.id
}

output "logs_bucket_arn" {
  description = "ARN of the S3 bucket storing CIS compliance evidence"
  value       = aws_s3_bucket.logs.arn
}

output "security_group_id" {
  description = "Security group ID used by Image Builder build instances (explicit or auto-created default)"
  value       = local.resolved_security_group_id
}
