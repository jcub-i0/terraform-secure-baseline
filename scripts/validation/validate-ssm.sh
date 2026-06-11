#!/usr/bin/env bash

# validate-ssm.sh
#
# Validates SSM access and operational readiness for a deployed
# tf-secure-baseline workload environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - SSM-managed instances are discovered
# - Managed instances are online
# - Managed instances use expected tf-secure-baseline names/tags
# - SSM instance associations are reported
# - SSM maintenance windows are reported
# - SSM patch baselines are reported
#
# Usage:
#   ./scripts/validation/validate-ssm.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-ssm.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-ssm.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-ssm.sh dev