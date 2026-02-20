########################################
# CONFIG BASELINE -- MANAGED RULE PACK #
########################################

locals {
  # Rule catalog (AWS-Managed Rules)
  # Add new rules here; toggles in variables.tf decide what gets created.
  managed_rules = {
    # ------------------------
    # S3 BASELINE
    # ------------------------
    s3_bucket_level_public_access_prohibited = {
      family      = "s3_baseline"
      name_suffix = "s3-bucket-level-public-access-prohibited"
      identifier  = "S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED"
    }
    s3_bucket_public_read_prohibited = {
      family      = "s3_baseline"
      name_suffix = "s3-bucket-public-read-prohibited"
      identifier  = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
    }
    s3_bucket_public_write_prohibited = {
      family      = "s3_baseline"
      name_suffix = "s3-bucket-public-write-prohibited"
      identifier  = "S3_BUCKET_PUBLIC_WRITE_PROHIBITED"
    }
    s3_bucket_sse_enabled = {
      family      = "s3_baseline"
      name_suffix = "s3-bucket-sse-enabled"
      identifier  = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
    }
    s3_bucket_versioning_enabled = {
      family      = "s3_baseline"
      name_suffix = "s3-bucket-versioning-enabled"
      identifier  = "S3_BUCKET_VERSIONING_ENABLED"
    }
    # ------------------------
    # CLOUDTRAIL BASELINE
    # ------------------------
    cloudtrail_enabled = {
      family      = "cloudtrail_baseline"
      name_suffix = "cloudtrail-enabled"
      identifier  = "CLOUD_TRAIL_ENABLED"
    }
    cloudtrail_multi_region_enabled = {
      family      = "cloudtrail_baseline"
      name_suffix = "multi-region-cloudtrail-enabled"
      identifier  = "MULTI_REGION_CLOUD_TRAIL_ENABLED"
    }
    cloudtrail_log_file_validation_enabled = {
      family      = "cloudtrail_baseline"
      name_suffix = "cloudtrail-log-file-validation-enabled"
      identifier  = "CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED"
    }
    # ------------------------
    # RDS BASELINE
    # ------------------------
    rds_storage_encrypted = {
      family      = "rds_baseline"
      name_suffix = "rds-storage-encrypted"
      identifier  = "RDS_STORAGE_ENCRYPTED"
    }
    rds_public_access_check = {
      family      = "rds_baseline"
      name_suffix = "rds-instance-public-access-check"
      identifier  = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK"
    }
    # ------------------------
    # EBS BASELINE
    # ------------------------
    ebs_encrypted_volumes = {
      family      = "ebs_baseline"
      name_suffix = "ebs-encrypted-volumes"
      identifier  = "ENCRYPTED_VOLUMES"
    }
    # ------------------------
    # SECURITY GROUP BASELINE
    # ------------------------
    incoming_ssh_disabled = {
      family      = "sg_baseline"
      name_suffix = "incoming-ssh-disabled"
      identifier  = "INCOMING_SSH_DISABLED"
    }
    # ------------------------
    # IAM BASELINE
    # ------------------------
    root_account_mfa_enabled = {
      family      = "iam_baseline"
      name_suffix = "root-account-mfa-enabled"
      identifier  = "ROOT_ACCOUNT_MFA_ENABLED"
    }
    iam_password_policy = {
      family      = "iam_baseline"
      name_suffix = "iam-password-policy"
      identifier  = "IAM_PASSWORD_POLICY"
    }
    # ------------------------
    # EC2 BASELINE
    # ------------------------
    ec2_ebs_optimized = {
      family      = "ec2_baseline"
      name_suffix = "ebs-optimized-instance"
      identifier  = "EBS_OPTIMIZED_INSTANCE"
    }
    ec2_imdsv2_required = {
      family      = "ec2_baseline"
      name_suffix = "ec2-imdsv2-required"
      identifier  = "EC2_IMDSV2_CHECK"
    }
    ec2_volume_inuse_check = {
      family      = "ec2_baseline"
      name_suffix = "ec2-volume-inuse-check"
      identifier  = "EC2_VOLUME_INUSE_CHECK"
    }
    ec2_no_public_ip = {
      family      = "ec2_baseline"
      name_suffix = "ec2-instance-no-public-ip"
      identifier  = "EC2_INSTANCE_NO_PUBLIC_IP"
    }
    # ------------------------
    # KMS BASELINE
    # ------------------------
    cmk_backing_key_rotation_enabled = {
      family = "kms_baseline"
      name_suffix = "cmk-backing-key-rotation-enabled"
      identifier = "CMK_BACKING_KEY_ROTATION_ENABLED"
    }
    kms_cmk_not_scheduled_for_deletion = {
      family = "kms_baseline"
      name_suffix = "kms-cmk-not-scheduled-for-deletion"
      identifier = "KMS_CMK_NOT_SCHEDULED_FOR_DELETION"
    }
    kms_key_policy_no_public_access = {
      family = "kms_baseline"
      name_suffix = "kms-key-policy-no-public-access"
      identifier = "KMS_KEY_POLICY_NO_PUBLIC_ACCESS"
    }
    kms_key_tagged = {
      family = "kms_baseline"
      name_suffix = "kms-key-tagged"
      identifier = "KMS_KEY_TAGGED"
    }
  }

  # DECIDE WHICH FAMILIES ARE ENABLED VIA THE TOGGLE OBJECT
  enabled_families = {
    s3_baseline         = var.enable_rules.s3_baseline
    cloudtrail_baseline = var.enable_rules.cloudtrail_baseline
    rds_baseline        = var.enable_rules.rds_baseline
    ebs_baseline        = var.enable_rules.ebs_baseline
    sg_baseline         = var.enable_rules.sg_baseline
    iam_baseline        = var.enable_rules.iam_baseline
    ec2_baseline        = var.enable_rules.ec2_baseline
    kms_baseline = var.enable_rules.kms_baseline
  }

  # FILTER RULE CATALOG FOR ONLY ENABLED FAMILIES
  enabled_managed_rules = {
    for k, v in local.managed_rules :
    k => v if local.enabled_families[v.family]
  }
}

# CREATE ALL ENABLED AWS-MANAGED CONFIG RULES
resource "aws_config_config_rule" "managed" {
  for_each = var.config_enabled ? local.enabled_managed_rules : {}

  name = "${var.config_rule_name_prefix}-${each.value.name_suffix}"

  source {
    owner             = "AWS"
    source_identifier = each.value.identifier
  }

  tags = var.tags
}