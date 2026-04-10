output "tf_state_bucket_arn" {
  description = "ARN of the S3 bucket where the Terraform state is stored"
  value       = aws_s3_bucket.state.arn
}

output "tf_state_bucket_name" {
  description = "Name of the S3 bucket where the Terraform state is stored"
  value       = aws_s3_bucket.state.bucket
}

output "tf_state_bucket_cmk_arn" {
  description = "ARN of the KMS CMK used to encrypt the Terraform State bucket"
  value       = aws_kms_key.state.arn
}

output "tf_state_lock_table_arn" {
  description = "ARN of the State Lock DynamoDB table"
  value       = aws_dynamodb_table.state_lock.arn
}

output "tf_state_lock_table_name" {
  description = "Name of the State Lock DynamoDB Table"
  value       = aws_dynamodb_table.state_lock.name
}