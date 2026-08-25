output "security_group_id" {
  description = "Security Group ID of the Application Load Balancer"
  value       = aws_security_group.load_balancer.id
}

output "load_balancer_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.load_balancer.arn
}

output "dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.load_balancer.dns_name
}

output "https_listener_arn" {
  description = "ARN of the HTTPS listener"
  value       = aws_lb_listener.https.arn
}

output "target_groups" {
  description = "Target group metadata keyed by ECS service name"
  value = {
    for service_name, target_group in aws_lb_target_group.target_groups : service_name => {
      arn  = target_group.arn
      name = target_group.name
    }
  }
}