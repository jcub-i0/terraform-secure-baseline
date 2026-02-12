output "centralized_logs_bucket_name" {
  description = "The 'bucket' attribute of the Centralized Logs S3 bucket"
  value       = aws_s3_bucket.centralized_logs.bucket
}

output "centralized_logs_bucket_arn" {
  description = "The ARN of the Centralized Logs S3 bucket"
  value       = aws_s3_bucket.centralized_logs.arn
}

output "centralized_logs_bucket_id" {
  description = "The ID of the Centralized Logs S3 bucket"
  value       = aws_s3_bucket.centralized_logs.id
}

output "data_sg_id" {
  value = aws_security_group.data.id
}