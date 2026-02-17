#######################################
# CONFIG BASELINE -- GENERAL PLUMBING #
#######################################

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