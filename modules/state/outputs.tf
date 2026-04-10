output "tf_state_lock_table_arn" {
  description = "ARN of the State Lock DynamoDB table"
  value       = aws_dynamodb_table.state_lock.arn
}