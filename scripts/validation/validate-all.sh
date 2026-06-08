#!/usr/bin/env bash

# validate-all.sh
#
# Runs the full tf-secure-baseline post-deployment validation suite for a single
# environment.
#
# Usage:
#   ./scripts/validation/validate-all.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-all.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-all.sh dev
