output "state_lock_dynamodb_table_arn" {
  description = "ARN of the State DynamoDB table"
  value       = aws_dynamodb_table.state_lock.arn
}