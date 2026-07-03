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
- Deployment profile resolution
- Egress mode behavior
- Networking and private connectivity
- Dedicated VPC endpoint subnet placement
- Logging and monitoring
- Security services
- IAM Identity Center access
- Event-driven security automation
- Lambda workflows
- SNS, SQS, EventBridge, and DLQ-based alert delivery paths
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

1. Confirm AWS profile/account variables.
2. Run automated workload validation with `validate-all.sh` for each deployed workload environment.
3. Run automated control-plane validation with `validate-control-plane.sh`.
4. Review any control-plane warnings, especially AWS Organizations account placement warnings.
5. Validate GitHub Actions workflows manually.
6. Validate IAM Identity Center end-user access manually where required.
7. Run live Lambda workflow tests only in approved environments.
8. Run tamper and break-glass tests only when explicitly approved.
9. Review destroy safety requirements before running any destroy or teardown workflow.

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
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

### Staging

```bash
export AWS_PAGER=""
export AWS_PROFILE="staging"
export ENVIRONMENT="staging"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<STAGING-ACCOUNT-ID>"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

### Prod

```bash
export AWS_PAGER=""
export AWS_PROFILE="prod"
export ENVIRONMENT="prod"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<PROD-ACCOUNT-ID>"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

### Control-Plane

```bash
export AWS_PAGER=""
export AWS_PROFILE="control-plane"
export ENVIRONMENT="control-plane"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

---

## Automated Workload Validation

For deployed workload environments, most safe, read-only workload-account validation is automated by the scripts in:

```text
scripts/validation/
```

The primary command is:

```bash
./scripts/validation/validate-all.sh <dev|staging|prod>
```

Set `EXPECTED_ACCOUNT_ID` when running validation so the scripts can confirm that the selected AWS profile is pointed at the correct workload account.

### Dev

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/validation/validate-all.sh dev
```

### Staging

```bash
AWS_PAGER="" \
AWS_PROFILE=staging \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
./scripts/validation/validate-all.sh staging
```

### Prod

```bash
AWS_PAGER="" \
AWS_PROFILE=prod \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
./scripts/validation/validate-all.sh prod
```

If a non-default naming convention is used, pass `NAME_PREFIX` explicitly:

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
NAME_PREFIX="tf-secure-baseline-dev" \
./scripts/validation/validate-all.sh dev
```

### Automated Validation Coverage

`validate-all.sh` runs the following safe, read-only workload validation scripts all at once:

```text
validate-env.sh
validate-networking.sh
validate-vpc-endpoints.sh
validate-logging.sh
validate-security-services.sh
validate-kms.sh
validate-backup.sh
validate-sns.sh
validate-sqs.sh
validate-eventbridge.sh
validate-lambda.sh
validate-ssm.sh
validate-compute.sh
validate-iam.sh
```

To validate a specific architecture area, you can also run individual validation scripts directly.

Examples:

```bash
./scripts/validation/validate-networking.sh dev
./scripts/validation/validate-vpc-endpoints.sh dev
./scripts/validation/validate-logging.sh dev
./scripts/validation/validate-security-services.sh dev
./scripts/validation/validate-kms.sh dev
./scripts/validation/validate-backup.sh dev
./scripts/validation/validate-sns.sh dev
./scripts/validation/validate-sqs.sh dev
./scripts/validation/validate-eventbridge.sh dev
./scripts/validation/validate-lambda.sh dev
./scripts/validation/validate-ssm.sh dev
./scripts/validation/validate-compute.sh dev
./scripts/validation/validate-iam.sh dev
```

These scripts validate:

- AWS account identity and expected account ID
- Terraform outputs and effective environment settings
- VPC, subnets, route tables, NAT Gateway, and Network Firewall expectations
- VPC endpoint placement, state, route table associations, and endpoint security group paths
- CloudTrail, VPC Flow Logs, CloudWatch log groups, metric filters, and alarms
- GuardDuty, Security Hub, AWS Config, Inspector, and AWS Backup enablement based on effective profile settings
- KMS aliases, CMKs, key state, key manager, and rotation status
- Backup vaults, plans, selections, schedules, retention, tagged resources, recent jobs, and recovery point reporting
- SNS topics, subscriptions, pending confirmations, and encryption mode
- SQS queues, SNS-to-SQS delivery paths, queue policies, encryption mode, redrive policies, DLQ status, visible messages, and not-visible messages
- EventBridge default-bus and SecOps-bus rules, state, targets, target DLQs, retry policies, and rollback rule coverage
- Lambda functions, runtime, state, execution role, timeout, memory, KMS config, VPC config, environment variables, resource policies, and EventBridge permissions
- SSM managed instance registration, online status, associations, maintenance windows, and patch baseline visibility
- EC2 compute instances, private placement, public IP absence, IMDSv2, detailed monitoring, instance profiles, security groups, required tags, isolation eligibility, and EBS encryption
- IAM roles, service trust policies, key service roles, GitHub OIDC roles where present, break-glass MFA conditions, and shared log access policies

A successful run should end with:

```text
Validation scripts passed:  14/14
Validation scripts failed:  0/14
```

## Automated Control-Plane Validation

Control-plane validation is handled separately from workload validation because the control plane manages governance and bootstrap resources rather than workload baseline infrastructure.

Run the control-plane validation script with the control-plane AWS profile:

```bash
AWS_PAGER="" \
AWS_PROFILE=control-plane \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
./scripts/validation/validate-control-plane.sh
```

Example:

```bash
AWS_PAGER="" \
AWS_PROFILE=control-plane \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="example-org/terraform-secure-baseline" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
./scripts/validation/validate-control-plane.sh
```

This script performs safe, read-only validation for:

- AWS caller identity and expected control-plane account ID
- Control-plane Terraform state stack outputs
- Terraform state S3 bucket existence, versioning, encryption, and public access block settings
- Terraform state KMS CMK existence and key state
- Terraform state DynamoDB lock table existence and status
- GitHub OIDC provider existence
- Control-plane GitHub plan/apply role existence
- GitHub OIDC trust policy conditions for the expected repository
- AWS Organizations root and expected OU structure
- IAM Identity Center instance discovery
- Expected SecOps Identity Center groups
- Identity Center permission set outputs
- Identity Center permission set existence
- Identity Center account assignment presence for dev, staging, and prod

A successful run should end with:

```text
[PASS] Control-plane validation completed successfully
```

### Control-Plane Warning Behavior

Some control-plane checks may warn instead of fail.

For example, account OU placement may produce warnings if workload accounts currently remain under the AWS Organizations root instead of under the `NonProd` or `Prod` OUs.

This is expected if the Organizations stack creates OU structure but does not currently manage account placement. Treat these warnings as governance follow-up items unless account placement has been made a strict requirement for the deployment.

## Exporting Workload Validation Evidence

After running the workload validation suite, export a timestamped validation report package:

```bash
ENV_NAME="dev"

AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<account-id>" \
NAME_PREFIX="tf-secure-baseline-${ENV_NAME}" \
./scripts/validation/export-report.sh "${ENV_NAME}"
```

The export creates:

```text
validation-results/<environment>/<timestamp>/
├── summary.md
├── summary.json
├── validate-env.log
├── validate-networking.log
├── validate-vpc-endpoints.log
├── validate-logging.log
├── validate-security-services.log
├── validate-kms.log
├── validate-backup.log
├── validate-sns.log
├── validate-sqs.log
├── validate-eventbridge.log
├── validate-lambda.log
├── validate-ssm.log
├── validate-compute.log
└── validate-iam.log
```

Use `summary.md` for human review and client handoff. Use `summary.json` for automation, indexing, or future reporting workflows.

The report does not replace manual validation for GitHub Actions workflow execution, Identity Center end-user access, live Lambda workflows, tamper detection, break-glass access, or destroy safety review.

## Manual Validation Still Required

The automated validation scripts are intentionally read-only. They do not perform live, destructive, or privileged workflow tests.

Manual validation is still required for:

- GitHub Actions workflow execution
- IAM Identity Center end-user login and effective access testing
- Identity Center group membership review
- Live EC2 isolation testing
- Live EC2 rollback testing
- Live IP enrichment testing
- Tamper detection tests
- Break-glass role assumption tests
- Destroy workflow and teardown safety checks

The automated control-plane validation script confirms control-plane resource presence and selected configuration, but it does not execute GitHub workflows, modify Identity Center assignments, test end-user SSO login, assume privileged roles, move AWS accounts between OUs, or perform destructive operations.

Use the remaining sections in this checklist for manual spot checks, deeper troubleshooting, or tests that intentionally trigger live workflows.

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

The preferred validation path is the automated read-only control-plane validation script:

```bash
AWS_PAGER="" \
AWS_PROFILE=control-plane \
AWS_REGION="${AWS_REGION}" \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
./scripts/validation/validate-control-plane.sh
```

This validates the control-plane state backend, GitHub OIDC execution plane, AWS Organizations OU structure, and IAM Identity Center basics.

The manual commands below can be used for spot checks, troubleshooting, or deeper review.

Run manual spot checks using the control-plane profile:

```bash
export AWS_PROFILE="control-plane"
export ENVIRONMENT="control-plane"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
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

## 4.4 Validate Identity Center Permission Sets and Assignments

The automated control-plane validation script checks for permission set outputs, permission set existence, and account assignment presence.

For manual troubleshooting, list permission sets:

```bash
INSTANCE_ARN="$(aws sso-admin list-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Instances[0].InstanceArn' \
  --output text)"

aws sso-admin list-permission-sets \
  --instance-arn "${INSTANCE_ARN}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

To inspect assignments for a target account and permission set:

```bash
aws sso-admin list-account-assignments \
  --instance-arn "${INSTANCE_ARN}" \
  --account-id "<TARGET-ACCOUNT-ID>" \
  --permission-set-arn "<PERMISSION-SET-ARN>" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected:

- Expected permission sets exist.
- Expected account assignments exist for enabled SecOps roles.
- Customer-managed policy attachments are present only when the required workload-account policy names have been provided and the policies exist in the target account.

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

Run these checks for each environment, ensuring the appropriate environment profile is set beforehand.

```bash
export AWS_PROFILE="<env>"
export ENVIRONMENT="<env>"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

---

## 5.1 Validate Terraform Outputs

From the target environment directory:

```bash
terraform output
```

Expected outputs include:

```text
deployment_profile
egress_mode
effective_egress_mode
effective_cloudwatch_retention_days
effective_enable_config
effective_enable_rules
effective_backup_enabled
effective_inspector_enabled
```

Expected profile behavior:

| `deployment_profile` | Default `effective_egress_mode` | AWS Config | Backup | Inspector | CloudWatch retention |
|---|---|---:|---:|---:|---:|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | 90 days |
| `development` | `nat_only` | Enabled | Disabled | Enabled | 30 days |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | 14 days |

If `egress_mode`, `enable_config`, `backup_enabled`, `cloudwatch_retention_days`, or related overrides are explicitly set, the effective outputs should reflect those overrides.

---

## 5.2 Validate VPC

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

## 5.3 Validate Subnets

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
- Private compute subnets exist.
- Private data subnets exist.
- Private serverless subnets exist.
- Private endpoint subnets exist.
- Private firewall subnets exist when Network Firewall mode is used.
- Private subnets do not auto-assign public IPs.

---

## 5.4 Validate EC2 Instances

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

Interface VPC Endpoints should be deployed into dedicated endpoint private subnets.

The S3 Gateway Endpoint should be associated with the private route tables that need S3 access.

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
- S3 Gateway Endpoint exists.

Common endpoints include:

```text
sts
ssm
ssmmessages
logs
kms
secretsmanager
ec2
events
sns
securityhub
lambda
s3
```

---

## Validate Endpoint Private Subnets

```bash
aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Endpoint-Private-*" \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table
```

Expected:

- Endpoint private subnets exist in each configured Availability Zone.
- Endpoint private subnets use the expected CIDR ranges.
- `MapPublicIpOnLaunch` is `false`.

---

## Validate Interface Endpoint Subnet Placement

```bash
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[].[ServiceName,State,SubnetIds]' \
  --output table
```

Expected:

- Interface Endpoints are deployed into endpoint private subnets.
- Interface Endpoint state is `available`.
- Interface Endpoint subnet IDs match the dedicated endpoint private subnet IDs.

---

## Validate Endpoint Private Route Tables

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Endpoint-Private-RT-*" \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,RouteTableId,Routes]' \
  --output json
```

Expected:

- Endpoint private route tables exist.
- Endpoint private route tables are associated with endpoint private subnets.
- No `0.0.0.0/0` default route is required.
- Route tables should contain the implicit local VPC route.

---

## Validate S3 Gateway Endpoint Route Tables

```bash
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.s3" \
  --query 'VpcEndpoints[0].RouteTableIds' \
  --output table
```

Expected:

- S3 Gateway Endpoint exists.
- Route table IDs include the private route tables intentionally passed to the VPC endpoints module.
- S3 Gateway Endpoint route tables commonly include compute private route tables and serverless private route tables.

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

Confirm that outbound traffic behaves according to the selected `deployment_profile` and effective `egress_mode`.

The baseline supports three egress modes:

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route |
|---|---:|---:|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint |
| `nat_only` | No | Yes | NAT Gateway |
| `vpc_endpoints_only` | No | No | No default route |

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
- If `nat_only` is enabled, compute private route tables should route `0.0.0.0/0` to NAT Gateway.
- If `vpc_endpoints_only` is enabled, compute private route tables should not have a `0.0.0.0/0` route.

---

## Check Network Firewall Presence

```bash
aws network-firewall list-firewalls \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Firewalls[?contains(FirewallName, `'"${NAME_PREFIX}"'`)].[FirewallName,FirewallArn]' \
  --output table
```

Expected:

- `network_firewall`: matching firewall exists.
- `nat_only`: no matching firewall exists.
- `vpc_endpoints_only`: no matching firewall exists.

---

## Check NAT Gateway Presence

```bash
aws ec2 describe-nat-gateways \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filter "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId,NatGatewayAddresses[0].PublicIp]' \
  --output table
```

Expected:

- `network_firewall`: NAT Gateways exist and are `available`.
- `nat_only`: NAT Gateways exist and are `available`.
- `vpc_endpoints_only`: no NAT Gateways are expected.

---

## Check Compute Private Default Routes

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-RT-*" \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[?DestinationCidrBlock==`0.0.0.0/0`]}' \
  --output json
```

Expected:

- `network_firewall`: default route points to a Network Firewall endpoint.
- `nat_only`: default route points to a NAT Gateway.
- `vpc_endpoints_only`: no default route is present.

---

## Optional Internet Egress Test

Run from inside an SSM session:

```bash
timeout 5 bash -c "cat < /dev/null > /dev/tcp/example.com/443" \
  && echo "Internet egress reachable" || echo "No direct internet egress"
```

Expected result depends on your egress design:

- If `network_firewall` or `nat_only` is enabled, internet access may succeed depending on route tables, firewall policy, and security group rules.
- If using `vpc_endpoints_only`, internet egress should fail.

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

## 9.4 Validate CloudWatch Log Retention

```bash
aws logs describe-log-groups \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'logGroups[?contains(logGroupName, `'"${NAME_PREFIX}"'`) || contains(logGroupName, `/aws/lambda/`) || contains(logGroupName, `/aws/cloudtrail/`) || contains(logGroupName, `/aws/vpc-flow-logs/`)].[logGroupName,retentionInDays]' \
  --output table
```

Expected:

- Relevant baseline log groups have retention configured.
- `production` defaults to 90 days unless overridden.
- `development` defaults to 30 days unless overridden.
- `minimal` defaults to 14 days unless overridden.

---

# 10. Validate Security Services

## Purpose

Confirm that core AWS security services are enabled according to the selected deployment profile and explicit overrides.

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

- If `effective_enable_config = true`, configuration recorder exists, delivery channel exists, and recorder is enabled.
- If `effective_enable_config = false`, AWS Config resources may be absent or disabled, depending on current state and configuration.
- If Config is disabled, Config rule groups should be forced off.

---

## 10.4 Inspector

```bash
aws inspector2 batch-get-account-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --account-ids "${ACCOUNT_ID}" \
  --query 'accounts[0].{AccountStatus:state.status,EC2:resourceState.ec2.status,Lambda:resourceState.lambda.status,LambdaCode:resourceState.lambdaCode.status}' \
  --output table
```

Expected:

- If `effective_inspector_enabled = true`, Inspector account/resource statuses should be enabled according to configuration.
- If `effective_inspector_enabled = false`, Inspector may be disabled or return no enabled resource status.

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

Note:

Backup-related KMS aliases may only exist when backup resources are enabled.

---

# 12. Validate SNS, SQS, and Notification DLQs

## Purpose

Confirm that security and compliance notification paths are deployed, encrypted, subscribed, and protected with the expected DLQs.

Most of this validation is automated by:

```bash
./scripts/validation/validate-sns.sh "${ENVIRONMENT}"
./scripts/validation/validate-sqs.sh "${ENVIRONMENT}"
./scripts/validation/validate-eventbridge.sh "${ENVIRONMENT}"
```

These scripts should be the primary validation path. The commands below are useful for spot checks, troubleshooting, or manual release review.

---

## 12.1 Validate SNS Topics and Subscriptions

List expected notification topics:

```bash
aws sns list-topics \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Topics[?contains(TopicArn, `security-notifications`) || contains(TopicArn, `compliance-notifications`)].TopicArn' \
  --output table
```

Expected topics:

```text
${NAME_PREFIX}-security-notifications
${NAME_PREFIX}-compliance-notifications
```

For each expected topic, check attributes and subscriptions:

```bash
aws sns get-topic-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --topic-arn "<SNS_TOPIC_ARN>" \
  --query 'Attributes.{TopicArn:TopicArn,KmsMasterKeyId:KmsMasterKeyId,SubscriptionsConfirmed:SubscriptionsConfirmed,SubscriptionsPending:SubscriptionsPending}' \
  --output table

aws sns list-subscriptions-by-topic \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --topic-arn "<SNS_TOPIC_ARN>" \
  --query 'Subscriptions[].[Protocol,Endpoint,SubscriptionArn]' \
  --output table
```

Expected:

- SNS topics are encrypted with the logs CMK.
- The compliance topic has an SQS subscription to the compliance queue.
- The security notifications topic has expected email subscriptions and an SQS subscription to the security notifications queue.
- Confirmed subscriptions show real subscription ARNs.
- Unconfirmed email subscriptions show `PendingConfirmation`.

---

## 12.2 Validate SQS Notification Queues and DLQs

List environment queues:

```bash
aws sqs list-queues \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-name-prefix "${NAME_PREFIX}" \
  --output table
```

Expected queues include:

```text
${NAME_PREFIX}-compliance-queue
${NAME_PREFIX}-security-notifications-queue
${NAME_PREFIX}-security-notifications-dlq
${NAME_PREFIX}-security-notifications-eventbridge-dlq
${NAME_PREFIX}-ec2-isolation-dlq
${NAME_PREFIX}-ec2-rollback-dlq
${NAME_PREFIX}-ip-enrichment-dlq
```

Meaning:

| Queue | Purpose |
|---|---|
| `compliance-queue` | Durable compliance notification subscriber |
| `security-notifications-queue` | Durable security notification subscriber |
| `security-notifications-dlq` | Redrive DLQ for repeated processing failures from the security notifications queue |
| `security-notifications-eventbridge-dlq` | EventBridge target DLQ for failed EventBridge deliveries to the security notifications SNS topic |
| `ec2-isolation-dlq` | EC2 Isolation automation failure-retention queue |
| `ec2-rollback-dlq` | EC2 Rollback automation failure-retention queue |
| `ip-enrichment-dlq` | IP Enrichment automation failure-retention queue |

Check queue attributes:

```bash
QUEUE_URL="$(aws sqs get-queue-url \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-name "${NAME_PREFIX}-security-notifications-queue" \
  --query 'QueueUrl' \
  --output text)"

aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --attribute-names All \
  --query 'Attributes.{QueueArn:QueueArn,KmsMasterKeyId:KmsMasterKeyId,RedrivePolicy:RedrivePolicy,Messages:ApproximateNumberOfMessages,NotVisible:ApproximateNumberOfMessagesNotVisible}' \
  --output json
```

Expected:

- `KmsMasterKeyId` is configured.
- Security notifications queue has a redrive policy to `security-notifications-dlq`.
- Queue policy allows the security notifications SNS topic to send messages.
- Visible messages may accumulate if no downstream consumer is configured.
- DLQ visible message counts should normally be `0`.

---

## 12.3 Validate EventBridge Notification DLQ

Check the shared EventBridge DLQ for security notification delivery failures:

```bash
EVENTBRIDGE_DLQ_URL="$(aws sqs get-queue-url \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-name "${NAME_PREFIX}-security-notifications-eventbridge-dlq" \
  --query 'QueueUrl' \
  --output text)"

aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${EVENTBRIDGE_DLQ_URL}" \
  --attribute-names All \
  --query 'Attributes.{QueueArn:QueueArn,KmsMasterKeyId:KmsMasterKeyId,Policy:Policy,Messages:ApproximateNumberOfMessages,NotVisible:ApproximateNumberOfMessagesNotVisible,Oldest:ApproximateAgeOfOldestMessage}' \
  --output json
```

Expected:

- `KmsMasterKeyId` is configured.
- Queue policy allows `events.amazonaws.com` to send messages from expected EventBridge rule ARNs.
- Visible message count is normally `0`.

---

## 12.4 Validate Notification DLQ Alarms

Check CloudWatch alarms related to notification DLQs:

```bash
aws cloudwatch describe-alarms \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --alarm-name-prefix "${NAME_PREFIX}" \
  --query 'MetricAlarms[?contains(AlarmName, `DLQ`) || contains(AlarmName, `dlq`)].[AlarmName,StateValue,MetricName,Namespace]' \
  --output table
```

Expected alarms include:

```text
${NAME_PREFIX}-security-notifications-dlq-visible-messages
${NAME_PREFIX}-Security-Notifications-EventBridge-DLQ-Messages
```

Automation workflow DLQ alarms may also appear depending on module configuration.

---

## 12.5 DLQ Operational Follow-Up

DLQs are terminal failure-retention queues. They retain failed events for review and do not automatically replay messages.

If a DLQ alarm fires:

1. Identify which DLQ has visible messages.
2. Capture approximate visible, not-visible, and oldest-message counts.
3. Review recent CloudWatch alarm state changes.
4. Inspect one message without deleting it.
5. Determine whether the failure is caused by EventBridge delivery, SNS/SQS policy, KMS permissions, Lambda processing, or downstream consumer behavior.
6. Fix the underlying issue.
7. Replay, archive, or discard the message only after review.

Inspect queue counts:

```bash
aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
  --output table
```

Inspect one message safely with a short visibility timeout:

```bash
aws sqs receive-message \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --max-number-of-messages 1 \
  --visibility-timeout 30 \
  --attribute-names All \
  --message-attribute-names All \
  --output json
```

Do not delete the message until the failure has been understood and the operator has decided whether to replay, archive, or discard it.

For `security-notifications-eventbridge-dlq`, check:

- EventBridge target exists and points to the security notifications SNS topic.
- EventBridge target has the expected DLQ and retry policy.
- Security notifications SNS topic exists.
- SNS topic policy allows the source EventBridge rule ARN to publish.
- EventBridge DLQ queue policy allows the source EventBridge rule ARN to send messages.
- KMS permissions allow encrypted SNS/SQS delivery.

For `security-notifications-dlq`, check:

- Whether a downstream consumer is configured.
- Consumer logs, permissions, timeouts, and parsing errors.
- Message schema compatibility.
- Queue redrive policy and max receive count.
- KMS permissions for the consumer.

Messages in the primary compliance or security notification queues may accumulate when no downstream consumer is configured. Messages in a DLQ should be treated as a failure signal.

# 13. Validate EventBridge Rules

## Purpose

Confirm that EventBridge rules exist for security automation across all expected event buses.

Check the default bus:

```bash
aws events list-rules \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --event-bus-name default \
  --query 'Rules[].[Name,State,EventBusName]' \
  --output table
```

Expected rules may include:

- Amazon Inspector rules, if enabled
- Security Hub high/critical finding handling
- Tamper detection
- Break-glass detection (`break-glass-admin-assumed`)
- EC2 isolation trigger (`EC2-High-Critical`)

Validate `secops` custom event bus:

```bash
aws events list-event-buses \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'EventBuses[].[Name,Arn]' \
  --output table
```

Expected:

```text
default
secops-bus
```

Check the customer `SecOps` bus:

```bash
aws events list-rules \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --event-bus-name "${CLOUD_NAME}-${ENVIRONMENT}-secops-bus" \
  --query 'Rules[].[Name,State,EventBusName]' \
  --output table
```

Expected rules may include:

- EC2 Rollback

Confirm EventBridge targets and target DLQs:

```bash
aws events list-targets-by-rule \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --rule "${CLOUD_NAME}-${ENVIRONMENT}-securityhub-high-critical" \
  --event-bus-name default \
  --query 'Targets[].{Id:Id,Arn:Arn,DLQ:DeadLetterConfig.Arn,MaxAttempts:RetryPolicy.MaximumRetryAttempts,MaxAge:RetryPolicy.MaximumEventAgeInSeconds}' \
  --output table
```

Expected targets may include:

- `IpEnrichmentLambda`
- `sec-hub-to-secops-sns`

Expected:

- Security notification SNS targets use the shared `security-notifications-eventbridge-dlq`.
- Automation Lambda targets use workflow-specific DLQs.
- Protected EventBridge targets use retry attempts of `3`.
- Protected EventBridge targets use max event age of `3600` seconds.

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
TRAIL_NAME="$(aws cloudtrail describe-trails \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'trailList[0].Name' \
  --output text)"

aws cloudtrail stop-logging \
  --name "${TRAIL_NAME}" \
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
  --name "${TRAIL_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Confirm CloudTrail is logging again:

```bash
aws cloudtrail get-trail-status \
  --name "${TRAIL_NAME}" \
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

If safe to test, use one of the principal ARNs included in the `break_glass_trusted_principal_arns` variable to assume or simulate use of the configured break-glass role.

This test requires the user assuming the `BreakGlass-Admin` role to be enrolled with MFA.

Confirm your account is configured with an MFA device:

```bash
aws iam list-mfa-devices \
  --user-name baseline-admin \
  --profile "${AWS_PROFILE}" \
  --query 'MFADevices[].[SerialNumber,EnableDate]' \
  --output table
```

Expected output:

```text
arn:aws:iam::<ACCOUNT_ID>:mfa/<DEVICE_NAME>
```

Then set the MFA serial:

```bash
export MFA_SERIAL="$(aws iam list-mfa-devices \
  --user-name baseline-admin \
  --profile "${AWS_PROFILE}" \
  --query 'MFADevices[0].SerialNumber' \
  --output text)"
```

Assume the `BreakGlass-Admin` role, replacing `<MFA_CODE>` with the six digit code from your authentication device:

```bash
export BREAK_GLASS_ROLE_ARN="$(aws iam list-roles \
  --profile "${AWS_PROFILE}" \
  --query 'Roles[?contains(RoleName, `BreakGlass`) || contains(RoleName, `break-glass`)].Arn | [0]' \
  --output text)"

aws sts assume-role \
  --role-arn "${BREAK_GLASS_ROLE_ARN}" \
  --role-session-name "break-glass-validation-test" \
  --serial-number "${MFA_SERIAL}" \
  --token-code "<MFA_CODE>" \
  --profile "${AWS_PROFILE}" \
  --output json
```

Expected output:

```json
{
    "Credentials": {
        "AccessKeyId": "XXXXXX",
        "SecretAccessKey": "XXXXXX",
        "SessionToken": "XXXXXX",
        "Expiration": "XXXXXX"
    },
    "AssumedRoleUser": {
        "AssumedRoleId": "XXXXXX",
        "Arn": "arn:aws:sts::<ACCOUNT_ID>:assumed-role/<CLOUD_NAME>-<ENVIRONMENT>-BreakGlass-Admin/break-glass-validation-test"
    }
}
```

Expected behavior after assuming the role:

- CloudTrail records the role assumption.
- EventBridge rule matches the activity.
- Break-Glass SNS alert is sent.

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

Confirm the effective backup setting first:

```bash
terraform output effective_backup_enabled
```

If backup is enabled, confirm the backup vault exists:

```bash
aws backup list-backup-vaults \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'BackupVaultList[].[BackupVaultName,BackupVaultArn]' \
  --output table
```

Confirm vault encryption is configured:

```bash
export BACKUP_VAULT_NAME="$(aws backup list-backup-vaults \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'BackupVaultList[0].BackupVaultName' \
  --output text)"

aws backup describe-backup-vault \
  --backup-vault-name "${BACKUP_VAULT_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query '{Name:BackupVaultName,Arn:BackupVaultArn,EncryptionKeyArn:EncryptionKeyArn,RecoveryPoints:NumberOfRecoveryPoints}' \
  --output table
```

Expected when backup is enabled:

- Backup vault exists.
- `EncryptionKeyArn` is populated.
- `EncryptionKeyArn` points to the expected backup vault KMS CMK.

Expected when backup is disabled:

- Project-specific backup vaults and plans may be absent.
- This is expected for lower-cost profiles such as `development` and `minimal` unless backup is explicitly enabled.

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

- AWS-managed default patch baselines are visible.
- If custom patch baselines are enabled, project-specific baselines appear.
- If no custom patch baselines are configured, seeing only `AWS-*DefaultPatchBaseline` entries is acceptable.
- Maintenance window exists if enabled.

---

# 20. Validate GitHub Actions Workflows

## Purpose

Confirm that CI/CD workflows operate successfully.

Run the following workflows:

- Terraform Static Analysis
- Docs Validation
- Terraform Plan
- Terraform Apply
- Terraform Destroy in a non-production environment only
  > Ensure that the `bootstrap/<env>/account` stack has been reapplied with the `lambda_cmk_arn` and `secrets_manager_cmk_arn` variables set before running the Terraform Destroy workflow

Expected:

- Static analysis workflow succeeds.
- Docs validation workflow succeeds.
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

## Profile or Egress Mode Looks Wrong

Check:

- Environment `deployment_profile` value.
- Environment `egress_mode` value.
- Terraform output `effective_egress_mode`.
- Any explicit override variables such as `enable_config`, `backup_enabled`, `cloudwatch_retention_days`, or `egress_mode`.

Useful command from the environment directory:

```bash
terraform output
```

Expected:

- `deployment_profile` shows the selected profile.
- `egress_mode` shows the selected input.
- `effective_egress_mode` shows the resolved routing mode.

---

## SSM Session Fails

Check:

- Instance has SSM agent installed and running.
- Instance IAM role includes SSM permissions.
- Interface endpoints exist for:
  - `sts`
  - `logs`
  - `ssm`
  - `ssmmessages`
  - `secretsmanager`
  - `kms`
  - `config`
  - `sns`
  - `ec2`
  - `events`
  - `securityhub`
  - `lambda`
- Endpoint security group allows inbound 443 from workload security group.
- Workload security group allows outbound 443 to endpoint security group.
- Instance has network path to SSM endpoints.
- Interface Endpoints are deployed into endpoint private subnets.

---

## VPC Endpoint DNS Fails

Check:

- Private DNS is enabled on the endpoint.
- VPC DNS hostnames are enabled.
- VPC DNS resolution is enabled.
- Endpoint exists in the expected VPC and endpoint private subnets.
- Security groups allow traffic.

---

## AWS Service 443 Checks Fail

Check:

- Endpoint security group allows traffic.
- Workload security group egress allows 443.
- Route tables are correct.
- Interface Endpoints are deployed into endpoint private subnets.
- Network Firewall rules allow required egress if applicable.
- NAT Gateway exists if internet egress is expected.

---

## Internet Egress Is Unexpected

Check:

- Effective egress mode.
- Route tables.
- NAT Gateway routes.
- Network Firewall policy.
- Security group egress.
- NACLs.
- Whether the selected environment is intended to allow controlled internet egress.

Expected by mode:

- `network_firewall`: internet egress may be available through Network Firewall and NAT, depending on firewall policy.
- `nat_only`: internet egress may be available through NAT.
- `vpc_endpoints_only`: general internet egress should not be available.

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

## AWS Config Is Missing

Check:

- `effective_enable_config` output.
- `enable_config` override value.
- `deployment_profile`.

Expected:

- `production` and `development` enable AWS Config by default.
- `minimal` disables AWS Config by default unless explicitly overridden.

---

## Backup Resources Are Missing

Check:

- `effective_backup_enabled` output.
- `backup_enabled` override value.
- `deployment_profile`.

Expected:

- `production` enables backup by default.
- `development` and `minimal` disable backup by default unless explicitly overridden.

---

## Control-Plane Validation Fails

Check:

- `AWS_PROFILE` is set to the control-plane profile.
- `EXPECTED_ACCOUNT_ID` matches the control-plane account ID.
- `EXPECTED_GITHUB_REPOSITORY` matches the repository trusted by the GitHub OIDC role, using the exact owner/repo spelling.
- `ACCOUNT_ID_DEV`, `ACCOUNT_ID_STAGING`, and `ACCOUNT_ID_PROD` are set when validating Identity Center assignments or account placement.
- `bootstrap/control_plane/state` has been applied and has current Terraform outputs.
- `bootstrap/control_plane/account` has been applied with GitHub OIDC enabled.
- `bootstrap/control_plane/organizations` has been applied.
- `bootstrap/control_plane/identity_center` has been applied after workload baseline policy names were available, if optional policy-backed roles are enabled.

If the script warns that workload accounts are under the AWS Organizations root instead of the expected OUs, confirm whether account placement is currently managed by Terraform. If account placement is not managed, treat this as a governance warning rather than a deployment failure.

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

## Notification or Automation DLQ Has Messages

Check:

- Which DLQ has visible messages.
- Whether the DLQ is an EventBridge target DLQ, SQS redrive DLQ, or workflow automation DLQ.
- EventBridge target DLQ and retry policy configuration.
- SNS topic policy and SQS queue policy.
- KMS key policy permissions for SNS, SQS, EventBridge, Lambda, or the downstream consumer.
- Lambda function logs and async/EventBridge delivery behavior for workflow-specific DLQs.
- Whether the message still needs to be replayed, archived, or discarded.

Useful commands:

```bash
aws sqs list-queues \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-name-prefix "${NAME_PREFIX}" \
  --output table
```

```bash
aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateAgeOfOldestMessage \
  --output table
```

```bash
aws sqs receive-message \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --max-number-of-messages 1 \
  --visibility-timeout 30 \
  --attribute-names All \
  --message-attribute-names All \
  --output json
```

Do not delete DLQ messages until the root cause has been understood and the operator has decided whether to replay, archive, or discard them.

---

# Summary

This checklist validates that `tf-secure-baseline` is deployed correctly and that the core security workflows function as intended.

A successful validation means:

- Automated workload validation passes for the target environment.
- AWS accounts and profiles are correct.
- Terraform state backends exist.
- GitHub OIDC roles work if enabled.
- Automated control-plane validation passes for state backend resources, GitHub OIDC, Organizations OU structure, and IAM Identity Center basics.
- Environment baselines exist.
- Deployment profile outputs resolve correctly.
- Egress mode behavior matches the selected profile or override.
- Private networking and endpoint access are configured.
- Interface Endpoints are deployed into dedicated endpoint private subnets.
- Logging and security services are active where expected.
- KMS, Backup, SNS, SQS, EventBridge, Lambda, SSM, Compute, and IAM controls validate successfully.
- Notification and automation DLQs exist, are encrypted, and are reviewed when messages appear.
- Identity Center permission sets and account assignments are present, with end-user login and group membership reviewed manually where required.
- Live EC2 isolation, rollback, IP enrichment, tamper detection, and break-glass workflows have been tested manually where appropriate.
- Destroy procedures are understood before teardown.