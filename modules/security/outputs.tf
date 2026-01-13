output "logs_kms_key_arn" {
  description = "The ARN of the KMS CMK"
  value       = aws_kms_key.logs.arn
}