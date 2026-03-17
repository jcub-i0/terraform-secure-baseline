# CLOUDWATCH LOG GROUP FOR NETWORK FIREWALL
resource "aws_cloudwatch_log_group" "network_firewall" {
  name              = var.network_firewall_log_group_name
  retention_in_days = 30
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "${var.cloud_name}-network-firewall-logs"
    Environment = var.environment
    Terraform   = "true"
  }
}

# RULE GROUP FOR NETWORK FIREWALL
resource "aws_networkfirewall_rule_group" "stateful_domains" {
  capacity = 100
  name     = "${var.cloud_name}-egress-stateful-domains"
  type     = "STATEFUL"

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets = [
          ".ubuntu.com",
          ".security.ubuntu.com",
          ".archive.ubuntu.com",
          ".ntp.ubuntu.com",
          ".ec2.archive.ubuntu.com"
        ]
      }
    }

    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }

  tags = {
    Name        = "${var.cloud_name}-stateful-domains"
    Environment = var.environment
    Terraform   = "true"
  }
}

# POLICY FOR NETWORK FIREWALL
resource "aws_networkfirewall_firewall_policy" "egress" {
  name = "${var.cloud_name}-egress"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    stateful_default_actions = [
      "aws:drop_established",
      "aws:alert_established"
    ]

    stateful_rule_group_reference {
      priority     = 1
      resource_arn = aws_networkfirewall_rule_group.stateful_domains.arn
    }
  }

  tags = {
    Name        = "${var.cloud_name}-egress-policy"
    Environment = var.environment
    Terraform   = "true"
  }
}

# NETWORK FIREWALL LOGGING CONFIG
resource "aws_networkfirewall_logging_configuration" "egress" {
  firewall_arn = aws_networkfirewall_firewall.egress.arn

  logging_configuration {
    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "S3"
      log_destination = {
        bucketName = var.centralized_logs_bucket_name
        prefix     = "${var.cloud_name}/firewall/flow"
      }
    }

    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.network_firewall.name
      }
    }
  }
}

resource "aws_networkfirewall_firewall" "egress" {
  name                = "${var.cloud_name}-egress-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.egress.arn
  vpc_id              = var.vpc_id

  delete_protection                 = false # CHANGE THIS IN PROD
  firewall_policy_change_protection = false # CHANGE THIS IN PROD
  subnet_change_protection          = false # CHANGE THIS IN PROD

  dynamic "subnet_mapping" {
    for_each = var.firewall_private_subnet_ids_map
    content {
      subnet_id = subnet_mapping.value
    }
  }

  tags = {
    Name        = "${var.cloud_name}-egress-firewall"
    Environment = var.environment
    Terraform   = "true"
    Purpose     = "Centralized outbound traffic inspection and control"
  }
}