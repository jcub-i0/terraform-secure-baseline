# Automation Module

This Terraform module provisions security automation workflows driven by AWS Security Hub findings. It deploys Lambda responders, EventBridge rules/bus integrations, encrypted logging, and secret management to support automated containment and controlled recovery.

## What this module does

The module creates three automation pipelines:

1. **EC2 isolation automation**
   - Packages and deploys `ec2_isolation.py` as a Lambda function.
   - Listens for **HIGH/CRITICAL** Security Hub findings on `AwsEc2Instance` resources with workflow status `NEW`.
   - Takes EBS snapshots before isolation.
   - Replaces instance security groups with a quarantine SG.
   - Tags the instance with isolation metadata and notifies a SecOps SNS topic.

2. **EC2 rollback automation**
   - Packages and deploys `ec2_rollback.py` as a Lambda function.
   - Creates a dedicated **SecOps EventBridge custom bus** and bus policy for rollback event intake.
   - Invokes rollback Lambda on `custom.rollback` events.
   - Restores original security groups from instance tags, writes release/audit tags, and sends SNS notification.

3. **IP enrichment automation**
   - Packages and deploys `ip_enrichment.py` as a Lambda function.
   - Listens for **HIGH/CRITICAL** Security Hub findings.
   - Extracts public IPs from findings and enriches reputation context via AbuseIPDB.
   - Publishes formatted enrichment reports to SNS.
   - Optionally writes enrichment notes back into Security Hub findings.
   - Stores threat intel API keys in AWS Secrets Manager (KMS-encrypted).

Across all Lambdas, the module enables X-Ray tracing and provisions KMS-encrypted CloudWatch log groups.

## Resources created (high level)

- Lambda functions:
  - `${name_prefix}-ec2-isolation`
  - `${name_prefix}-ec2-rollback`
  - `${name_prefix}-ip-enrichment`
- Lambda security groups for isolation and rollback handlers
- EventBridge rules/targets/permissions for Security Hub-triggered and manual rollback flows
- EventBridge custom bus: `${name_prefix}-secops-bus`
- Event bus policy scoped to approved event sources
- CloudWatch log groups (30-day retention, KMS key)
- Secrets Manager secret + version for threat intel API keys

## Input Variables

| Name | Type | Description |
|---|---|---|
| `vpc_id` | `string` | VPC ID used for Lambda security groups and VPC-attached functions. |
| `name_prefix` | `string` | Prefix used for naming resources. |
| `cloud_name` | `string` | Environment/cloud identifier used by IP enrichment (e.g., User-Agent, Security Hub note author). |
| `environment` | `string` | Environment tag value (e.g., dev, staging, prod). |
| `lambda_ec2_isolation_role_arn` | `string` | IAM role ARN for the EC2 isolation Lambda. |
| `lambda_ec2_rollback_role_arn` | `string` | IAM role ARN for the EC2 rollback Lambda. |
| `lambda_ip_enrichment_role_arn` | `string` | IAM role ARN for the IP enrichment Lambda. |
| `serverless_private_subnet_ids` | `list(string)` | Private subnet IDs for VPC-attached Lambdas (isolation/rollback). |
| `quarantine_sg_id` | `string` | Security group ID applied to EC2 instances during automated isolation. |
| `secops_topic_arn` | `string` | SNS topic ARN for SecOps notifications from all automations. |
| `account_id` | `string` | AWS account ID used in EventBridge bus policy conditions/principals. |
| `primary_region` | `string` | Primary AWS region (declared input; useful for caller-level conventions). |
| `eventbridge_putevents_to_secops_role_arn` | `string` | EventBridge PutEvents role ARN (declared input; intended for caller-level integration patterns). |
| `lambda_cmk_arn` | `string` | KMS CMK ARN for Lambda environment encryption. |
| `secrets_manager_cmk_arn` | `string` | KMS CMK ARN used for Secrets Manager encryption. |
| `interface_endpoints_sg_id` | `string` | Interface endpoint SG ID (declared input; reserved for integration constraints). |
| `logs_cmk_arn` | `string` | KMS CMK ARN for CloudWatch log group encryption. |
| `ip_enrichment_write_to_securityhub` | `bool` | Whether IP enrichment writes notes back to Security Hub findings. |
| `abuseipdb_api_key` | `string (sensitive)` | AbuseIPDB API key stored into Secrets Manager secret version. |
| `ip_enrich_max_ips_per_event` | `string` | Max public IPs enriched per invocation. |
| `ip_enrich_abuseipdb_max_age` | `string` | `maxAgeInDays` sent to AbuseIPDB API queries. |
| `ip_enrich_max_ips_extracted` | `string` | Upper limit of IPs extracted from findings before truncation. |

## Outputs

| Name | Description |
|---|---|
| `secops_event_bus_name` | Name of the custom SecOps EventBridge bus. |
| `secops_event_bus_arn` | ARN of the custom SecOps EventBridge bus. |
| `lambda_ec2_isolation_sg_id` | Security group ID for EC2 isolation Lambda. |
| `lambda_ec2_rollback_sg_id` | Security group ID for EC2 rollback Lambda. |
| `threat_intel_api_keys_arn` | ARN of Secrets Manager secret storing threat intel API keys. |
| `lambda_ip_enrichment_log_group_arn` | ARN of the IP enrichment Lambda CloudWatch log group. |
| `securityhub_high_critical_rule_arn` | ARN of Security Hub HIGH/CRITICAL EventBridge rule used by enrichment. |
| `securityhub_high_critical_rule_name` | Name of Security Hub HIGH/CRITICAL EventBridge rule used by enrichment. |

## Example usage

```hcl
module "automation" {
  source = "../../modules/automation"

  vpc_id                                = module.networking.vpc_id
  name_prefix                           = local.name_prefix
  cloud_name                            = local.cloud_name
  environment                           = var.environment

  lambda_ec2_isolation_role_arn         = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn          = module.iam.lambda_ec2_rollback_role_arn
  lambda_ip_enrichment_role_arn         = module.iam.lambda_ip_enrichment_role_arn

  serverless_private_subnet_ids         = module.networking.serverless_private_subnet_ids
  quarantine_sg_id                      = module.security.quarantine_sg_id
  secops_topic_arn                      = module.monitoring.secops_topic_arn

  account_id                            = data.aws_caller_identity.current.account_id
  primary_region                        = var.primary_region
  eventbridge_putevents_to_secops_role_arn = module.iam.eventbridge_putevents_to_secops_role_arn

  lambda_cmk_arn                        = module.security.lambda_cmk_arn
  secrets_manager_cmk_arn               = module.security.secrets_manager_cmk_arn
  interface_endpoints_sg_id             = module.vpc_endpoints.interface_endpoints_sg_id
  logs_cmk_arn                          = module.logging.logs_cmk_arn

  ip_enrichment_write_to_securityhub    = true
  abuseipdb_api_key                     = var.abuseipdb_api_key
  ip_enrich_max_ips_per_event           = "25"
  ip_enrich_abuseipdb_max_age           = "90"
  ip_enrich_max_ips_extracted           = "200"
}
```

## Operational notes

- Ensure Lambda IAM roles include least-privilege permissions for EC2, SNS, CloudWatch Logs, X-Ray, Security Hub, Secrets Manager, and KMS as appropriate for each function.
- `abuseipdb_api_key` is sensitive and should be provided via secure variable handling (e.g., CI secret store, encrypted tfvars).
- Rollback events must be sent to the custom bus with `source = "custom.rollback"` and include `instance_id`, `approved_by`, and `ticket_id` in `detail`.
- IP enrichment runs outside VPC by design to allow direct internet egress without NAT dependency.
