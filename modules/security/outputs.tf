output "logs_kms_key_arn" {
  description = "The ARN of the KMS CMK"
  value       = aws_kms_key.logs.arn
}

output "ebs_kms_key_arn" {
  description = "The ARN of the EBS KMS CMK"
  value = aws_kms_key.ebs.arn
}

output "ebs_kms_alias_arn" {
  description = "The EBS KMS CMK alias"
  value = aws_kms_alias.ebs.arn
}