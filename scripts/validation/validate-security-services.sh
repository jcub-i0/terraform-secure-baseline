#!/usr/bin/env bash

# validate-security-services.sh
#
# Validates security services for a deployed tf-secure-baseline environment.
#
# Checks:
# - Terraform effective security-service outputs are readable
# - GuardDuty detector exists and is enabled
# - Security Hub is enabled
# - Inspector is validated when effective_inspector_enabled = true
# - AWS Config is validated when effective_enable_config = true
# - AWS Backup is validated when effective_backup_enabled = true
#
# Usage:
#   ./scripts/validation/validate-security-services.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-security-services.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-security-services.sh dev

