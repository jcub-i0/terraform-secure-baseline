import boto3
import os
import json
from datetime import datetime

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
    pass