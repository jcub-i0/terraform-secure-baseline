resource "aws_wafv2_web_acl" "alb" {
  count = var.waf_enabled ? 1 : 0

  name        = "${var.name_prefix}-waf"
  description = "Optional AWS WAF protection for the shared ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Managed Rules -- Core Rule Set
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      dynamic "count" {
        for_each = var.waf_mode == "count" ? [1] : []
        content {}
      }

      dynamic "none" {
        for_each = var.waf_mode == "enforce" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = var.waf_sampled_requests_enabled
      metric_name                = "${var.name_prefix}-waf-common"
    }
  }

  # AWS Managed Rules -- Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      dynamic "count" {
        for_each = var.waf_mode == "count" ? [1] : []
        content {}
      }

      dynamic "none" {
        for_each = var.waf_mode == "enforce" ? [1] : []
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = var.waf_sampled_requests_enabled
      metric_name                = "${var.name_prefix}-waf-bad-inputs"
    }
  }

  # Optional IP-based rate limiting
  dynamic "rule" {
    for_each = var.waf_rate_limit_requests == null ? [] : [
      var.waf_rate_limit_requests
    ]

    content {
      name     = "IPRateLimit"
      priority = 30

      action {
        dynamic "count" {
          for_each = var.waf_mode == "count" ? [1] : []
          content {}
        }

        dynamic "block" {
          for_each = var.waf_mode == "enforce" ? [1] : []
          content {}
        }
      }

      statement {
        rate_based_statement {
          limit                 = rule.value
          aggregate_key_type    = "IP"
          evaluation_window_sec = 300
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = var.waf_sampled_requests_enabled
        metric_name                = "${var.name_prefix}-waf-rate-limit"
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = var.waf_sampled_requests_enabled
    metric_name                = "${var.name_prefix}-waf"
  }

  tags = {
    Name        = "${var.name_prefix}-WAF"
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  count = var.waf_enabled ? 1 : 0

  resource_arn = aws_lb.load_balancer.arn
  web_acl_arn  = aws_wafv2_web_acl.alb[0].arn
}