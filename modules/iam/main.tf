# EC2 Roles and Policies
## EC2 Role
resource "aws_iam_role" "ec2_role" {
  name = "ec2_compute_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

## Allow SSM to access EC2 resources
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

## Allow EC2 to push logs and metrics to CloudWatch
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

## Create EC2 Instance Profile to attach the ec2_role IAM Role, thus allowing EC2 compute instance(s) to inherit the role
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "tf_sec_baseline_ec2_compute_instance_profile"
  role = aws_iam_role.ec2_role.name
}

# CLOUDTRAIL
## CLOUDTRAIL ROLE
resource "aws_iam_role" "cloudtrail" {
  name = "cloudtrail-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "cloudtrail.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

##CLOUDTRAIL ROLE POLICY
resource "aws_iam_role_policy" "cloudtrail" {
  role = aws_iam_role.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${var.cloudtrail_log_group_arn}:*"
    }]
  })
}

# VPC FLOWLOGS
## FLOWLOGS ROLE
resource "aws_iam_role" "flowlogs" {
  name = "VpcFlowLogsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Role = "VPCFlowLogs"
  }
}

## FLOWLOGS POLICY
resource "aws_iam_role_policy" "flowlogs" {
  name = "VpcFlowLogsPolicy"
  role = aws_iam_role.flowlogs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

# CONFIG SERVICE-LINKED ROLE
resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

# CONFIG REMEDIATION ROLE
resource "aws_iam_role" "config_remediation" {
  name = "ConfigRemediationRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ssm.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.account_id
        }
      }
    }]
  })
}

data "aws_iam_policy" "ssm_automation" {
  name = "AmazonSSMAutomationRole"
}

resource "aws_iam_role_policy_attachment" "config_ssm_automation" {
  role       = aws_iam_role.config_remediation.name
  policy_arn = data.aws_iam_policy.ssm_automation.arn
}

## CONFIG REMEDIATION S3 PUBLIC ACCESS BLOCK POLICY
resource "aws_iam_role_policy" "s3_public_remediation" {
  name = "S3PublicAccessBlockRemediation"
  role = aws_iam_role.config_remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketPublicAccessBlock",
          "s3:PutBucketPublicAccessBlock",
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy"
        ]
        Resource = "*"
      }
    ]
  })
}

# LAMBDA ROLES
## AWS-MANAGED POLICIES FOR LAMBDA LOGGING & VPC ENI ACCESS
data "aws_iam_policy" "lambda_vpc" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy" "lambda_logs" {
  arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

## EC2 ISOLATION LAMBDA
### EC2 ISOLATION LAMBDA EXECUTION ROLE
resource "aws_iam_role" "lambda_ec2_isolation" {
  name = "lambda-ec2-isolation-role"

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
  name = "lambda-ec2-isolation"

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
        ],
        Resource = var.secops_topic_arn
      },
      # ALLOW LAMBDA TO CALL LOGS KMS KEY
      {
        Effect = "Allow",
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ],
        Resource = var.logs_kms_key_arn
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

### ATTACH AWS-MANAGED POLICY FOR LAMBDA LOGGING
resource "aws_iam_role_policy_attachment" "ec2_isolation_logs_attach" {
  role       = aws_iam_role.lambda_ec2_isolation.name
  policy_arn = data.aws_iam_policy.lambda_logs.arn
}

## EC2 ROLLBACK LAMBDA
### EC2 ROLLBACK LAMBDA EXECUTION ROLE
resource "aws_iam_role" "lambda_ec2_rollback" {
  name = "lambda-ec2-rollback"

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
  name = "lambda-rollback-policy"

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
        ],
        Resource = "*"
      },
      # ALLOW LAMBDA TO CALL SNS
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ],
        Resource = var.secops_topic_arn
      },
      # ALLOW LAMBDA TO CALL LOGS KMS KEY
      {
        Effect = "Allow",
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:DescribeKey"
        ],
        Resource = var.logs_kms_key_arn
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

### ATTACH AWS-MANAGED POLICY FOR LAMBDA LOGGING
resource "aws_iam_role_policy_attachment" "ec2_rollback_logs_attach" {
  role       = aws_iam_role.lambda_ec2_rollback.name
  policy_arn = data.aws_iam_policy.lambda_logs.arn
}

# SECURITY OPERATIONS IAM RESOURCES
## SECOPS IAM ROLE TRUST POLICY
resource "aws_iam_role" "secops" {
  name = "SecOpsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${var.account_id}:root"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringLike = {
          "aws:PrincipalArn" : [
            "arn:aws:iam::${var.account_id}:user/baseline-admin",
            "arn:aws:iam::${var.account_id}:role/SecOps-*"
          ]
        }
      }
    }]
  })

  tags = {
    Role = "SecurityOperations"
  }
}

### ROLLBACK TRIGGER POLICY
resource "aws_iam_policy" "secops_rollback_trigger" {
  name = "SecOpsRollbackTriggerPolicy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowEc2RollbackEventOnly"
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = "arn:aws:events:${var.primary_region}:${var.account_id}:event-bus/security-operations-bus"
      }
    ]
  })
}

### ATTACH SECURITY OPERATIONS POLICY TO SECURITY OPERATIONS ROLE
resource "aws_iam_role_policy_attachment" "secops_rollback_attach" {
  role       = aws_iam_role.secops.name
  policy_arn = aws_iam_policy.secops_rollback_trigger.arn
}