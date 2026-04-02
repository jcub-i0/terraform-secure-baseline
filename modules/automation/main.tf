# EC2 ISOLATION LAMBDA RESOURCES
## PACKAGE EC2 ISOLATION LAMBDA
data "archive_file" "lambda_ec2_isolation" {
  type        = "zip"
  source_file = "${path.module}/lambda/ec2_isolation.py"
  output_path = "${path.module}/lambda/ec2_isolation.zip"
}

## EC2 ISOLATION LAMBDA FUNCTION
resource "aws_lambda_function" "ec2_isolation" {
  function_name                  = "${var.name_prefix}-ec2-isolation"
  description                    = "Isolate EC2 resources by sending them to the Quarantine SG when a HIGH/CRITICAL Security Hub finding is observed on an instance"
  role                           = var.lambda_ec2_isolation_role_arn
  handler                        = "ec2_isolation.lambda_handler"
  runtime                        = "python3.12"
  filename                       = data.archive_file.lambda_ec2_isolation.output_path
  timeout                        = 60
  memory_size                    = 256
  source_code_hash               = data.archive_file.lambda_ec2_isolation.output_base64sha256
  kms_key_arn                    = var.lambda_cmk_arn
  reserved_concurrent_executions = 5

  # ENABLE X-RAY TRACING FOR LAMBDA FUNC
  tracing_config {
    mode = "Active"
  }

  vpc_config {
    subnet_ids         = var.serverless_private_subnet_ids
    security_group_ids = [aws_security_group.lambda_ec2_isolation_sg.id]
  }

  environment {
    variables = {
      QUARANTINE_SG_ID = var.quarantine_sg_id
      SNS_TOPIC_ARN    = var.secops_topic_arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_ec2_isolation
  ]

  tags = {
    Name        = "${var.name_prefix}-EC2-Isolation"
    Environment = var.environment
    Terraform   = "true"
  }
}

## EC2 ISOLATION SECURITY GROUP
resource "aws_security_group" "lambda_ec2_isolation_sg" {
  name                   = "${var.name_prefix}-Lambda-EC2-Isolation-SG"
  description            = "Security Group for the EC2 Isolation Lambda function"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = {
    Name        = "${var.name_prefix}-Lambda-EC2-Isolation-SG"
    Environment = var.environment
    Terraform   = "true"
  }
}

### EVENTBRIDGE RESOURCES
#### EVENT RULE TO TRIGGER UPON HIGH/CRITICAL SECURITY HUB EC2 FINDINGS
resource "aws_cloudwatch_event_rule" "securityhub_ec2_high_critical" {
  name        = "securityhub-ec2-high-critical"
  description = "New High/Critical Security Hub EC2 findings"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"],
    detail-type = ["Security Hub Findings - Imported"],
    detail = {
      findings = {
        Severity = {
          Label = ["HIGH", "CRITICAL"]
        },
        Resources = {
          Type = ["AwsEc2Instance"]
        },
        Workflow = {
          Status = ["NEW"]
        }
      }
    }
  })
}

#### EVENT TARGET FOR HIGH/CRITICAL SECURITY HUB EC2 FINDINGS EVENT RULE
resource "aws_cloudwatch_event_target" "ec2_isolation" {
  rule      = aws_cloudwatch_event_rule.securityhub_ec2_high_critical.name
  target_id = "Ec2Isolation"
  arn       = aws_lambda_function.ec2_isolation.arn

  depends_on = [
    aws_cloudwatch_event_rule.securityhub_ec2_high_critical
  ]
}

#### PERMISSION TO ALLOW EVENTBRIDGE TO INVOKE EC2 ISOLATION LAMBDA
resource "aws_lambda_permission" "allow_eventbridge_ec2_isolation" {
  statement_id  = "AllowExecutionFromEventBridgeEc2Isolation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ec2_isolation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.securityhub_ec2_high_critical.arn
}

### CLOUDWATCH LOG GROUP FOR EC2 ISOLATION LAMBDA
resource "aws_cloudwatch_log_group" "lambda_ec2_isolation" {
  name              = "/aws/lambda/${var.name_prefix}-ec2-isolation"
  retention_in_days = 30
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-Lambda-EC2-Isolation-Logs"
    Environment = var.environment
    Terraform   = "true"
  }
}

# EC2 ROLLBACK LAMBDA RESOURCES
## PACKAGE EC2 ROLLBACK LAMBDA
data "archive_file" "lambda_ec2_rollback" {
  type        = "zip"
  source_file = "${path.module}/lambda/ec2_rollback.py"
  output_path = "${path.module}/lambda/ec2_rollback.zip"
}

## EC2 ROLLBACK LAMBDA FUNCTION
resource "aws_lambda_function" "ec2_rollback" {
  function_name                  = "${var.name_prefix}-ec2-rollback"
  description                    = "Restore EC2 resources in the Quarantine SG back to their original SG(s)"
  role                           = var.lambda_ec2_rollback_role_arn
  handler                        = "ec2_rollback.lambda_handler"
  runtime                        = "python3.12"
  filename                       = data.archive_file.lambda_ec2_rollback.output_path
  timeout                        = 60
  memory_size                    = 256
  source_code_hash               = data.archive_file.lambda_ec2_rollback.output_base64sha256
  kms_key_arn                    = var.lambda_cmk_arn
  reserved_concurrent_executions = 5

  # ENABLE X-RAY TRACING
  tracing_config {
    mode = "Active"
  }

  vpc_config {
    subnet_ids         = var.serverless_private_subnet_ids
    security_group_ids = [aws_security_group.lambda_ec2_rollback_sg.id]
  }

  environment {
    variables = {
      SNS_TOPIC_ARN = var.secops_topic_arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_ec2_rollback
  ]

  tags = {
    Name        = "${var.name_prefix}-EC2-Rollback"
    Environment = var.environment
    Terraform   = "true"
  }
}

## EC2 ROLLBACK SG
resource "aws_security_group" "lambda_ec2_rollback_sg" {
  name                   = "${var.name_prefix}-Lambda-EC2-Rollback-SG"
  description            = "Security Group for the EC2 Rollback Lambda function"
  vpc_id                 = var.vpc_id
  revoke_rules_on_delete = true

  tags = {
    Name        = "${var.name_prefix}-Lambda-EC2-Rollback-SG"
    Environment = var.environment
    Terraform   = "true"
  }
}

### EVENTBRIDGE RESOURCES
#### CUSTOM EVENT BUS TO LIMIT ONLY SECURITY OPERATIONS USERS TO TRIGGER EC2 ROLLBACK
resource "aws_cloudwatch_event_bus" "secops" {
  name = "security-operations-bus"
  tags = {
    Name        = "${var.name_prefix}-secops-bus"
    Environment = var.environment
    Terraform   = "true"
  }
}

#### SECURITY OPERATIONS EVENT BUS POLICY
resource "aws_cloudwatch_event_bus_policy" "secops_bus_policy" {
  event_bus_name = aws_cloudwatch_event_bus.secops.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ALLOW MANUAL EC2 ROLLBACK INJECTION FROM SECOPS-OPERATOR
      {
        Sid    = "AllowSecOpsRollbackOnly"
        Effect = "Allow"
        Principal = {
          AWS = "*"
        }
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.secops.arn
        Condition = {
          StringEquals = {
            "events:source" = "custom.rollback"
          }
        }
      },
      # ALLOW EVENTBRIDGE FORWARDING ROLE TO PUT EVENTS ON BUS
      {
        Sid    = "AllowEventBridgeForwardingRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.account_id}:root"
        }
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.secops.arn
        Condition = {
          StringEquals = {
            "events:source" = "aws.securityhub"
          }
        }
      }
    ]
  })
}

#### EVENT RULE TO TRIGGER UPON MANUAL TRIGGER
resource "aws_cloudwatch_event_rule" "ec2_rollback" {
  name           = "ec2-rollback-rule"
  description    = "Trigger Lambda to rollback isolated EC2 instances to their original security groups"
  event_bus_name = aws_cloudwatch_event_bus.secops.name

  event_pattern = jsonencode({
    "source" = ["custom.rollback"]
  })

  force_destroy = true
}

#### EVENT TARGET FOR EC2 ROLLBACK EVENT RULE
resource "aws_cloudwatch_event_target" "ec2_rollback" {
  rule           = aws_cloudwatch_event_rule.ec2_rollback.name
  event_bus_name = aws_cloudwatch_event_bus.secops.name
  target_id      = "Ec2RollbackLambda"
  arn            = aws_lambda_function.ec2_rollback.arn

  depends_on = [
    aws_cloudwatch_event_rule.ec2_rollback
  ]
}

#### ALLOW EVENTBRIDGE TO INVOKE EC2 ROLLBACK LAMBDA
resource "aws_lambda_permission" "allow_eventbridge_ec2_rollback" {
  statement_id  = "AllowExecutionFromEventBridgeEc2Rollback"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ec2_rollback.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ec2_rollback.arn
}

### CLOUDWATCH LOG GROUP FOR EC2 ROLLBACK LAMBDA
resource "aws_cloudwatch_log_group" "lambda_ec2_rollback" {
  name              = "/aws/lambda/${var.name_prefix}-ec2-rollback"
  retention_in_days = 30
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-Lambda-EC2-Rollback-Logs"
    Environment = var.environment
    Terraform   = "true"
  }
}

# IP ENRICHMENT LAMBDA RESOURCES
data "archive_file" "lambda_ip_enrichment" {
  type        = "zip"
  source_file = "${path.module}/lambda/ip_enrichment.py"
  output_path = "${path.module}/lambda/ip_enrichment.zip"
}

resource "aws_lambda_function" "ip_enrichment" {
  function_name                  = "${var.name_prefix}-ip-enrichment"
  description                    = "Enrich IP address information by querying a Threat Intel platform and include that data in an SNS notification"
  role                           = var.lambda_ip_enrichment_role_arn
  handler                        = "ip_enrichment.lambda_handler"
  runtime                        = "python3.12"
  filename                       = data.archive_file.lambda_ip_enrichment.output_path
  timeout                        = 60
  memory_size                    = 256
  source_code_hash               = data.archive_file.lambda_ip_enrichment.output_base64sha256
  kms_key_arn                    = var.lambda_cmk_arn
  reserved_concurrent_executions = 2

  # ENABLE X-RAY TRACING
  tracing_config {
    mode = "Active"
  }

  # NO VPC_CONFIG HERE (SO THE FUNCTION CAN REACH INTERNET WITHOUT NAT)

  environment {
    variables = {
      CLOUD_NAME              = var.cloud_name
      SNS_TOPIC_ARN           = var.secops_topic_arn
      THREAT_INTEL_SECRET_ARN = aws_secretsmanager_secret.threat_intel_api_keys.arn
      WRITE_TO_SECURITYHUB    = var.ip_enrichment_write_to_securityhub
      MAX_IPS_PER_EVENT       = var.ip_enrich_max_ips_per_event
      ABUSEIPDB_MAX_AGE_DAYS  = var.ip_enrich_abuseipdb_max_age
      MAX_IPS_EXTRACTED       = var.ip_enrich_max_ips_extracted
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda_ip_enrichment
  ]

  tags = {
    Name        = "${var.name_prefix}-IP-Enrichment"
    Environment = var.environment
    Terraform   = "true"
  }
}

### STORE IP ENRICHMENT'S API KEYS IN AWS SECRETS MANAGER
resource "aws_secretsmanager_secret" "threat_intel_api_keys" {
  name_prefix = "${var.name_prefix}/threat-intel/api-keys-"
  description = "API keys for external threat intel providers (AbuseIPDB)"
  kms_key_id  = var.secrets_manager_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-Threat-Intel-API-Keys"
    Environment = var.environment
    Terraform   = "true"
  }
}

#### STORE THREAT INTEL API KEYS FOR IP ENRICHMENT FUNCTION IN AWS SECRETS MANAGER
resource "aws_secretsmanager_secret_version" "threat_intel_api_keys" {
  secret_id = aws_secretsmanager_secret.threat_intel_api_keys.id

  secret_string = jsonencode({
    ABUSEIPDB_API_KEY = var.abuseipdb_api_key
  })
}

resource "aws_cloudwatch_event_rule" "securityhub_high_critical" {
  name        = "securityhub-high-critical"
  description = "New High/Critical Security Hub findings"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"],
    detail-type = ["Security Hub Findings - Imported"],
    detail = {
      findings = {
        Severity = {
          Label = ["HIGH", "CRITICAL"]
        },
        Workflow = {
          Status = ["NEW"]
        }
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "ip_enrichment" {
  rule      = aws_cloudwatch_event_rule.securityhub_high_critical.name
  target_id = "IpEnrichment"
  arn       = aws_lambda_function.ip_enrichment.arn

  depends_on = [
    aws_cloudwatch_event_rule.securityhub_high_critical
  ]
}

resource "aws_lambda_permission" "allow_eventbridge_ip_enrichment" {
  statement_id  = "AllowExecutionFromEventBridgeIpEnrichment"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ip_enrichment.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.securityhub_high_critical.arn
}

### CLOUDWATCH LOG GROUP FOR IP ENRICHMENT LAMBDA
resource "aws_cloudwatch_log_group" "lambda_ip_enrichment" {
  name              = "/aws/lambda/${var.name_prefix}-ip-enrichment"
  retention_in_days = 30
  kms_key_id        = var.logs_cmk_arn

  tags = {
    Name        = "${var.name_prefix}-Lambda-IP-Enrichment-Logs"
    Environment = var.environment
    Terraform   = "true"
  }
}