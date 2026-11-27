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

output "broker_log_group" {
  description = "Broker Lambda log group metadata; null when no jobs are configured."

  value = length(aws_cloudwatch_log_group.broker) > 0 ? {
    arn  = aws_cloudwatch_log_group.broker[0].arn
    name = aws_cloudwatch_log_group.broker[0].name
  } : null
}

output "broker_lambda" {
  description = "Broker Lambda function metadata; null when no approved package is configured."

  value = length(aws_lambda_function.broker) > 0 ? {
    arn  = aws_lambda_function.broker[0].arn
    name = aws_lambda_function.broker[0].function_name
  } : null
}

output "broker_processing_dlq" {
  description = "Broker processing failure DLQ metadata; null when no jobs are configured."

  value = length(aws_sqs_queue.broker_processing_dlq) > 0 ? {
    arn  = aws_sqs_queue.broker_processing_dlq[0].arn
    url  = aws_sqs_queue.broker_processing_dlq[0].url
    name = aws_sqs_queue.broker_processing_dlq[0].name
  } : null
}

output "broker_event_source_mapping_uuid" {
  description = "SQS-to-Lambda mapping UUID; null when no broker Lambda is configured."

  value = length(aws_lambda_event_source_mapping.broker_requests) > 0 ? (
    aws_lambda_event_source_mapping.broker_requests[0].uuid
  ) : null
}

output "broker_completion_queue" {
  description = "Disabled completion transport and failure-queue metadata; null when not configured."
  value = local.completion_enabled ? {
    queue = {
      arn  = aws_sqs_queue.broker_completion[0].arn
      url  = aws_sqs_queue.broker_completion[0].url
      name = aws_sqs_queue.broker_completion[0].name
    }
    
    dlqs = {
      for purpose, queue in aws_sqs_queue.broker_completion_dlq : purpose => {
        arn  = queue.arn
        url  = queue.url
        name = queue.name
      }
    }

    rule = {
      arn  = aws_cloudwatch_event_rule.broker_completion[0].arn
      name = aws_cloudwatch_event_rule.broker_completion[0].name
    }
    event_source_mapping_uuid = try(aws_lambda_event_source_mapping.broker_completion[0].uuid, null)
  } : null
}