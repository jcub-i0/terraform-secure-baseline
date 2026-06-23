# LAMBDA ROLES
## AWS-MANAGED POLICIES FOR LAMBDA LOGGING & VPC ENI ACCESS
data "aws_iam_policy" "lambda_vpc" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy" "lambda_logs" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy" "lambda_xray" {
  arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# LAMBDA TRUST POLICY
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    sid     = "AllowLambdaAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

## EC2 ISOLATION LAMBDA
### EC2 ISOLATION LAMBDA EXECUTION ROLE
resource "aws_iam_role" "lambda_ec2_isolation" {
  name               = "${var.name_prefix}-lambda-ec2-isolation"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name        = "lambda-ec2-isolation"
    Terraform   = "true"
    Environment = var.environment
  }
}

### EC2 ISOLATION IAM POLICY
data "aws_iam_policy_document" "lambda_ec2_isolation" {
  statement {
    sid    = "AllowEC2IsolationActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:DescribeSecurityGroups",
      "ec2:CreateTags",
      "ec2:CreateSnapshot"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowSNSSecurityAlerts"
    effect = "Allow"
    actions = [
      "sns:Publish"
    ]

    resources = [var.secops_topic_arn]
  }

  statement {
    sid    = "AllowLogsKMSUsage"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt",
      "kms:DescribeKey"
    ]

    resources = [var.logs_cmk_arn]
  }

  statement {
    sid    = "SendEC2IsolationFailuresToDLQ"
    effect = "Allow"

    actions = [
      "sqs:SendMessage"
    ]

    resources = [
      var.lambda_ec2_isolation_dlq_arn
    ]
  }
}

resource "aws_iam_policy" "lambda_ec2_isolation" {
  name   = "${var.name_prefix}-lambda-ec2-isolation"
  policy = data.aws_iam_policy_document.lambda_ec2_isolation.json
}

### ATTACH EC2 ISOLATION POLICY TO EC2 ISOLATION EXECUTION ROLE
resource "aws_iam_role_policy_attachment" "lambda_ec2_isolation" {
  role       = aws_iam_role.lambda_ec2_isolation.name
  policy_arn = aws_iam_policy.lambda_ec2_isolation.arn
}

### ATTACH AWS-MANAGED POLICY FOR LAMBDA VPC ENI ACCESS
resource "aws_iam_role_policy_attachment" "ec2_isolation_vpc_attach" {
  role       = aws_iam_role.lambda_ec2_isolation.name
  policy_arn = data.aws_iam_policy.lambda_vpc.arn
}

### ATTACH BASIC LAMBDA EXECUTION ROLE (X-RAY + BASELINE LOGGING)
resource "aws_iam_role_policy_attachment" "ec2_isolation_logs_attach" {
  role       = aws_iam_role.lambda_ec2_isolation.name
  policy_arn = data.aws_iam_policy.lambda_logs.arn
}

### ATTACH AWS-MANAGED X-RAY POLICY TO LAMBDA
resource "aws_iam_role_policy_attachment" "ec2_isolation_xray_attach" {
  role       = aws_iam_role.lambda_ec2_isolation.name
  policy_arn = data.aws_iam_policy.lambda_xray.arn
}

## EC2 ROLLBACK LAMBDA
### EC2 ROLLBACK LAMBDA EXECUTION ROLE
resource "aws_iam_role" "lambda_ec2_rollback" {
  name               = "${var.name_prefix}-lambda-ec2-rollback"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name        = "Lambda-EC2-Rollback-Role"
    Terraform   = "true"
    Environment = var.environment
  }
}

### EC2 ROLLBACK IAM POLICY
data "aws_iam_policy_document" "lambda_ec2_rollback" {
  statement {
    sid    = "AllowEC2RollbackActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:ModifyInstanceAttribute",
      "ec2:DescribeSecurityGroups",
      "ec2:CreateTags"
    ]

    resources = ["*"]
  }

  statement {
    sid     = "AllowSNSSecurityAlerts"
    effect  = "Allow"
    actions = ["sns:Publish"]

    resources = [var.secops_topic_arn]
  }

  statement {
    sid    = "AllowLogsKMSUsage"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt",
      "kms:DescribeKey"
    ]

    resources = [var.logs_cmk_arn]
  }
}

resource "aws_iam_policy" "lambda_ec2_rollback" {
  name   = "${var.name_prefix}-lambda-rollback-policy"
  policy = data.aws_iam_policy_document.lambda_ec2_rollback.json
}

### ATTACH EC2 ROLLBACK POLICY TO EC2 ROLLBACK EXECUTION ROLE
resource "aws_iam_role_policy_attachment" "lambda_ec2_rollback" {
  role       = aws_iam_role.lambda_ec2_rollback.name
  policy_arn = aws_iam_policy.lambda_ec2_rollback.arn
}

### ATTACH AWS-MANAGED POLICY FOR LAMBDA VPC ENI ACCESS
resource "aws_iam_role_policy_attachment" "ec2_rollback_vpc_attach" {
  role       = aws_iam_role.lambda_ec2_rollback.name
  policy_arn = data.aws_iam_policy.lambda_vpc.arn
}

### ATTACH BASIC LAMBDA EXECUTION ROLE (X-RAY + BASELINE LOGGING)
resource "aws_iam_role_policy_attachment" "ec2_rollback_logs_attach" {
  role       = aws_iam_role.lambda_ec2_rollback.name
  policy_arn = data.aws_iam_policy.lambda_logs.arn
}

### ATTACH AWS-MANAGED X-RAY POLICY TO LAMBDA
resource "aws_iam_role_policy_attachment" "ec2_rollback_xray_attach" {
  role       = aws_iam_role.lambda_ec2_rollback.name
  policy_arn = data.aws_iam_policy.lambda_xray.arn
}

## IP ENRICHMENT LAMBDA
### IP ENRICHMENT LAMBDA EXECUTION ROLE
resource "aws_iam_role" "lambda_ip_enrichment" {
  name               = "${var.name_prefix}-lambda-ip-enrichment"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name        = "Lambda-IP-Enrichment-Role"
    Terraform   = "true"
    Environment = var.environment
  }
}

data "aws_iam_policy_document" "lambda_ip_enrichment" {
  statement {
    sid    = "AllowThreatIntelSecretRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]

    resources = [var.threat_intel_api_keys_arn]
  }

  statement {
    sid     = "AllowSNSSecurityAlerts"
    effect  = "Allow"
    actions = ["sns:Publish"]

    resources = [var.secops_topic_arn]
  }

  statement {
    sid    = "AllowLogsKMSUsage"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt",
      "kms:DescribeKey"
    ]

    resources = [var.logs_cmk_arn]
  }

  statement {
    sid       = "AllowSecurityHubFindingUpdates"
    effect    = "Allow"
    actions   = ["securityhub:BatchUpdateFindings"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowSecretsManagerKMSUsage"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]

    resources = [var.secrets_manager_cmk_arn]
  }
}

resource "aws_iam_policy" "lambda_ip_enrichment" {
  name        = "${var.name_prefix}-lambda-ip-enrichment-policy"
  description = "Permissions for IP Enrichment Lambda"
  policy      = data.aws_iam_policy_document.lambda_ip_enrichment.json
}

### ATTACH LAMBDA_IP_ENRICHMENT IAM POLICY TO IP ENRICHMENT LAMBDA
resource "aws_iam_role_policy_attachment" "ip_enrichment" {
  role       = aws_iam_role.lambda_ip_enrichment.name
  policy_arn = aws_iam_policy.lambda_ip_enrichment.arn
}

### ATTACH BASIC LAMBDA EXECUTION ROLE (X-RAY + BASELINE LOGGING)
resource "aws_iam_role_policy_attachment" "ip_enrichment_logs_attach" {
  role       = aws_iam_role.lambda_ip_enrichment.name
  policy_arn = data.aws_iam_policy.lambda_logs.arn
}

### ATTACH AWS-MANAGED X-RAY POLICY TO LAMBDA
resource "aws_iam_role_policy_attachment" "ip_enrichment_xray_attach" {
  role       = aws_iam_role.lambda_ip_enrichment.name
  policy_arn = data.aws_iam_policy.lambda_xray.arn
}