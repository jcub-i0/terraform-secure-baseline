# vpc_endpoints Module

## Overview

The `vpc_endpoints` module provisions private AWS service access for workloads running inside the VPC.

This module creates:
- An S3 Gateway VPC Endpoint
- Multiple AWS PrivateLink Interface VPC Endpoints
- A shared security group for interface endpoints
- Private DNS support for supported AWS services

The purpose of this module is to reduce dependency on public internet paths for AWS service access and support a private-first workload architecture.

---

## Purpose

This module supports the baseline’s private networking model by allowing resources in private compute subnets to reach AWS services without requiring direct public internet access.

It is especially important for:
- SSM Session Manager access
- CloudWatch Logs delivery
- KMS operations
- Secrets Manager access
- Security Hub integration
- AWS Config operations
- Lambda service access
- EventBridge and SNS communication
- EC2 API access
- STS calls from private workloads

This helps keep compute resources private while still allowing them to interact with required AWS control plane services.

---

## Resources Created

### S3 Gateway Endpoint

Creates an S3 Gateway VPC Endpoint.

This endpoint is associated with the compute private route tables.

Purpose:
- Allows private subnets to access Amazon S3 without routing through the NAT Gateway
- Reduces NAT Gateway dependency and cost for S3 traffic
- Keeps S3 access on the AWS private network path

Created resource:

```hcl
resource "aws_vpc_endpoint" "s3"
```

---

### Interface Endpoint Security Group

Creates a shared security group for all interface endpoints.

Created resource:

```hcl
resource "aws_security_group" "interface_endpoints_sg"
```

The security group is attached to each interface endpoint created by the module.

Important:

- The module creates the security group itself.
- The current module does not define explicit ingress or egress rules inside this file.
- Ensure required HTTPS access to interface endpoints is allowed elsewhere if endpoint connectivity fails.

Typical expected rule:

```text
Allow TCP/443 from private workload security groups or private subnet CIDR ranges to the interface endpoint security group.
```

---

### Interface VPC Endpoints

Creates Interface VPC Endpoints for core AWS services using AWS PrivateLink.

Created resource:

```hcl
resource "aws_vpc_endpoint" "interface"
```

The module currently creates interface endpoints for:

| Service | Purpose |
|---------|---------|
| `sts` | Allows private workloads to call AWS STS |
| `logs` | Allows private CloudWatch Logs access |
| `ssm` | Supports AWS Systems Manager access |
| `ssmmessages` | Supports SSM Session Manager communication |
| `secretsmanager` | Allows private Secrets Manager access |
| `kms` | Allows private KMS API access |
| `config` | Supports AWS Config operations |
| `sns` | Allows private SNS API access |
| `ec2` | Allows private EC2 API access |
| `events` | Allows private EventBridge access |
| `securityhub` | Allows private Security Hub API access |
| `lambda` | Allows private Lambda API access |

Private DNS is enabled for interface endpoints.

This allows standard AWS service DNS names to resolve to private endpoint IP addresses inside the VPC.

---

## Network Placement

Interface endpoints are deployed into the compute private subnets.

The module uses:

```hcl
var.compute_private_subnet_ids_map
```

for interface endpoint subnet placement.

The S3 Gateway Endpoint is associated with:

```hcl
var.compute_private_route_table_ids_map
```

This means private compute subnets can route S3 traffic through the S3 Gateway Endpoint instead of through NAT.

---

## High-Level Flow

```text
Private Compute Subnets
    |
    +--> S3 Gateway Endpoint
    |
    +--> Interface Endpoints
            |
            +--> STS
            +--> CloudWatch Logs
            +--> SSM
            +--> Secrets Manager
            +--> KMS
            +--> Config
            +--> SNS
            +--> EC2
            +--> EventBridge
            +--> Security Hub
            +--> Lambda
```

---

## Security Design

This module supports the baseline security model by:

- Keeping AWS service traffic private where possible
- Reducing reliance on NAT Gateway for AWS API traffic
- Supporting private SSM Session Manager access
- Supporting private secrets retrieval
- Supporting private KMS operations
- Supporting private logging and monitoring integrations
- Avoiding direct public exposure for private workloads

---

## Important Notes

### Interface Endpoint Security Group Rules

The current module creates the interface endpoint security group but does not define explicit ingress rules in `main.tf`.

If private workloads cannot reach AWS services through the endpoints, confirm that TCP/443 is allowed from the relevant workload security groups or subnet CIDR ranges to the endpoint security group.

Example expected access pattern:

```text
Source: Private compute workloads
Destination: Interface endpoint security group
Protocol: TCP
Port: 443
```

---

### Private DNS

Private DNS is enabled for all interface endpoints.

This allows workloads to use normal AWS service endpoints such as:

```text
ssm.<region>.amazonaws.com
kms.<region>.amazonaws.com
secretsmanager.<region>.amazonaws.com
```

while resolving to private endpoint IP addresses inside the VPC.

---

### NAT Gateway Relationship

VPC endpoints do not eliminate all NAT Gateway requirements.

They reduce NAT dependency for supported AWS services, but private workloads may still need NAT or firewall-routed egress for:
- Public package repositories
- External APIs
- Third-party integrations
- Vendor services
- Internet-based updates

In this baseline, private workload egress is expected to follow the controlled egress path defined by the networking and firewall modules.

---

## Inputs

| Name | Description | Required |
|------|-------------|----------|
| `name_prefix` | Prefix used for naming resources | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `vpc_id` | ID of the VPC where endpoints are deployed | Yes |
| `account_id` | AWS account ID | Yes |
| `primary_region` | AWS region used to build endpoint service names | Yes |
| `compute_private_subnet_ids_map` | Map of compute private subnet IDs used for interface endpoint placement | Yes |
| `serverless_private_subnet_ids_map` | Map of serverless private subnet IDs; currently provided for module compatibility/future use | Yes |
| `subnet_cidrs` | Map of subnet CIDR lists; currently used to derive compute private subnet CIDRs | Yes |
| `compute_sg_id` | Compute security group ID; currently provided for module compatibility/future use | Yes |
| `lambda_ec2_isolation_sg_id` | EC2 isolation Lambda security group ID; currently provided for module compatibility/future use | Yes |
| `lambda_ec2_rollback_sg_id` | EC2 rollback Lambda security group ID; currently provided for module compatibility/future use | Yes |
| `compute_private_route_table_ids_map` | Map of compute private route table IDs used by the S3 Gateway Endpoint | Yes |

---

## Outputs

| Name | Description |
|------|-------------|
| `interface_endpoints_sg_id` | ID of the shared security group attached to interface VPC endpoints |

---

## Usage Example

```hcl
module "vpc_endpoints" {
  source = "../../modules/vpc_endpoints"

  name_prefix = local.name_prefix
  environment = var.environment
  vpc_id      = module.networking.vpc_id
  account_id  = var.account_id

  primary_region = var.primary_region

  compute_private_subnet_ids_map       = module.networking.compute_private_subnet_ids_map
  serverless_private_subnet_ids_map    = module.networking.serverless_private_subnet_ids_map
  compute_private_route_table_ids_map  = module.networking.compute_private_route_table_ids_map
  subnet_cidrs                         = var.subnet_cidrs

  compute_sg_id                 = module.compute.compute_sg_id
  lambda_ec2_isolation_sg_id    = module.automation.lambda_ec2_isolation_sg_id
  lambda_ec2_rollback_sg_id     = module.automation.lambda_ec2_rollback_sg_id
}
```

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
- S3 Gateway Endpoint exists.
- Interface endpoints exist for the configured AWS services.
- Endpoint state is `available`.
- Private DNS is enabled for interface endpoints.

---

### Validate S3 Gateway Endpoint Route Tables

```bash
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=service-name,Values=com.amazonaws.${AWS_REGION}.s3" \
  --query 'VpcEndpoints[].[VpcEndpointId,VpcEndpointType,RouteTableIds]' \
  --output table
```

Expected:
- S3 Gateway Endpoint is associated with compute private route tables.

---

### Validate Interface Endpoint Subnets

```bash
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[].[VpcEndpointId,ServiceName,SubnetIds,Groups]' \
  --output table
```

Expected:
- Interface endpoints are deployed into private compute subnets.
- Interface endpoints use the shared endpoint security group.

---

### Validate Private DNS from an Instance

From a private EC2 instance:

```bash
dig ssm.${AWS_REGION}.amazonaws.com
dig kms.${AWS_REGION}.amazonaws.com
dig secretsmanager.${AWS_REGION}.amazonaws.com
```

Expected:
- DNS resolves successfully.
- Responses should resolve to private VPC endpoint IP addresses.

---

### Validate HTTPS Connectivity to an AWS Service

From a private EC2 instance:

```bash
aws sts get-caller-identity \
  --region "${AWS_REGION}"
```

Expected:
- The command succeeds without requiring direct public internet routing.
- If the command fails, check:
  - Interface endpoint state
  - Private DNS setting
  - Endpoint security group rules
  - Instance security group egress
  - Route table configuration
  - IAM permissions

---

## Troubleshooting

### Interface Endpoint Exists but Service Calls Fail

Check:
- Endpoint state is `available`
- Private DNS is enabled
- Endpoint security group allows TCP/443 from private workloads
- Workload security group allows outbound TCP/443
- DNS resolution works inside the VPC
- The AWS service endpoint exists in the selected region

---

### SSM Session Manager Does Not Work

Confirm that the following endpoints exist and are available:

```text
ssm
ssmmessages
ec2messages
```

Important:

The current module creates `ssm` and `ssmmessages`.

If Session Manager connectivity fails and the environment requires private-only SSM access, verify whether an `ec2messages` interface endpoint is also required for your instance/agent behavior.

---

### S3 Traffic Still Uses NAT Gateway

Check:
- S3 Gateway Endpoint exists
- Compute private route tables are associated with the endpoint
- The workload is running in a subnet using one of those route tables
- Bucket policies do not deny access from the endpoint path
- No application-level proxy is forcing traffic through another route

---

### Private DNS Conflicts

If custom DNS, Route 53 Resolver, or third-party DNS forwarding is used, confirm that AWS service names resolve correctly inside the VPC.

Private DNS must resolve AWS service names to VPC endpoint IP addresses for the intended private routing behavior.

---

## Design Principles

This module follows:

- Private-first workload access
- Reduced public internet dependency
- Least-exposure networking
- Centralized AWS service access through VPC endpoints
- Support for SSM-based administration
- Support for secure logging, secrets, encryption, and monitoring paths
- Compatibility with controlled egress through firewall and NAT architecture

---

## Notes

- Interface endpoints are deployed into compute private subnets.
- The S3 Gateway Endpoint is attached to compute private route tables.
- Private DNS is enabled for interface endpoints.
- The module currently outputs only the interface endpoint security group ID.
- Additional endpoint IDs can be added as outputs later if needed for validation, monitoring, or policy conditions.
- Endpoint policies are not currently customized in this module.
- Security group rule handling should be reviewed if private service connectivity fails.