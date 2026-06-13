#!/usr/bin/env bash

# validate-compute.sh
#
# Validates EC2 compute resources for a deployed tf-secure-baseline workload
# environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - VPC is resolved
# - Compute and quarantine security groups exist
# - EC2 instances exist and are private
# - EC2 instances are in compute private subnets
# - EC2 instances have no public IPs
# - EC2 instances enforce IMDSv2
# - EC2 instances have detailed monitoring enabled
# - EC2 instances have IAM instance profiles
# - Required automation/operations tags exist
# - Root EBS volumes are encrypted, gp3, 20 GiB
# - Root EBS volumes use a KMS key
#
# Usage:
#   ./scripts/validation/validate-compute.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-compute.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-compute.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-compute.sh dev