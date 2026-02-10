# IAM ACCESS ANALYZER
resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "account-access-analyzer"
  type          = "ACCOUNT"

  tags = {
    Terraform = "true"
  }
}

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

### POLICY FOR FLOWLOGS ROLE
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
      Resource = "${var.flowlogs_log_group_arn}:*"
    }]
  })
}

## CLOUDWATCH TO FIREHOSE ROLE
resource "aws_iam_role" "cw_to_firehose" {
  name = "CloudWatchLogsToFirehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

### POLICY FOR CLOUDWATCH TO FIREHOSE ROLE
resource "aws_iam_role_policy" "cw_to_firehose" {
  role = aws_iam_role.cw_to_firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "firehose:PutRecord",
        "firehose:PutRecordBatch"
      ]
      Resource = var.flowlogs_firehose_delivery_stream_arn
    }]
  })
}

# KINESIS FIREHOSE
## FIREHOSE FLOW LOGS ROLE
resource "aws_iam_role" "firehose_flow_logs" {
  name = "FirehoseFlowLogsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "firehose.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

## FIREHOSE FLOW LOGS POLICY
resource "aws_iam_role_policy" "firehose_flow_logs" {
  role = aws_iam_role.firehose_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ALLOW FIREHOSE TO USE CENTRALIZED LOGS S3 BUCKET
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.centralized_logs_bucket_arn,
          "${var.centralized_logs_bucket_arn}/*"
        ]
      },
      # ALLOW FIREHOSE TO USE LOGS KMS KEY
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = var.logs_kms_key_arn
      }
    ]
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
}

## GENERIC POLICY TO ALLOW READ ACCESS TO CENTRALIZED LOGS S3 BUCKET
resource "aws_iam_policy" "logs_s3_readonly" {
  name = "CentralizedLogsS3ReadOnly"
  description = "Read-only access to Centralized Logs S3 bucket (no delete, no write)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # LIST BUCKET + READ BUCKET METADATA
      {
        Sid = "ListCentralizedLogsBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = var.centralized_logs_bucket_arn
      },
      # READ OBJECTS + VERSIONS
      {
        Sid = "ReadCentralizedLogsObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${var.centralized_logs_bucket_arn}/*"
      }
    ]
  })
}

## ALLOW DECRYPTION OF OBJECTS ENCRYPTED WITH THE LOGS CMK
resource "aws_iam_policy" "logs_kms_decrypt" {
  name = "LogsKmsDecrypt"
  description = "Allow decryption of objects encrypted with the Logs CMK"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "AllowDecryptLogsKey"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.logs_kms_key_arn
      }
    ]
  })
}

## ATTACH CENTRALIZED LOGS READ ONLY POLICY TO SECOPS ROLE
resource "aws_iam_role_policy_attachment" "logs_s3_readonly_secops" {
  policy_arn = aws_iam_policy.logs_s3_readonly.arn
  role = aws_iam_role.secops.name
}

## ATTACH LogsKmsReadOnly POLICY TO SECOPS ROLE
resource "aws_iam_role_policy_attachment" "logs_kms_decrypt_secops" {
  policy_arn = aws_iam_policy.logs_kms_decrypt.arn
  role = aws_iam_role.secops.name
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

# EVENTBRIDGE ROLE
resource "aws_iam_role" "eventbridge_putevents_to_secops" {
  name = "EventBridgePutEventsToSecopsBus"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ALLOW EVENTBRIDGE TO PUT EVENTS TO SECOPS BUS
resource "aws_iam_role_policy" "eventbridge_putevents_to_secops" {
  role = aws_iam_role.eventbridge_putevents_to_secops.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = var.secops_event_bus_arn
    }]

  })
}