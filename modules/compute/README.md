# Compute Module

## Overview

The `compute` module provisions the workload EC2 compute layer.

It creates:

- A compute security group
- A quarantine security group for incident-response isolation
- One Ubuntu EC2 instance per configured private compute subnet
- A dependency-readiness checkpoint that prevents EC2 instances from launching
  before required security group rules exist
- Encrypted `gp3` root volumes
- IMDSv2-only metadata access
- First-boot operating system patching and package installation
- Tags used by patching, backup, and isolation automation

The module creates the compute security groups and EC2 instances. Security group
rules for normal workload traffic remain owned by the networking
`security_policy` layer.

---

## Architecture

The module participates in a resource-level dependency chain:

```text
aws_security_group.compute
        |
        v
networking.security_policy
        |
        v
networking.compute_sg_rule_ids
        |
        v
terraform_data.compute_security_policy_ready
        |
        v
aws_instance.ec2
```

This ordering allows the compute security group to be created early so the
networking security-policy layer can attach rules to it, while delaying only
the EC2 instances until those rules exist.

This prevents first-boot user data from running before required HTTPS, VPC
endpoint, and database security group rules have been created.

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
| Egress | TCP | 443 | `0.0.0.0/0` | Restricted HTTPS access for SSM and forensic workflows |

The quarantine security group intentionally defines no inbound rules.

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
and distribution upgrade.

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

The EC2 instances explicitly depend on this resource:

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

Current instance configuration:

| Setting | Value |
|---|---|
| AMI | Latest matching Canonical Ubuntu 24.04 LTS AMI |
| Instance type | `t3.micro` |
| Placement | One instance per compute private subnet map entry |
| Security group | `aws_security_group.compute` |
| Detailed monitoring | Enabled |
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
4. Sets a five-minute dpkg lock timeout
5. Configures APT retries
6. Rewrites Ubuntu repository URLs from HTTP to HTTPS
7. Runs `apt-get update`
8. Runs `apt-get dist-upgrade -y`
9. Installs:
   - `ca-certificates`
   - `curl`
   - `jq`
10. Records selected package versions
11. Reports whether a reboot is required
12. Logs the completion timestamp

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
- An approved internal package mirror

VPC endpoint access alone does not provide access to public Ubuntu repositories.

The readiness dependency prevents EC2 creation before the managed security group
rules exist. It does not replace route, NAT Gateway, firewall, DNS, or repository
availability checks.

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
| `Backup` | `true` | AWS Backup tag-based selection |

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

Restoring an isolated instance should be handled through the approved rollback
workflow or another documented incident-response process.

---

## Patch Management Integration

The module applies:

```text
PatchGroup = var.patch_tag_value
```

The separate `patch_management` module uses this tag to target instances with
SSM Patch Manager.

The compute bootstrap performs first-boot package updates. Patch Manager provides
ongoing scheduled patching after launch.

---

## Backup Integration

The module applies:

```text
Backup = true
```

The backup module can use this tag for resource selection.

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
| `isolation_allowed` | `bool` | `false` | Whether instances may be automatically isolated |
| `compute_sg_rule_ids` | `object` | n/a | Security group rule IDs that must exist before EC2 launch |

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

```hcl
module "compute" {
  source = "../../modules/compute"

  name_prefix = local.name_prefix
  vpc_id      = module.networking.vpc_id
  environment = var.environment

  compute_private_subnet_ids_map = module.networking.compute_private_subnet_ids_map
  instance_profile_name          = module.iam.compute_instance_profile_name
  ebs_cmk_arn                    = module.kms.ebs_cmk_arn

  patch_tag_value  = var.patch_tag_value
  isolation_allowed = var.isolation_allowed

  compute_sg_rule_ids = module.networking.compute_sg_rule_ids

  # Retained compatibility inputs.
  interface_endpoints_sg_id = module.networking.interface_endpoints_sg_id
  data_sg_id                = module.storage.data_sg_id
  db_port                   = var.db_port
}
```

The exact upstream output names may differ in the calling root. The important
dependency input is:

```hcl
compute_sg_rule_ids = module.networking.compute_sg_rule_ids
```

Do not add a module-level dependency from the entire compute module to the
networking module when the networking security-policy layer already consumes
`module.compute.compute_sg_id`. The readiness object provides the required
resource-level ordering without creating a module cycle.

---

## Validation

### Terraform Validation

```bash
terraform fmt -recursive
terraform validate
terraform plan
```

### Confirm Security Groups

```bash
aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --filters \
    "Name=group-name,Values=${NAME_PREFIX}-Compute-SG,${NAME_PREFIX}-Quarantine-SG" \
  --query 'SecurityGroups[].[GroupName,GroupId,VpcId,Description]' \
  --output table
```

### Confirm EC2 Placement

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:Environment,Values=${ENVIRONMENT}" \
    "Name=tag:Terraform,Values=true" \
  --query 'Reservations[].Instances[].[InstanceId,Placement.AvailabilityZone,SubnetId,PrivateIpAddress,PublicIpAddress,State.Name]' \
  --output table
```

Expected:

- Instances are in compute private subnets
- Instances have private IP addresses
- Public IP addresses are absent
- Instances are running

### Confirm IMDSv2

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --filters \
    "Name=tag:Environment,Values=${ENVIRONMENT}" \
    "Name=tag:Terraform,Values=true" \
  --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
  --output table
```

Expected:

```text
HttpTokens = required
HttpPutResponseHopLimit = 2
```

### Confirm SSM Registration

```bash
aws ssm describe-instance-information \
  --region "${AWS_REGION}" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]' \
  --output table
```

Expected:

- `PingStatus` is `Online`
- Platform is Ubuntu

### Confirm Bootstrap Results

```bash
aws ssm send-command \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=[
    "cloud-init status --long",
    "tail -n 250 /var/log/instance-bootstrap.log",
    "tail -n 250 /var/log/cloud-init-output.log"
  ]'
```

The bootstrap log should show:

- Successful Ubuntu repository access
- APT metadata refresh
- Distribution upgrade execution
- Required package installation
- Relevant package versions
- Bootstrap completion timestamp

### Confirm Package Repository Access

```bash
aws ssm send-command \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=[
    "curl -4 -fsSI --connect-timeout 10 --max-time 30 https://security.ubuntu.com/ubuntu/dists/noble-security/InRelease",
    "curl -4 -fsSI --connect-timeout 10 --max-time 30 https://us-east-1.ec2.archive.ubuntu.com/ubuntu/dists/noble/InRelease"
  ]'
```

### Confirm Isolation Tags

```bash
aws ec2 describe-instances \
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

### EC2 Launches Before HTTPS Egress Is Ready

Confirm that:

- `networking.security_policy` outputs all required rule IDs
- `networking` passes through `compute_sg_rule_ids`
- The compute module receives `module.networking.compute_sg_rule_ids`
- `terraform_data.compute_security_policy_ready` uses that object
- `aws_instance.ec2` depends on the readiness resource
- The optional internet rule attribute is named
  `compute_egress_to_internet_https`

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
- The default isolation authorization is fail-closed.
- Normal security group rules remain centrally owned by the networking
  security-policy layer.
- EC2 instances wait for required security group rules before launch.
- User-data changes replace instances.
- First-boot bootstrap upgrades the installed operating system packages.
- Routine Terraform applies do not automatically release isolated instances.
- SSM Session Manager should be preferred over inbound SSH administration.

---

## Design Principles

- Private-by-default compute
- Explicit resource-level dependency ordering
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
- AMI ID, instance type, and root-volume sizing are currently fixed in
  `main.tf`.
- The bootstrap script is located at
  `modules/compute/user_data/bootstrap.sh`.
- The bootstrap log is written to
  `/var/log/instance-bootstrap.log`.
- The networking security-policy output and compute input must use matching
  `compute_sg_rule_ids` object attributes.