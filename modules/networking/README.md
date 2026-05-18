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
- Private endpoint subnets for Interface VPC Endpoints
- Internet Gateway
- Conditional Elastic IPs for NAT Gateways
- Conditional NAT Gateways
- Public route tables
- Private route tables
- Route table associations
- Configurable private compute egress routing
- Optional AWS Network Firewall egress routing
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
- Dedicated VPC endpoint subnet placement
- Per-AZ route table segmentation
- Conditional NAT Gateway deployment
- Configurable egress modes
- DNS support for private AWS service access
- Downstream VPC endpoint deployment
- Optional Network Firewall routing integration
- Centralized security group rule management through the `security_policy` child module

The module is designed to provide the baseline network structure without tightly coupling every firewall policy and security group behavior into a single file.

---

## Egress Modes

The module supports configurable private compute egress through `egress_mode`.

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route | Intended use |
|---|---:|---:|---|---|
| `network_firewall` | Yes | Yes | AWS Network Firewall endpoint | Production / sensitive workloads |
| `nat_only` | No | Yes | NAT Gateway | Lower-cost development/testing |
| `vpc_endpoints_only` | No | No | No default route | AWS-private / lowest-cost testing |

The effective egress mode is normally resolved by the baseline stack from `deployment_profile` and `egress_mode`.

Typical profile behavior:

| `deployment_profile` | Default `egress_mode` |
|---|---|
| `production` | `network_firewall` |
| `development` | `nat_only` |
| `minimal` | `vpc_endpoints_only` |

Important:

When `egress_mode = "vpc_endpoints_only"`, NAT Gateways and Network Firewall are not deployed, and compute private subnets do not receive a default internet route. This mode is intended for AWS-private testing or workloads that do not require external package repositories or third-party internet access.

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

- NAT Gateways when NAT is enabled
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

These subnets are primarily used when:

```text
egress_mode = "network_firewall"
```

---

### Endpoint Private Subnets

Creates one endpoint private subnet per Availability Zone:

```hcl
resource "aws_subnet" "endpoint_private"
```

Subnet CIDRs come from:

```hcl
var.subnet_cidrs.vpc_endpoints_private
```

Endpoint private subnets are intended for:

- Interface VPC Endpoint ENIs
- Private AWS service access
- Dedicated endpoint placement separate from compute workloads

Public IP assignment on launch is disabled.

These subnets do not require a default internet route. Interface Endpoint ENIs are reachable from compute and serverless workloads over normal VPC-local routing and security group rules.

---

### Internet Gateway

Creates an Internet Gateway for the VPC:

```hcl
resource "aws_internet_gateway" "igw"
```

The Internet Gateway is used by public route tables and NAT Gateway egress when NAT is enabled.

---

### Elastic IPs for NAT Gateways

Creates one Elastic IP per Availability Zone when NAT is enabled:

```hcl
resource "aws_eip" "nat"
```

NAT is enabled when:

```hcl
var.egress_mode != "vpc_endpoints_only"
```

Each Elastic IP is used by a NAT Gateway in the matching public subnet.

No NAT Elastic IPs are created when:

```text
egress_mode = "vpc_endpoints_only"
```

---

### NAT Gateways

Creates one NAT Gateway per Availability Zone when NAT is enabled:

```hcl
resource "aws_nat_gateway" "natgw"
```

NAT is enabled when:

```hcl
var.egress_mode != "vpc_endpoints_only"
```

Each NAT Gateway is deployed into the corresponding public subnet.

The NAT Gateways depend on the Internet Gateway:

```hcl
depends_on = [aws_internet_gateway.igw]
```

NAT Gateway behavior by egress mode:

| `egress_mode` | NAT Gateway behavior |
|---|---|
| `network_firewall` | NAT Gateways are deployed after Network Firewall inspection |
| `nat_only` | NAT Gateways are deployed as the compute egress path |
| `vpc_endpoints_only` | NAT Gateways are not deployed |

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

When `egress_mode = "network_firewall"`, the module also creates return-path routes from the public route tables back to compute private CIDRs through the appropriate Network Firewall endpoint.

This supports symmetric routing for inspected egress traffic.

---

### Compute Private Route Tables

Creates one compute private route table per Availability Zone:

```hcl
resource "aws_route_table" "compute_private"
```

Each compute private route table is associated with the corresponding compute private subnet.

Compute private default routing depends on `egress_mode`:

| `egress_mode` | Compute private default route |
|---|---|
| `network_firewall` | AWS Network Firewall endpoint |
| `nat_only` | NAT Gateway |
| `vpc_endpoints_only` | No default route |

When `egress_mode = "network_firewall"`, compute private route tables send default egress to the AWS Network Firewall endpoint in the same Availability Zone.

When `egress_mode = "nat_only"`, compute private route tables send default egress directly to the NAT Gateway in the same Availability Zone.

When `egress_mode = "vpc_endpoints_only"`, no default route is created for compute private route tables.

---

### Firewall Private Route Tables

Creates one firewall private route table per Availability Zone:

```hcl
resource "aws_route_table" "firewall_private"
```

Each firewall private route table is associated with the corresponding firewall private subnet.

When `egress_mode = "network_firewall"`, each firewall private route table includes a default route to the NAT Gateway in the same Availability Zone.

This supports the broader inspected egress path:

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

When `egress_mode` is `nat_only` or `vpc_endpoints_only`, firewall private route tables do not receive a default NAT route.

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

No default internet route is created in these route tables by this module.

This keeps serverless workloads private unless explicit routing is added elsewhere.

---

### Endpoint Private Route Tables

Creates one endpoint private route table per Availability Zone:

```hcl
resource "aws_route_table" "endpoint_private"
```

Each endpoint private route table is associated with the corresponding endpoint private subnet.

Endpoint private route tables do not receive a default internet route.

This is intentional. Interface Endpoint ENIs do not need outbound internet access to serve private AWS service traffic from workloads inside the VPC.

---

## Security Policy Child Module

The networking module includes a `security_policy` child module directory:

```text
modules/networking/security_policy
```

The `security_policy` module manages security group rules that connect resources created by other modules.

This README intentionally does not go deep into the child module because it has its own README.

At a high level, the child module manages rules for:

- Compute access to Interface VPC Endpoints over TCP/443
- Lambda isolation access to Interface VPC Endpoints over TCP/443
- Lambda rollback access to Interface VPC Endpoints over TCP/443
- Compute access to the database port
- Database ingress from compute
- Compute HTTPS egress through configured egress paths
- Interface Endpoint security group ingress and egress

This split keeps base VPC/subnet/route resources in the parent networking module while keeping security group policy rules in a focused child module.

---

## Network Segmentation

The module creates six subnet tiers across the configured Availability Zones:

| Subnet tier | Purpose |
|---|---|
| Public | NAT Gateways and public edge infrastructure |
| Compute private | EC2 workload instances and private compute |
| Data private | RDS and data-layer resources |
| Serverless private | VPC-attached Lambda and serverless workloads |
| Firewall private | AWS Network Firewall endpoints and inspected egress path |
| Endpoint private | Interface VPC Endpoint ENIs |

This segmentation supports separation of duties between workload, data, serverless, public egress, inspection, and private AWS service access layers.

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
| `azs` | List of Availability Zones where subnets and per-AZ resources are created | Yes |
| `subnet_cidrs` | Map of subnet CIDR lists for each subnet tier | Yes |
| `egress_mode` | Effective private compute egress mode. Valid values: `network_firewall`, `nat_only`, `vpc_endpoints_only` | Yes |
| `firewall_endpoint_ids_by_az` | Map of AWS Network Firewall endpoint IDs keyed by Availability Zone; required when `egress_mode = "network_firewall"` | No |

---

## Expected `subnet_cidrs` Structure

The `subnet_cidrs` variable is a map of lists.

Expected keys include:

```hcl
subnet_cidrs = {
  public                = [...]
  compute_private       = [...]
  data_private          = [...]
  serverless_private    = [...]
  firewall_private      = [...]
  vpc_endpoints_private = [...]
}
```

Each list should align with the order of `var.azs`.

For example:

```hcl
azs = [
  "us-east-1a",
  "us-east-1b"
]

subnet_cidrs = {
  public                = ["10.0.0.0/24", "10.0.1.0/24"]
  compute_private       = ["10.0.16.0/24", "10.0.17.0/24"]
  data_private          = ["10.0.32.0/24", "10.0.33.0/24"]
  serverless_private    = ["10.0.48.0/24", "10.0.49.0/24"]
  firewall_private      = ["10.0.64.0/24", "10.0.65.0/24"]
  vpc_endpoints_private = ["10.0.128.0/24", "10.0.129.0/24"]
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
| `endpoint_private_subnet_ids_map` | Map of endpoint private subnet IDs by Availability Zone |
| `public_subnet_ids_list` | List of public subnet IDs |
| `compute_private_subnet_ids_list` | List of compute private subnet IDs |
| `data_private_subnet_ids_list` | List of data private subnet IDs |
| `serverless_private_subnet_ids_list` | List of serverless private subnet IDs |
| `firewall_private_subnet_ids_list` | List of firewall private subnet IDs |
| `endpoint_private_subnet_ids_list` | List of endpoint private subnet IDs |
| `compute_private_route_table_ids_map` | Map of compute private route table IDs by Availability Zone |
| `serverless_private_route_table_ids_map` | Map of serverless private route table IDs by Availability Zone |
| `endpoint_private_route_table_ids_map` | Map of endpoint private route table IDs by Availability Zone |
| `nat_gateway_ids_by_az` | Map of NAT Gateway IDs by Availability Zone. Empty when NAT is disabled |

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
| Map | EC2 instances per subnet/AZ, Interface VPC Endpoints, per-AZ routing |
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

  egress_mode = local.effective_egress_mode

  firewall_endpoint_ids_by_az = (
    local.effective_egress_mode == "network_firewall"
    ? module.firewall[0].firewall_endpoint_ids_by_az
    : {}
  )
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
  egress_mode                = local.effective_egress_mode
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
| `compute_private_subnet_ids_map` | Compute |
| `compute_private_subnet_ids_list` | Workload placement or validation |
| `data_private_subnet_ids_list` | RDS DB subnet group |
| `serverless_private_subnet_ids_map` | Lambda/security automation placement |
| `firewall_private_subnet_ids_map` | AWS Network Firewall subnet mappings |
| `endpoint_private_subnet_ids_map` | Interface VPC Endpoint subnet placement |
| `compute_private_route_table_ids_map` | S3 Gateway VPC Endpoint route table associations |
| `serverless_private_route_table_ids_map` | Optional S3 Gateway VPC Endpoint route table associations |
| `nat_gateway_ids_by_az` | NAT-only compute private default routing |

### Common Upstream Inputs

This module is usually one of the first workload modules deployed.

For `network_firewall` mode, Network Firewall endpoint IDs must be available so compute private route tables can route default egress through the correct per-AZ firewall endpoint.

For `nat_only` and `vpc_endpoints_only`, `firewall_endpoint_ids_by_az` can be an empty map.

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
- Endpoint private subnets exist
- Subnets exist across the configured Availability Zones
- `MapPublicIpOnLaunch` is `false`

---

### Confirm Endpoint Private Subnets

```bash
aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Endpoint-Private-*" \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table
```

Expected:

- Endpoint private subnets exist
- Endpoint private subnet CIDRs match `var.subnet_cidrs.vpc_endpoints_private`
- Endpoint private subnets exist across the configured Availability Zones
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

For `network_firewall` or `nat_only`:

- One NAT Gateway exists per configured Availability Zone
- NAT Gateway state is `available`
- Each NAT Gateway is deployed into a public subnet
- Each NAT Gateway has an Elastic IP address

For `vpc_endpoints_only`:

- No NAT Gateways should be returned for this VPC

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
- Endpoint private route tables exist
- Each route table is associated with the expected subnet tier

---

### Confirm Compute Private Route Tables

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-RT-*" \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,RouteTableId:RouteTableId,DefaultRoutes:Routes[?DestinationCidrBlock==`0.0.0.0/0`]}' \
  --output json
```

Expected:

For `network_firewall`:

- Each compute private route table has a default route to a Network Firewall endpoint

For `nat_only`:

- Each compute private route table has a default route to a NAT Gateway

For `vpc_endpoints_only`:

- Compute private route tables have no `0.0.0.0/0` default route

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

For `network_firewall`:

- Firewall private route tables exist
- Each firewall private route table has a default route to a NAT Gateway

For `nat_only` or `vpc_endpoints_only`:

- Firewall private route tables should not have a default NAT route

---

### Confirm Endpoint Private Route Tables Have No Default Route

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Endpoint-Private-RT-*" \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,RouteTableId:RouteTableId,Routes:Routes}' \
  --output json
```

Expected:

- Endpoint private route tables exist
- Endpoint private route tables are associated with endpoint private subnets
- Only the local VPC route should exist
- No `0.0.0.0/0` default route should exist

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
- Endpoint private route tables are associated with endpoint private subnets

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
- Endpoint private subnets
- VPC endpoint ENIs
- Firewall endpoint placement

---

### NAT Gateway Cost

NAT Gateways are one of the main cost drivers in this architecture.

NAT Gateway deployment depends on `egress_mode`:

| `egress_mode` | NAT Gateway deployment |
|---|---:|
| `network_firewall` | Yes |
| `nat_only` | Yes |
| `vpc_endpoints_only` | No |

Cost drivers include:

- NAT Gateway hourly charges
- NAT Gateway data processing
- Elastic IP usage
- Cross-AZ traffic if routing is misaligned

For lower-cost development environments, use `egress_mode = "nat_only"`.

For lowest-cost AWS-private testing, use `egress_mode = "vpc_endpoints_only"`.

---

### Public Subnets Do Not Auto-Assign Public IPs

Public subnets are created with:

```hcl
map_public_ip_on_launch = false
```

This is intentional.

If a future public-facing resource needs a public IP address, assign it explicitly through that resource configuration.

---

### Private Subnets Do Not Automatically Bypass Inspection

In `network_firewall` mode, compute private route tables send default outbound traffic to AWS Network Firewall endpoints.

This is intentional for a private-first, inspected-egress architecture.

Private outbound access should be provided intentionally through:

- AWS Network Firewall routing
- NAT Gateway routing after firewall inspection
- Direct NAT routing in `nat_only` mode
- VPC endpoints
- Explicit route table changes

---

### Network Firewall Integration

When `egress_mode = "network_firewall"`, the module routes compute private egress to Network Firewall endpoints.

High-level flow:

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

Ensure firewall endpoint IDs are passed by Availability Zone and that routing remains AZ-aligned.

---

### Network Firewall Traffic Control

AWS Network Firewall is not intended to act as a simple pass-through route to the Internet.

The broader baseline design uses Network Firewall as an egress inspection and control layer. Private workload traffic is routed through Network Firewall before reaching NAT Gateway, allowing firewall policy rules to restrict outbound access.

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

### VPC Endpoints Only Mode

When `egress_mode = "vpc_endpoints_only"`:

- NAT Gateways are not deployed
- Network Firewall is not deployed
- Compute private subnets do not receive a default internet route
- Endpoint private subnets still host Interface VPC Endpoints
- S3 Gateway Endpoint access depends on route table associations
- Workloads can access supported AWS services privately through VPC endpoints

This mode is intended for AWS-private testing or workloads that do not require third-party internet access.

Important:

EC2 user data package installation may fail in this mode unless package repository access is provided another way.

---

### Endpoint Private Subnets

Interface VPC Endpoints are deployed into dedicated endpoint private subnets.

These subnets have their own route tables and do not require a default internet route.

Workloads in compute and serverless subnets reach Interface Endpoints over VPC-local routing and security group rules.

S3 Gateway Endpoints are different. They attach to route tables rather than subnets. The S3 Gateway Endpoint should be associated with the route tables that need private S3 access, such as compute private route tables.

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
- `vpc_endpoints_private` is defined in `subnet_cidrs`
- Availability Zone names are valid for the selected region
- Account has permissions to create subnets

---

### NAT Gateway Stays Pending or Fails

Check:

- `egress_mode` requires NAT Gateway deployment
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

### NAT Gateway Is Missing

Check the active egress mode.

NAT Gateways are not deployed when:

```text
egress_mode = "vpc_endpoints_only"
```

If NAT is expected, confirm the effective egress mode from Terraform outputs:

```bash
terraform output effective_egress_mode
```

Expected:

- `network_firewall` or `nat_only` should deploy NAT Gateways
- `vpc_endpoints_only` should not deploy NAT Gateways

---

### Private Instances Cannot Reach AWS Services

Check:

- Required VPC endpoints exist
- Interface Endpoints are deployed into endpoint private subnets
- Interface endpoint security group allows traffic from compute
- Compute security group allows egress to endpoints
- DNS support and DNS hostnames are enabled on the VPC
- Route tables are associated with the expected subnets
- The selected `egress_mode` supports the needed traffic path
- Firewall policy allows the required traffic when using `network_firewall`

---

### Private Instances Cannot Reach Package Repositories

Check:

- Effective egress mode
- Compute private route table default route
- NAT Gateway availability if using `nat_only`
- Network Firewall route and policy if using `network_firewall`
- DNS resolution
- Security group egress rules

Important:

If `egress_mode = "vpc_endpoints_only"`, package repository access is not expected unless another private package access pattern has been implemented.

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
- Interface Endpoints are deployed into endpoint private subnets
- Endpoint private route tables exist and are associated correctly

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

- Effective egress mode
- Route table names
- Route table associations
- Default routes
- NAT Gateway route placement
- Firewall route placement
- Whether compute private default routes point to the expected destination for the active egress mode
- Whether endpoint private route tables have no default route

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
- Endpoint private subnets do not receive a default internet route.
- Compute private default routing depends on `egress_mode`.
- Network Firewall is deployed only when `egress_mode = "network_firewall"`.
- NAT Gateways are not deployed when `egress_mode = "vpc_endpoints_only"`.
- Firewall private route tables route outbound traffic to NAT Gateways only in `network_firewall` mode.
- Security group rules are managed separately in the `security_policy` child module.
- Private AWS service access should be handled through VPC endpoints where possible.
- Internet egress should be routed intentionally through controlled firewall/NAT paths.
- Network Firewall policy should restrict outbound traffic instead of allowing unrestricted internet access.

---

## Design Principles

This module follows:

- Private-first networking
- Multi-AZ subnet segmentation
- Separation of public, compute, data, serverless, firewall, and endpoint layers
- Per-AZ routing patterns
- DNS support for AWS-native private connectivity
- Configurable egress behavior
- Optional inspected egress through AWS Network Firewall
- Dedicated subnet placement for Interface VPC Endpoints
- Separation between network infrastructure and security group policy
- Production-aligned VPC foundations with lower-cost deployment options

---

## Notes

- Deploy this module early because most other modules depend on its outputs.
- The number of subnet CIDRs per tier should match the number of Availability Zones.
- The module creates one NAT Gateway per Availability Zone only when NAT is enabled.
- NAT is enabled for `network_firewall` and `nat_only` modes.
- NAT is disabled for `vpc_endpoints_only` mode.
- The module creates route tables per subnet tier per Availability Zone.
- The compute private route table default route depends on `egress_mode`.
- Interface VPC Endpoints should use `endpoint_private_subnet_ids_map`.
- S3 Gateway Endpoint route table associations should include the route tables that need private S3 access.
- The `security_policy` child module should receive security group IDs from compute, storage, automation, and VPC endpoint modules.