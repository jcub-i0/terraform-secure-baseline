#!/usr/bin/env bash

# validate-backup.sh
#
# Validates AWS Backup resources for a deployed tf-secure-baseline workload
# environment.
#
# Checks:
# - Terraform outputs are readable
# - effective_backup_enabled is respected
# - AWS caller identity is valid
# - Backup vault exists when backups are enabled
# - Backup vault encryption is configured
# - Backup plan exists when backups are enabled
# - Backup plan targets the expected vault
# - Backup selection exists when backups are enabled
# - Backup selection uses the expected tag-based selection model
# - Backup service role is configured on the selection
# - Recovery points and recent backup jobs are reported
#
# Usage:
#   ./scripts/validation/validate-backup.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-backup.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-backup.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-backup.sh dev