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

def tag_release(instance_id, approved_by, ticket_id, reason):
    ec2.create_tags(
        Resources = [instance_id],
        Tags = [
            {
                "Key": "Isolated", "Value": "false"
            },
            {
                "Key": "IsolationReleased", "Value": "true"
            },
            {
                "Key": "ReleaseTime", "Value": datetime.now(timezone.utc).isoformat()
            },
            {
                "Key": "ReleaseApprovedBy", "Value": approved_by
            },
            {
                "Key": "ReleaseTicket", "Value": ticket_id
            },
            {
                "Key": "ReleaseReason", "Value": reason
            }
        ]
    )

    logger.info(f"Release tags applied to {instance_id}")

def publish_to_sns(instance_id, sgs, approved_by, ticket_id):
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set. Skipping SNS notification.")

    message = (
        f"✅ EC2 instance {instance_id} was RELEASED from quarantine. \n\n"
        f"Approved by: {approved_by}\n"
        f"Ticket: {ticket_id}\n"
        f"Restored SGs: {sgs}\n"
        f"Timestamp: {datetime.now(timezone.utc).isoformat()}"
    )

    sns.publish(
        TopicArn = SNS_TOPIC_ARN,
        Subject = "EC2 QUARANTINE RELEASED",
        Message = message
    )

    logger.info("SNS notification sent.")