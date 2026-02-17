########################################
# CONFIG BASELINE -- AUTO REMEDIATIONS #
########################################

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