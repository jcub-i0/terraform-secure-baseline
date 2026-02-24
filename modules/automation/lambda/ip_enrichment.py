import boto3 # type: ignore
import os
import logging
import json
import re
import urllib.request
import urllib.parse
from typing import Any, Dict, List, Optional, Set, Tuple

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client("sns")
secretsmanager = boto3.client("secretsmanager")
securityhub = boto3.client("securityhub")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
THREAT_INTEL_SECRET_ARN = os.environ.get("THREAT_INTEL_SECRET_ARN")
SECURITYHUB_REGION = os.environ.get("SECURITYHUB_REGION")
WRITE_TO_SECURITYHUB = os.environ.get("WRITE_TO_SECURITYHUB", "true")

# CACHE SECRET ACROSS INVOCATIONS
_cached_abuseipdb_key: Optional[str] = None

# BASIC IP REGEX
_IPV4_RE = re.compile(r"\b(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\b")
# BASIC IPV6 REGEX
_IPV6_RE = re.compile(r"\b(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}\b")

# GUARDRAILS
MAX_IPS_PER_EVENT = int(os.environ.get("MAX_IPS_PER_EVENT", "25"))
ABUSEIPDB_MAX_AGE_DAYS = os.environ.get("ABUSEIPDB_MAX_AGE_DAYS", "90")