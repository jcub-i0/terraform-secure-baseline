
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

## EC2 ISOLATION LAMBDA
### EC2 ISOLATION LAMBDA EXECUTION ROLE
resource "aws_iam_role" "lambda_ec2_isolation" {
  name = "${var.name_prefix}-lambda-ec2-isolation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

### EC2 ISOLATION IAM POLICY
resource "aws_iam_policy" "lambda_ec2_isolation" {
  name = "${var.name_prefix}-lambda-ec2-isolation"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      # CUSTOM POLICY FOR EC2 CONTROL
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeSecurityGroups",
          "ec2:CreateTags",
          "ec2:CreateSnapshot"
        ]
        Resource = "*"
      },
      # ALLOW LAMBDA TO CALL SNS
      {
        Effect = "Allow",
        Action = [
          "sns:Publish"
        ]
        Resource = var.secops_topic_arn
      },
      # ALLOW USE OF LOGS KMS KEY (USED FOR SNS)
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.logs_cmk_arn
      }
    ]
  })
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
  name = "${var.name_prefix}-lambda-ec2-rollback"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

### EC2 ROLLBACK IAM POLICY
resource "aws_iam_policy" "lambda_ec2_rollback" {
  name = "${var.name_prefix}-lambda-rollback-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # CUSTOM POLICY FOR EC2 CONTROL
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeSecurityGroups",
          "ec2:CreateTags"
        ]
        Resource = "*"
      },
      # ALLOW LAMBDA TO CALL SNS
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = var.secops_topic_arn
      },
      # ALLOW USE OF LOGS KMS KEY (USED FOR SNS)
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.logs_cmk_arn
      }
    ]
  })
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
  name = "${var.name_prefix}-lambda-ip-enrichment"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
  tags = {
    Name      = "Lambda-IP-Enrichment-Role"
    Terraform = "true"
  }
}

resource "aws_iam_policy" "lambda_ip_enrichment" {
  name        = "${var.name_prefix}-lambda-ip-enrichment-policy"
  description = "Permissions for IP Enrichment Lambda"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ALLOW LAMBDA TO RETRIEVE THREAT_INTEL_API_KEYS FROM SECRETS MANAGER
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = var.threat_intel_api_keys_arn
      },
      # PUBLISH ENRICHED ALERT TO SNS
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = var.secops_topic_arn
      },
      # ALLOW USE OF LOGS KMS KEY (USED FOR SNS)
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.logs_cmk_arn
      },
      # ALLOW LAMBDA TO WRITE ENRICHMENT NOTES TO FINDINGS
      {
        Effect = "Allow"
        Action = [
          "securityhub:BatchUpdateFindings"
        ]
        Resource = "*"
      },
      # ALLOW LAMBDA TO CALL SECRETS MANAGER KMS KEY
      {
        Effect = "Allow",
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ],
        Resource = var.secrets_manager_cmk_arn
      }
    ]
  })
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