# Validation Checklist - tf-secure-baseline

## Purpose

This checklist verifies that `tf-secure-baseline` deployed successfully and that the core security controls are functioning as expected.

Use this checklist after completing the deployment steps in:

```text
docs/quickstart.md
```

This checklist validates:

- AWS account and profile correctness
- Terraform state backend resources
- GitHub OIDC roles
- Control-plane resources
- Environment baseline infrastructure
- Networking and private connectivity
- Logging and monitoring
- Security services
- IAM Identity Center access
- Event-driven security automation
- Lambda workflows
- Alerting
- Destroy/cleanup readiness

---

## Validation Scope

Run this checklist for each deployed workload environment:

```text
dev
staging
prod
```

Some checks also apply to the control plane:

```text
control-plane
```

Recommended validation order:

1. Account/profile validation
2. Terraform state validation
3. GitHub OIDC validation
4. Control-plane validation
5. Environment baseline validation
6. Networking validation
7. Logging validation
8. Security service validation
9. Identity Center validation
10. Lambda workflow validation
11. Alerting validation
12. Destroy safety validation

---

## Required Variables

Because these validation checks require switching between different workload accounts, it is recommended to use **four separate terminals**, each dedicated to a specific account.

Set these variables before running environment-specific checks.

### Dev

```bash
export AWS_PAGER=""
export AWS_PROFILE="dev"
export ENVIRONMENT="dev"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<DEV-ACCOUNT-ID>"
```

### Staging

```bash
export AWS_PAGER=""
export AWS_PROFILE="staging"
export ENVIRONMENT="staging"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<STAGING-ACCOUNT-ID>"
```

### Prod

```bash
export AWS_PAGER=""
export AWS_PROFILE="prod"
export ENVIRONMENT="prod"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<PROD-ACCOUNT-ID>"
```

### Control-Plane

```bash
export AWS_PAGER=""
export AWS_PROFILE="control-plane"
export ENVIRONMENT="control-plane"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>"
```

---

# 1. Validate AWS CLI Identity

## Purpose

Confirm that the AWS CLI is authenticated to the correct AWS account before validating resources.

## Command

```bash
aws sts get-caller-identity --profile "${AWS_PROFILE}"
```

## Expected Outcome

- The returned `Account` matches the expected account ID.
- The profile corresponds to the environment being validated.
- No SSO, credential, or profile errors occur.

---

# 2. Validate Terraform State Backends

## Purpose

Confirm that the Terraform backend resources exist for each account/environment.

The `state` substacks create backend resources such as:

- S3 bucket for Terraform state
- KMS key for state encryption
- DynamoDB table or S3 lockfile support for state locking

## Check State Bucket

```bash
aws s3api head-bucket \
  --bucket "${CLOUD_NAME}-${ENVIRONMENT}-state" \
  --profile "${AWS_PROFILE}"
```

## Check State Bucket Encryption

```bash
aws s3api get-bucket-encryption \
  --bucket "${CLOUD_NAME}-${ENVIRONMENT}-state" \
  --profile "${AWS_PROFILE}" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault'
```

If your state bucket uses a different name, replace the bucket name accordingly.

## Check State Lock Table

```bash
aws dynamodb describe-table \
  --table-name "${CLOUD_NAME}-${ENVIRONMENT}-lock" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Table.TableStatus'
```

## Terraform Init Check

From the target stack directory:

```bash
terraform init
```

Expected:

- Backend initializes successfully.
- No state lock or access errors occur.

## Expected Outcome

- S3 state bucket exists.
- KMS encryption is configured.
- Locking resource exists if configured.
- Terraform can initialize successfully in stacks that use the backend.

---

# 3. Validate GitHub OIDC Roles

## Purpose

Confirm that GitHub OIDC roles exist for each environment if GitHub OIDC is enabled.

Each environment may include:

- GitHub Plan role
- GitHub Apply role

## Check IAM Roles

```bash
aws iam list-roles \
  --profile "${AWS_PROFILE}" \
  --query "Roles[?contains(RoleName, 'github')].[RoleName, Arn]" \
  --output table
```

## Expected Outcome

Environment accounts should show roles similar to:

```text
tf-secure-baseline-dev-github-plan-role
tf-secure-baseline-dev-github-apply-role
```

Control plane should show roles similar to:

```text
tf-secure-baseline-control-plane-github-plan-role
tf-secure-baseline-control-plane-github-apply-role
```

## GitHub Workflow Validation

Run the Terraform Plan workflow in GitHub Actions.

Expected:

- `Configure AWS credentials from GitHub OIDC` step confirms GitHub successfully assumed the plan role.
- `Verify Identity` step returns the expected account for `aws sts get-caller-identity`.
- `Terraform Plan` completes without OIDC errors.

---

# 4. Validate Control Plane

## Purpose

Confirm that control-plane resources were deployed correctly.

Run these checks using the control-plane profile.

```bash
export AWS_PROFILE="control-plane"
export ENVIRONMENT="control-plane"
```

---

## 4.1 Validate AWS Organizations

```bash
aws organizations describe-organization \
  --profile "${AWS_PROFILE}"
```

Expected:

- Organization exists.
- The Organization's `MasterAccountId` equals that of the `control-plane` account ID.

## List OUs

```bash
aws organizations list-roots \
  --profile "${AWS_PROFILE}"
```

Then list OUs under the root:

```bash
ROOT_ID="$(aws organizations list-roots \
  --profile "${AWS_PROFILE}" \
  --query 'Roots[0].Id' \
  --output text)"

aws organizations list-organizational-units-for-parent \
  --parent-id "${ROOT_ID}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected OUs:

```text
Workloads
```

Then verify child OUs under `Workloads`:

```bash
WORKLOADS_OU_ID="$(aws organizations list-organizational-units-for-parent \
  --parent-id "${ROOT_ID}" \
  --profile "${AWS_PROFILE}" \
  --query "OrganizationalUnits[?Name=='Workloads'].Id | [0]" \
  --output text)"

aws organizations list-organizational-units-for-parent \
  --parent-id "${WORKLOADS_OU_ID}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected child OUs:

```text
NonProd
Prod
```

---

## 4.2 Validate IAM Identity Center Instance

```bash
aws sso-admin list-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- IAM Identity Center instance exists.
- Instance ARN and Identity Store ID are returned.

---

## 4.3 Validate Identity Center Groups

```bash
IDENTITY_STORE_ID="$(aws sso-admin list-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Instances[0].IdentityStoreId' \
  --output text)"

aws identitystore list-groups \
  --identity-store-id "${IDENTITY_STORE_ID}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Groups[].DisplayName' \
  --output table
```

Expected groups may include:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
```

Optional groups may include:

```text
SecOps-Analyst-Dev
SecOps-Engineer-Dev
SecOps-Analyst-Staging
SecOps-Engineer-Staging
SecOps-Analyst-Prod
SecOps-Engineer-Prod
```

---

# 5. Validate Environment Baseline

## Purpose

Confirm that the baseline deployed into the selected workload account.

Run this section for each environment:

```text
dev
staging
prod
```

Run these checks for each environment (`dev`, `staging`, and `prod`), ensuring the appropriate environment profile is set beforehand.

```text
export AWS_PROFILE="<env>"
export ENVIRONMENT="<env>"
```

---

## 5.1 Validate VPC

```bash
aws ec2 describe-vpcs \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Name,Values=*${CLOUD_NAME}-${ENVIRONMENT}*" \
  --query 'Vpcs[].[VpcId,CidrBlock,State]' \
  --output table
```

Expected:

- VPC exists.
- VPC state is `available`.

---

## 5.2 Validate Subnets

```bash
aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Name,Values=*${CLOUD_NAME}-${ENVIRONMENT}*" \
  --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

Expected:

- Public subnets exist.
- Private compute/data/serverless/endpoint subnets exist, depending on configuration.
- Private subnets do not auto-assign public IPs.

---

## 5.3 Validate EC2 Instances

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PrivateIpAddress,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

Expected:

- Workload instances exist if enabled.
- Private workload instances do not have public IPs.
- Instances are in the expected state.

---

# 6. Validate Private Access and SSM

## Purpose

Confirm that private instances can be accessed through SSM Session Manager without SSH.

## List SSM-Managed Instances

```bash
aws ssm describe-instance-information \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query "InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]" \
  --output table
```

Expected:

- Target EC2 instances appear.
- `PingStatus` is `Online`.

## Start SSM Session

```bash
aws ssm start-session \
  --target "<INSTANCE_ID>" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- Session starts successfully.
- No SSH is required.
- No public IP is required.

---

# 7. Validate VPC Endpoints

## Purpose

Confirm that VPC endpoints exist for private AWS service access.

## List VPC Endpoints

```bash
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'VpcEndpoints[].[VpcEndpointId,ServiceName,VpcEndpointType,State,PrivateDnsEnabled]' \
  --output table
```

Expected:

- Required endpoints exist.
- Interface endpoints are `available`.
- Private DNS is enabled where expected.

Common endpoints include:

```text
ssm
ssmmessages
ec2messages
logs
kms
secretsmanager
ec2
s3
```

---

## Validate Endpoint DNS from Instance

Run from inside an SSM session:

```bash
export AWS_REGION="us-east-1"
getent hosts sts.${AWS_REGION}.amazonaws.com
getent hosts ssm.${AWS_REGION}.amazonaws.com
getent hosts secretsmanager.${AWS_REGION}.amazonaws.com
getent hosts logs.${AWS_REGION}.amazonaws.com
getent hosts kms.${AWS_REGION}.amazonaws.com
```

Expected:

- Commands return private RFC1918 IPs where interface endpoints and Private DNS are used.

---

## Validate 443 Connectivity to AWS Services

Run from inside an SSM session:

```bash
export AWS_REGION="us-east-1"
for h in sts ssm secretsmanager logs kms; do
  host="${h}.${AWS_REGION}.amazonaws.com"
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/443" \
    && echo "OK  ${host}:443" || echo "FAIL ${host}:443"
done
```

Expected:

- Required AWS services return `OK`.

---

# 8. Validate Controlled Egress

## Purpose

Confirm that outbound traffic behaves according to the deployed architecture.

The default architecture may use AWS Network Firewall and NAT Gateway for controlled egress.

## Check Route Tables

Run from your local CLI:

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Name,Values=*${CLOUD_NAME}-${ENVIRONMENT}*" \
  --query 'RouteTables[].[RouteTableId,Routes]' \
  --output json
```

Expected:

- Private subnet routes follow the intended egress path.
- Workloads do not route directly to the Internet Gateway.
- If Network Firewall is enabled, private egress routes should pass through firewall endpoints before NAT/IGW.

## Optional Internet Egress Test

Run from inside an SSM session:

```bash
timeout 5 bash -c "cat < /dev/null > /dev/tcp/example.com/443" \
  && echo "Internet egress reachable" || echo "No direct internet egress"
```

Expected result depends on your egress design:

- If controlled NAT/Network Firewall egress is enabled, internet access may succeed.
- If using a VPC-endpoints-only posture, internet egress should fail.

---

# 9. Validate Logging

## Purpose

Confirm that logging resources exist and receive data.

---

## 9.1 Validate CloudTrail

```bash
aws cloudtrail describe-trails \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'trailList[].[Name,TrailARN,LogFileValidationEnabled,IsMultiRegionTrail]' \
  --output table
```

Check logging status:

```bash
TRAIL_NAME="$(aws cloudtrail describe-trails \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'trailList[0].Name' \
  --output text)"

aws cloudtrail get-trail-status \
  --name "${TRAIL_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- CloudTrail exists.
- Logging is enabled.
- Log file validation is enabled if configured.
- Trail delivers to the centralized logs bucket.

---

## 9.2 Validate Centralized Logs Bucket

```bash
aws s3api list-buckets \
  --profile "${AWS_PROFILE}" \
  --query "Buckets[?contains(Name, 'logs')].Name" \
  --output table
```

For the target logs bucket:

```bash
aws s3api get-bucket-encryption \
  --bucket "<CENTRALIZED-LOGS-BUCKET>" \
  --profile "${AWS_PROFILE}"

aws s3api get-bucket-versioning \
  --bucket "<CENTRALIZED-LOGS-BUCKET>" \
  --profile "${AWS_PROFILE}"

aws s3api get-object-lock-configuration \
  --bucket "<CENTRALIZED-LOGS-BUCKET>" \
  --profile "${AWS_PROFILE}"
```

Expected:

- Bucket exists.
- Encryption is enabled.
- Versioning is enabled.
- Object Lock is enabled if configured.

---

## 9.3 Validate VPC Flow Logs

```bash
aws ec2 describe-flow-logs \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'FlowLogs[].[FlowLogId,ResourceId,FlowLogStatus,LogDestinationType,LogDestination]' \
  --output table
```

Expected:

- Flow logs exist.
- Status is `ACTIVE`.
- Destination is the expected logs destination.

---

# 10. Validate Security Services

## Purpose

Confirm that core AWS security services are enabled.

---

## 10.1 GuardDuty

```bash
aws guardduty list-detectors \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- At least one detector ID is returned.

---

## 10.2 Security Hub

```bash
aws securityhub describe-hub \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- Security Hub is enabled.
- Hub ARN is returned.

Check enabled standards:

```bash
aws securityhub get-enabled-standards \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'StandardsSubscriptions[].StandardsArn' \
  --output table
```

Expected:

- Expected standards are enabled according to configuration.

---

## 10.3 AWS Config

```bash
aws configservice describe-configuration-recorders \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"

aws configservice describe-delivery-channels \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"

aws configservice describe-configuration-recorder-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- Configuration recorder exists.
- Delivery channel exists.
- Recorder is enabled and recording.

---

## 10.4 Inspector

```bash
aws inspector2 batch-get-account-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --account-ids "${ACCOUNT_ID}"
```

Expected:

- Inspector account status is returned.
- Enabled resource types match configuration.

---

# 11. Validate KMS

## Purpose

Confirm that KMS keys exist for key platform functions.

```bash
aws kms list-aliases \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query "Aliases[?contains(AliasName, '${CLOUD_NAME}')].[AliasName,TargetKeyId]" \
  --output table
```

Expected aliases may include keys for:

```text
state
logs
lambda
ebs
backup_vault
secrets_manager
```

---

# 12. Validate SNS Notifications

## Purpose

Confirm that SNS topics exist and subscriptions are confirmed.

```bash
aws sns list-topics \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Topics[].TopicArn' \
  --output table
```

For each expected topic:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "<SNS_TOPIC_ARN>" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- SecOps and compliance topics exist if enabled.
- Email subscriptions are confirmed.

---

# 13. Validate EventBridge Rules

## Purpose

Confirm that EventBridge rules exist for security automation.

```bash
aws events list-rules \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Rules[].[Name,State,EventBusName]' \
  --output table
```

Expected rules may include:

- Security Hub high/critical finding handling
- EC2 isolation trigger
- IP enrichment trigger
- Tamper detection
- Break-glass detection
- EC2 rollback trigger on the SecOps event bus

Validate `secops` and custom event bus:

```bash
aws events list-event-buses \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'EventBuses[].[Name,Arn]' \
  --output table
```

Expected:

```text
secops-bus
```

or an environment-prefixed equivalent, depending on configuration.

---

# 14. Validate Lambda Functions

## Purpose

Confirm that Lambda automation functions exist.

```bash
aws lambda list-functions \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query "Functions[?contains(FunctionName, '${CLOUD_NAME}-${ENVIRONMENT}')].[FunctionName,Runtime,State]" \
  --output table
```

Expected functions include:

```text
ec2-isolation
ec2-rollback
ip-enrichment
```

Then run the detailed Lambda test docs:

```text
docs/lambda_tests/ec2_isolation.md
docs/lambda_tests/ec2_rollback.md
docs/lambda_tests/ip_enrichment.md
```

---

# 15. Validate EC2 Isolation and Rollback

## Purpose

Confirm that automated containment and controlled rollback work end-to-end.

## EC2 Isolation

Follow:

```text
docs/lambda_tests/ec2_isolation.md
```

Expected:

- High or critical EC2 finding causes isolation.
- Instance is moved to quarantine security group.
- Instance is tagged.
- SNS notification is sent.

## EC2 Rollback

Follow:

```text
docs/lambda_tests/ec2_rollback.md
```

Expected:

- SecOps-Operator can submit rollback event.
- Rollback Lambda restores original security groups.
- SNS notification is sent.

---

# 16. Validate IP Enrichment

## Purpose

Confirm that Security Hub findings containing public IPs are enriched.

Follow:

```text
docs/lambda_tests/ip_enrichment.md
```

Expected:

- Public IPv4 and IPv6 addresses are extracted.
- AbuseIPDB enrichment succeeds.
- SNS notification is sent.
- Security Hub writeback occurs if enabled and valid finding IDs are used.

---

# 17. Validate Tamper Detection

## Purpose

Confirm that attempts to modify or disable protected security services generate alerts.

Tamper detection monitors actions defined in:

```text
modules/security/tamper_detection/main.tf
```

Examples may include attempts to modify or disable:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- KMS

## Controlled CloudTrail Test

Only run this in a non-production environment unless explicitly approved.

```bash
aws cloudtrail stop-logging \
  --name "<TRAIL_NAME>" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- EventBridge detects the action.
- SNS alert is generated.
- CloudTrail tamper alert is received.

Immediately restart logging:

```bash
aws cloudtrail start-logging \
  --name "<TRAIL_NAME>" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Confirm CloudTrail is logging again:

```bash
aws cloudtrail get-trail-status \
  --name "<TRAIL_NAME>" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'IsLogging'
```

Expected:

```text
true
```

---

# 18. Validate Break-Glass Monitoring

## Purpose

Confirm that use of the break-glass role generates an alert.

If safe to test, assume or simulate use of the configured break-glass role.

Expected:

- CloudTrail records the role assumption.
- EventBridge rule matches the activity.
- SNS alert is sent.

If testing role assumption is not appropriate, validate that:

- Break-glass role exists.
- EventBridge rule exists.
- SNS target is configured.
- CloudTrail is logging management events.

---

# 19. Validate Backup and Patch Management

## Purpose

Confirm backup and patch management resources exist if enabled.

## AWS Backup

```bash
aws backup list-backup-vaults \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'BackupVaultList[].[BackupVaultName,BackupVaultArn]' \
  --output table
```

Expected:

- Backup vault exists.
- Vault encryption is configured.

## SSM Patch Manager

```bash
aws ssm describe-patch-baselines \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table

aws ssm describe-maintenance-windows \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected:

- Patch baseline exists if enabled.
- Maintenance window exists if enabled.

---

# 20. Validate GitHub Actions Workflows

## Purpose

Confirm that CI/CD workflows operate successfully.

Run the following workflows:

- Terraform Plan
- Terraform Apply
- Terraform Destroy in a non-production environment only

Expected:

- Plan workflow succeeds for expected stacks.
- Apply workflow can deploy selected environment.
- Destroy workflow first cleans up Identity Center attachments and then destroys selected environment baseline.
- No OIDC role assumption errors occur.
- No Terraform state lock conflicts occur.

---

# 21. Destroy Safety Check

## Purpose

Confirm that destroy operations are understood before running them.

Before destroying anything, review:

```text
docs/quickstart.md
```

Specifically review:

```text
Destruction / Cleanup Procedure
```

Important rules:

- Do not destroy `bootstrap/<env>/account` before `environments/<env>`.
- Do not destroy `bootstrap/<env>/state` before all stacks using that backend are destroyed.
- Do not destroy `bootstrap/control_plane/account` before other control-plane substacks.
- Destroy `bootstrap/control_plane/state` last.
- For single-environment teardown, clean up Identity Center attachments before destroying the environment baseline.

---

# 22. Quick Failure Triage Guide

## SSM Session Fails

Check:

- Instance has SSM agent installed and running.
- Instance IAM role includes SSM permissions.
- Interface endpoints exist for `ssm`, `ssmmessages`, and `ec2messages`.
- Endpoint security group allows inbound 443 from workload security group.
- Workload security group allows outbound 443 to endpoint security group.
- Instance has network path to SSM endpoints.

---

## VPC Endpoint DNS Fails

Check:

- Private DNS is enabled on the endpoint.
- VPC DNS hostnames are enabled.
- VPC DNS resolution is enabled.
- Endpoint exists in the expected VPC and subnets.
- Security groups allow traffic.

---

## AWS Service 443 Checks Fail

Check:

- Endpoint security group allows traffic.
- Workload security group egress allows 443.
- Route tables are correct.
- Network Firewall rules allow required egress if applicable.
- NAT Gateway exists if internet egress is expected.

---

## Internet Egress Is Unexpected

Check:

- Route tables.
- NAT Gateway routes.
- Network Firewall policy.
- Security group egress.
- NACLs.
- Whether the selected environment is intended to allow controlled internet egress.

---

## CloudTrail Is Not Logging

Check:

- Trail status.
- S3 bucket policy.
- KMS key policy.
- CloudTrail service permissions.
- CloudWatch Logs delivery role if configured.

---

## Security Hub or GuardDuty Is Missing

Check:

- The security module is enabled.
- Region is correct.
- Account is correct.
- Terraform apply completed successfully.
- Service-linked roles exist.

---

## Identity Center Assignment Fails

Check:

- Target account is a member of the organization.
- IAM Identity Center is enabled in the control-plane account.
- Account ID variables are correct.
- Permission set exists.
- Group exists.
- Customer-managed policy names exist in the target account if being attached.

---

## IAM Policy DeleteConflict During Destroy

Cause:

- Identity Center still has a customer-managed policy attached to a permission set provisioned into the target account.

Fix:

- Re-apply the Identity Center stack with that environment's optional Analyst/Engineer attachments disabled.
- Then re-run `terraform destroy` for the environment baseline.

---

## Terraform State Lock Error

Check:

- No other Terraform job is currently running for the same backend key.
- GitHub Actions did not cancel a job while a lock was held.
- Backend key is unique per stack.
- Use `terraform force-unlock` only after confirming no active operation is running.

---

# Summary

This checklist validates that `tf-secure-baseline` is deployed correctly and that the core security workflows function as intended.

A successful validation means:

- AWS accounts and profiles are correct.
- Terraform state backends exist.
- GitHub OIDC roles work if enabled.
- Control-plane resources are deployed.
- Environment baselines exist.
- Private networking and endpoint access work.
- Logging and security services are active.
- Identity Center access is configured.
- EC2 isolation and rollback work.
- IP enrichment works.
- Tamper and break-glass alerts are configured.
- Destroy procedures are understood before teardown.