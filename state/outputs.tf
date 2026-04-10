output "tf_state_lock_table_arn" {
  description = "ARN of the State Lock DynamoDB table used for Terraform state locking"
  value       = module.state.state_lock_dynamodb_table_arn
}