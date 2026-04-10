output "tf_state_bucket_arn" {
  description = "ARN of the S3 bucket where the Terraform state is stored"
  value       = module.state.tf_state_bucket_arn
}

output "tf_state_bucket_name" {
  description = "Name of the S3 bucket where the Terraform state is stored"
  value       = module.state.tf_state_bucket_name
}

output "tf_state_bucket_cmk_arn" {
  description = "ARN of the KMS CMK used to encrypt the Terraform State bucket"
  value       = module.state.tf_state_bucket_cmk_arn
}

output "tf_state_lock_table_arn" {
  description = "ARN of the State Lock DynamoDB table used for Terraform state locking"
  value       = module.state.tf_state_lock_table_arn
}