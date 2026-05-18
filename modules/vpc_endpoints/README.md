# VPC Endpoints Module

## Overview

The `vpc_endpoints` module provisions private AWS service access for the workload VPCs.

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

This module helps enforce the baseline’s private-by-default networking model and is especially important for `vpc_endpoints_only` deployments where private compute subnets do not receive a default internet route.

---

## Resources Created

### S3 Gateway Endpoint

Creates an S3 Gateway VPC Endpoint:

```hcl
resource "aws_vpc_endpoint" "s3"
```

The S3 Gateway Endpoint is associated with the private route tables that need private S3 access.

This allows resources in private subnets to reach S3 using private AWS network paths instead of routing S3 traffic through the internet gateway, NAT gateway, or Network Firewall path.

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
modules/networking/security_policy
```

This separation keeps endpoint creation in the `vpc_endpoints` module while keeping network security rules centralized in the networking policy layer.

---

## Security Group Rules

The Interface Endpoint security group rules are defined in:

```text
modules/networking/security_policy
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

Interface Endpoints are deployed into dedicated VPC endpoint private subnets.

```hcl
local.interface_endpoint_subnet_ids_map = var.endpoint_private_subnet_ids_map
```

These subnets are separate from:

- Compute private subnets
- Data private subnets
- Serverless private subnets
- Firewall private subnets
- Public subnets

Dedicated endpoint subnets keep Interface Endpoint ENIs separate from workload ENIs and reduce private IP consumption in compute subnets.

The endpoint private subnets have their own route tables and do not require a default internet route. Workloads in compute and serverless subnets reach Interface Endpoints through normal VPC-local routing and security group rules.

The S3 Gateway Endpoint is associated with the route tables passed into the module:

```hcl
route_table_ids = var.s3_gateway_endpoint_route_table_ids
```

This allows the root baseline stack to decide which private route tables need S3 Gateway Endpoint access.

---

## Deployment Profile and Egress Mode Behavior

This module is used across all deployment profiles and egress modes.

| `egress_mode` | Role of this module |
|---|---|
| `network_firewall` | Provides private AWS service access while internet-bound traffic routes through Network Firewall and NAT Gateway |
| `nat_only` | Provides private AWS service access while internet-bound traffic routes directly through NAT Gateway |
| `vpc_endpoints_only` | Provides the primary AWS service access path because private compute subnets do not have a default internet route |

When `deployment_profile = "minimal"` and `egress_mode = "auto"`, the effective egress mode is `vpc_endpoints_only`.

In that mode:

- Network Firewall is not deployed.
- NAT Gateways are not deployed.
- Compute private subnets do not receive a default internet route.
- Interface VPC Endpoints and the S3 Gateway Endpoint are the main AWS service access path.

This means VPC endpoints are especially important for minimal/private AWS-only deployments.

Important:

`vpc_endpoints_only` does not provide access to third-party internet destinations, operating system package repositories, public container registries, or AWS services that are not covered by configured endpoints.

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
| `endpoint_private_subnet_ids_map` | Map of dedicated endpoint private subnet IDs where Interface Endpoints are deployed | Yes |
| `endpoint_private_rt_ids_map` | Map of dedicated endpoint private route table IDs | Yes |
| `s3_gateway_endpoint_route_table_ids` | List of route table IDs that should use the S3 Gateway Endpoint | Yes |
| `compute_sg_id` | Security group ID for compute workloads | Yes |
| `lambda_ec2_isolation_sg_id` | Security group ID for the EC2 Isolation Lambda | Yes |
| `lambda_ec2_rollback_sg_id` | Security group ID for the EC2 Rollback Lambda | Yes |

---

## Outputs

| Name | Description |
|---|---|
| `interface_endpoints_sg_id` | Security group ID for the Interface VPC Endpoints |

---

## Usage Example

```hcl
module "vpc_endpoints" {
  source = "../modules/vpc_endpoints"

  name_prefix    = local.name_prefix
  vpc_id         = module.networking.vpc_id
  environment    = var.environment
  account_id     = var.account_id
  primary_region = var.primary_region

  compute_private_subnet_ids_map       = module.networking.compute_private_subnet_ids_map
  serverless_private_subnet_ids_map    = module.networking.serverless_private_subnet_ids_map
  endpoint_private_subnet_ids_map      = module.networking.endpoint_private_subnet_ids_map
  endpoint_private_route_table_ids_map = module.networking.endpoint_private_route_table_ids_map

  s3_gateway_endpoint_rt_ids_list = concat(
    values(module.networking.endpoint_private_route_table_ids_map),
    values(module.networking.compute_private_route_table_ids_map),
    values(module.networking.serverless_private_route_table_ids_map)
  )

  subnet_cidrs  = var.subnet_cidrs
  compute_sg_id = module.compute.compute_sg_id

  lambda_ec2_isolation_sg_id = module.automation.lambda_ec2_isolation_sg_id
  lambda_ec2_rollback_sg_id  = module.automation.lambda_ec2_rollback_sg_id
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
modules/networking/security_policy
```

This keeps traffic policy decisions centralized in the networking module instead of scattering security group rules across multiple modules.

---

### S3 Uses a Gateway Endpoint

S3 is created as a Gateway Endpoint instead of an Interface Endpoint.

This is appropriate because S3 Gateway Endpoints integrate directly with route tables and allow private S3 access without creating endpoint ENIs.

The root baseline stack passes in the route tables that should receive S3 Gateway Endpoint access.

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

### Dedicated Endpoint Subnets

Interface Endpoints deploy into dedicated endpoint private subnets.

This keeps endpoint ENIs out of compute subnets and provides cleaner subnet segmentation.

The dedicated endpoint subnets do not need a default route. Interface Endpoint ENIs are reached over VPC-local routing from approved workload security groups.

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

### Confirm Interface Endpoints Use Endpoint Private Subnets

List the endpoint private subnet IDs:

```bash
aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Endpoint-Private-*" \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,SubnetId,AvailabilityZone,CidrBlock]' \
  --output table
```

Then list Interface Endpoint subnet placement:

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

### Confirm Endpoint Private Route Tables

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

---

### Confirm S3 Gateway Endpoint Route Tables

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
- Route table IDs include the private route tables intentionally passed to the module.
- S3 Gateway Endpoint route tables commonly include compute private route tables and serverless private route tables.

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
export AWS_REGION="us-east-1"
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

- Private EC2 instances appear in Systems Manager.
- `PingStatus` is `Online`.
- `LastPingDateTime` is recent.
- Inspector-created Linux associations may show `Success`.
- Inspector-created non-Linux associations may show `Skipped` with `InvalidPlatform` on Ubuntu/Linux instances.
- `InvalidPlatform` on skipped Inspector associations does not indicate SSM connectivity failure when the Linux Inspector associations are successful.

---

## Operational Considerations

### Cost

Interface Endpoints have hourly and data processing costs.

This module creates multiple Interface Endpoints, so costs can add up across:

- dev
- staging
- prod

Deployment profiles and egress modes can reduce NAT Gateway and Network Firewall cost, but Interface Endpoint costs still apply when endpoints are deployed.

---

### NAT Gateway Still May Be Needed

VPC endpoints reduce dependency on NAT Gateway for supported AWS services.

They do not eliminate NAT requirements for:

- Internet package repositories
- Third-party APIs
- External SaaS services
- Public container registries
- Any AWS service not covered by an endpoint

When `egress_mode = "vpc_endpoints_only"`, NAT Gateway is not deployed. In that mode, workloads should not depend on general internet access unless another access path is intentionally provided.

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
- The Interface Endpoint is deployed into endpoint private subnets
- The endpoint private subnet route tables exist and have the implicit local VPC route

---

### SSM Session Manager Does Not Work

Check that these endpoints exist and are available:

```text
ssm
ssmmessages
```

Also check:

- EC2 instance has an IAM role with SSM permissions
- SSM Agent is installed and running
- Security group rules allow HTTPS to Interface Endpoints
- The instance can resolve AWS service DNS names privately

Note:

This module intentionally does not create an ec2messages endpoint. AWS recommends using ssmmessages for Systems Manager communication, and ec2messages is not supported in AWS Regions launched in 2024 or later.

---

### S3 Access Still Uses NAT

Check:

- S3 Gateway Endpoint exists
- The expected private route tables are associated with the S3 Gateway Endpoint
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
- Endpoint rules are managed in `modules/networking/security_policy`.
- Interface Endpoints are deployed into dedicated endpoint private subnets.
- Endpoint private subnets do not require a default internet route.
- S3 private access is handled through a Gateway Endpoint and route table association.
- Private DNS avoids hardcoding endpoint-specific URLs.
- The module supports private operation of SSM, logging, encryption, secrets retrieval, EventBridge, Security Hub, and Lambda API access.
- Endpoint access should remain scoped to approved workload and automation security groups.

---

## Design Principles

This module follows:

- Private-first networking
- Least privilege network access
- Dedicated endpoint subnet segmentation
- Centralized security group policy
- Reduced public internet dependency
- Compatibility with AWS-native tooling
- Secure-by-default workload operations

---

## Notes

- This module should be deployed after the VPC, subnets, route tables, and workload security groups exist.
- The endpoint security group ID should be passed into the networking/security policy layer.
- Security group rules for the endpoint security group are not defined inside this module.
- The S3 Gateway Endpoint attaches to the route tables passed into this module.
- Interface Endpoints deploy into dedicated endpoint private subnets.
- `vpc_endpoints_only` mode depends heavily on these endpoints for AWS service access.