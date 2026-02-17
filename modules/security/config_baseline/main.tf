# CONFIG

## CONFIGURATION RECORDER
resource "aws_config_configuration_recorder" "config" {
  name     = "tf-secure-baseline"
  role_arn = var.config_role_arn

  recording_group {
    all_supported                 = false
    include_global_resource_types = false
    exclusion_by_resource_types {
      resource_types = [
        "AWS::FraudDetector::EntityType",
        "AWS::FraudDetector::Label"
      ]
    }
    recording_strategy {
      use_only = "EXCLUSION_BY_RESOURCE_TYPES"
    }

  }
}

## DELIVERY CHANNEL
resource "aws_config_delivery_channel" "config" {
  s3_bucket_name = var.centralized_logs_bucket_name
  s3_key_prefix  = "Config"
  s3_kms_key_arn = var.logs_kms_key_arn
  sns_topic_arn  = var.compliance_topic_arn

  depends_on = [
    aws_config_configuration_recorder.config
  ]
}

resource "time_sleep" "wait_for_config_recorder" {
  depends_on      = [aws_config_delivery_channel.config]
  create_duration = "20s"
}

## CONFIGURATION RECORDER STATUS
resource "aws_config_configuration_recorder_status" "config" {
  name       = aws_config_configuration_recorder.config.name
  is_enabled = true

  depends_on = [
    time_sleep.wait_for_config_recorder
  ]
}

# CONFIG REMEDIATIONS
## S3 PUBLIC ACCESS BLOCK CONFIG REMEDIATION
### S3 PUBLIC ACCESS REMEDIATION RULE
resource "aws_config_config_rule" "s3_public_access_block" {
  name = "s3-bucket-public-read-block"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED"
  }
}

### REMEDIATION TO AUTOMATICALLY DISABLE S3 PUBLIC READ AND WRITE
resource "aws_config_remediation_configuration" "s3_public_access_block" {
  config_rule_name           = aws_config_config_rule.s3_public_access_block.name
  resource_type              = "AWS::S3::Bucket"
  target_type                = "SSM_DOCUMENT"
  target_id                  = "AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock"
  automatic                  = true
  maximum_automatic_attempts = 3
  retry_attempt_seconds      = 60

  parameter {
    name         = "AutomationAssumeRole"
    static_value = var.config_remediation_role_arn
  }

  parameter {
    name           = "BucketName"
    resource_value = "RESOURCE_ID"
  }
}

## RULE TO DETECT EC2 INSTANCES WITH PUBLIC IP ADDRESSES
resource "aws_config_config_rule" "ec2_no_public_ip" {
  name = "ec2-no-public-ip"

  source {
    owner             = "AWS"
    source_identifier = "EC2_INSTANCE_NO_PUBLIC_IP"
  }
}