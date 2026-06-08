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
6. Deployment profile validation
7. Networking validation
8. VPC endpoint validation
9. Logging validation
10. Security service validation
11. Identity Center validation
12. Lambda workflow validation
13. Alerting validation
14. Destroy safety validation

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

For deployed workload environments, the safe, read-only workload-account checks for environment outputs, networking, VPC endpoints, logging, security services, and IAM can be run with the validation scripts in `scripts/validation/`.

Set the expected account ID when running validation so the scripts can confirm that the selected AWS profile is pointed at the correct workload account.

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/validation/validate-all.sh dev

AWS_PAGER="" \
AWS_PROFILE=staging \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
./scripts/validation/validate-all.sh staging

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

These scripts automate the safe, read-only workload-account checks in this checklist.

Manual validation is still required for control-plane resources, Identity Center assignments, live Lambda workflow tests, tamper tests, break-glass tests, GitHub Actions workflow review, and destroy safety.

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

Confirm EventBridge Targets:

```bash
aws events list-targets-by-rule \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --rule "${CLOUD_NAME}-${ENVIRONMENT}-securityhub-high-critical" \
  --event-bus-name default \
  --query 'Targets[].[Id,Arn]' \
  --output table
```

Expected targets may include:

- `IpEnrichment`
- `sec-hub-to-secops-sns`

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
- Deployment profile outputs resolve correctly.
- Egress mode behavior matches the selected profile or override.
- Private networking and endpoint access work.
- Interface Endpoints are deployed into dedicated endpoint private subnets.
- Logging and security services are active where expected.
- Identity Center access is configured.
- EC2 isolation and rollback work.
- IP enrichment works.
- Tamper and break-glass alerts are configured.
- Destroy procedures are understood before teardown.