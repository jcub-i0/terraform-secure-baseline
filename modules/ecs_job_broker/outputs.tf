output "broker_execution_role" {
  description = "Broker Lambda execution role metadata"

  value = length(var.jobs) > 0 ? {
    arn  = aws_iam_role.broker_execution[0].arn
    name = aws_iam_role.broker_execution[0].name
  } : null
}

output "launcher_roles" {
  description = "Dedicated launcher roles keyed by job"

  value = {
    for job_name, role in aws_iam_role.launcher :
    job_name => {
      arn  = role.arn
      name = role.name
    }
  }
}

output "launcher_policy_ids" {
  description = "Launcher IAM policy readiness IDs"

  value = {
    for job_name, policy in aws_iam_role_policy.job_launch :
    job_name => policy.id
  }
}

output "broker_request_queue" {
  description = "Application-owned SQS broker request queue metadata; null when no jobs are configured"

  value = length(aws_sqs_queue.broker_requests) > 0 ? {
    arn  = aws_sqs_queue.broker_requests[0].arn
    url  = aws_sqs_queue.broker_requests[0].url
    name = aws_sqs_queue.broker_requests[0].name
  } : null
}

output "execution_ledger" {
  description = "DynamoDB execution ledger metadata; null when no jobs are configured."

  value = length(aws_dynamodb_table.execution_ledger) > 0 ? {
    arn  = aws_dynamodb_table.execution_ledger[0].arn
    name = aws_dynamodb_table.execution_ledger[0].name
  } : null
}
