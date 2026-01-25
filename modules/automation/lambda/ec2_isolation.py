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

QUARANTINE_SG = os.environ["QUARANTINE_SG_ID"]
PROTECTION_TAG = "IsolationAllowed"
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

def lambda_handler(event, context):
    if not QUARANTINE_SG:
        logger.error(f"QUARANTINE_SG not set. Aborting isolation.")
        return
    
    logger.info(f"Received event: {json.dumps(event, indent=2)}")

    findings = event.get("detail", {}).get("findings", [])

    for finding in findings:

        try:
            severity = finding.get("Severity", {}).get("Label")
            workflow = finding.get("Workflow", {}).get("Status")

            if severity not in ["HIGH", "CRITICAL"] or workflow != "NEW":
                logger.info("Skipping finding due to severity/workflow")
                continue

            for resource in finding.get("Resources", []):
                if resource.get("Type") != "AwsEc2Instance":
                    logger.info("Skipping finding due to resource type (not EC2)")
                    continue

                instance_id = resource.get("Id", "").split("/")[-1]

                logger.info(f"Processing instance: {instance_id}")

                # SNAPSHOT INSTANCE VOLUME BEFORE EC2 ISOLATION
                instance = snapshot_attached_volumes(instance_id)
                if instance is None:
                    logger.warning(f"Skipping isolation for {instance_id} due to snapshot failure")
                    continue

                isolate_instance(instance, finding["Id"])

        except Exception as e:
            logger.error(f"ERROR PROCESSING FINDING: {str(e)}")

def snapshot_attached_volumes(instance_id):
    logger.info(f"Describing volumes for instance {instance_id}")

    try:
        # GET INSTANCE DETAILS
        reservations = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
        instances = [i for r in reservations for i in r["Instances"]]

        if not instances:
            logger.warning(f"No instance found with ID {instance_id}")
            return
        
        instance = instances[0]

        # SKIP SNAPSHOT IF INSTANCE IS ALREADY QUARANTINED
        tags = {tag["Key"]: tag["Value"] for tag in instance.get("Tags", [])}
        if tags.get("Isolated", "") == "true":
            logger.info(f"Instance {instance_id} is already quarantined; skipping snapshot")
            return
        
        for device in instance.get("BlockDeviceMappings", []):
            volume_id = device.get("Ebs", {}).get("VolumeId")
            device_name = device.get("DeviceName")

            if volume_id:
                logger.info(f"Creating snapshot for EBS volume {volume_id} ({device_name})")
                description = f"Snapshot of {volume_id} from instance {instance_id} prior to EC2 isolation"

                # CREATE VOLUME SNAPSHOT
                response = ec2.create_snapshot(
                    Description = description,
                    VolumeId = volume_id,
                    TagSpecifications = [
                        {"Key": "Name", "Value": f"{instance_id}-{volume_id}"},
                        {"Key": "CreatedBy", "Value": "LambdaAutoResponse"},
                        {"Key": "InstanceId", "Value": instance_id}
                    ]
                )

                snapshot_id = response["SnapshotId"]
                logger.info(f"Snapshot {snapshot_id} successfully created for instance {instance_id}")

    except Exception as e:
        logger.error(f"Failed to create snapshot: {str(e)}")
        raise

    return instance

def isolate_instance(instance, finding_id):
    instance_id = instance["InstanceId"]
    state = instance["State"]["Name"]

    if state not in ['running', 'stopped']:
        logger.info(f"Instance {instance_id} not in isolatable state")
        return
    
    tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}

    if tags.get(PROTECTION_TAG, "").lower() == "false":
        logger.info(f"Instance {instance_id} is protected from isolation")
        return
    
    original_sgs = [sg["GroupId"] for sg in instance["SecurityGroups"]]

    if original_sgs == [QUARANTINE_SG]:
        logger.info(f"Instance {instance_id} is already isolated")
        return
    
    logger.info(f"Original SGs: {original_sgs}")

    # REPLACE SGS
    ec2.modify_instance_attribute(
        InstanceId = instance_id,
        Groups = [QUARANTINE_SG]        
    )

    # CREATE TAGS
    ec2.create_tags(
        Resources = [
            instance_id
        ],
        Tags = [
            {
                "Key": PROTECTION_TAG,
                "Value": "false"
            },
            {
                "Key": "Isolated",
                "Value": "true"
            },
            {
                "Key": "IsolatedBy",
                "Value": "LambdaAutoResponse"
            },
            {
                "Key": "IsolationFinding",
                "Value": finding_id
            },
            {
                "Key": "IsolationTime",
                "Value": datetime.now(timezone.utc).isoformat()
            },
            {
                "Key": "OriginalSecurityGroups",
                "Value": ",".join(original_sgs)
            }
        ]
    )

    logger.info(f"SUCCESS: Instance {instance_id} isolated.")

    # SEND SNS NOTIFICATION
    publish_to_sns(instance_id, finding_id, original_sgs)

def publish_to_sns(instance_id, finding_id, original_sgs):
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN not set. Skipping alert notification.")
        return
    
    message = (
        f"🚨 EC2 instance {instance_id} was automatically isolated!\n"
        f"Finding ID: {finding_id}\n"
        f"Original Security Groups: {",".join(original_sgs)}\n"
        f"Quarantine SG: {QUARANTINE_SG}\n"
        f"Timestamp: {datetime.now(timezone.utc).isoformat()}"
    )

    logger.info(f"Publishing to SNS Topic {SNS_TOPIC_ARN} with message:\n{message}")

    try:
        sns.publish(
            TopicArn = SNS_TOPIC_ARN,
            Subject = "LAMBDA TRIGGERED: EC2 ISOLATION",
            Message = message
        )
        logger.info("SNS notification sent")
    except Exception as e:
        logger.error(f"FAILED TO SEND SNS NOTIFICATION: {str(e)}")