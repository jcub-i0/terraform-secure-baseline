#######################################
# CONFIG BASELINE -- GENERAL PLUMBING #
#######################################

## CONFIGURATION RECORDER
resource "aws_config_configuration_recorder" "config" {
  name     = var.name_prefix
  role_arn = var.config_role_arn

  recording_group {
    # Include current and future supported resource types, including KMS keys.
    # Record global IAM resources in the designated us-east-1 Region; reuse in
    # other Regions requires an explicit global-IAM support review.
    all_supported                 = true
    include_global_resource_types = true

    recording_strategy {
      use_only = "ALL_SUPPORTED_RESOURCE_TYPES"
    }
  }
}

## DELIVERY CHANNEL
resource "aws_config_delivery_channel" "config" {
  s3_bucket_name = var.centralized_logs_bucket_name
  s3_key_prefix  = "Config"
  s3_kms_key_arn = var.logs_cmk_arn
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
  #checkov:skip=CKV2_AWS_45:Recorder activation follows enable_config; minimal is intentionally disabled by default while enabled profiles undergo live recorder validation.
  name       = aws_config_configuration_recorder.config.name
  is_enabled = var.enable_config

  depends_on = [
    time_sleep.wait_for_config_recorder
  ]
}
