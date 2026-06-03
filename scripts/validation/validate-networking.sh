#!/usr/bin/env bash

# validate-networking.sh
#
# Validates core networking behavior for a deployed tf-secure-baseline
# environment based on the effective egress mode.
#
# Usage:
#   ./scripts/validation/validate-networking.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-networking.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-networking.sh dev