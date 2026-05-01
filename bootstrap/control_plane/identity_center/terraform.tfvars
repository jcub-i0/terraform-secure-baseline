cloud_name                           = "tf-secure-baseline"
primary_region_dev                   = "us-east-1"
primary_region_prod                  = "us-east-1"
primary_region_staging               = "us-east-1"

logs_s3_readonly_policy_name_dev     = "tf-secure-baseline-dev-CentralizedLogsS3ReadOnly"
logs_cmk_decrypt_policy_name_dev = "tf-secure-baseline-dev-LogsKmsDecrypt"

logs_s3_readonly_policy_name_prod    = "tf-secure-baseline-prod-CentralizedLogsS3ReadOnly"
logs_cmk_decrypt_policy_name_prod = "tf-secure-baseline-prod-LogsKmsDecrypt"

logs_s3_readonly_policy_name_staging = "tf-secure-baseline-staging-CentralizedLogsS3ReadOnly"
logs_cmk_decrypt_policy_name_staging = "tf-secure-baseline-staging-LogsKmsDecrypt"