output "secops_event_bus_name" {
  value = aws_cloudwatch_event_bus.secops.name
}

output "secops_event_bus_arn" {
  value = aws_cloudwatch_event_bus.secops.arn
}

output "lambda_ec2_isolation_sg_id" {
  value = aws_security_group.lambda_ec2_isolation_sg.id
}

output "lambda_ec2_rollback_sg_id" {
  value = aws_security_group.lambda_ec2_rollback_sg.id
}

output "threat_intel_api_keys_arn" {
  value = aws_secretsmanager_secret.threat_intel_api_keys.arn
}

output "lambda_ip_enrichment_log_group_arn" {
  value = aws_cloudwatch_log_group.lambda_ip_enrichment.arn
}