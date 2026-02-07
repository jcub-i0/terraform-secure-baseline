output "secops_event_bus_name" {
  value = aws_cloudwatch_event_bus.secops.name
}

output "secops_event_bus_arn" {
  value = aws_cloudwatch_event_bus.secops.arn
}