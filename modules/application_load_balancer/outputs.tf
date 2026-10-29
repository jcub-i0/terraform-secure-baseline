output "security_group_id" {
  description = "Security Group ID of the Application Load Balancer"
  value       = aws_security_group.load_balancer.id
}

output "load_balancer_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.load_balancer.arn
}

output "load_balancer_arn_suffix" {
  description = "ARN suffix of the Application Load Balancer for CloudWatch and Application Auto Scaling metrics"
  value       = aws_lb.load_balancer.arn_suffix
}

output "dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.load_balancer.dns_name
}

output "https_listener" {
  description = "HTTPS listener metadata"

  value = {
    arn             = aws_lb_listener.https.arn
    certificate_arn = aws_lb_listener.https.certificate_arn
    ssl_policy      = aws_lb_listener.https.ssl_policy
  }
}

output "target_groups" {
  description = "Target group metadata keyed by ECS service name"

  value = {
    for service_name, target_group in aws_lb_target_group.target_groups : service_name => {
      arn        = target_group.arn
      arn_suffix = target_group.arn_suffix
      name       = target_group.name
    }
  }
}

output "access_logs" {
  description = "ALB access logging configuration and S3 destination metadata."

  value = {
    enabled = var.access_logs_enabled

    bucket_name = (
      var.access_logs_enabled
      ? aws_s3_bucket.access_logs[0].id
      : null
    )

    bucket_arn = (
      var.access_logs_enabled
      ? aws_s3_bucket.access_logs[0].arn
      : null
    )

    expected_bucket_name = local.access_logs_bucket_name

    prefix = var.access_logs_enabled ? "alb" : null

    retention_days = (
      var.access_logs_enabled
      ? var.access_logs_retention_days
      : null
    )

    force_destroy = (
      var.access_logs_enabled
      ? aws_s3_bucket.access_logs[0].force_destroy
      : null
    )
  }
}

output "waf" {
  description = "AWS WAF configuration and association metadata."

  value = {
    enabled = var.waf_enabled

    mode = (
      var.waf_enabled
      ? var.waf_mode
      : null
    )

    web_acl_arn = (
      var.waf_enabled
      ? aws_wafv2_web_acl.alb[0].arn
      : null
    )

    web_acl_id = (
      var.waf_enabled
      ? aws_wafv2_web_acl.alb[0].id
      : null
    )

    association_id = (
      var.waf_enabled
      ? aws_wafv2_web_acl_association.alb[0].id
      : null
    )

    rate_limit_requests = (
      var.waf_enabled
      ? var.waf_rate_limit_requests
      : null
    )
  }
}