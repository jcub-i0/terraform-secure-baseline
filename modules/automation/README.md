# Automation Module

## Overview

The `automation` module deploys event-driven security automation for the AWS security baseline.

It creates the Lambda functions, EventBridge rules, EventBridge targets, Lambda permissions, CloudWatch log groups, SQS DLQs, DLQ alarms, supporting Lambda security groups, a custom SecOps EventBridge bus, and a Secrets Manager secret used by the threat intelligence workflow.

This module owns the response resources and Python handlers described below. IAM roles are supplied by [IAM](../iam/README.md); security-group rules are supplied by [security policy](../networking/security_policy/README.md). Deployment does not by itself prove successful containment, recovery, notification delivery, or effective authorization.

---

## Purpose

This module provides automation for:

- Requesting snapshots and isolating opted-in EC2 instances for eligible GuardDuty findings imported through Security Hub
- Rolling back isolated EC2 instances through a controlled SecOps workflow
- Enriching Security Hub findings with external threat intelligence
- Routing workflow events through EventBridge
- Retaining failed automation events in workflow-specific DLQs
- Alerting SecOps when automation DLQs receive messages

---

## Architecture

```text
Security Hub Finding
    |
    +--> EventBridge Rule: HIGH / CRITICAL GuardDuty EC2 Finding
    |       |
    |       v
    |   EC2 Isolation Lambda
    |       |
    |       +--> Quarantine Security Group + SNS Alert
    |       |
    |       +--> EC2 Isolation DLQ
    |
    +--> EventBridge Rule: HIGH / CRITICAL Finding
            |
            v
        IP Enrichment Lambda
            |
            +--> Threat Intel Lookup + SNS Alert
            |
            +--> IP Enrichment DLQ

Approved operational event submission
    |
    | custom.rollback event
    v
Custom EventBridge Bus: <name_prefix>-secops-bus
    |
    v
EC2 Rollback Lambda
    |
    +--> Restore Original Security Groups + SNS Alert
    |
    +--> EC2 Rollback DLQ
```

The diagram shows intended processing and configured failure destinations, not a guarantee that every processing error creates a DLQ message. EventBridge and Lambda have separate retry/error semantics, described under [Failure Handling](#failure-handling). The bus name does not establish an Operator-only authorization boundary.

---

## Lambda Packaging and Saved-Plan Deployment

The module packages each Python Lambda handler with a managed `archive_file` resource:

| Archive resource | Source file | Generated package |
|---|---|---|
| `archive_file.lambda_ec2_isolation` | `lambda/ec2_isolation.py` | `lambda/ec2_isolation.zip` |
| `archive_file.lambda_ec2_rollback` | `lambda/ec2_rollback.py` | `lambda/ec2_rollback.zip` |
| `archive_file.lambda_ip_enrichment` | `lambda/ip_enrichment.py` | `lambda/ip_enrichment.zip` |

Each `aws_lambda_function` references the corresponding archive resource's `output_path` and `output_base64sha256`. This creates an explicit Terraform dependency between package creation and Lambda deployment.

The archives are generated build outputs. They should not be manually maintained or treated as the source of truth; the `.py` files and Terraform configuration are authoritative.

Managed archive resources participate in the repository's saved-plan deployment graph. They reference one handler file each; the module does not implement a dependency-installation or third-party-library packaging step. Retain the source checkout, plan, and deployment logs needed to establish what was packaged and applied. Resource dependencies alone are not evidence that a fresh-runner package build or deployed code-hash comparison was executed successfully.

When adding another Lambda, review its source/package dependency, IAM, routing, failure destinations, and validator inventory together. The three-function validator inventory is explicit; a new function is not automatically covered merely because it uses the same packaging pattern.

---

## Automation Workflows

[main.tf](main.tf) configures all three functions with the following settings;
these are resource settings, not defaults exposed by this module's inputs:

| Function | Runtime | Timeout | Memory | Tracing | Workload VPC attachment |
|---|---|---:|---:|---|---|
| EC2 Isolation | `python3.12` | 60 seconds | 256 MB | `Active` | Supplied serverless-private subnets and isolation Lambda SG |
| EC2 Rollback | `python3.12` | 60 seconds | 256 MB | `Active` | Supplied serverless-private subnets and rollback Lambda SG |
| IP Enrichment | `python3.12` | 60 seconds | 256 MB | `Active` | None |

`reserved_concurrent_executions` is `null` for each function; the commented
numbers next to that setting are not configured concurrency reservations.
The module creates the automation resources independently of the deployment
profile. Profile and workload settings are resolved by the calling baseline.

### EC2 Isolation

The EC2 Isolation EventBridge rule matches HIGH or CRITICAL, NEW, ACTIVE GuardDuty findings imported through Security Hub for `AwsEc2Instance` resources. It matches the exact regional GuardDuty `ProductArn`. The [handler](lambda/ec2_isolation.py) independently rechecks product, severity, workflow, and record state before instance operations; this is narrower than the separate IP Enrichment rule.

The baseline supplies `ec2_auto_isolation_severities`, normally `["CRITICAL"]`, and Terraform joins that set into `AUTO_ISOLATION_SEVERITIES`. This child module has no default for that required input. The Python handler also falls back to `CRITICAL` for an absent or empty severity setting. HIGH events can reach the function, but are skipped unless the supplied severity set includes HIGH.

An instance is isolated only when all of the following are true:

- the finding `ProductArn` equals the regional GuardDuty product ARN;
- the normalized finding severity is included in `AUTO_ISOLATION_SEVERITIES`;
- the finding workflow status is `NEW`;
- the finding record state is `ACTIVE`;
- the resource type is `AwsEc2Instance`, its extracted ID begins with `i-`, and the EC2 describe operation resolves an instance;
- the instance is `running` or `stopped`;
- the instance tag `IsolationAllowed`, after trimming and lowercasing, is `true`;
- the instance is not already marked or configured as isolated; and
- pre-isolation snapshots can be requested for its attached EBS volumes.

After the checks pass, the handler requests one snapshot for each attached EBS
volume and retains the original security-group IDs in memory. It then calls
`modify_instance_attribute`, writes `OriginalSecurityGroups` and the other
isolation tags, and attempts SNS publication, in that order. It does not wait
for snapshots to complete or establish application-consistent recovery.

A snapshot request error prevents that finding's subsequent group replacement,
but snapshots already requested are not automatically deleted. The handler
catches finding-processing exceptions, increments its returned `errors` count,
and normally returns a summary rather than raising a Lambda invocation error.
A zero-depth DLQ is therefore not evidence of successful containment.

Group replacement and tag persistence are not transactional. A failure after
replacement can leave the instance in quarantine without the original-group
tag needed by rollback. A later invocation can skip that instance because it
already has the quarantine SG. Deduplication is local to one invocation; there
is no persistent lock or transaction coordinating concurrent events. The
helper's defensive eligibility rechecks use the previously read instance
record, not a fresh atomic authorization check.

`isolation_allowed` is supplied by the workload root and is not a universal
production/development rule implemented here. Review the selected root,
effective input, and live `IsolationAllowed` tag rather than inferring eligibility
from the environment name. The reusable baseline defaults the setting to false,
but root defaults and workflow-supplied values can differ. Eligibility is
checked by Python; the isolation role's EC2 action statement itself uses
`Resource = "*"` without an `IsolationAllowed` condition.

The quarantine network policy intentionally retains TCP/443 access to the
shared Interface Endpoint SG. It is not complete network disconnection or a
path restricted only to SSM. See [security policy](../networking/security_policy/README.md).

#### EventBridge Match

```text
source      = aws.securityhub
detail-type = Security Hub Findings - Imported
ProductArn  = arn:aws:securityhub:<region>::product/aws/guardduty
severity    = HIGH or CRITICAL
resource    = AwsEc2Instance
workflow    = NEW
record      = ACTIVE
```

#### Runtime Safety Gates

```text
GuardDuty product  = exact regional ProductArn
automatic severity = supplied set; handler fallback CRITICAL
record state       = ACTIVE
instance state     = running or stopped
IsolationAllowed   = true
already isolated   = false
```

#### Resources

| Resource | Purpose |
|---|---|
| `archive_file.lambda_ec2_isolation` | Generates the EC2 isolation Lambda deployment package from `ec2_isolation.py` |
| `aws_lambda_function.ec2_isolation` | Runs the EC2 isolation workflow |
| `aws_security_group.lambda_ec2_isolation_sg` | Security group for the VPC-enabled Lambda |
| `aws_cloudwatch_event_rule.securityhub_ec2_high_critical` | Matches HIGH/CRITICAL, NEW, ACTIVE GuardDuty EC2 findings |
| `aws_cloudwatch_event_target.ec2_isolation` | Sends matching findings to the Lambda |
| `aws_lambda_permission.allow_eventbridge_ec2_isolation` | Allows EventBridge to invoke the Lambda |
| `aws_lambda_function_event_invoke_config.ec2_isolation` | Sends asynchronous Lambda processing failures to the workflow DLQ |
| `aws_cloudwatch_log_group.lambda_ec2_isolation` | Stores encrypted Lambda logs |
| `aws_sqs_queue.ec2_isolation_dlq` | Retains failed EC2 isolation events |
| `aws_sqs_queue_policy.ec2_isolation_dlq` | Allows EventBridge and the Lambda role to send failure messages |
| `aws_cloudwatch_metric_alarm.ec2_isolation_dlq_visible_messages` | Alerts when messages are visible in the DLQ |

---

### EC2 Rollback

The EC2 Rollback workflow restores isolated EC2 instances to their previous security group configuration.

This workflow is routed through a custom SecOps EventBridge bus rather than
the default bus. The rule matches `source = custom.rollback`; it does not
validate approval fields or an approver identity.

The rollback bus policy uses `aws:PrincipalArn` to scope its
`custom.rollback` Allow to IAM Identity Center
`AWSReservedSSO_SecOps-Operator-<environment>_*` role ARNs, including their
AWS-generated suffixes. The role name derives from the permission set,
not the configurable Identity Center group display name. An explicit Deny
rejects `custom.rollback` publication by nonmatching principals even when
another identity policy allows `events:PutEvents`. The separate
`aws.securityhub` forwarding Allow remains unchanged.

The [Identity Center caller](../../bootstrap/control_plane/identity_center/main.tf)
and workload automation now use the same prefixed bus name. The caller derives
it from `cloud_name` and the workload map key; the automation module receives
`name_prefix`. Verify effective group membership, account/Region identity,
and positive/negative publisher authorization in each deployed environment.
The [Identity Center reference](../../bootstrap/control_plane/identity_center/README.md)
covers the separate access model. The handler does not independently authenticate
the supplied human approval or ticket.

#### Trigger

```text
event bus = <name_prefix>-secops-bus
source    = custom.rollback
```

The [rollback handler](lambda/ec2_rollback.py) reads `detail.instance_id`,
`detail.approved_by`, `detail.ticket_id`, and `detail.reason`. It requires the
first three to be truthy; it does not authenticate the named approver or query
a ticket/approval system. The source check is in the EventBridge rule, not an
independent handler check for callers invoking Lambda directly.

It requires `Isolated` to be exactly `"true"` and a nonempty
`OriginalSecurityGroups` tag, describes those groups, restores them, writes
release tags, then publishes an SNS notification. Supply a valid string reason:
the handler does not reject a missing reason at entry but passes it as a tag
value after restoring the groups.

Release tagging sets **`IsolationAllowed=true`**, rather than restoring a saved
previous opt-in value. It leaves the original isolation metadata and snapshots
in place. The compute resource does not ignore `IsolationAllowed` drift, so
reconcile the intended policy through reviewed Terraform inputs after recovery.
Do not describe rollback as restoring every pre-incident setting.

Some early failures return normally; group-validation, restoration, tagging,
and notification exceptions can escape. A failure after group replacement can
leave partially completed recovery. A retry after `Isolated=false` is written
may skip the remaining work. There is no transactional rollback of these steps.

#### Resources

| Resource | Purpose |
|---|---|
| `archive_file.lambda_ec2_rollback` | Generates the EC2 rollback Lambda deployment package from `ec2_rollback.py` |
| `aws_lambda_function.ec2_rollback` | Runs the rollback workflow |
| `aws_security_group.lambda_ec2_rollback_sg` | Security group for the VPC-enabled Lambda |
| `aws_cloudwatch_event_bus.secops` | Custom EventBridge bus for SecOps workflows |
| `aws_cloudwatch_event_bus_policy.secops_bus_policy` | Conditions `custom.rollback` Allow on matching Operator-role identity, explicitly denies non-Operator publishers, and retains separate `aws.securityhub` forwarding Allow |
| `aws_cloudwatch_event_rule.ec2_rollback` | Matches rollback events on the SecOps bus |
| `aws_cloudwatch_event_target.ec2_rollback` | Sends rollback events to the Lambda |
| `aws_lambda_permission.allow_eventbridge_ec2_rollback` | Allows EventBridge to invoke the Lambda |
| `aws_lambda_function_event_invoke_config.ec2_rollback` | Sends asynchronous Lambda processing failures to the workflow DLQ |
| `aws_cloudwatch_log_group.lambda_ec2_rollback` | Stores encrypted Lambda logs |
| `aws_sqs_queue.ec2_rollback_dlq` | Retains failed rollback events |
| `aws_sqs_queue_policy.ec2_rollback_dlq` | Allows EventBridge and the Lambda role to send failure messages |
| `aws_cloudwatch_metric_alarm.ec2_rollback_dlq_visible_messages` | Alerts when messages are visible in the DLQ |

---

### IP Enrichment

The IP Enrichment workflow is triggered by new HIGH or CRITICAL Security Hub findings.

The [handler](lambda/ip_enrichment.py) finds IP-like values in finding fields,
filters candidate addresses, queries AbuseIPDB, and attempts an SNS summary.
Optional Security Hub writeback adds enrichment notes. Its EventBridge rule
matches HIGH/CRITICAL and NEW findings without the isolation rule's
GuardDuty-product, EC2-resource, or ACTIVE-record restrictions. The handler does
not independently reapply all those EventBridge filters to a direct invocation.

`MAX_IPS_PER_EVENT` limits the selected public-IP lookup loop. Requests are
sequential, with a ten-second timeout for each HTTP lookup, within the function's
sixty-second execution limit. Configured maxima are not a guarantee that every
selected address can be processed before timeout. `MAX_IPS_EXTRACTED` is tested
after a whole finding is scanned; it is not a strict cap on candidates collected
from one large finding. Address extraction is heuristic, not a complete parser
for every possible finding representation.

The external request sends selected IP addresses, the configured age filter,
and the API credential to AbuseIPDB. The full finding is not included in that
HTTP query. SNS summaries and Security Hub notes can contain additional finding
metadata. Review this disclosure and the resulting evidence access separately
from private workload networking.

#### Trigger

```text
source      = aws.securityhub
detail-type = Security Hub Findings - Imported
severity    = HIGH or CRITICAL
workflow    = NEW
```

#### Threat Intel Secret

The AbuseIPDB API key is stored in AWS Secrets Manager.

```text
Secret name prefix:
<name_prefix>/threat-intel/api-keys-
```

The secret is encrypted with the Secrets Manager CMK passed into the module.
Its JSON object contains the `ABUSEIPDB_API_KEY` key; the handler accepts that spelling or the
lowercase equivalent. Terraform supplies the value through a secret-version
resource, so marking the input sensitive must not be represented as excluding
it from state and saved-plan handling. Treat those artifacts as sensitive; see
[Terraform sensitive-data handling](https://developer.hashicorp.com/terraform/language/manage-sensitive-data).

The handler caches the retrieved key in the warm execution environment without
an explicit expiry/refresh timer. Updating the secret does not prove that every
warm function environment has fetched the new value. No rotation workflow or
cache-refresh mechanism is configured by this module.

#### Resources

| Resource | Purpose |
|---|---|
| `archive_file.lambda_ip_enrichment` | Generates the IP enrichment Lambda deployment package from `ip_enrichment.py` |
| `aws_lambda_function.ip_enrichment` | Runs threat intelligence enrichment |
| `aws_secretsmanager_secret.threat_intel_api_keys` | Stores threat intelligence API credentials |
| `aws_secretsmanager_secret_version.threat_intel_api_keys` | Stores the current AbuseIPDB API key value |
| `aws_cloudwatch_event_rule.securityhub_high_critical` | Matches high/critical Security Hub findings |
| `aws_cloudwatch_event_target.ip_enrichment` | Sends matching findings to the Lambda |
| `aws_lambda_permission.allow_eventbridge_ip_enrichment` | Allows EventBridge to invoke the Lambda |
| `aws_lambda_function_event_invoke_config.ip_enrichment` | Sends asynchronous Lambda processing failures to the workflow DLQ |
| `aws_cloudwatch_log_group.lambda_ip_enrichment` | Stores encrypted Lambda logs |
| `aws_sqs_queue.ip_enrichment_dlq` | Retains failed IP enrichment events |
| `aws_sqs_queue_policy.ip_enrichment_dlq` | Allows EventBridge and the Lambda role to send failure messages |
| `aws_cloudwatch_metric_alarm.ip_enrichment_dlq_visible_messages` | Alerts when messages are visible in the DLQ |

---

## Failure Handling

Each automation workflow has a dedicated SQS DLQ.

| Workflow | DLQ Name Format | Retention | Encryption |
|---|---|---:|---|
| EC2 Isolation | `<name_prefix>-ec2-isolation-dlq` | 14 days | logs CMK |
| EC2 Rollback | `<name_prefix>-ec2-rollback-dlq` | 14 days | logs CMK |
| IP Enrichment | `<name_prefix>-ip-enrichment-dlq` | 14 days | logs CMK |

The delivery and execution paths are configured separately:

| Path | Configured retries | Maximum event age | Failure destination |
|---|---:|---:|---|
| EventBridge target delivery | 3 | 3600 seconds | Target `dead_letter_config`, the workflow SQS queue |
| Lambda asynchronous invocation | 2 | 3600 seconds | `destination_config.on_failure`, the same workflow SQS queue |

The Lambda setting is an asynchronous on-failure **destination**, not a
`dead_letter_config` block on `aws_lambda_function`. The two producers do not
necessarily produce the same message envelope; inspect producer metadata
before deciding how an event can be replayed. The configured counts are not
an exactly-once processing guarantee or a universal total-attempt count.

DLQ queue policies allow `events.amazonaws.com` to send messages from the matching EventBridge rule. They also allow the corresponding Lambda execution role to send failure messages.

DLQs are terminal failure-retention queues. Messages are not automatically
replayed by this module. Receiving a queue message is itself an
operational action that changes receive/visibility state; follow the
[validation checklist](../../docs/validation-checklist.md) rather than treating
message receipt as a non-mutating configuration check.

A returned dictionary containing `errors`, `statusCode = 400`, or
`statusCode = 500` is not an exception raised to Lambda. The handlers have
important normal-return and caught-error paths:

| Handler | Examples that do not necessarily fail the Lambda invocation |
|---|---|
| Isolation | Missing configuration, invalid finding container, and caught per-finding API errors return a summary; notification API errors are logged after isolation |
| Rollback | Missing required fields, failed instance lookup, not-isolated state, or missing original-group tags return without raising |
| IP Enrichment | Missing secret/key returns an error-shaped payload; HTTP lookup errors skip results; SNS and writeback exceptions are caught |

For IP Enrichment, the Security Hub batch-update response is not inspected for
per-item unprocessed findings. A log saying writeback was attempted or a normal
handler return is not independent evidence that every note was updated.

Inspect invocation logs, handler outcomes, actual resource state, and receipt
of notifications together. Neither an empty DLQ nor successful EventBridge
submission proves the business operation completed. See [AWS asynchronous
invocation error handling](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async-error-handling.html)
for the service-level failure boundary.

---

## DLQ Alarms

Each workflow DLQ has a CloudWatch alarm on:

```text
AWS/SQS ApproximateNumberOfMessagesVisible
```

Each alarm uses a 300-second period, `Maximum`, one evaluation period, threshold
zero with `GreaterThanThreshold`, and `treat_missing_data = notBreaching`.
Its ALARM action targets the supplied SecOps SNS topic; no OK action is declared.
This configuration does not test topic subscription confirmation, message
receipt, or handling of errors swallowed by a function.

| Alarm | Queue |
|---|---|
| `<name_prefix>-ec2-isolation-dlq-visible-messages` | EC2 Isolation DLQ |
| `<name_prefix>-ec2-rollback-dlq-visible-messages` | EC2 Rollback DLQ |
| `<name_prefix>-ip-enrichment-dlq-visible-messages` | IP Enrichment DLQ |

A visible DLQ message should be treated as an operational signal that the automation workflow needs review.

---

## Security Design

The implemented security controls and their boundaries are:

- Lambda deployment packages are generated by managed Terraform resources, preserving package-to-function dependency ordering during saved-plan Apply.
- Lambda functions use dedicated IAM roles passed into the module.
- `kms_key_arn` supplies the customer key for Lambda environment-variable encryption; it does not configure customer-key encryption of the source ZIP. No `source_kms_key_arn` is configured. See [AWS source ZIP encryption](https://docs.aws.amazon.com/lambda/latest/dg/encrypt-zip-package.html).
- Lambda CloudWatch log groups are encrypted with the logs CMK.
- Workflow DLQs are encrypted with the logs CMK.
- Threat intelligence API keys are stored in Secrets Manager and encrypted with the Secrets Manager CMK.
- EC2 Isolation and EC2 Rollback Lambdas run inside private serverless subnets.
- EC2 Isolation checks the normalized `IsolationAllowed=true` value in handler logic; the IAM EC2 grant is not constrained by that tag.
- EC2 Isolation rechecks the regional GuardDuty product, configured severity set, and ACTIVE/NEW finding state.
- EC2 Isolation requests snapshots before replacing groups, but does not wait for completed recovery points or atomically persist rollback metadata.
- IP Enrichment intentionally does not use a VPC configuration so it can reach external threat intelligence APIs without requiring NAT.
- EC2 Rollback is routed through a custom EventBridge bus with a role-scoped `custom.rollback` Allow and explicit non-Operator Deny; supplied approval metadata remains unauthenticated.
- EventBridge targets use retry policies and DLQs.
- DLQ send permissions are scoped to expected EventBridge rule ARNs and Lambda execution roles.

---

## Usage

These are excerpts of the baseline composition, not standalone deployment roots.
The provider Region is selected by the workload root; this module does not
select a backend Region from `primary_region`.

```hcl
module "automation" {
  source = "../modules/automation"

  cloud_name                               = var.cloud_name
  account_id                               = var.account_id
  name_prefix                              = local.name_prefix
  environment                              = var.environment
  primary_region                           = data.aws_region.current.region

  vpc_id                                   = module.networking.vpc_id
  serverless_private_subnet_ids            = module.networking.serverless_private_subnet_ids_list
  interface_endpoints_sg_id                = module.vpc_endpoints.interface_endpoints_sg_id
  quarantine_sg_id                         = module.compute.quarantine_sg_id

  lambda_ec2_isolation_role_arn            = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn             = module.iam.lambda_ec2_rollback_role_arn
  ec2_auto_isolation_severities            = var.ec2_auto_isolation_severities
  lambda_ip_enrichment_role_arn            = module.iam.lambda_ip_enrichment_role_arn
  eventbridge_putevents_to_secops_role_arn = module.iam.eventbridge_putevents_to_secops_role_arn

  secops_topic_arn                         = module.monitoring.secops_topic_arn
  lambda_cmk_arn                           = module.security.lambda_cmk_arn
  logs_cmk_arn                             = module.security.logs_cmk_arn
  secrets_manager_cmk_arn                  = module.security.secrets_manager_cmk_arn

  cloudwatch_retention_days                = local.effective_cloudwatch_retention_days

  abuseipdb_api_key                        = var.abuseipdb_api_key
  ip_enrichment_write_to_securityhub       = var.ip_enrichment_write_to_securityhub
  ip_enrich_max_ips_per_event              = var.ip_enrich_max_ips_per_event
  ip_enrich_abuseipdb_max_age              = var.ip_enrich_abuseipdb_max_age
  ip_enrich_max_ips_extracted              = var.ip_enrich_max_ips_extracted
}
```

---

## Inputs

All inputs in [variables.tf](variables.tf) are required: none has a declared
default in this child module. Baseline defaults and Python fallback values are
separate from this interface. Numeric-looking string inputs are not validated
here for positivity or conversion to integers.

| Name | Type | Description |
|---|---|---|
| `vpc_id` | `string` | VPC for the isolation/rollback Lambda security groups |
| `name_prefix` | `string` | Prefix used for resource identities |
| `cloud_name` | `string` | Cloud name forwarded to IP Enrichment metadata |
| `environment` | `string` | Environment tag value; not an isolation authorization decision |
| `lambda_ec2_isolation_role_arn` | `string` | Isolation execution role supplied by IAM |
| `lambda_ec2_rollback_role_arn` | `string` | Rollback execution role supplied by IAM |
| `lambda_ip_enrichment_role_arn` | `string` | IP Enrichment execution role supplied by IAM |
| `serverless_private_subnet_ids` | `list(string)` | Subnets for the two VPC-attached functions |
| `quarantine_sg_id` | `string` | Quarantine group passed to the isolation handler |
| `secops_topic_arn` | `string` | SNS destination for handler notifications and DLQ alarms |
| `account_id` | `string` | Account context used in policies |
| `primary_region` | `string` | Service Region used in the isolation rule ProductArn |
| `eventbridge_putevents_to_secops_role_arn` | `string` | Declared integration input; not consumed by the module resource expressions |
| `lambda_cmk_arn` | `string` | Lambda environment-variable encryption key via `kms_key_arn`; not a source ZIP encryption setting |
| `secrets_manager_cmk_arn` | `string` | Threat-intelligence secret encryption key |
| `interface_endpoints_sg_id` | `string` | Declared integration input; rules are attached by the separate security-policy module |
| `logs_cmk_arn` | `string` | Encryption key for function log groups and workflow queues |
| `cloudwatch_retention_days` | `string` | Log-retention value supplied by the baseline |
| `ip_enrichment_write_to_securityhub` | `bool` | Handler writeback toggle; does not remove the IAM grant |
| `abuseipdb_api_key` | `string` | Sensitive API key written to the secret-version resource |
| `ip_enrich_max_ips_per_event` | `string` | Value parsed by Python as the lookup-loop limit |
| `ip_enrich_abuseipdb_max_age` | `string` | Value parsed by Python as the API lookback-days parameter |
| `ip_enrich_max_ips_extracted` | `string` | Value parsed by Python as the post-finding extraction threshold |
| `ec2_auto_isolation_severities` | `set(string)` | Severity labels joined into AUTO_ISOLATION_SEVERITIES |

`interface_endpoints_sg_id` and `eventbridge_putevents_to_secops_role_arn` are
retained interface inputs but are not used by this module's resource expressions.
Passing them does not create endpoint rules or an additional forwarding target.
The baseline composes the required security-group rules separately.

---

## Outputs

| Name | Description |
|---|---|
| `secops_event_bus_name` | Name of the custom SecOps EventBridge bus |
| `secops_event_bus_arn` | ARN of the custom SecOps EventBridge bus |
| `lambda_ec2_isolation_sg_id` | Security group ID for the EC2 Isolation Lambda |
| `lambda_ec2_isolation_dlq_arn` | ARN of the EC2 Isolation workflow DLQ |
| `lambda_ec2_rollback_sg_id` | Security group ID for the EC2 Rollback Lambda |
| `lambda_ec2_rollback_dlq_arn` | ARN of the EC2 Rollback workflow DLQ |
| `threat_intel_api_keys_arn` | ARN of the Secrets Manager secret storing threat intelligence API keys |
| `lambda_ip_enrichment_log_group_arn` | ARN of the CloudWatch log group for the IP Enrichment Lambda |
| `lambda_ip_enrichment_dlq_arn` | ARN of the IP Enrichment workflow DLQ |
| `securityhub_high_critical_rule_arn` | ARN of the EventBridge rule for HIGH / CRITICAL Security Hub findings |
| `securityhub_high_critical_rule_name` | Name of the EventBridge rule for HIGH / CRITICAL Security Hub findings |

---

## Usage Example

```hcl
module "automation" {
  source = "../modules/automation"

  cloud_name     = var.cloud_name
  account_id     = var.account_id
  name_prefix    = local.name_prefix
  environment    = var.environment
  primary_region = data.aws_region.current.region

  vpc_id                        = module.networking.vpc_id
  serverless_private_subnet_ids = module.networking.serverless_private_subnet_ids_list
  interface_endpoints_sg_id     = module.vpc_endpoints.interface_endpoints_sg_id
  quarantine_sg_id              = module.compute.quarantine_sg_id

  lambda_ec2_isolation_role_arn            = module.iam.lambda_ec2_isolation_role_arn
  lambda_ec2_rollback_role_arn             = module.iam.lambda_ec2_rollback_role_arn
  ec2_auto_isolation_severities            = var.ec2_auto_isolation_severities
  lambda_ip_enrichment_role_arn            = module.iam.lambda_ip_enrichment_role_arn
  eventbridge_putevents_to_secops_role_arn = module.iam.eventbridge_putevents_to_secops_role_arn

  cloudwatch_retention_days = local.effective_cloudwatch_retention_days

  secops_topic_arn        = module.monitoring.secops_topic_arn
  lambda_cmk_arn          = module.security.lambda_cmk_arn
  logs_cmk_arn            = module.security.logs_cmk_arn
  secrets_manager_cmk_arn = module.security.secrets_manager_cmk_arn

  abuseipdb_api_key = var.abuseipdb_api_key

  ip_enrichment_write_to_securityhub = var.ip_enrichment_write_to_securityhub
  ip_enrich_max_ips_per_event        = var.ip_enrich_max_ips_per_event
  ip_enrich_abuseipdb_max_age        = var.ip_enrich_abuseipdb_max_age
  ip_enrich_max_ips_extracted        = var.ip_enrich_max_ips_extracted
}
```

---

## Validation

Use the existing workload validators from the repository root after selecting
and initializing the workload context in the [validation checklist](../../docs/validation-checklist.md).
This local example assumes an exported named profile, service Region, and
expected account. `${VAR:?message}` rejects missing/empty values; it does not
verify their correctness. GitHub OIDC runs use their supplied credential chain
instead of requiring a named local profile.

```bash
(
  set -euo pipefail
  : "${ENVIRONMENT:?Select dev, staging, or prod}"
  case "$ENVIRONMENT" in dev|staging|prod) ;; *) exit 1 ;; esac
  export AWS_PROFILE="${AWS_PROFILE:?Set the workload profile}"
  export AWS_REGION="${AWS_REGION:?Set the service Region}"
  export EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the workload account ID}"
  ./scripts/validation/validate-lambda.sh "$ENVIRONMENT"
  ./scripts/validation/validate-eventbridge.sh "$ENVIRONMENT"
  ./scripts/validation/validate-sqs.sh "$ENVIRONMENT"
  ./scripts/validation/validate-iam.sh "$ENVIRONMENT"
)
```

The [Lambda validator](../../scripts/validation/validate-lambda.sh) performs
selected presence/sanity checks, not an exact comparison of every resource:

| Setting | Actual Lambda-validator acceptance |
|---|---|
| Three named functions | Must exist and report `Active` |
| Runtime | Must be present; not compared to the configured Python runtime |
| Execution role | Must be present; a nonmatching role-name keyword warns |
| Timeout and memory | Positive timeout and at least 128 MB; not exact 60-second/256-MB equality |
| KMS | Configured key is reported; a missing key warns, with no exact CMK comparison here |
| Isolation/rollback VPC config | At least one subnet and SG required; exact IDs are not compared here |
| IP Enrichment VPC config | Not required; a VPC attachment is also accepted by this script |
| Environment | Variable count reported; zero warns, values are not compared |
| Function resource policy | Read and summarized; missing policy/EventBridge service-principal evidence warns |

The other entry points supply their own selected IAM, queue, and EventBridge
checks. Do not infer exact code-hash verification, asynchronous-invoke settings,
all DLQ alarms, every source-ARN restriction, or live handler success from the
Lambda PASS. A reported setting is not necessarily a blocking assertion.

Packaging on a fresh runner, exact saved-plan Apply, deployed code identity,
and actual response/notification outcomes need their own deployment or live
evidence. The read-only validators do not execute handlers or prove that caught
errors reach an on-failure destination. Review warnings and per-script logs,
not only the aggregate suite count.

For a targeted function configuration inspection that avoids dumping environment
values, use a reviewed function name:

```bash
aws lambda get-function-configuration \
  --profile "${AWS_PROFILE:?Set the workload profile}" \
  --region "${AWS_REGION:?Set the service Region}" \
  --function-name "${FUNCTION_NAME:?Set the exact workload function name}" \
  --query '{Name:FunctionName,State:State,Update:LastUpdateStatus,Runtime:Runtime,Role:Role,Timeout:Timeout,Memory:MemorySize,KMS:KMSKeyArn,VPC:VpcConfig,CodeSha256:CodeSha256}' \
  --output json
```

Compare these observations with the intended resource configuration and package
hash; the query is an inspection, not an automated equality assertion. Use the
[isolation](../../docs/lambda_tests/ec2_isolation.md),
[rollback](../../docs/lambda_tests/ec2_rollback.md), and
[enrichment](../../docs/lambda_tests/ip_enrichment.md) guides only with approved
scope and the handler limitations above. Live response tests can alter workload
state and incur snapshot/external-service costs.

---

## Operational Considerations

### DLQ Messages

A message may be delivery-failure evidence or a Lambda asynchronous destination record. Review its producer and failure details. Absence of messages does not clear logged handler errors or partially completed mutations.

Recommended response:

1. Identify the affected workflow from the queue name.
2. Inspect the DLQ message body and attributes.
3. Determine whether EventBridge delivery failed, Lambda processing failed, or downstream permissions/configuration failed.
4. Review the corresponding Lambda logs.
5. Fix the underlying issue.
6. Manually replay or remediate only after confirming the event is safe to process.

---

### EC2 Isolation Safety

EC2 Isolation changes instance security group attachments and can interrupt network access to a workload.

The handler refuses isolation when its product, severity, state, or opt-in checks
fail. That does not make the multi-step response atomic:

- verify the actual `IsolationAllowed` input/tag instead of relying on an environment label;
- confirm the GuardDuty product and configured severity set;
- confirm the running/stopped instance and same-invocation duplicate checks;
- distinguish requested snapshots from completed, usable recovery points;
- preserve external incident evidence for original SGs before relying on tag-based recovery; and
- verify the actual groups and tags when the handler reports errors or a retry skips an already-quarantined instance.

Use this workflow carefully in non-development environments. Confirm the quarantine security group, snapshot permissions, SNS notification path, and rollback procedure before enabling live response against production workloads.

---

### EC2 Rollback Control

Rollback uses a custom SecOps EventBridge bus and the `custom.rollback` source.

The Operator persona submits recovery events rather than modifying EC2
directly. The bus policy restricts `custom.rollback` publication to matching
Identity Center Operator role ARNs, including generated suffixes, and explicitly
denies nonmatching publishers. The Identity Center caller derives the same
prefixed bus ARN. Verify the intended account's group assignment and positive/
negative access evidence independently.

`approved_by` and `ticket_id` remain event payload fields, not
independently verified approvals. Record the real authorizing principal and
incident approval separately. After rollback, verify restored groups, release
tags, the changed `IsolationAllowed` value, and notification receipt.

---

### IP Enrichment Internet Access

The IP Enrichment Lambda intentionally does not use a VPC configuration.

Its external traffic is not governed by the workload VPC SG, NAT, or Network Firewall allowlist. An endpoints-only workload profile does not make this function endpoints-only. A future VPC attachment would require a separately designed external API path and requalification.

---

### Secrets Manager Rotation

The module stores the AbuseIPDB API key in Secrets Manager.

Rotation is not configured in this module. A separate rotation process must account for the warm-function key cache and the Terraform-managed secret version; merely updating a secret out of band can leave configuration drift or cached old credentials.

---

## Troubleshooting

### EventBridge Target Is Not Invoking Lambda

Check:

- The EventBridge rule exists and is enabled.
- The target ARN points to the expected Lambda function.
- The Lambda permission allows `events.amazonaws.com` from the expected rule ARN.
- The event matches the rule pattern.
- The target DLQ does not contain failed delivery events.

---

### DLQ Alarm Fired

Check:

- Which workflow DLQ contains visible messages.
- The message body and attributes.
- The matching EventBridge rule and target configuration.
- The corresponding Lambda CloudWatch log group.
- KMS permissions for EventBridge, Lambda, SQS, and CloudWatch Logs.
- IAM permissions used by the Lambda execution role.

---

### EC2 Isolation Did Not Apply Quarantine

Check:

- The finding matches the exact regional GuardDuty ProductArn as well as HIGH/CRITICAL, NEW, ACTIVE, and EC2-resource conditions.
- The finding severity is included in `AUTO_ISOLATION_SEVERITIES`; the deployed default is `CRITICAL`.
- The finding resource type is `AwsEc2Instance` and its instance ID is valid.
- The finding workflow status is `NEW` and its record state is `ACTIVE`.
- The instance is in the `running` or `stopped` state.
- The normalized `IsolationAllowed` tag is true; missing or other normalized values are skipped.
- The instance is not already tagged `Isolated=true` and is not already attached only to the quarantine security group.
- The Lambda execution role can describe instances, create and tag EBS snapshots, modify security groups, create tags, and publish to SNS.
- The quarantine security group ID is correct.
- The Lambda has network access to the required AWS APIs through the configured VPC endpoints or egress path.
- Inspect the returned/logged `errors` count and actual groups/tags; a snapshot request error blocks subsequent isolation for that finding, but later errors can leave partial changes without a DLQ record.

---

### EC2 Rollback Did Not Restore Security Groups

Check:

- The rollback event was sent to the custom SecOps event bus.
- The event source is `custom.rollback`; the supplied approver/ticket strings are not independent proof of approval.
- The EventBridge rollback rule exists on the SecOps bus.
- The Lambda execution role can read the preserved original security group metadata and modify EC2 instance security groups.
- Inspect handler logs and actual groups/tags, not only the DLQ; some failures return normally, and later failures can occur after group restoration.
- `detail.reason` is a valid string for release tagging, even though the entry check does not require it.
- The restored `IsolationAllowed=true` value agrees with the reviewed workload policy or is reconciled deliberately.

---

### IP Enrichment Did Not Return Results

Check:

- The finding contains public IP addresses.
- The AbuseIPDB API key secret exists.
- The Lambda execution role can read the secret.
- The API key is valid.
- The function has outbound internet access.
- The configured lookup budget fits within the 60-second Lambda timeout; the extraction threshold is not a strict per-finding size cap.
- Warm execution environments may still have an earlier API key cached.
- HTTP, SNS, or Security Hub failures may be caught and logged without failing the invocation.
- A Security Hub batch response can contain unprocessed items; verify the resulting finding notes independently.

---

## Important Notes

- Lambda ZIP files are generated by managed `archive_file` resources and are not manually maintained deployment inputs.
- EC2 Isolation receives NEW, ACTIVE GuardDuty EC2 findings at HIGH/CRITICAL; automatic response follows the supplied severity set, with a CRITICAL handler fallback.
- EC2 Isolation checks normalized opt-in and ACTIVE/NEW finding state in handler logic, not an IAM tag condition.
- EC2 Isolation requests EBS snapshots before replacing groups, then writes rollback tags; these operations are not atomic and do not wait for snapshot completion.
- EC2 Rollback is triggered through the custom SecOps event bus using the `custom.rollback` source.
- IP Enrichment is triggered by new HIGH or CRITICAL Security Hub findings.
- IP Enrichment is intentionally not placed in a VPC.
- Lambda IAM roles are created outside this module and passed in as inputs.
- CloudWatch log groups are created explicitly so retention and KMS encryption can be controlled.
- Workflow DLQs are encrypted with the logs CMK and retain messages for 14 days.
- DLQ messages are not automatically replayed, and caught/normal-return handler errors are not necessarily captured by a failure destination.
- The AbuseIPDB API key is stored in Secrets Manager and encrypted with the provided Secrets Manager CMK.

---

## Summary

The `automation` module provides the baseline's event-driven security response layer.

It connects Security Hub, EventBridge, Lambda, SQS, SNS, Secrets Manager, and CloudWatch Logs for EC2 response and enrichment. Treat IAM authorization, event eligibility, resource mutation, error reporting, and recovery evidence as separate responsibilities; configuration alone does not establish successful end-to-end response.
