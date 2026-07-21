import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import boto3  # type: ignore
from botocore.exceptions import BotoCoreError, ClientError  # type: ignore

# Configure logging once when the Lambda execution environment starts.
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Reuse AWS SDK clients across warm Lambda invocations.
ec2 = boto3.client("ec2")
sns = boto3.client("sns")

QUARANTINE_SG = os.getenv("QUARANTINE_SG_ID", "").strip()
SNS_TOPIC_ARN = os.getenv("SNS_TOPIC_ARN", "").strip()
PROTECTION_TAG = "IsolationAllowed"
ISOLATED_TAG = "Isolated"


def _configured_severities() -> set[str]:
    """Return the explicitly configured Security Hub severities.

    The fail-safe default is CRITICAL only. Set the Lambda environment variable
    AUTO_ISOLATION_SEVERITIES to a comma-separated value such as
    "HIGH,CRITICAL" to opt back into HIGH-severity automatic isolation.
    """
    configured = os.getenv("AUTO_ISOLATION_SEVERITIES", "CRITICAL")
    severities = {
        value.strip().upper()
        for value in configured.split(",")
        if value.strip()
    }
    return severities or {"CRITICAL"}


AUTO_ISOLATION_SEVERITIES = _configured_severities()


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, int]:
    """Process eligible Security Hub EC2 findings and isolate approved instances."""
    del context  # Lambda supplies this argument, but this function does not use it.

    summary = {
        "findings_received": 0,
        "instances_evaluated": 0,
        "instances_isolated": 0,
        "instances_skipped": 0,
        "errors": 0,
    }

    if not QUARANTINE_SG:
        logger.error("QUARANTINE_SG_ID is not configured; aborting isolation")
        summary["errors"] += 1
        return summary

    logger.info(
        "Received event with automatic-isolation severities=%s: %s",
        sorted(AUTO_ISOLATION_SEVERITIES),
        json.dumps(event, default=str),
    )

    findings = event.get("detail", {}).get("findings", [])
    if not isinstance(findings, list):
        logger.error("Event detail.findings is not a list")
        summary["errors"] += 1
        return summary

    summary["findings_received"] = len(findings)
    evaluated_instance_ids: set[str] = set()

    for finding in findings:
        try:
            if not isinstance(finding, dict):
                logger.warning("Skipping malformed finding: %r", finding)
                summary["instances_skipped"] += 1
                continue

            severity = str(
                finding.get("Severity", {}).get("Label", "")
            ).strip().upper()
            workflow = str(
                finding.get("Workflow", {}).get("Status", "")
            ).strip().upper()
            record_state = str(finding.get("RecordState", "ACTIVE")).strip().upper()
            finding_id = str(finding.get("Id", "")).strip()

            if (
                severity not in AUTO_ISOLATION_SEVERITIES
                or workflow != "NEW"
                or record_state != "ACTIVE"
            ):
                logger.info(
                    "Skipping finding %s: severity=%s workflow=%s record_state=%s",
                    finding_id or "<missing>",
                    severity or "<missing>",
                    workflow or "<missing>",
                    record_state or "<missing>",
                )
                continue

            for resource in finding.get("Resources", []):
                if not isinstance(resource, dict):
                    logger.warning("Skipping malformed resource in finding %s", finding_id)
                    summary["instances_skipped"] += 1
                    continue

                if resource.get("Type") != "AwsEc2Instance":
                    logger.info(
                        "Skipping non-EC2 resource type %s in finding %s",
                        resource.get("Type", "<missing>"),
                        finding_id or "<missing>",
                    )
                    continue

                instance_id = str(resource.get("Id", "")).rsplit("/", 1)[-1].strip()
                if not instance_id.startswith("i-"):
                    logger.warning(
                        "Skipping invalid EC2 instance ID %r in finding %s",
                        instance_id,
                        finding_id or "<missing>",
                    )
                    summary["instances_skipped"] += 1
                    continue

                if instance_id in evaluated_instance_ids:
                    logger.info(
                        "Skipping duplicate instance %s in the same invocation",
                        instance_id,
                    )
                    summary["instances_skipped"] += 1
                    continue

                evaluated_instance_ids.add(instance_id)
                summary["instances_evaluated"] += 1

                instance = describe_instance(instance_id)
                if instance is None:
                    summary["instances_skipped"] += 1
                    continue

                if not is_instance_isolatable(instance):
                    summary["instances_skipped"] += 1
                    continue

                if not is_isolation_allowed(instance):
                    summary["instances_skipped"] += 1
                    continue

                if is_already_isolated(instance):
                    summary["instances_skipped"] += 1
                    continue

                # Snapshot only after all eligibility checks pass.
                snapshot_attached_volumes(instance, finding_id)

                if isolate_instance(instance, finding_id):
                    summary["instances_isolated"] += 1
                else:
                    summary["instances_skipped"] += 1

        except (BotoCoreError, ClientError):
            summary["errors"] += 1
            logger.exception(
                "AWS API error while processing finding %s",
                finding.get("Id", "<missing>") if isinstance(finding, dict) else "<malformed>",
            )
        except Exception:
            summary["errors"] += 1
            logger.exception(
                "Unexpected error while processing finding %s",
                finding.get("Id", "<missing>") if isinstance(finding, dict) else "<malformed>",
            )

    logger.info("Isolation invocation summary: %s", json.dumps(summary))
    return summary


def describe_instance(instance_id: str) -> dict[str, Any] | None:
    """Retrieve one current EC2 instance record."""
    logger.info("Describing instance %s", instance_id)

    response = ec2.describe_instances(InstanceIds=[instance_id])
    instances = [
        instance
        for reservation in response.get("Reservations", [])
        for instance in reservation.get("Instances", [])
    ]

    if not instances:
        logger.warning("No instance found with ID %s", instance_id)
        return None

    return instances[0]


def instance_tags(instance: dict[str, Any]) -> dict[str, str]:
    """Return EC2 tags as a simple key/value mapping."""
    return {
        str(tag.get("Key", "")): str(tag.get("Value", ""))
        for tag in instance.get("Tags", [])
        if tag.get("Key")
    }


def is_instance_isolatable(instance: dict[str, Any]) -> bool:
    """Confirm the EC2 instance is in a state where SG replacement is valid."""
    instance_id = str(instance.get("InstanceId", "<unknown>"))
    state = str(instance.get("State", {}).get("Name", "")).lower()

    if state not in {"running", "stopped"}:
        logger.info(
            "Skipping instance %s because state %s is not isolatable",
            instance_id,
            state or "<missing>",
        )
        return False

    return True


def is_isolation_allowed(instance: dict[str, Any]) -> bool:
    """Fail closed unless IsolationAllowed is explicitly set to true."""
    instance_id = str(instance.get("InstanceId", "<unknown>"))
    value = instance_tags(instance).get(PROTECTION_TAG, "").strip().lower()

    if value != "true":
        logger.info(
            "Skipping instance %s because %s is not explicitly true (value=%r)",
            instance_id,
            PROTECTION_TAG,
            value,
        )
        return False

    return True


def is_already_isolated(instance: dict[str, Any]) -> bool:
    """Detect isolation through either the incident tag or quarantine SG."""
    instance_id = str(instance.get("InstanceId", "<unknown>"))
    tags = instance_tags(instance)
    security_groups = [
        str(group.get("GroupId", ""))
        for group in instance.get("SecurityGroups", [])
        if group.get("GroupId")
    ]

    isolated_tag = tags.get(ISOLATED_TAG, "").strip().lower() == "true"
    quarantine_sg_attached = security_groups == [QUARANTINE_SG]

    if isolated_tag or quarantine_sg_attached:
        logger.info(
            "Instance %s is already isolated (tag=%s quarantine_sg_attached=%s)",
            instance_id,
            isolated_tag,
            quarantine_sg_attached,
        )
        return True

    return False


def snapshot_attached_volumes(
    instance: dict[str, Any],
    finding_id: str,
) -> list[str]:
    """Create tagged snapshots of all attached EBS volumes before isolation.

    Any snapshot error is propagated so the caller fails closed and does not
    isolate an instance without first requesting snapshots for all EBS volumes.
    """
    instance_id = str(instance["InstanceId"])
    snapshot_ids: list[str] = []

    for device in instance.get("BlockDeviceMappings", []):
        volume_id = device.get("Ebs", {}).get("VolumeId")
        device_name = str(device.get("DeviceName", "unknown"))

        if not volume_id:
            continue

        logger.info(
            "Creating snapshot for volume %s on instance %s (%s)",
            volume_id,
            instance_id,
            device_name,
        )

        response = ec2.create_snapshot(
            Description=(
                f"Snapshot of {volume_id} from instance {instance_id} "
                "prior to EC2 isolation"
            ),
            VolumeId=volume_id,
            TagSpecifications=[
                {
                    "ResourceType": "snapshot",
                    "Tags": [
                        {
                            "Key": "Name",
                            "Value": f"{instance_id}-{volume_id}-pre-isolation",
                        },
                        {"Key": "CreatedBy", "Value": "LambdaAutoResponse"},
                        {"Key": "InstanceId", "Value": instance_id},
                        {"Key": "IsolationFinding", "Value": finding_id[:256]},
                    ],
                }
            ],
        )

        snapshot_id = str(response["SnapshotId"])
        snapshot_ids.append(snapshot_id)
        logger.info(
            "Requested and tagged snapshot %s for volume %s",
            snapshot_id,
            volume_id,
        )

    logger.info(
        "Requested %d pre-isolation snapshot(s) for instance %s",
        len(snapshot_ids),
        instance_id,
    )
    return snapshot_ids


def isolate_instance(instance: dict[str, Any], finding_id: str) -> bool:
    """Replace the instance SGs and add incident-response state tags."""
    instance_id = str(instance["InstanceId"])

    # Defensive rechecks keep this function safe if called independently.
    if not is_instance_isolatable(instance):
        return False
    if not is_isolation_allowed(instance):
        return False
    if is_already_isolated(instance):
        return False

    original_sgs = [
        str(group["GroupId"])
        for group in instance.get("SecurityGroups", [])
        if group.get("GroupId")
    ]

    if not original_sgs:
        logger.error(
            "Instance %s has no security groups to preserve; aborting isolation",
            instance_id,
        )
        return False

    logger.info(
        "Replacing security groups on instance %s: original=%s quarantine=%s",
        instance_id,
        original_sgs,
        QUARANTINE_SG,
    )

    ec2.modify_instance_attribute(
        InstanceId=instance_id,
        Groups=[QUARANTINE_SG],
    )

    isolation_time = datetime.now(timezone.utc).isoformat()
    ec2.create_tags(
        Resources=[instance_id],
        Tags=[
            {"Key": ISOLATED_TAG, "Value": "true"},
            {"Key": "IsolatedBy", "Value": "LambdaAutoResponse"},
            {"Key": "IsolationFinding", "Value": finding_id[:256]},
            {"Key": "IsolationTime", "Value": isolation_time},
            {"Key": "OriginalSecurityGroups", "Value": ",".join(original_sgs)},
        ],
    )

    logger.info("Successfully isolated instance %s", instance_id)
    publish_to_sns(instance_id, finding_id, original_sgs, isolation_time)
    return True


def publish_to_sns(
    instance_id: str,
    finding_id: str,
    original_sgs: list[str],
    isolation_time: str,
) -> None:
    """Publish an isolation notification when an SNS topic is configured."""
    if not SNS_TOPIC_ARN:
        logger.warning("SNS_TOPIC_ARN is not configured; skipping notification")
        return

    original_sg_text = ",".join(original_sgs)
    message = (
        f"EC2 instance {instance_id} was automatically isolated.\n"
        f"Finding ID: {finding_id}\n"
        f"Original security groups: {original_sg_text}\n"
        f"Quarantine security group: {QUARANTINE_SG}\n"
        f"Timestamp: {isolation_time}"
    )

    logger.info(
        "Publishing isolation notification for instance %s to %s",
        instance_id,
        SNS_TOPIC_ARN,
    )

    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="EC2 automatic isolation triggered",
            Message=message,
        )
        logger.info("SNS notification sent for instance %s", instance_id)
    except (BotoCoreError, ClientError):
        # Isolation has already succeeded; notification failure must not roll it back.
        logger.exception(
            "Failed to send SNS notification for instance %s",
            instance_id,
        )