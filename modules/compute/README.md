# Compute Module

## Overview

The `compute` module provisions private EC2 compute resources and related security groups for the workload environment.

This includes:

- A compute security group for EC2 instances
- A quarantine security group for incident response isolation
- Ubuntu-based EC2 instances deployed into private compute subnets
- Encrypted EBS root volumes using the EBS CMK
- IMDSv2 enforcement
- Detailed monitoring
- IAM instance profile attachment
- User data bootstrapping through `user_data/bootstrap.sh.tpl`
- Tags for backup, patching, and automated isolation workflows

This module represents the baseline workload compute layer.

---

## Purpose

The purpose of this module is to deploy private EC2 instances that can be managed, patched, backed up, monitored, and isolated if needed.

It supports:

- Private-by-default compute placement
- SSM-based instance management
- Encrypted root volumes
- Patch Manager targeting through tags
- Backup targeting through tags
- Security automation targeting through tags
- Quarantine-based incident response
- Initial operating system bootstrap on first boot

The compute instances are intentionally deployed without public exposure and are designed to operate inside the secured VPC architecture.

---

## Resources Created

### Compute Security Group

Creates the primary security group for EC2 compute instances:

```hcl
resource "aws_security_group" "compute"
```

Security group name format:

```text
<name_prefix>-Compute-SG
```

This security group is attached to all EC2 instances created by this module.

The module creates the security group itself, but traffic rules are expected to be managed by the broader networking/security policy layer.

This keeps the compute module focused on creating compute resources while centralizing network access rules elsewhere.

---

### Quarantine Security Group

Creates a quarantine security group used for EC2 incident response isolation:

```hcl
resource "aws_security_group" "quarantine"
```

Security group name format:

```text
<name_prefix>-Quarantine-SG
```

Purpose:

```text
IncidentResponse
```

The quarantine security group is intended to be used by the EC2 Isolation Lambda when an instance receives a high or critical security finding.

When an instance is isolated, the automation can replace the instance’s existing security groups with this quarantine security group.

Current quarantine egress allows only:

| Direction | Protocol | Port | Destination | Purpose |
|---|---|---:|---|---|
| Egress | TCP | 443 | `0.0.0.0/0` | Allow HTTPS egress for SSM and forensics |

This allows limited outbound HTTPS access while removing normal workload network paths.

---

### Ubuntu EC2 AMI Lookup

Looks up the latest Ubuntu 24.04 LTS AMI:

```hcl
data "aws_ami" "ec2"
```

AMI owner:

```text
099720109477
```

AMI filter:

```text
ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server*
```

The module uses the most recent matching Ubuntu Noble 24.04 AMI.

---

### EC2 Instances

Creates one EC2 instance per private compute subnet entry:

```hcl
resource "aws_instance" "ec2"
```

The module uses:

```hcl
for_each = var.compute_private_subnet_ids_map
```

This means that by default, the number of EC2 instances is driven by the number of entries in the compute private subnet map.

Each instance is deployed into a private compute subnet.

Current instance configuration:

| Setting | Value |
|---|---|
| AMI | Latest Ubuntu 24.04 Noble AMI |
| Instance type | `t3.micro` |
| Subnet | Each compute private subnet from `compute_private_subnet_ids_map` |
| Security group | Compute security group |
| Detailed monitoring | Enabled |
| IAM instance profile | `var.instance_profile_name` |
| User data | `user_data/bootstrap.sh.tpl` |
| Public IP | Not explicitly associated |
| IMDSv2 | Required |
| Root volume size | 20 GB |
| Root volume type | `gp3` |
| Root volume encryption | Enabled |
| Root volume KMS key | `var.ebs_cmk_arn` |

---

### EC2 Metadata Options

The EC2 instances enforce IMDSv2:

```hcl
metadata_options {
  http_tokens                 = "required"
  http_put_response_hop_limit = 2
}
```

This requires session tokens for instance metadata access.

IMDSv2 helps reduce risk from metadata credential theft techniques that rely on unauthenticated metadata access.

---

### Encrypted Root Volume

Each EC2 instance receives an encrypted root EBS volume:

```hcl
root_block_device {
  volume_size = 20
  volume_type = "gp3"
  encrypted   = true
  kms_key_id  = var.ebs_cmk_arn
}
```

This ensures the instance root volume is encrypted using the baseline EBS CMK.

---

## User Data Bootstrap

The module includes a user data directory:

```text
modules/compute/user_data
```

The EC2 instances use:

```text
modules/compute/user_data/bootstrap.sh.tpl
```

This script runs during initial instance boot.

---

### Bootstrap Script Purpose

The bootstrap script performs initial operating system preparation.

Current behavior:

- Enables strict shell execution with `set -euo pipefail`
- Writes bootstrap logs to `/var/log/instance-bootstrap.log`
- Rewrites Ubuntu package source URLs from `http://` to `https://`
- Runs `apt-get update`
- Installs baseline packages:
  - `ca-certificates`
  - `curl`
  - `jq`

This helps ensure package operations use HTTPS and that basic operational tooling is present on the instance.

---

### Bootstrap Log File

Bootstrap output is written to:

```text
/var/log/instance-bootstrap.log
```

Use this log file to troubleshoot first-boot initialization.

Example command from the instance:

```bash
sudo cat /var/log/instance-bootstrap.log
```

Expected:

- Bootstrap start timestamp
- Ubuntu package source rewrite message, if the source file exists
- Package update/install output
- Bootstrap completion timestamp

---

### Ubuntu Package Source Rewrite

The script checks for:

```text
/etc/apt/sources.list.d/ubuntu.sources
```

If the file exists, it creates a backup:

```text
/etc/apt/sources.list.d/ubuntu.sources.bak
```

Then it replaces:

```text
http://
```

with:

```text
https://
```

This ensures Ubuntu package sources use HTTPS.

---

## Instance Tags

Each EC2 instance is tagged with:

| Tag | Value | Purpose |
|---|---|---|
| `Name` | `<name_prefix>-EC2-<subnet-key>` | Human-readable instance name |
| `Environment` | `var.environment` | Environment ownership |
| `Terraform` | `true` | IaC ownership marker |
| `Purpose` | Workload description | Describes the compute role |
| `IsolationAllowed` | `true` | Marks instance as eligible for isolation automation |
| `PatchGroup` | `var.patch_tag_value` | Used by SSM Patch Manager targeting |
| `Backup` | `true` | Used by AWS Backup tag-based selection |

These tags are important for automation and operations.

---

## Automation Integration

### EC2 Isolation

Instances are tagged with:

```text
IsolationAllowed = true
```

The quarantine security group output is used by the EC2 Isolation Lambda.

Expected isolation behavior:

```text
Security Hub Finding
    |
    v
EventBridge Rule
    |
    v
EC2 Isolation Lambda
    |
    v
Snapshot EBS volume(s)
    |
    v
Replace instance security groups with Quarantine SG
    |
    v
Update instance tags

```

This allows high or critical EC2 findings to trigger automated containment.

---

### Patch Management

Instances are tagged with:

```text
PatchGroup = var.patch_tag_value
```

This allows the patch management module to target instances by patch group.

The actual patch baseline and maintenance window behavior is managed outside this module, at `modules/patch_management/`.

---

### Backup

Instances are tagged with:

```text
Backup = true
```

This allows the backup module to include compute resources in tag-based backup selections if configured.

---

## Network Placement

The module deploys EC2 instances into private compute subnets:

```hcl
for_each  = var.compute_private_subnet_ids_map
subnet_id = each.value
```

Expected placement:

```text
Private Compute Subnets
    |
    v
Controlled egress path through firewall/NAT and/or VPC endpoints
```

The instances should not require public IP addresses for normal management.

Management should generally occur through AWS Systems Manager Session Manager.

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `name_prefix` | Prefix used for resource naming | Yes |
| `vpc_id` | VPC ID where compute security groups are created | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `compute_private_subnet_ids_map` | Map of compute private subnet IDs keyed by subnet/AZ name | Yes |
| `instance_profile_name` | IAM instance profile name attached to EC2 instances | Yes |
| `ebs_cmk_arn` | KMS CMK ARN used to encrypt EC2 root EBS volumes | Yes |
| `interface_endpoints_sg_id` | Interface endpoint security group ID; currently available for security policy integration | Yes |
| `data_sg_id` | Data/RDS security group ID; currently available for security policy integration | Yes |
| `db_port` | Database port; currently available for security policy integration | Yes |
| `patch_tag_value` | Patch group tag value applied to EC2 instances | Yes |

---

## Outputs

| Name | Description |
|---|---|
| `compute_sg_id` | ID of the compute EC2 security group |
| `quarantine_sg_id` | ID of the quarantine security group used for EC2 isolation |

---

## Usage Example

```hcl
module "compute" {
  source = "../modules/compute"

  name_prefix                    = local.name_prefix
  vpc_id                         = module.networking.vpc_id
  environment                    = var.environment

  compute_private_subnet_ids_map = module.networking.compute_private_subnet_ids_map
  instance_profile_name          = module.iam.instance_profile_name
  ebs_cmk_arn                    = module.security.ebs_cmk_arn

  interface_endpoints_sg_id      = module.vpc_endpoints.interface_endpoints_sg_id
  data_sg_id                     = module.storage.data_sg_id
  db_port                        = var.db_port
  patch_tag_value                = var.patch_tag_value
}
```

---

## Dependency Notes

This module depends on resources created by other modules.

### Required Before Compute

The following should exist before this module is applied:

- VPC
- Private compute subnets
- EC2 instance profile
- EBS KMS CMK

### Common Downstream Consumers

Outputs from this module are commonly consumed by:

| Output | Consumer |
|---|---|
| `compute_sg_id` | Networking/security policy rules |
| `compute_sg_id` | VPC endpoint access rules |
| `compute_sg_id` | Database access rules |
| `quarantine_sg_id` | EC2 Isolation Lambda |
| `quarantine_sg_id` | EC2 Rollback Lambda |

---

## Validation

### Confirm Compute Security Groups

```bash
aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=group-name,Values=${NAME_PREFIX}-Compute-SG,${NAME_PREFIX}-Quarantine-SG" \
  --query 'SecurityGroups[].[GroupName,GroupId,VpcId,Description]' \
  --output table
```

Expected:

- Compute security group exists
- Quarantine security group exists
- Both security groups are attached to the workload VPC

---

### Confirm EC2 Instances

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Terraform,Values=true" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,SubnetId,PrivateIpAddress,PublicIpAddress]' \
  --output table
```

Expected:

- EC2 instances exist
- Instances are in private compute subnets
- Instances have private IP addresses
- Public IP address should be empty or `None`
- Instance type is `t3.micro` (or whatever is configured)

---

### Confirm Instance Tags

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Terraform,Values=true" \
  --query 'Reservations[].Instances[].[InstanceId,Tags]' \
  --output json
```

Expected tags include:

- `Name`
- `Environment`
- `Terraform`
- `Purpose`
- `IsolationAllowed`
- `PatchGroup`
- `Backup`

---

### Confirm IMDSv2 Enforcement

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Terraform,Values=true" \
  --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
  --output table
```

Expected:

- `HttpTokens` is `required`
- `HttpPutResponseHopLimit` is `2`

---

### Confirm EBS Root Volume Encryption

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Terraform,Values=true" \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' \
  --output text
```

Then describe the returned volume IDs:

```bash
VOLUME_IDS=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Terraform,Values=true" \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' \
  --output text)

aws ec2 describe-volumes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --volume-ids ${VOLUME_IDS} \
  --query 'Volumes[].[VolumeId,Encrypted,KmsKeyId,Size,VolumeType]' \
  --output table
```

Expected:

- Encrypted is `true`
- KMS key is the EBS CMK
- Volume size is 20 GB
- Volume type is `gp3`

---

### Confirm IAM Instance Profile

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Terraform,Values=true" \
  --query 'Reservations[].Instances[].[InstanceId,IamInstanceProfile.Arn]' \
  --output table
```

Expected:

- Each instance has an IAM instance profile attached
- Instance profile matches the expected EC2 instance profile

---

### Confirm SSM Managed Instance Registration

```bash
aws ssm describe-instance-information \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,PlatformVersion,AgentVersion]' \
  --output table
```

Expected:

- EC2 instances appear as managed instances
- Ping status is `Online`
- Platform is Ubuntu

If instances do not appear, check IAM instance profile permissions, SSM Agent status, and VPC endpoint connectivity.

---

### Confirm Bootstrap Log

Start an SSM Session Manager session on the instance:

```bash
aws ssm start-session \
  --target "${INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

From that SSM Session Manager session:

```bash
sudo cat /var/log/instance-bootstrap.log
```

Expected:

- Bootstrap started successfully
- Ubuntu package sources were updated to HTTPS, if the source file existed
- Package update completed
- `ca-certificates`, `curl`, and `jq` were installed
- Bootstrap completed successfully

---

## Operational Considerations

### Instances Are Private

Instances are deployed into private compute subnets.

They should not be managed through public SSH by default.

Preferred access method:

```text
AWS Systems Manager Session Manager
```

This reduces exposure and avoids requiring inbound SSH access.

---

### SSM Requires Supporting Infrastructure

For Session Manager to work, the environment needs:

- EC2 IAM instance profile with SSM permissions
- SSM Agent installed and running
- Network path to SSM services
- Required VPC endpoints or controlled NAT egress

Relevant VPC endpoints commonly include:

```text
ssm
ssmmessages
ec2messages
logs
kms
```

---

### User Data Runs at First Boot

The bootstrap script runs when the instance first launches.

If the script fails, check:

```text
/var/log/instance-bootstrap.log
```

The script uses:

```bash
set -euo pipefail
```

This means unexpected command failures can stop the script early.

Also ensure that the EC2 instance has a valid outbound path for package installation and AWS service access, either through controlled NAT egress, approved firewall rules, or required VPC endpoints.

---

### Patch Group Tagging

Patch targeting depends on the `PatchGroup` tag.

If instances are not included in patch operations, confirm the tag value matches the patch management module configuration.

---

### Backup Tagging

Backup targeting depends on the `Backup = true` tag if the backup module uses tag-based backup selections.

If instances or volumes are not included in backups, confirm tag-based selection criteria match.

---

### Quarantine Behavior

The quarantine security group allows only HTTPS egress.

This is intentional.

During an incident, isolated instances should have restricted network access while still allowing limited management or forensic workflows.

Do not add broad inbound access to the quarantine security group unless there is a documented incident response requirement.

---

## Troubleshooting

### EC2 Instances Do Not Launch

Check:

- Private compute subnet IDs are valid
- The selected Ubuntu AMI exists in the region
- Instance profile exists
- EBS CMK exists and is enabled
- Caller has permission to use the EBS CMK
- Account has EC2 capacity for `t3.micro`
- Security group creation succeeded

Useful command:

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Environment,Values=${ENVIRONMENT}" \
  --output table
```

---

### Instance Is Not Reachable Through SSM

Check:

- Instance has the correct IAM instance profile
- Instance role includes SSM permissions
- SSM Agent is installed and running
- Required VPC endpoints exist and are reachable
- Compute security group can reach Interface Endpoints on TCP/443
- Endpoint security group allows traffic from compute security group
- Instance has a route to required AWS services

Useful command:

```bash
aws ssm describe-instance-information \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,LastPingDateTime]' \
  --output table
```

---

### Bootstrap Script Fails

Open an SSM session and check:

```bash
sudo cat /var/log/instance-bootstrap.log
```

Common causes:

- Package repository access is blocked
- DNS resolution is not working
- NAT Gateway or required VPC endpoint access is unavailable
- Ubuntu source file path changed
- `apt-get update` failed
- KMS or network policy prevents normal instance initialization

---

### Package Install Fails

Check whether the instance can reach Ubuntu package repositories.

From the instance:

```bash
curl -I https://archive.ubuntu.com
```

If the environment uses controlled egress, confirm:

- Network Firewall allows required package repository access
- NAT Gateway route exists where required
- DNS works
- TLS/HTTPS egress is permitted

---

### EBS Volume Is Not Encrypted With Expected Key

First, get the EBS volume IDs attached to the Terraform-managed EC2 instances:

```bash
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Environment,Values=${ENVIRONMENT}" "Name=tag:Terraform,Values=true" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

VOLUME_IDS=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --instance-ids ${INSTANCE_IDS} \
  --query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' \
  --output text)

aws ec2 describe-volumes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --volume-ids ${VOLUME_IDS} \
  --query 'Volumes[].[VolumeId,Encrypted,KmsKeyId,Size,VolumeType,State]' \
  --output table
```

Expected:

- Encrypted is `true`
- KMS key is the expected EBS CMK
- Volume type is `gp3`
- Volume size is 20 GB

---

### Isolation Automation Does Not Work

Check:

- Instance has `IsolationAllowed = true`
- Quarantine security group exists
- EC2 Isolation Lambda has permission to modify instance security groups
- Security Hub finding matches the automation rule
- Instance is in a supported state
- Rollback process has stored enough original security group context to restore access later

Useful command:

```bash
aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --group-ids "${QUARANTINE_SG_ID}"
```

---

## Security Notes

- EC2 instances are deployed into private compute subnets.
- Public IP assignment is not explicitly enabled.
- IMDSv2 is required.
- Root EBS volumes are encrypted using the EBS CMK.
- Instances use an IAM instance profile instead of static credentials.
- Instances are tagged for patching, backup, and isolation workflows.
- The quarantine security group restricts isolated instances to HTTPS egress only.
- User data rewrites Ubuntu package sources to HTTPS.
- User data installs only minimal operational packages.
- Instance management should use SSM Session Manager instead of public SSH.

---

## Design Principles

This module follows:

- Private-by-default compute
- Encrypted instance storage
- SSM-first administration
- Minimal baseline bootstrap
- Automated patching support
- Automated backup support
- Incident response readiness
- IMDSv2 enforcement
- Clear separation between resource creation and network policy rules

---

## Notes

- Deploy this module after networking, IAM, KMS, and VPC endpoint resources are available.
- The compute security group ID is used by the networking/security policy layer.
- The quarantine security group ID is used by security automation.
- The bootstrap script is located at `modules/compute/user_data/bootstrap.sh.tpl`.
- The bootstrap script logs to `/var/log/instance-bootstrap.log`.
- The module currently creates one EC2 instance per compute private subnet map entry.
- Future versions may make AMI, instance type, root volume size, and user data behavior configurable.