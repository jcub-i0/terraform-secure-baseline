# Compute Module

## Overview

The `compute` module provisions the workload EC2 compute layer.

These are standalone `aws_instance` resources, not an Auto Scaling Group or
ECS capacity provider. The module does not provide health-based replacement,
load balancing, rolling patch orchestration, or automatic capacity scaling.
The Fargate application runtime is a separate layer.

It creates:

- A compute security group
- A quarantine security group for incident-response isolation
- One Ubuntu EC2 instance per configured private compute subnet
- Dependency-readiness checkpoints that prevent EC2 instances from launching
  before required security group rules and Terraform-managed Interface VPC Endpoints exist
- Encrypted `gp3` root volumes
- IMDSv2-only metadata access
- First-boot operating system patching and package installation
- Tags used by patching, backup, and isolation automation

The module creates the compute security groups and EC2 instances. Security group
rules for normal workload traffic remain owned by the networking
`security_policy` layer.

---

## Architecture

The module participates in two resource-level readiness chains:

```text
aws_security_group.compute
        |
        v
security_policy security-group rules
        |
        v
security_policy.compute_sg_rule_ids
        |
        v
terraform_data.compute_security_policy_ready
        |
        +------------------+
                           |
vpc_endpoints.interface_endpoint_ids
        |
        v                  |
terraform_data.compute_vpc_endpoints_ready
        |                  |
        +------------------+
                |
                v
        aws_instance.ec2
```

This ordering allows the compute security group to exist early enough for the networking `security_policy` layer to reference it, while delaying EC2 launch until both the required traffic rules and the Terraform-managed Interface Endpoints exist.

The endpoint dependency is especially important for GuardDuty Runtime Monitoring. Because `guardduty-data` is part of the Terraform-managed Interface Endpoint set, eligible EC2 instances are not launched before that endpoint exists, avoiding reliance on a GuardDuty-created VPC endpoint.

---

## Resources Created

### Compute Security Group

```hcl
resource "aws_security_group" "compute"
```

Name:

```text
<name_prefix>-Compute-SG
```

The compute security group is attached to every EC2 instance created by this
module.

The module creates the security group without inline traffic rules. Normal
traffic rules are managed by the networking `security_policy` layer.

This separation keeps security policy centralized while allowing the compute
module to own the EC2 security group lifecycle.

---

### Quarantine Security Group

```hcl
resource "aws_security_group" "quarantine"
```

Security group resource name:

```text
<name_prefix>-Quarantine-SG
```

The `Name` tag is:

```text
<name_prefix>-EC2-Quarantine-SG
```

The quarantine security group is used by EC2 isolation automation to replace an
instance's normal security group attachments during incident response.

Current quarantine egress:

| Direction | Protocol | Port | Destination | Purpose |
|---|---|---:|---|---|
| Egress | TCP | 443 | Shared Interface Endpoint SG | Access to the endpoint ENIs permitted by the networking security-policy layer |

The quarantine security group intentionally defines no inbound rules. Its
HTTPS egress and the reciprocal endpoint ingress are created by
[`security_policy`](../networking/security_policy/README.md), not inline here.
This retains access to the shared endpoint group, not just SSM. It is not a
complete network disconnect or an IAM restriction on which AWS APIs the
instance can call. No general internet or S3-prefix-list egress rule is created
for quarantine by that module.

---

### Ubuntu AMI Lookup

```hcl
data "aws_ami" "ec2"
```

The module selects the most recent matching Canonical Ubuntu 24.04 LTS image.

| Setting | Value |
|---|---|
| Owner | `099720109477` |
| Name filter | `ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server*` |
| Most recent | `true` |

Selecting the most recent AMI does not guarantee that every installed package is
fully current. The first-boot bootstrap script performs an APT metadata refresh
and distribution upgrade. The AMI ID is resolved dynamically, not pinned to a
literal image ID. A later plan can select a newer image and propose instance
replacement even without a repository change. Review the saved plan and retain
the resolved AMI as deployment evidence.

---

### Security-Policy Readiness Checkpoint

```hcl
resource "terraform_data" "compute_security_policy_ready"
```

The readiness checkpoint receives the required security group rule IDs through:

```hcl
input = var.compute_sg_rule_ids
```

It does not create AWS infrastructure. Its purpose is to preserve resource-level
Terraform dependencies between:

1. The compute security group
2. The networking security-policy rules
3. The EC2 instances

The EC2 instances include this dependency (excerpt; the full list appears below):

```hcl
depends_on = [
  terraform_data.compute_security_policy_ready
]
```

The readiness object contains:

```hcl
{
  endpoints_ingress_from_compute    = string
  compute_egress_to_endpoints       = string
  compute_egress_to_db              = string
  compute_egress_to_internet_https  = optional(string)
}
```

`compute_egress_to_internet_https` is optional because the rule does not exist
when the effective egress mode is `vpc_endpoints_only`.

The attribute names in the compute variable and the networking output must match
exactly. In particular, use:

```text
compute_egress_to_internet_https
```

Do not use `compute_egress_to_internet_egress`.

---

### Interface Endpoint Readiness Checkpoint

```hcl
resource "terraform_data" "compute_vpc_endpoints_ready"
```

The second readiness checkpoint receives:

```hcl
input = var.interface_endpoint_ids
```

where `interface_endpoint_ids` is the map exported by `modules/vpc_endpoints`.

The EC2 instances depend on both readiness resources:

```hcl
depends_on = [
  terraform_data.compute_security_policy_ready,
  terraform_data.compute_vpc_endpoints_ready
]
```

This establishes a narrow Terraform dependency on the endpoint resources themselves rather than a broad module-level `depends_on`.

The map currently includes the full Terraform-managed Interface Endpoint set, including `guardduty-data`. The checkpoint proves Terraform has created those endpoint resources before EC2 launch; it does not prove endpoint DNS resolution, route health, AWS service health, or public package-repository reachability.

---

### EC2 Instances

```hcl
resource "aws_instance" "ec2"
```

The module creates one instance per entry in:

```hcl
var.compute_private_subnet_ids_map
```

Expected map format:

```hcl
{
  "us-east-1a" = "subnet-0123456789abcdef0"
  "us-east-1b" = "subnet-0fedcba9876543210"
}
```

In the integrated baseline, the default topology provides three compute subnets
for the production profile and two for the development/minimal profiles.
Explicit supported AZ selections can change that count. This child module
iterates the supplied map; it does not enforce those profile rules itself.
Map-key changes alter instance addresses and require careful plan review.

Current instance configuration:

| Setting | Value |
|---|---|
| AMI | Latest matching Canonical Ubuntu 24.04 LTS AMI |
| Instance type | `t3.micro` |
| Placement | One instance per compute private subnet map entry |
| Security group | `aws_security_group.compute` |
| Detailed monitoring | Enabled |
| EBS optimized | `true` |
| IAM instance profile | `var.instance_profile_name` |
| User data | `user_data/bootstrap.sh` |
| Replace on user-data change | Enabled |
| Public IP | Not explicitly associated |
| IMDSv2 | Required |
| Metadata hop limit | `2` |
| Root volume size | `20` GiB |
| Root volume type | `gp3` |
| Root volume encryption | Enabled |
| Root volume KMS key | `var.ebs_cmk_arn` |

---

## User Data Bootstrap

The instance user data is loaded with:

```hcl
user_data = file("${path.module}/user_data/bootstrap.sh")
```

The module also sets:

```hcl
user_data_replace_on_change = true
```

Changing `user_data/bootstrap.sh` therefore causes Terraform to replace the EC2
instances so the new first-boot configuration is applied.

### Bootstrap Behavior

The bootstrap script:

1. Enables strict Bash behavior with `set -Eeuo pipefail`
2. Writes output to `/var/log/instance-bootstrap.log`
3. Configures noninteractive APT behavior
4. Sets a five-minute dpkg lock timeout and five retries
5. Forces APT operations over IPv4
6. Rewrites HTTP URLs in `/etc/apt/sources.list.d/ubuntu.sources` to HTTPS when that file exists
7. Runs `apt-get update` with `APT::Update::Error-Mode=any`
8. Runs `apt-get dist-upgrade -y`
9. Installs `ca-certificates`, `curl`, and `jq`
10. Records selected package versions and reboot-required state
11. Logs the completion timestamp

The source rewrite is not a rewrite of every APT source file. A missing
`ubuntu.sources` file produces a warning. The script reports a required reboot
but does not reboot the instance, explicitly install/configure SSM Agent or
CloudWatch Agent, or verify that every vulnerability has been remediated.
Terraform instance creation and SSM registration do not independently establish
that this script completed successfully.

If any configured repository still fails after retries, metadata refresh fails and strict shell handling stops the bootstrap instead of continuing with stale package indexes.

### Bootstrap Log

```text
/var/log/instance-bootstrap.log
```

From an SSM session:

```bash
sudo cat /var/log/instance-bootstrap.log
```

Also inspect the cloud-init log when first-boot execution fails:

```bash
sudo tail -n 300 /var/log/cloud-init-output.log
```

### Package Versions Recorded

The current script records versions for:

- `ubuntu-advantage-tools`
- `ubuntu-pro-client`
- `ubuntu-pro-client-l10n`
- `vim`
- `vim-common`
- `vim-runtime`
- `vim-tiny`
- `xxd`

The version-reporting command is informational and does not fail the bootstrap
when one of the listed packages is absent.

### Repository Access Requirement

First-boot patching requires a functioning outbound path to the Ubuntu package
repositories.

Depending on the effective deployment profile, that path may use:

- NAT Gateway egress
- AWS Network Firewall followed by a NAT Gateway
- An approved internal package mirror, if separately configured and reachable

VPC endpoint access alone does not provide access to public Ubuntu repositories.

The readiness dependencies prevent EC2 creation before the managed security group rules and Interface Endpoint resources exist. They do not replace route, NAT Gateway, firewall, DNS, endpoint-health, or package-repository availability checks.

---

## Metadata Security

The module requires IMDSv2:

```hcl
metadata_options {
  http_tokens                 = "required"
  http_put_response_hop_limit = 2
}
```

This prevents unauthenticated IMDSv1 requests and requires session tokens for
instance metadata access.

---

## Root Volume Encryption

Each instance uses an encrypted root volume:

```hcl
root_block_device {
  volume_size = 20
  volume_type = "gp3"
  encrypted   = true
  kms_key_id  = var.ebs_cmk_arn
}
```

The caller and EC2 service path must be authorized to use the supplied EBS KMS
key.

---

## Instance Tags

Each instance receives:

| Tag | Value | Purpose |
|---|---|---|
| `Name` | `<name_prefix>-EC2-<map-key>` | Human-readable resource name |
| `Environment` | `var.environment` | Environment ownership |
| `Terraform` | `true` | Infrastructure-as-code ownership |
| `Purpose` | Workload processing description | Workload role |
| `IsolationAllowed` | `tostring(var.isolation_allowed)` | Explicit isolation authorization |
| `PatchGroup` | `var.patch_tag_value` | SSM Patch Manager targeting |
| `Backup` | `tostring(var.backup_enabled)` | AWS Backup tag-based selection intent |

### Isolation Authorization

`isolation_allowed` defaults to:

```hcl
false
```

This is a fail-closed default. Automatic isolation should occur only when the
root configuration explicitly sets:

```hcl
isolation_allowed = true
```

The resulting EC2 tag is stored as the string `true` or `false`.

The reusable compute module defaults to `false`, but the supplied `dev`,
`staging`, and `prod` workload roots each declare a `true` default and forward
that input. Do not infer disabled response from an environment name or the
child-module default. Set the intended value explicitly in reviewed local/CI
inputs and inspect the live tag.

The isolation handler trims and lowercases the tag before comparing it with
`true`; this is a handler gate, not an IAM condition on the response role.
Rollback writes `IsolationAllowed=true` rather than recovering a prior value.
Reconcile that write with the approved Terraform input after a response test.

---

## Isolation Drift Protection

The EC2 resource ignores changes to:

```hcl
vpc_security_group_ids
tags["Isolated"]
tags["IsolatedBy"]
tags["IsolationFinding"]
tags["IsolationTime"]
tags["OriginalSecurityGroups"]
```

This prevents a routine `terraform apply` from:

- Reattaching the normal compute security group to an isolated instance
- Removing incident-response tags written by isolation automation

Terraform continues to manage `IsolationAllowed`. That policy tag is
intentionally not ignored.

### Operational Tradeoff

Because all changes to `vpc_security_group_ids` are ignored, Terraform will not
automatically correct manual or automation-driven security group attachment
changes.

Restoring an isolated instance should be handled through an approved and
verified recovery procedure. See the [isolation](../../docs/lambda_tests/ec2_isolation.md)
and [rollback](../../docs/lambda_tests/ec2_rollback.md) guides for partial-failure
and authorization limits.

The ignore list protects in-place attachment/tag ownership; it is not
`prevent_destroy`. AMI or user-data replacement and an approved destroy can
still remove an isolated instance. Review incident and evidence-preservation
requirements before applying a replacement. The rollback-only release tags
are not all included in this ignore list.

---

## Patch Management Integration

The module applies:

```text
PatchGroup = var.patch_tag_value
```

The separate `patch_management` module uses this tag to target instances with
SSM Patch Manager.

The compute bootstrap attempts first-boot package updates. The separate
[patch-management module](../patch_management/README.md) configures scheduled
patching; successful execution, complete target coverage, repository access,
and any required reboot must be verified separately. Its tag target does not
exclude quarantined instances.

---

## Backup Integration

The module applies:

```text
Backup = tostring(var.backup_enabled)
```

`backup_enabled` is a required child-module Boolean with no default. The
baseline supplies its resolved profile-aware value. This child module does not
resolve a deployment profile or convert a null input into a profile default.
When scheduling is disabled, the tag is `false`; the retained encrypted Backup
vault is a separate resource. A `true` tag is selection intent, not proof of a
successful backup or a recoverable snapshot.

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | `string` | n/a | Prefix used for resource names |
| `vpc_id` | `string` | n/a | VPC where the compute security groups are created |
| `environment` | `string` | n/a | Environment name |
| `compute_private_subnet_ids_map` | `map(string)` | n/a | Compute private subnet IDs keyed by AZ or logical subnet name |
| `instance_profile_name` | `string` | n/a | IAM instance profile attached to EC2 instances |
| `ebs_cmk_arn` | `string` | n/a | KMS key ARN used for root-volume encryption |
| `interface_endpoints_sg_id` | `string` | n/a | Interface endpoint security group ID |
| `data_sg_id` | `string` | n/a | Data-tier security group ID |
| `db_port` | `string` | n/a | Database port |
| `patch_tag_value` | `string` | n/a | Value assigned to the `PatchGroup` tag |
| `isolation_allowed` | `bool` | `false` | Whether instances may be automatically isolated; the caller can override this default |
| `backup_enabled` | `bool` | n/a | Resolved backup-selection Boolean supplied by the baseline |
| `compute_sg_rule_ids` | `object` | n/a | Security group rule IDs that must exist before EC2 launch |
| `interface_endpoint_ids` | `map(string)` | n/a | Terraform-managed Interface Endpoint IDs that must exist before EC2 launch |

### `compute_sg_rule_ids` Type

Use:

```hcl
variable "compute_sg_rule_ids" {
  description = "Security group rule IDs that must exist before compute EC2 instances launch"

  type = object({
    endpoints_ingress_from_compute   = string
    compute_egress_to_endpoints      = string
    compute_egress_to_db             = string
    compute_egress_to_internet_https = optional(string)
  })
}
```

### `interface_endpoint_ids` Type

Use:

```hcl
variable "interface_endpoint_ids" {
  description = "Map of Interface-type VPC Endpoints and their IDs"
  type        = map(string)
}
```

The expected caller is:

```hcl
interface_endpoint_ids = module.vpc_endpoints.interface_endpoint_ids
```

This creates the resource-level dependency from the Interface Endpoint resources to the EC2 instances.

---

### Compatibility Inputs

The current `main.tf` does not directly reference:

- `interface_endpoints_sg_id`
- `data_sg_id`
- `db_port`

They remain declared for compatibility with the surrounding module interface.
The active security group rules that use these values are owned by the
networking `security_policy` layer.

Remove these inputs from the compute module in a future breaking cleanup only
after updating every calling root module.

---

## Outputs

| Name | Description |
|---|---|
| `compute_sg_id` | ID of the compute security group |
| `quarantine_sg_id` | ID of the quarantine security group |

---

## Usage

This is the composition used from `baseline/`; it is not a standalone workload root.

```hcl
module "compute" {
  source = "../modules/compute"

  name_prefix = local.name_prefix
  vpc_id      = module.networking.vpc_id
  environment = var.environment

  compute_private_subnet_ids_map = module.networking.compute_private_subnet_ids_map
  compute_sg_rule_ids            = module.security_policy.compute_sg_rule_ids
  instance_profile_name          = module.iam.instance_profile_name
  ebs_cmk_arn                    = module.security.ebs_cmk_arn
  isolation_allowed              = var.isolation_allowed
  backup_enabled                 = local.effective_backup_enabled

  interface_endpoint_ids    = module.vpc_endpoints.interface_endpoint_ids
  interface_endpoints_sg_id = module.vpc_endpoints.interface_endpoints_sg_id
  data_sg_id                = module.storage.data_sg_id
  db_port                   = var.db_port
  patch_tag_value           = var.patch_tag_value
}
```

The important dependency inputs are:

```hcl
compute_sg_rule_ids   = module.security_policy.compute_sg_rule_ids
interface_endpoint_ids = module.vpc_endpoints.interface_endpoint_ids
```

Do not add a module-level dependency from the entire compute module to the standalone `security_policy` or `vpc_endpoints` module. The readiness objects preserve the required resource-level ordering while keeping the dependency graph narrow and avoiding a cycle with `security_policy`, which already consumes `module.compute.compute_sg_id`.

---

## Validation

Run these local Bash examples from the repository root after initializing the
selected workload backend with reviewed settings. Set the intended account
independently of the current credentials. `us-east-1` and `dev` are examples,
not universal deployment settings. These examples use a named AWS profile;
GitHub OIDC jobs instead use their configured default credential chain.

```bash
export AWS_PAGER=""
export AWS_PROFILE="dev"
export AWS_REGION="us-east-1"
export ENVIRONMENT="dev"
export EXPECTED_ACCOUNT_ID="<WORKLOAD-ACCOUNT-ID>"

prepare_workload_context() {
  local caller
  case "${ENVIRONMENT:-}" in
    dev|staging|prod) ;;
    *) printf '%s\n' 'Select dev, staging, or prod.' >&2; return 1 ;;
  esac
  : "${AWS_PROFILE:?Set the workload profile}"
  : "${AWS_REGION:?Set the service Region}"
  [[ "${EXPECTED_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] || {
    printf '%s\n' 'Set the intended 12-digit account ID.' >&2; return 1;
  }
  caller="$(aws sts get-caller-identity --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --query Account --output text)" || return 1
  [[ "$caller" == "$EXPECTED_ACCOUNT_ID" ]] || {
    printf '%s\n' 'AWS caller account mismatch.' >&2; return 1;
  }
  WORKLOAD_ROOT="environments/${ENVIRONMENT}"
  WORKLOAD_OUTPUTS_JSON="$(terraform -chdir="$WORKLOAD_ROOT" output -json)" || return 1
  jq -e --arg region "$AWS_REGION" '
    .primary_region.value == $region and
    (.name_prefix.value | type == "string" and length > 0) and
    (.vpc_id.value | type == "string" and startswith("vpc-"))
  ' <<< "$WORKLOAD_OUTPUTS_JSON" >/dev/null || return 1
  NAME_PREFIX="$(jq -r '.name_prefix.value' <<< "$WORKLOAD_OUTPUTS_JSON")"
  VPC_ID="$(jq -r '.vpc_id.value' <<< "$WORKLOAD_OUTPUTS_JSON")"
  export WORKLOAD_ROOT NAME_PREFIX VPC_ID
}

prepare_workload_context
```

Stop if this preflight fails. The `${VAR:?message}` expressions require a
non-empty value; they do not validate a profile's authority. Keep the selected
credentials, account, Region, and backend consistent throughout each test.
Re-run the complete preflight after changing environments.

Use the existing workload validators for their implemented configuration checks:

```bash
./scripts/validation/validate-compute.sh "${ENVIRONMENT:?Select the workload}"
./scripts/validation/validate-ssm.sh "${ENVIRONMENT:?Select the workload}"
./scripts/validation/validate-networking.sh "${ENVIRONMENT:?Select the workload}"
```

They do not execute the first-boot script, prove patch completion, establish
EC2 application high availability, or substitute for a live EC2 GuardDuty
coverage test. Fargate coverage evidence is not EC2-agent evidence.

### Terraform Validation

After reviewing backend initialization and selecting the same effective inputs
as the deployment, run from the repository root:

```bash
terraform -chdir="${WORKLOAD_ROOT:?Run the preflight}" fmt -check -recursive
terraform -chdir="${WORKLOAD_ROOT:?Run the preflight}" validate
terraform -chdir="${WORKLOAD_ROOT:?Run the preflight}" plan
```

Do not run the reusable child module as a deployment root. These commands do
not execute the remote bootstrap or patch task.

### Confirm Security Groups

```bash
aws ec2 describe-security-groups \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --filters \
    "Name=group-name,Values=${NAME_PREFIX}-Compute-SG,${NAME_PREFIX}-Quarantine-SG" \
    "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[].[GroupName,GroupId,VpcId,Description]' \
  --output table
```

### Confirm EC2 Placement

```bash
aws ec2 describe-instances \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:Environment,Values=${ENVIRONMENT}" \
    "Name=tag:Name,Values=${NAME_PREFIX}-EC2-*" \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,SubnetId,PrivateIpAddress,PublicIpAddress,State.Name]' \
  --output table
```

Expected:

- Instances are in compute private subnets
- Instances have private IP addresses
- Public IP addresses are absent
- Instances are running in normal operation; an approved stopped/isolation state must be recorded separately

Compare the full instance/subnet/AZ set with the applied `network_topology`
output. A table with one matching instance does not establish complete fleet
placement. Terminated instances are deliberately excluded from this inspection.

### Confirm IMDSv2

```bash
aws ec2 describe-instances \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:Environment,Values=${ENVIRONMENT}" \
    "Name=tag:Name,Values=${NAME_PREFIX}-EC2-*" \
    "Name=vpc-id,Values=${VPC_ID}" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
  --output table
```

Expected:

```text
HttpTokens = required
HttpPutResponseHopLimit = 2
```

### Confirm SSM Registration

Select one actual instance ID from the reviewed workload inventory; repeat for
every expected instance. Do not select an arbitrary first account-wide result.

```bash
export INSTANCE_ID="<REVIEWED-WORKLOAD-INSTANCE-ID>"
aws ssm describe-instance-information \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]' \
  --output table
```

Expect the exact selected instance, `PingStatus=Online`, and the intended Ubuntu
platform. An empty result is missing registration evidence, not a pass.

### Confirm Bootstrap Results

Prefer reading the bootstrap and cloud-init logs through an approved SSM
session. The following alternative creates a Run Command execution. Although
its remote commands inspect files, `send-command` is not a read-only AWS API.
Obtain authorization for that exact instance and retain the command ID.

```bash
(
  set -euo pipefail
  prepare_workload_context
  : "${INSTANCE_ID:?Select the reviewed instance}"
  : "${APPROVED_INSTANCE_ID:?Set the independently approved instance ID}"
  [[ "$INSTANCE_ID" == "$APPROVED_INSTANCE_ID" ]]
  instance_vpc="$(aws ec2 describe-instances --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].VpcId' --output text)"
  [[ "$instance_vpc" == "$VPC_ID" ]]
  command_id="$(aws ssm send-command --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters '{"commands":["set -eu","cloud-init status --long","tail -n 250 /var/log/instance-bootstrap.log","tail -n 250 /var/log/cloud-init-output.log"]}' \
    --query 'Command.CommandId' --output text)"
  [[ -n "$command_id" && "$command_id" != "None" ]]
  printf 'Review command ID: %s\n' "$command_id"
  if ! aws ssm wait command-executed --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --command-id "$command_id" --instance-id "$INSTANCE_ID"; then
    printf '%s\n' 'Waiter did not confirm success; inspect the command result.' >&2
  fi
  result="$(aws ssm get-command-invocation --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --command-id "$command_id" --instance-id "$INSTANCE_ID" \
    --output json)"
  jq '{CommandId,InstanceId,Status,ResponseCode,StandardOutputContent,StandardErrorContent}' <<< "$result"
  jq -e '.Status == "Success" and .ResponseCode == 0' <<< "$result" >/dev/null
)
```

`cloud-init` can report incomplete/error status and stop the remote shell before
the log-tail commands; inspect those logs separately in that case. A waiter
failure can also mean its polling period ended before the command finished.
Reinspect the same ID rather than blindly resubmitting. Returned output can be
truncated and is not automatically archived by this example.

Require bootstrap completion without unresolved APT errors, the recorded
package/reboot state, and the intended instance identity. A successful command
transport alone does not certify the log content or prove a required reboot
occurred. The source uses `Acquire::ForceIPv4=true` and
`APT::Update::Error-Mode=any`.

### Confirm Package Repository Access

From an approved SSM session, inspect the node's actual source files first:

```bash
sudo cat /etc/apt/sources.list.d/ubuntu.sources
sudo test ! -f /etc/apt/sources.list || sudo cat /etc/apt/sources.list
```

Select the actual HTTPS mirror and suite from that output; do not assume a
particular Region's Ubuntu mirror. A read-only HTTP request can test that one
path without installing updates:

```bash
REPOSITORY_PROBE_URL="https://security.ubuntu.com/ubuntu/dists/noble-security/InRelease"
# Replace the example URL with the actual source being tested.
curl -4 -fsSI --connect-timeout 10 --max-time 30 "$REPOSITORY_PROBE_URL"
```

A successful HEAD response is not an APT update, signature-validation, complete
mirror-reachability, or installation test. Review all active sources and the
bootstrap/patch results separately. Do not repair failed package access by
loosening quarantine or production egress as part of this inspection.

### Confirm Isolation Tags

```bash
aws ec2 describe-instances \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].Tags[?Key==`IsolationAllowed` || starts_with(Key, `Isolat`) || Key==`OriginalSecurityGroups`].[Key,Value]' \
  --output table
```

---

## Troubleshooting

### Bootstrap Reports No Package Upgrades

Check:

1. `/var/log/instance-bootstrap.log`
2. `/var/log/cloud-init-output.log`
3. DNS resolution
4. TCP/443 egress from the compute security group
5. The compute subnet's effective default route
6. NAT Gateway or Network Firewall availability
7. Ubuntu repository reachability
8. The `compute_sg_rule_ids` readiness object

A managed SSM connection does not prove that public Ubuntu repository access
works. SSM may use interface VPC endpoints while APT requires a separate
internet or package-mirror path.

### EC2 Launches Before Managed Dependencies Are Ready

Confirm that:

- the standalone `security_policy` module outputs all required rule IDs;
- the baseline passes `module.security_policy.compute_sg_rule_ids` directly into `compute`;
- `terraform_data.compute_security_policy_ready` uses that object;
- the VPC Endpoints module exports `interface_endpoint_ids`;
- the baseline passes `module.vpc_endpoints.interface_endpoint_ids` into `compute`;
- `terraform_data.compute_vpc_endpoints_ready` uses that map;
- `aws_instance.ec2` depends on both readiness resources; and
- the optional internet rule attribute is named `compute_egress_to_internet_https`.

If GuardDuty Runtime Monitoring is expected, also confirm the endpoint map contains `guardduty-data` before EC2 creation.

A misspelled optional object attribute can become `null` and fail to preserve
the intended dependency on the internet HTTPS rule.

### Instance Is Not Reachable Through SSM

Check:

- IAM instance-profile permissions
- SSM Agent status
- VPC endpoint reachability
- Compute-to-endpoint TCP/443 rule
- Endpoint security group ingress from compute
- DNS support and hostnames in the VPC

### Terraform Tries to Undo Isolation

The EC2 lifecycle configuration should ignore security group attachment changes
and isolation metadata tags.

Confirm the deployed resource includes:

```hcl
lifecycle {
  ignore_changes = [
    vpc_security_group_ids,
    tags["Isolated"],
    tags["IsolatedBy"],
    tags["IsolationFinding"],
    tags["IsolationTime"],
    tags["OriginalSecurityGroups"],
  ]
}
```

Do not add `tags["IsolationAllowed"]` to this list.

### User Data Change Does Not Replace Instances

Confirm:

```hcl
user_data_replace_on_change = true
```

Then inspect the plan for instance replacement after modifying
`user_data/bootstrap.sh`.

---

## Security Considerations

- EC2 instances are deployed into private subnets.
- Public IP assignment is not explicitly enabled.
- IMDSv2 is required.
- Root volumes use customer-managed KMS encryption.
- The child-module default is fail-closed; supplied workload roots override it unless configured otherwise.
- Normal security group rules remain centrally owned by the networking
  security-policy layer.
- EC2 instances wait for required security group rules and Terraform-managed Interface Endpoints before launch.
- The `guardduty-data` endpoint can therefore exist before GuardDuty Runtime Monitoring evaluates eligible EC2 instances.
- User-data changes replace instances.
- First-boot bootstrap upgrades the installed operating system packages.
- In-place Terraform updates preserve ignored containment attachments; replacement and destroy are separate risks.
- SSM Session Manager should be preferred over inbound SSH administration.

---

## Design Principles

- Private-by-default compute
- Explicit resource-level dependency ordering
- Terraform-owned service dependencies before compute launch
- Centralized security-policy ownership
- Fail-closed isolation authorization
- Encrypted storage
- IMDSv2 enforcement
- SSM-first administration
- First-boot patching
- Ongoing Patch Manager integration
- Backup integration
- Incident-response isolation support
- Terraform protection for automation-managed containment state

---

## Notes

- The module currently creates one EC2 instance per compute subnet map entry.
- AMI selection criteria, instance type, and root-volume sizing are defined in
  `main.tf`; the selected AMI ID is dynamic.
- The bootstrap script is located at
  `modules/compute/user_data/bootstrap.sh`.
- The bootstrap log is written to
  `/var/log/instance-bootstrap.log`.
- The networking security-policy output and compute input must use matching `compute_sg_rule_ids` object attributes.
- `interface_endpoint_ids` should come directly from the VPC Endpoints module so endpoint creation remains part of the EC2 dependency graph.

Implementation references: [resources](main.tf), [inputs](variables.tf),
[outputs](outputs.tf), [bootstrap script](user_data/bootstrap.sh), and
[baseline composition](../../baseline/main.tf).
