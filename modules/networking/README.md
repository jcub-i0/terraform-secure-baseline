# Networking Module

## Overview

The `networking` module provisions the core VPC network foundation for the workload environment.

This includes:

- Main workload VPC
- Public subnets
- Private compute subnets
- Private data subnets
- Private serverless subnets
- Private firewall subnets
- Internet Gateway
- Elastic IPs for NAT Gateways
- NAT Gateways
- Public route tables
- Private route tables
- Route table associations
- Outputs for downstream modules
- Security group rule wiring through the `security_policy` child module

This module provides the network segmentation layer used by compute, storage, logging, security, automation, VPC endpoints, and firewall components.

---

## Purpose

The purpose of this module is to create a segmented, private-first AWS VPC architecture.

It supports:

- Public ingress/egress infrastructure through public subnets
- Private workload placement for EC2 compute
- Private database placement for RDS/data resources
- Private serverless placement for Lambda functions
- Dedicated firewall subnet placement
- Per-AZ NAT Gateway deployment
- Per-AZ route table segmentation
- DNS support for private AWS service access
- Downstream VPC endpoint deployment
- Downstream Network Firewall routing integration
- Centralized security group rule management through the `security_policy` child module

The module is designed to provide the baseline network structure without tightly coupling every route, firewall, and security group behavior into a single file.

---

## Resources Created

### Main VPC

Creates the primary workload VPC:

```hcl
resource "aws_vpc" "main"
```

Configuration:

| Setting | Value |
|---|---|
| CIDR block | `var.main_vpc_cidr` |
| DNS support | Enabled |
| DNS hostnames | Enabled |

DNS support and DNS hostnames are enabled so private workloads can resolve AWS service endpoints, VPC endpoints, RDS endpoints, and other internal DNS names.

---

### Public Subnets

Creates one public subnet per Availability Zone:

```hcl
resource "aws_subnet" "public"
```

The module loops over:

```hcl
var.azs
```

Subnet CIDRs come from:

```hcl
var.subnet_cidrs.public
```

Public subnets are used for:

- NAT Gateways
- Internet Gateway routing
- Public edge infrastructure if needed in the future

Public IP assignment on launch is disabled:

```hcl
map_public_ip_on_launch = false
```

This means instances will not automatically receive public IPs just because they are launched in a public subnet.

---

### Compute Private Subnets

Creates one compute private subnet per Availability Zone:

```hcl
resource "aws_subnet" "compute_private"
```

Subnet CIDRs come from:

```hcl
var.subnet_cidrs.compute_private
```

Compute private subnets are intended for:

- EC2 workload instances
- Private application compute
- Workloads managed through SSM
- Workloads that use VPC endpoints and controlled egress

Public IP assignment on launch is disabled.

---

### Data Private Subnets

Creates one data private subnet per Availability Zone:

```hcl
resource "aws_subnet" "data_private"
```

Subnet CIDRs come from:

```hcl
var.subnet_cidrs.data_private
```

Data private subnets are intended for:

- RDS instances
- Database subnet groups
- Data-layer resources
- Private storage services that should not have direct public exposure

Public IP assignment on launch is disabled.

---

### Serverless Private Subnets

Creates one serverless private subnet per Availability Zone:

```hcl
resource "aws_subnet" "serverless_private"
```

Subnet CIDRs come from:

```hcl
var.subnet_cidrs.serverless_private
```

Serverless private subnets are intended for:

- VPC-attached Lambda functions
- Security automation Lambdas
- Private service integrations

Public IP assignment on launch is disabled.

---

### Firewall Private Subnets

Creates one firewall private subnet per Availability Zone:

```hcl
resource "aws_subnet" "firewall_private"
```

Subnet CIDRs come from:

```hcl
var.subnet_cidrs.firewall_private
```

Firewall private subnets are intended for:

- AWS Network Firewall endpoints
- Egress inspection architecture
- Per-AZ firewall routing

Public IP assignment on launch is disabled.

---

### Internet Gateway

Creates an Internet Gateway for the VPC:

```hcl
resource "aws_internet_gateway" "igw"
```

The Internet Gateway is used by public route tables and NAT Gateway egress.

---

### Elastic IPs for NAT Gateways

Creates one Elastic IP per Availability Zone:

```hcl
resource "aws_eip" "nat"
```

Each Elastic IP is used by a NAT Gateway in the matching public subnet.

---

### NAT Gateways

Creates one NAT Gateway per Availability Zone:

```hcl
resource "aws_nat_gateway" "natgw"
```

Each NAT Gateway is deployed into the corresponding public subnet.

The NAT Gateways depend on the Internet Gateway:

```hcl
depends_on = [aws_internet_gateway.igw]
```

The intended design is to support per-AZ private outbound egress.

---

## Route Tables

### Public Route Tables

Creates one public route table per Availability Zone:

```hcl
resource "aws_route_table" "public"
```

Each public route table includes a default route to the Internet Gateway:

```hcl
route {
  cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.igw.id
}
```

Each public route table is associated with the corresponding public subnet.

---

### Compute Private Route Tables

Creates one compute private route table per Availability Zone:

```hcl
resource "aws_route_table" "compute_private"
```

Each compute private route table is associated with the corresponding compute private subnet.

Current note:

The default route from compute private subnets to AWS Network Firewall is present in commented code and not currently active in this module.

Commented pattern:

```hcl
resource "aws_route" "compute_default_to_firewall" {
  for_each               = local.az_index_map
  route_table_id         = aws_route_table.compute_private[each.key].id
  destination_cidr_block = "0.0.0.0/0"

  vpc_endpoint_id = var.firewall_endpoint_ids_by_az[each.key]
}
```

This indicates the expected future or external integration point for routing private compute egress through Network Firewall endpoints.

---

### Firewall Private Route Tables

Creates one firewall private route table per Availability Zone:

```hcl
resource "aws_route_table" "firewall_private"
```

Each firewall private route table includes a default route to the NAT Gateway in the same Availability Zone:

```hcl
route {
  cidr_block     = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.natgw[each.key].id
}
```

Each firewall private route table is associated with the corresponding firewall private subnet.

This supports the broader intended egress path:

```text
Private Workloads
    |
    v
AWS Network Firewall endpoint
    |
    v
Firewall Private Route Table
    |
    v
NAT Gateway
    |
    v
Internet Gateway
```

---

### Data Private Route Tables

Creates one data private route table per Availability Zone:

```hcl
resource "aws_route_table" "data_private"
```

Each data private route table is associated with the corresponding data private subnet.

No default internet route is created in these route tables.

This keeps data-layer subnets isolated by default.

---

### Serverless Private Route Tables

Creates one serverless private route table per Availability Zone:

```hcl
resource "aws_route_table" "serverless_private"
```

Each serverless private route table is associated with the corresponding serverless private subnet.

No default internet route is created in these route tables.

This keeps serverless workloads private unless explicit routing is added elsewhere.

---

## Security Policy Child Module

The networking module includes a `security_policy` child module directory:

```text
modules/networking/security_policy
```

The `security_policy` module manages security group rules that connect resources created by other modules.

This README intentionally does not go deep into the child module because it should have its own README.

At a high level, the child module manages rules for:

- Compute access to Interface VPC Endpoints over TCP/443
- Lambda isolation access to Interface VPC Endpoints over TCP/443
- Lambda rollback access to Interface VPC Endpoints over TCP/443
- Compute access to the database port
- Database ingress from compute
- Compute HTTPS egress through controlled egress paths
- Interface Endpoint security group ingress and egress

This split keeps base VPC/subnet/route resources in the parent networking module while keeping security group policy rules in a focused child module.

---

## Network Segmentation

The module creates five subnet tiers across the configured Availability Zones:

| Subnet tier | Purpose |
|---|---|
| Public | NAT Gateways and public edge infrastructure |
| Compute private | EC2 workload instances and private compute |
| Data private | RDS and data-layer resources |
| Serverless private | VPC-attached Lambda and serverless workloads |
| Firewall private | AWS Network Firewall endpoints and inspected egress path |

This segmentation supports separation of duties between workload, data, serverless, public egress, and inspection layers.

---

## Availability Zone Model

The module builds a local AZ index map:

```hcl
locals {
  az_index_map = { for indx, az in var.azs : az => indx }
}
```

This allows the module to create subnet and route table resources per Availability Zone while selecting the matching CIDR block from each subnet CIDR list.

Example:

```text
var.azs[0] -> var.subnet_cidrs.public[0]
var.azs[1] -> var.subnet_cidrs.public[1]
var.azs[2] -> var.subnet_cidrs.public[2]
```

The same pattern is used for each subnet tier.

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `name_prefix` | Prefix used for resource naming | Yes |
| `main_vpc_cidr` | CIDR block for the main workload VPC | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `cloud_name` | Cloud or project name used by the broader baseline | Yes |
| `azs` | List of Availability Zones where subnets and NAT Gateways are created | Yes |
| `subnet_cidrs` | Map of subnet CIDR lists for each subnet tier | Yes |
| `firewall_endpoint_ids_by_az` | Map of AWS Network Firewall endpoint IDs keyed by Availability Zone; used when routing private subnet egress through firewall endpoints | Yes |

---

## Expected `subnet_cidrs` Structure

The `subnet_cidrs` variable is a map of lists.

Expected keys include:

```hcl
subnet_cidrs = {
  public             = [...]
  compute_private    = [...]
  data_private       = [...]
  serverless_private = [...]
  firewall_private   = [...]
}
```

Each list should align with the order of `var.azs`.

For example:

```hcl
azs = [
  "us-east-1a",
  "us-east-1b",
  "us-east-1c"
]

subnet_cidrs = {
  public             = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
  compute_private    = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
  data_private       = ["10.0.20.0/24", "10.0.21.0/24", "10.0.22.0/24"]
  serverless_private = ["10.0.30.0/24", "10.0.31.0/24", "10.0.32.0/24"]
  firewall_private   = ["10.0.40.0/24", "10.0.41.0/24", "10.0.42.0/24"]
}
```

The number of CIDRs in each subnet tier should match the number of Availability Zones.

---

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | ID of the main workload VPC |
| `public_subnet_ids_map` | Map of public subnet IDs by Availability Zone |
| `compute_private_subnet_ids_map` | Map of compute private subnet IDs by Availability Zone |
| `data_private_subnet_ids_map` | Map of data private subnet IDs by Availability Zone |
| `serverless_private_subnet_ids_map` | Map of serverless private subnet IDs by Availability Zone |
| `firewall_private_subnet_ids_map` | Map of firewall private subnet IDs by Availability Zone |
| `public_subnet_ids_list` | List of public subnet IDs |
| `compute_private_subnet_ids_list` | List of compute private subnet IDs |
| `data_private_subnet_ids_list` | List of data private subnet IDs |
| `serverless_private_subnet_ids_list` | List of serverless private subnet IDs |
| `firewall_private_subnet_ids_list` | List of firewall private subnet IDs |
| `compute_private_route_table_ids_map` | Map of compute private route table IDs by Availability Zone |

---

## Map vs. List Outputs

This module exposes both map and list outputs for subnet IDs.

Map outputs are useful when downstream resources use `for_each` by Availability Zone.

Example:

```hcl
compute_private_subnet_ids_map = module.networking.compute_private_subnet_ids_map
```

List outputs are useful when AWS resources expect a list of subnet IDs.

Example:

```hcl
data_private_subnet_ids_list = module.networking.data_private_subnet_ids_list
```

Common examples:

| Output type | Use case |
|---|---|
| Map | EC2 instances per subnet/AZ, VPC endpoints, per-AZ routing |
| List | RDS DB subnet groups, Lambda subnet config, AWS Network Firewall subnet mappings |

---

## Usage Example

```hcl
module "networking" {
  source = "../modules/networking"

  name_prefix   = local.name_prefix
  environment   = var.environment
  cloud_name    = var.cloud_name

  main_vpc_cidr = var.main_vpc_cidr
  subnet_cidrs  = var.subnet_cidrs
  azs           = var.azs

  firewall_endpoint_ids_by_az = module.firewall.firewall_endpoint_ids_by_az
}
```

Example with security policy child module wiring in the root stack:

```hcl
module "security_policy" {
  source = "../modules/networking/security_policy"

  compute_sg_id              = module.compute.compute_sg_id
  data_sg_id                 = module.storage.data_sg_id
  lambda_ec2_isolation_sg_id = module.automation.lambda_ec2_isolation_sg_id
  lambda_ec2_rollback_sg_id  = module.automation.lambda_ec2_rollback_sg_id
  interface_endpoints_sg_id  = module.vpc_endpoints.interface_endpoints_sg_id
  db_port                    = var.db_port
}
```

---

## Dependency Notes

### Downstream Consumers

Outputs from this module are consumed by many other modules.

| Output | Typical Consumer |
|---|---|
| `vpc_id` | Compute, storage, VPC endpoints, automation, firewall |
| `public_subnet_ids_map` | NAT Gateway routing or public resources |
| `compute_private_subnet_ids_map` | Compute, VPC endpoints |
| `compute_private_subnet_ids_list` | Workload placement or validation |
| `data_private_subnet_ids_list` | RDS DB subnet group |
| `serverless_private_subnet_ids_map` | Lambda/security automation placement |
| `firewall_private_subnet_ids_map` | AWS Network Firewall subnet mappings |
| `compute_private_route_table_ids_map` | S3 Gateway VPC Endpoint route table associations |

### Common Upstream Inputs

This module is usually one of the first workload modules deployed.

It mostly depends on:

- Environment variables
- CIDR planning
- Availability Zone selection
- Naming locals

Other modules generally depend on networking outputs.

---

## Validation

### Confirm VPC Exists

```bash
aws ec2 describe-vpcs \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=tag:Name,Values=${NAME_PREFIX}-Main" \
  --query 'Vpcs[].[VpcId,CidrBlock,State,IsDefault]' \
  --output table
```

Expected:

- VPC exists
- CIDR matches `main_vpc_cidr`
- State is `available`
- `IsDefault` is `false`

---

### Confirm VPC DNS Settings

```bash
aws ec2 describe-vpc-attribute \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --vpc-id "${VPC_ID}" \
  --attribute enableDnsSupport

aws ec2 describe-vpc-attribute \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --vpc-id "${VPC_ID}" \
  --attribute enableDnsHostnames
```

Expected:

- `EnableDnsSupport.Value` is `true`
- `EnableDnsHostnames.Value` is `true`

---

### Confirm Subnets

```bash
aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table
```

Expected:

- Public subnets exist
- Compute private subnets exist
- Data private subnets exist
- Serverless private subnets exist
- Firewall private subnets exist
- Subnets exist across the configured Availability Zones
- `MapPublicIpOnLaunch` is `false`

---

### Confirm Internet Gateway

```bash
aws ec2 describe-internet-gateways \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query 'InternetGateways[].[InternetGatewayId,Attachments[0].State]' \
  --output table
```

Expected:

- Internet Gateway exists
- Internet Gateway is attached to the workload VPC
- Attachment state is `available`

---

### Confirm NAT Gateways

```bash
aws ec2 describe-nat-gateways \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filter "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId,NatGatewayAddresses[0].PublicIp]' \
  --output table
```

Expected:

- One NAT Gateway exists per configured Availability Zone
- NAT Gateway state is `available`
- Each NAT Gateway is deployed into a public subnet
- Each NAT Gateway has an Elastic IP address

---

### Confirm Public Route Tables

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Public-Route-Table-*" \
  --query 'RouteTables[].[RouteTableId,Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId]|[0][0]]' \
  --output table
```

Expected:

- Public route tables exist
- Each public route table has a default route to the Internet Gateway

---

### Confirm Private Route Tables

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,RouteTableId,Associations[].SubnetId | join(`,`, @)]' \
  --output table
```

Expected:

- Compute private route tables exist
- Data private route tables exist
- Serverless private route tables exist
- Firewall private route tables exist
- Each route table is associated with the expected subnet tier

---

### Confirm Firewall Private Route Tables Route to NAT

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Firewall-Private-RT-*" \
  --query 'RouteTables[].[RouteTableId,Routes[?DestinationCidrBlock==`0.0.0.0/0`].[NatGatewayId]|[0][0]]' \
  --output table
```

Expected:

- Firewall private route tables exist
- Each firewall private route table has a default route to a NAT Gateway

---

### Confirm Compute Private Route Tables

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-RT-*" \
  --query 'RouteTables[].[RouteTableId,Routes]' \
  --output json
```

Expected:

- Compute private route tables exist
- Route table associations point to compute private subnets
- Default egress routing depends on the broader firewall/VPC endpoint routing design

Note:

In the current parent module, the compute private default route to Network Firewall is commented out.

---

### Confirm Route Table Associations

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,Associations[].SubnetId]' \
  --output json
```

Expected:

- Public route tables are associated with public subnets
- Compute private route tables are associated with compute private subnets
- Data private route tables are associated with data private subnets
- Serverless private route tables are associated with serverless private subnets
- Firewall private route tables are associated with firewall private subnets

---

## Operational Considerations

### CIDR Planning Matters

The `subnet_cidrs` map must be planned carefully.

Each subnet tier must have one CIDR per Availability Zone.

CIDRs must not overlap.

Plan enough address space for future growth, especially in:

- Compute private subnets
- Serverless private subnets
- Data private subnets
- VPC endpoint ENIs
- Firewall endpoint placement

---

### NAT Gateway Cost

This module creates one NAT Gateway per Availability Zone.

This improves availability and keeps egress AZ-local, but it increases cost.

Cost drivers include:

- NAT Gateway hourly charges
- NAT Gateway data processing
- Elastic IP usage
- Cross-AZ traffic if routing is misaligned

For lower-cost development environments, future versions may support configurable egress modes.

---

### Public Subnets Do Not Auto-Assign Public IPs

Public subnets are created with:

```hcl
map_public_ip_on_launch = false
```

This is intentional.

If a future public-facing resource needs a public IP address, assign it explicitly through that resource configuration.

---

### Private Subnets Do Not Automatically Have Internet Egress

Compute, data, and serverless private route tables do not currently include a default route to the Internet in this parent module.

This is intentional for a private-first architecture.

Private outbound access should be provided intentionally through:

- AWS Network Firewall routing
- NAT Gateway routing
- VPC endpoints
- Explicit route table changes

---

### Network Firewall Integration

The module includes a commented placeholder for routing compute private egress to Network Firewall endpoints.

This suggests the intended design is inspected egress.

Current intended high-level flow:

```text
Compute Private Subnets
    |
    v
AWS Network Firewall endpoint
    |
    v
Firewall Private Route Table
    |
    v
NAT Gateway
    |
    v
Internet Gateway
```

If this route is enabled later, ensure firewall endpoint IDs are passed by Availability Zone and that routing remains AZ-aligned.

---

### Network Firewall Traffic Control

AWS Network Firewall is not intended to act as a simple pass-through route to the Internet.

The broader baseline design uses Network Firewall as an egress inspection and control layer. Private workload traffic should be routed through Network Firewall before reaching NAT Gateway, allowing firewall policy rules to restrict outbound access.

Depending on the firewall policy, this can support controls such as:

- Allowing only approved outbound destinations
- Restricting traffic by domain or protocol
- Blocking known malicious destinations
- Enforcing centralized egress inspection
- Creating a controlled choke point for private subnet internet access

The intended model is:

```text
Private Compute Subnets
    |
    v
AWS Network Firewall policy enforcement
    |
    v
NAT Gateway
    |
    v
Internet Gateway
```

This means private workloads should not be treated as having unrestricted internet access just because a NAT Gateway exists.

---

### Security Group Policy Is Separate

The parent networking module creates the VPC and route structure.

Security group rules are handled by:

```text
modules/networking/security_policy
```

This keeps network resource creation separate from application/security access policy.

---

## Troubleshooting

### Subnet Creation Fails

Check:

- CIDRs do not overlap
- CIDRs fit inside `main_vpc_cidr`
- Each subnet CIDR list has the same number of entries as `var.azs`
- Availability Zone names are valid for the selected region
- Account has permissions to create subnets

---

### NAT Gateway Stays Pending or Fails

Check:

- Internet Gateway exists
- Public subnet exists
- Elastic IP allocation succeeded
- NAT Gateway is deployed into a valid public subnet
- Account has available Elastic IP quota
- Route table for the NAT Gateway subnet routes to the Internet Gateway

Useful command:

```bash
aws ec2 describe-nat-gateways \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filter "Name=vpc-id,Values=${VPC_ID}"
```

---

### Private Instances Cannot Reach AWS Services

Check:

- Required VPC endpoints exist
- Interface endpoint security group allows traffic from compute
- Compute security group allows egress to endpoints
- DNS support and DNS hostnames are enabled on the VPC
- Route tables are associated with the expected subnets
- Controlled NAT/firewall egress exists if the service does not have a VPC endpoint

---

### Private Instances Cannot Reach Package Repositories

Check:

- Private subnet route table has the intended outbound path
- Network Firewall route is configured if using inspected egress
- Firewall policy allows the required domains
- NAT Gateway is available
- DNS resolution works
- Security group egress allows HTTPS where intended

---

### VPC Endpoints Cannot Be Reached

Check security group rules in:

```text
modules/networking/security_policy
```

Validate:

- Compute egress to Interface Endpoint SG on TCP/443
- Lambda isolation egress to Interface Endpoint SG on TCP/443
- Lambda rollback egress to Interface Endpoint SG on TCP/443
- Interface Endpoint SG ingress from approved source security groups on TCP/443

---

### RDS Is Not Reachable from Compute

Check security group rules in:

```text
modules/networking/security_policy
```

Validate:

- Compute egress to data security group on `var.db_port`
- Data security group ingress from compute security group on `var.db_port`
- RDS is placed in data private subnets
- Route tables and NACLs do not block the traffic

---

### Route Tables Do Not Match Expected Architecture

Check:

- Route table names
- Route table associations
- Default routes
- NAT Gateway route placement
- Firewall route placement
- Whether the compute default route to firewall is intentionally commented out

Useful command:

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --output json
```

---

## Security Notes

- VPC DNS support is enabled.
- VPC DNS hostnames are enabled.
- Public subnet auto-assign public IP is disabled.
- All private subnet tiers disable public IP assignment.
- Data subnets do not receive a default internet route in this parent module.
- Serverless subnets do not receive a default internet route in this parent module.
- Compute private default internet routing is not active in the current parent module.
- Firewall private route tables route outbound traffic to NAT Gateways.
- NAT Gateways are deployed per Availability Zone.
- Security group rules are managed separately in the `security_policy` child module.
- Private AWS service access should be handled through VPC endpoints where possible.
- Internet egress should be routed intentionally through controlled firewall/NAT paths.

---

## Design Principles

This module follows:

- Private-first networking
- Multi-AZ subnet segmentation
- Separation of public, compute, data, serverless, and firewall layers
- Per-AZ routing patterns
- DNS support for AWS-native private connectivity
- Explicit egress design
- Separation between network infrastructure and security group policy
- Production-aligned VPC foundations

---

## Notes

- Deploy this module early because most other modules depend on its outputs.
- The number of subnet CIDRs per tier should match the number of Availability Zones.
- The module currently creates one NAT Gateway per Availability Zone.
- The module currently creates route tables per subnet tier per Availability Zone.
- The compute private route table default route to Network Firewall is currently commented out.
- The `security_policy` child module should receive security group IDs from compute, storage, automation, and VPC endpoint modules.
- Future versions may make egress modes configurable, such as `network_firewall`, `nat_only`, or `vpc_endpoints_only`.