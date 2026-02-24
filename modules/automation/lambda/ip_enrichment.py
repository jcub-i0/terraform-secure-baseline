import boto3 # type: ignore
import os
import logging
import requests # type: ignore
import json

logger = logging.getLogger()
logger.setLevel(logging.INFO)
sns = boto3.client('sns')