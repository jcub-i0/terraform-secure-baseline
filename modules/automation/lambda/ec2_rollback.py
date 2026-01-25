import boto3 # type: ignore
import os
import json
import logging
from datetime import datetime, timezone

# CONFIGURE ROOT LOGGER WHEN LAMBDA STARTS
logging.basicConfig(level=logging.INFO)

# DEFINE LOGGER VARIABLE FOR LOGGING CAPABILITIES
logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client("ec2")