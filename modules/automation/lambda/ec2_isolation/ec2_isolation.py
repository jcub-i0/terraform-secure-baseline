import boto3
import os
import json
from datetime import datetime, timezone

ec2 = boto3.client("ec2")

QUARANTINE_SG = os.environ["QUARANTINE_SG_ID"]
PROTECTION_TAG = "IsolationAllowed"

def lambda_handler(event, context):
    
    print("Received event:")
    print(json.dumps(event, indent=2))

    findings = event.get("detail", {}).get("findings", [])

    for finding in findings:

        try:
            severity = finding.get("Severity", {}).get("Label")
            workflow = finding.get("Workflow", {}).get("Status")

            if severity not in ["HIGH", "CRITICAL"] or workflow != "NEW":
                print("Skipping finding due to severity/workflow")
                continue

            for resource in finding.get("Resources", []):
                if resource.get("Type") != "AwsEc2Instance":
                    continue

                instance_id = resource.get("Id", "").split("/")[-1]

                print(f"Processing instance: {instance_id}")

                isolate_instance(instance_id, finding["Id"])

        except Exception as e:
            print(f"Error processing finding: {str(e)}")


def isolate_instance(instance_id, finding_id):
    try:
        response = ec2.describe_instances(InstanceIds=[instance_id])
    except Exception as e:
        print(f"Describe failed for {instance_id}: {str(e)}")
        return

    instance = response["Reservations"][0]["Instances"][0]
    state = instance["State"]["Name"]

    if state not in ['running', 'stopped']:
        print("Instance not in isolatable state")
        return
    
    tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}

    if tags.get(PROTECTION_TAG, "").lower() == "false":
        print("Instance is protected from isolation")
        return
    
    original_sgs = [sg["GroupId"] for sg in instance["SecurityGroups"]]

    if original_sgs == [QUARANTINE_SG]:
        print("Instance is already isolated")
        return
    
    print(f"Original SGs: {original_sgs}")

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
                "Value": "Lambda"
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

    print(f"SUCCESS: Instance {instance_id} isolated.")