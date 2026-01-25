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
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")

def lambda_handler(event, context):
    
    logger.info(f"Received rollback event: {json.dumps(event, indent=2)}")
    
    detail = event.get("detail", {})

    instance_id = detail.get("instance_id")
    approved_by = detail.get("approved_by")
    ticket_id = detail.get("ticket_id")
    reason = detail.get("reason")

    if not instance_id or not approved_by or not ticket_id:
        logger.error("Missing required rollback fields")
        return
    
    instance = get_instances(instance_id)
    if not instance:
        return


def get_instances(instance_id):
    try:
        response = ec2.describe_instances(InstanceIds=[instance_id])
        return response["Reservations"]

    except Exception as e:
        logger.error(f"Could not retrieve instance {instance_id}: {str(e)}")
        return

def validate_security_groups(group_ids):
    try:
        ec2.describe_security_groups(GroupIds=[group_ids])
        logger.info("All original security groups validated")
    except Exception as e:
        logger.error(f"Security group validation failed: {str(e)}")
        raise

def restore_security_groups(instance_id, group_ids):
    logger.info(f"Restoring SGs on {instance_id}: {group_ids}")

    ec2.modify_instance_attribute(
        InstanceId = instance_id,
        Groups = group_ids
    )

    logger.info("Security groups restored successfully.")

