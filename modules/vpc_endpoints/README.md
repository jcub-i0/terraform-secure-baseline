# VPC Endpoints Module

## Overview

The `vpc_endpoints` module provisions private AWS service access for the workload VPC.

This module creates:

- An S3 Gateway VPC Endpoint
- Interface VPC Endpoints for core AWS services
- A dedicated security group for Interface VPC Endpoints
- Private DNS support for Interface VPC Endpoints
- An output exposing the Interface Endpoint security group ID

The module is designed to support private-first AWS workloads by allowing compute resources, Lambda functions, and security automation to reach AWS APIs without relying entirely on public internet paths.

---

## Purpose

The purpose of this module is to provide private access to AWS control-plane and data-plane services from inside the VPC.

This supports:

- Private EC2 management through Systems Manager
- Private access to CloudWatch Logs
- Private access to KMS
- Private access to Secrets Manager
- Private access to Security Hub
- Private access to EventBridge
- Private access to Lambda APIs
- Private S3 access through a Gateway Endpoint
- Reduced dependency on NAT Gateway paths for AWS service traffic

This module helps enforce the baseline’s private-by-default networking model.

---

## Resources Created

### S3 Gateway Endpoint

Creates an S3 Gateway VPC Endpoint:

```hcl
resource "aws_vpc_endpoint" "s3"
```

The S3 Gateway Endpoint is associated with the compute private route tables.

This allows resources in the private compute subnets to reach S3 using private AWS network paths instead of routing S3 traffic through the internet gateway or NAT gateway.

---

### Interface VPC Endpoints

Creates Interface VPC Endpoints for the following AWS services:

| Service | Purpose |
|---|---|
| `sts` | AWS STS API access for identity and role assumption |
| `logs` | CloudWatch Logs access |
| `ssm` | Systems Manager API access |
| `ssmmessages` | SSM Session Manager message channel |
| `secretsmanager` | Secrets Manager API access |
| `kms` | KMS API access |
| `config` | AWS Config API access |
| `sns` | SNS API access |
| `ec2` | EC2 API access |
| `events` | EventBridge API access |
| `securityhub` | Security Hub API access |
| `lambda` | Lambda API access |

Each endpoint is created using:

```hcl
resource "aws_vpc_endpoint" "interface"
```

The module uses `for_each` over the endpoint service list, so each service receives its own Interface Endpoint.

Private DNS is enabled for all Interface Endpoints.

---

### Interface Endpoint Security Group

Creates a dedicated security group for Interface VPC Endpoints:

```hcl
resource "aws_security_group" "interface_endpoints_sg"
```

This security group is attached to all Interface Endpoint ENIs created by this module.

Important:

The security group itself is created in this module, but the security group rules are managed separately in:

```text
modules/networking/security_policy.tf
```

This separation keeps endpoint creation in the `vpc_endpoints` module while keeping network security rules centralized in the networking policy layer.

---

## Security Group Rules

The Interface Endpoint security group rules are defined in:

```text
modules/networking/security_policy.tf
```

Those rules allow HTTPS traffic to the Interface Endpoints from approved workload security groups.

Current endpoint-related rules include:

| Rule | Direction | Purpose |
|---|---:|---|
| `endpoints_ingress_from_compute` | Ingress | Allows compute instances to reach Interface Endpoints over TCP/443 |
| `endpoints_ingress_from_lambda_isolation` | Ingress | Allows the EC2 Isolation Lambda security group to reach Interface Endpoints over TCP/443 |
| `endpoints_ingress_from_lambda_rollback` | Ingress | Allows the EC2 Rollback Lambda security group to reach Interface Endpoints over TCP/443 |
| `endpoints_egress_any` | Egress | Allows endpoint ENIs to communicate with AWS services over TCP/443 |
| `compute_egress_to_endpoints` | Egress | Allows compute instances to initiate HTTPS connections to Interface Endpoints |
| `lambda_isolation_egress_to_endpoints` | Egress | Allows the EC2 Isolation Lambda to initiate HTTPS connections to Interface Endpoints |
| `lambda_rollback_egress_to_endpoints` | Egress | Allows the EC2 Rollback Lambda to initiate HTTPS connections to Interface Endpoints |

This design keeps endpoint access restricted to known internal security groups instead of exposing the endpoints broadly across the VPC CIDR.

---

## Network Placement

Interface Endpoints are deployed into the compute private subnets:

```hcl
local.interface_endpoint_subnets = var.compute_private_subnet_ids_map
```

The S3 Gateway Endpoint is associated with the compute private route tables:

```hcl
route_table_ids = values(local.interface_endpoint_route_table_ids)
```

This means the endpoint module is primarily focused on supporting private compute workloads and private security automation running inside the workload VPC.

---

## Private DNS

Private DNS is enabled for all Interface Endpoints:

```hcl
private_dns_enabled = true
```

This allows standard AWS service DNS names to resolve to private endpoint IPs from within the VPC.

For example, workloads can continue using normal AWS service endpoints such as:

```text
ssm.<region>.amazonaws.com
logs.<region>.amazonaws.com
kms.<region>.amazonaws.com
```

When queried from inside the VPC, those names resolve through the Interface Endpoint private DNS configuration.

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `name_prefix` | Prefix used for resource naming | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `vpc_id` | ID of the VPC where endpoints are created | Yes |
| `account_id` | AWS account ID | Yes |
| `primary_region` | AWS region used to build endpoint service names | Yes |
| `compute_private_subnet_ids_map` | Map of compute private subnet IDs where Interface Endpoints are deployed | Yes |
| `serverless_private_subnet_ids_map` | Map of serverless private subnet IDs | Yes |
| `subnet_cidrs` | Map of subnet CIDR lists | Yes |
| `compute_sg_id` | Security group ID for compute workloads | Yes |
| `lambda_ec2_isolation_sg_id` | Security group ID for the EC2 Isolation Lambda | Yes |
| `lambda_ec2_rollback_sg_id` | Security group ID for the EC2 Rollback Lambda | Yes |
| `compute_private_route_table_ids_map` | Map of compute private route table IDs used by the S3 Gateway Endpoint | Yes |

---

## Outputs

| Name | Description |
|---|---|
| `interface_endpoints_sg_id` | Security group ID for the Interface VPC Endpoints |

---

## Usage Example

```hcl
module "vpc_endpoints" {
  source = "../../modules/vpc_endpoints"

  name_prefix                     = local.name_prefix
  environment                     = var.environment
  vpc_id                          = module.networking.vpc_id
  account_id                      = var.account_id
  primary_region                  = var.primary_region
  compute_private_subnet_ids_map  = module.networking.compute_private_subnet_ids_map
  serverless_private_subnet_ids_map = module.networking.serverless_private_subnet_ids_map
  subnet_cidrs                    = var.subnet_cidrs
  compute_sg_id                   = module.networking.compute_sg_id
  lambda_ec2_isolation_sg_id      = module.networking.lambda_ec2_isolation_sg_id
  lambda_ec2_rollback_sg_id       = module.networking.lambda_ec2_rollback_sg_id
  compute_private_route_table_ids_map = module.networking.compute_private_route_table_ids_map
}
```

The `interface_endpoints_sg_id` output should be passed back into the networking/security policy layer so security group rules can be attached to the endpoint security group.

Example:

```hcl
interface_endpoints_sg_id = module.vpc_endpoints.interface_endpoints_sg_id
```

---

## Design Notes

### Endpoint Creation and Endpoint Rules Are Split

This module creates the endpoint resources and the shared Interface Endpoint security group.

The actual security group rules are intentionally managed in:

```text
modules/networking/security_policy.tf
```

This keeps traffic policy decisions centralized in the networking module instead of scattering security group rules across multiple modules.

---

### S3 Uses a Gateway Endpoint

S3 is created as a Gateway Endpoint instead of an Interface Endpoint.

This is appropriate because S3 Gateway Endpoints integrate directly with route tables and allow private S3 access without creating endpoint ENIs.

---

### Interface Endpoints Use Private DNS

All Interface Endpoints use private DNS so workloads do not need special endpoint-specific URLs.

This improves compatibility with:

- AWS SDKs
- AWS CLI
- Lambda functions
- EC2 user data scripts
- SSM Agent
- Security automation

---

### Compute Private Subnets Are the Endpoint Subnets

Interface Endpoints are currently deployed into compute private subnets.

This keeps endpoint access close to the primary workload layer.

If the architecture later introduces dedicated endpoint subnets, this module can be updated to use those subnets instead.

---

## Validation

### List VPC Endpoints

```bash
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'VpcEndpoints[].[VpcEndpointId,VpcEndpointType,ServiceName,State,PrivateDnsEnabled]' \
  --output table
```

Expected:

- S3 Gateway Endpoint exists
- Interface Endpoints exist for the configured AWS services
- Endpoint state is `available`
- Interface Endpoints have private DNS enabled

---

### Confirm Interface Endpoint Security Group

```bash
aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --group-ids "${INTERFACE_ENDPOINTS_SG_ID}" \
  --query 'SecurityGroups[0].[GroupId,GroupName,Description,VpcId]' \
  --output table
```

Expected:

- Security group exists
- Security group name matches the endpoint naming convention
- Security group is attached to the workload VPC

---

### Confirm Endpoint Security Group Rules

```bash
aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --group-ids "${INTERFACE_ENDPOINTS_SG_ID}" \
  --query 'SecurityGroups[0].IpPermissions'
```

Expected:

- HTTPS ingress from the compute security group
- HTTPS ingress from the EC2 Isolation Lambda security group
- HTTPS ingress from the EC2 Rollback Lambda security group

---

### Test Private DNS Resolution from a Private Instance

From an EC2 instance in a private compute subnet:

```bash
dig ssm.${AWS_REGION}.amazonaws.com
dig logs.${AWS_REGION}.amazonaws.com
dig kms.${AWS_REGION}.amazonaws.com
```

Expected:

- DNS resolves successfully
- Results should resolve to private endpoint IPs from inside the VPC

---

### Test SSM Connectivity

```bash
aws ssm describe-instance-information \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected:

- Private EC2 instances managed by SSM appear in the output
- Instances do not require public IP addresses for SSM management

---

## Operational Considerations

### Cost

Interface Endpoints have hourly and data processing costs.

This module creates multiple Interface Endpoints, so costs can add up across:

- dev
- staging
- prod

The current design prioritizes production-style private connectivity and security over minimum cost.

---

### NAT Gateway Still May Be Needed

VPC endpoints reduce dependency on NAT Gateway for supported AWS services.

They do not eliminate NAT requirements for:

- Internet package repositories
- Third-party APIs
- External SaaS services
- Public container registries
- Any AWS service not covered by an endpoint

The broader baseline still uses controlled egress through Network Firewall and NAT Gateway where needed.

---

### Endpoint Access Should Stay Narrow

Do not open Interface Endpoint ingress to the full VPC CIDR unless there is a clear reason.

Preferred pattern:

- Allow only known workload security groups
- Allow only TCP/443
- Keep endpoint access scoped to compute and authorized automation

---

## Troubleshooting

### Endpoint Exists but Workload Cannot Connect

Check:

- The Interface Endpoint is in `available` state
- Private DNS is enabled
- The workload security group has egress to the endpoint security group on TCP/443
- The endpoint security group has ingress from the workload security group on TCP/443
- The workload subnet uses DNS resolution and DNS hostnames correctly at the VPC level

---

### SSM Session Manager Does Not Work

Check that these endpoints exist and are available:

```text
ssm
ssmmessages
ec2messages
```

Also check:

- EC2 instance has an IAM role with SSM permissions
- SSM Agent is installed and running
- Security group rules allow HTTPS to Interface Endpoints
- The instance can resolve AWS service DNS names privately

Note:

If the `ec2messages` endpoint is not present, SSM behavior may vary depending on the operating system, agent version, and AWS service requirements. Add it if Session Manager connectivity is unreliable.

---

### S3 Access Still Uses NAT

Check:

- S3 Gateway Endpoint exists
- Compute private route tables are associated with the S3 Gateway Endpoint
- The workload is running in a subnet using one of those route tables
- S3 bucket policies do not block access from the VPC endpoint

---

### Private DNS Does Not Resolve to Private IPs

Check:

- Interface Endpoint has `private_dns_enabled = true`
- VPC DNS hostnames are enabled
- VPC DNS support is enabled
- The workload is using the VPC resolver
- No custom DNS configuration is overriding AWS service resolution

---

## Security Notes

- Interface Endpoint access is limited using security group rules.
- Endpoint rules are managed in `modules/networking/security_policy.tf`.
- S3 private access is handled through a Gateway Endpoint and route table association.
- Private DNS avoids hardcoding endpoint-specific URLs.
- The module supports private operation of SSM, logging, encryption, secrets retrieval, EventBridge, Security Hub, and Lambda API access.
- Endpoint access should remain scoped to approved workload and automation security groups.

---

## Design Principles

This module follows:

- Private-first networking
- Least privilege network access
- Centralized security group policy
- Reduced public internet dependency
- Compatibility with AWS-native tooling
- Secure-by-default workload operations

---

## Notes

- This module should be deployed after the VPC, subnets, route tables, and workload security groups exist.
- The endpoint security group ID should be passed into the networking security policy layer.
- Security group rules for the endpoint security group are not defined inside this module.
- The S3 Gateway Endpoint attaches to compute private route tables.
- Interface Endpoints currently deploy into compute private subnets.
- Future versions may support dedicated endpoint subnets or configurable endpoint service lists.