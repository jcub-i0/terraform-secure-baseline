output "tf_state_bucket_arn" {
  description = "ARN of the S3 bucket where the Terraform state is stored"
  value       = module.state.tf_state_bucket_arn
}

output "tf_state_lock_table_arn" {
  description = "ARN of the State Lock DynamoDB table used for Terraform state locking"
  value       = module.state.tf_state_lock_table_arn
}