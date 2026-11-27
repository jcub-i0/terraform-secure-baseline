resource "aws_lambda_event_source_mapping" "broker_requests" {
  count = length(aws_lambda_function.broker) > 0 ? 1 : 0

  event_source_arn = aws_sqs_queue.broker_requests[0].arn
  function_name    = aws_lambda_function.broker[0].arn

  # Protected deployment/delivery and live qualification remain required
  enabled = false

  # Process one request per Lambda invocation
  batch_size = 1

  # Do not delay request delivery for batching
  maximum_batching_window_in_seconds = 0

  depends_on = [
    aws_iam_role_policy.broker_runtime
  ]
}
