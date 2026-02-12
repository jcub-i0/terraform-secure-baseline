output "logs_kms_key_arn" {
  description = "The ARN of the KMS CMK"
  value       = aws_kms_key.logs.arn
}

output "ebs_kms_key_arn" {
  description = "The ARN of the EBS KMS CMK"
  value       = aws_kms_key.ebs.arn
}

output "ebs_kms_alias_arn" {
  description = "The EBS KMS CMK alias"
  value       = aws_kms_alias.ebs.arn
}

output "lambda_kms_key_arn" {
  description = "ARN of the Lambda CMK KMS key used to encrypt environment variables"
  value       = aws_kms_key.lambda.arn
}