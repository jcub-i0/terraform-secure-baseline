# Networking Module

## Overview

The `networking` module provisions the core VPC, subnet, gateway, and route-table foundation for a workload environment. It creates one VPC, seven subnet families across the configured Availability Zones, an Internet Gateway, conditional NAT Gateway infrastructure, per-AZ route tables, and egress-mode-specific routes.

The public edge is intentionally split into two routing roles:

- `ingress_public` — dedicated to internet-facing Application Load Balancers. Its route tables provide Internet Gateway reachability and preserve VPC-local routing to private workload targets.
- `egress_public` — dedicated to NAT Gateways. In `network_firewall` mode, its route tables own the same-AZ compute-private return routes through AWS Network Firewall.

The module supports three private-compute egress modes:

- `network_firewall` — compute-private default traffic is routed to an AWS Network Firewall endpoint in the same Availability Zone, firewall-private traffic is routed to the same-AZ NAT Gateway in `egress_public`, and the matching `egress_public` route table returns that compute-private CIDR through the same-AZ firewall endpoint.
- `nat_only` — compute-private default traffic is routed directly to the same-AZ NAT Gateway in `egress_public`.
- `vpc_endpoints_only` — NAT Gateways and NAT Elastic IPs are not created, and compute-private route tables receive no default internet route.

The baseline gives the ALB and NAT Gateways separate subnet and route-table roles. This module creates the subnet families; the ALB itself is owned by `modules/application_load_balancer`.

The repository also contains `modules/networking/security_policy`. That is a separate child module for security-group policy. This README only acknowledges that boundary and does not document the child module's rules or interfaces.

---

## Module Boundary

This parent module owns:

- The main workload VPC
- Ingress-public subnets
- Egress-public subnets
- Compute-private subnets
- Data-private subnets
- Serverless-private subnets
- Firewall-private subnets
- Endpoint-private subnets
- Internet Gateway
- Conditional NAT Elastic IPs
- Conditional NAT Gateways
- Ingress-public route tables
- Egress-public route tables
- Compute-private route tables
- Firewall-private route tables
- Endpoint-private route tables
- Data-private route tables
- Serverless-private route tables
- Route-table associations
- Egress-mode-specific routing
- Networking outputs for downstream consumers

This parent module does not define the security-group rules contained in `modules/networking/security_policy`, and it does not create AWS Network Firewall resources or VPC endpoint resources. It accepts Network Firewall endpoint IDs when `egress_mode = "network_firewall"` so it can build the required routes.

---

## Architecture

The module creates the following seven subnet families in every Availability Zone listed in `var.azs`:

```text
VPC
├── ingress_public
├── egress_public
├── compute_private
├── data_private
├── serverless_private
├── firewall_private
└── endpoint_private
```

`ingress_public` and `egress_public` are separate routing domains. `ingress_public` is for ALB ingress only; `egress_public` is for NAT Gateway egress only.

Each subnet disables automatic public IPv4 assignment:

```hcl
map_public_ip_on_launch = false
```

The module derives a per-AZ index map from `var.azs` and uses the matching index to select each subnet CIDR:

```hcl
locals {
  az_index_map = { for indx, az in var.azs : az => indx }
}
```

Conceptually:

```text
var.azs[0] -> var.subnet_cidrs.<family>[0]
var.azs[1] -> var.subnet_cidrs.<family>[1]
...
```

Because the module indexes each subnet CIDR list by Availability Zone position, each required subnet family must provide enough CIDRs for all configured Availability Zones.

---

## Baseline AZ and CIDR Derivation

The low-level module receives concrete `azs`, `subnet_cidrs`, and `egress_mode` values. It does not accept `deployment_profile`, `primary_region`, `state_region`, or the baseline-only `auto` egress value, and it does not discover AZs itself.

[baseline/main.tf](../../baseline/main.tf) asserts that `primary_region` matches the active AWS provider region. Its `data.aws_availability_zones.standard` query filters `opt-in-status` to `opt-in-not-required`; baseline sorts the returned names and selects the first three for production or first two for development/minimal unless `azs` is supplied explicitly.

The baseline contract is:

| Input/condition | Baseline behavior |
|---|---|
| `main_vpc_cidr` | Canonical IPv4 /16; default `10.0.0.0/16` |
| `azs = null` | Three discovered AZs for production; two for development/minimal |
| Explicit `azs` | Unique eligible AZs in the selected provider region; at least three for production or two otherwise |
| `subnet_cidrs = null` | Derive every family from `main_vpc_cidr`; explicit AZ count must equal the profile default |
| Explicit `subnet_cidrs` | Exact seven family keys, matching AZ-list lengths, canonical unique /24s inside the main /16 |
| Additional AZs | Supply both explicit AZs and a matching explicit subnet-CIDR map |

Default subnet numbers are independent of the selected /16:

| Family | Development/minimal netnums | Production netnums |
|---|---|---|
| `egress_public` | `0, 1` | `0, 1, 2` |
| `ingress_public` | `2, 3` | `3, 4, 5` |
| `compute_private` | `16, 17` | `16, 17, 18` |
| `data_private` | `32, 33` | `32, 33, 34` |
| `serverless_private` | `48, 49` | `48, 49, 50` |
| `firewall_private` | `64, 65` | `64, 65, 66` |
| `endpoint_private` | `128, 129` | `128, 129, 130` |

For a new development deployment, this baseline input excerpt derives 14 subnets from a non-default /16:

```hcl
deployment_profile = "development"
main_vpc_cidr      = "172.16.0.0/16"
azs                = null
subnet_cidrs       = null
```

For example, compute becomes `172.16.16.0/24` and `172.16.17.0/24`; endpoint-private becomes `172.16.128.0/24` and `172.16.129.0/24`. With production defaults there are 21 subnets. These counts describe default topology, not maximum supported AZ counts.

Changing the VPC CIDR, AZ order, or subnet assignments in an existing deployment is not a non-disruptive migration mechanism. Review replacements and dependent-resource changes in the exact plan. The region assertion and AZ discovery do not prove alternate-region live qualification or provide multi-region disaster recovery. S3 backend region/state-resource `state_region` remain separate from the workload service region.

## Resources Created

### Main VPC

The module creates one VPC:

```hcl
resource "aws_vpc" "main"
```

The VPC uses `var.main_vpc_cidr` and enables both DNS support and DNS hostnames:

```hcl
enable_dns_support   = true
enable_dns_hostnames = true
```

The VPC is tagged with:

```text
Name        = <name_prefix>-Main
Environment = <environment>
Terraform   = true
```

### Subnets

The module creates one subnet per configured Availability Zone for each of the following families:

| Family | Terraform resource | CIDR source | Public IP auto-assignment |
|---|---|---|---|
| Ingress public | `aws_subnet.ingress_public` | `var.subnet_cidrs.ingress_public` | Disabled |
| Egress public | `aws_subnet.egress_public` | `var.subnet_cidrs.egress_public` | Disabled |
| Compute private | `aws_subnet.compute_private` | `var.subnet_cidrs.compute_private` | Disabled |
| Data private | `aws_subnet.data_private` | `var.subnet_cidrs.data_private` | Disabled |
| Serverless private | `aws_subnet.serverless_private` | `var.subnet_cidrs.serverless_private` | Disabled |
| Firewall private | `aws_subnet.firewall_private` | `var.subnet_cidrs.firewall_private` | Disabled |
| Endpoint private | `aws_subnet.endpoint_private` | `var.subnet_cidrs.endpoint_private` | Disabled |

Subnet naming follows these patterns:

```text
<name_prefix>-Ingress-Public-<az>
<name_prefix>-Egress-Public-<az>
<name_prefix>-Compute-Private-<az>
<name_prefix>-Data-Private-<az>
<name_prefix>-Serverless-Private-<az>
<name_prefix>-Firewall-Private-<az>
<name_prefix>-Endpoint-Private-<az>
```

### Internet Gateway

The module always creates one Internet Gateway attached to the VPC:

```hcl
resource "aws_internet_gateway" "igw"
```

The Internet Gateway is named:

```text
<name_prefix>-IGW
```

### NAT Elastic IPs

NAT Elastic IPs are conditional:

```hcl
locals {
  nat_enabled = var.egress_mode != "vpc_endpoints_only"
}
```

When `nat_enabled` is true, the module creates one VPC Elastic IP per configured Availability Zone:

```hcl
resource "aws_eip" "nat"
```

No NAT Elastic IPs are created when:

```text
egress_mode = vpc_endpoints_only
```

### NAT Gateways

When `nat_enabled` is true, the module creates one NAT Gateway per configured Availability Zone:

```hcl
resource "aws_nat_gateway" "natgw"
```

Each NAT Gateway:

- Uses the Elastic IP for the same Availability Zone
- Is placed in the `egress_public` subnet for the same Availability Zone
- Depends on the Internet Gateway

NAT Gateways are therefore created in:

```text
network_firewall
nat_only
```

and are not created in:

```text
vpc_endpoints_only
```

---

## Route Tables and Routing

The module always creates one route table per configured Availability Zone for each subnet family:

```text
ingress_public
egress_public
compute_private
firewall_private
endpoint_private
data_private
serverless_private
```

The routes inside those route tables depend on the subnet family and, for compute/firewall/egress-public paths, the selected `egress_mode`.

### Ingress-Public Route Tables

The module creates one ingress-public route table per Availability Zone:

```hcl
resource "aws_route_table" "ingress_public"
```

Every ingress-public route table has exactly the normal Internet Gateway default path:

```text
0.0.0.0/0 -> Internet Gateway
```

Each route table is associated with the `ingress_public` subnet in the same Availability Zone.

The module does **not** add explicit compute-private routes to ingress-public route tables. ALB-to-ECS traffic therefore uses VPC-local routing rather than being redirected through Network Firewall.

### Egress-Public Route Tables

The module creates one egress-public route table per Availability Zone:

```hcl
resource "aws_route_table" "egress_public"
```

Every egress-public route table has a default route to the Internet Gateway and is associated with the same-AZ `egress_public` subnet that hosts the NAT Gateway:

```text
0.0.0.0/0 -> Internet Gateway
```

When `egress_mode = "network_firewall"`, the route table also contains exactly one same-AZ return route for the corresponding compute-private CIDR:

```text
<compute-private CIDR for AZ> -> Network Firewall endpoint for AZ
```

That return route is defined inside `aws_route_table.egress_public` and has a lifecycle precondition requiring `var.firewall_endpoint_ids_by_az` to contain an endpoint ID for the Availability Zone.

In `nat_only` and `vpc_endpoints_only`, no explicit compute-private return route is added to `egress_public`.

### Compute-Private Route Tables

The module creates one compute-private route table per Availability Zone:

```hcl
resource "aws_route_table" "compute_private"
```

Each route table is associated with the compute-private subnet in the same Availability Zone.

Default routing is mode-specific:

| `egress_mode` | Compute-private `0.0.0.0/0` route |
|---|---|
| `network_firewall` | Network Firewall endpoint in the same AZ |
| `nat_only` | NAT Gateway in the same AZ |
| `vpc_endpoints_only` | No default route |

#### `network_firewall`

The module creates:

```hcl
resource "aws_route" "compute_default_to_firewall"
```

which routes:

```text
0.0.0.0/0 -> Network Firewall endpoint for AZ
```

This resource also has a lifecycle precondition requiring `var.firewall_endpoint_ids_by_az` to contain an endpoint ID for every configured Availability Zone.

#### `nat_only`

The module creates:

```hcl
resource "aws_route" "compute_default_to_nat"
```

which routes:

```text
0.0.0.0/0 -> NAT Gateway for AZ
```

#### `vpc_endpoints_only`

Neither compute default-route resource is created, so the compute-private route table has no `0.0.0.0/0` route from this module.

### Firewall-Private Route Tables

The module creates one firewall-private route table per Availability Zone:

```hcl
resource "aws_route_table" "firewall_private"
```

Each route table is associated with the firewall-private subnet in the same Availability Zone.

Only `network_firewall` mode adds a default route:

```hcl
resource "aws_route" "firewall_private"
```

The route is:

```text
0.0.0.0/0 -> NAT Gateway for AZ
```

In `nat_only` and `vpc_endpoints_only`, the firewall-private route tables still exist, but this module does not add a default route to them.

### Endpoint-Private Route Tables

The module creates one endpoint-private route table per Availability Zone:

```hcl
resource "aws_route_table" "endpoint_private"
```

Each route table is associated with the endpoint-private subnet in the same Availability Zone.

This module does not add a default internet route to endpoint-private route tables.

### Data-Private Route Tables

The module creates one data-private route table per Availability Zone:

```hcl
resource "aws_route_table" "data_private"
```

Each route table is associated with the data-private subnet in the same Availability Zone.

This module does not add a default internet route to data-private route tables.

### Serverless-Private Route Tables

The module creates one serverless-private route table per Availability Zone:

```hcl
resource "aws_route_table" "serverless_private"
```

Each route table is associated with the serverless-private subnet in the same Availability Zone.

This module does not add a default internet route to serverless-private route tables.

---

## Egress Modes

### `network_firewall`

The inspected egress and return paths remain same-AZ and symmetric:

```text
Outbound:

Compute-private subnet
    |
    v
Compute-private route table
    |
    | 0.0.0.0/0
    v
same-AZ Network Firewall endpoint
    |
    v
Firewall-private route table
    |
    | 0.0.0.0/0
    v
same-AZ NAT Gateway in egress_public
    |
    v
Egress-public route table
    |
    | 0.0.0.0/0
    v
Internet Gateway

Return:

Internet Gateway
    |
    v
same-AZ NAT Gateway in egress_public
    |
    v
Egress-public route table
    |
    | compute-private CIDR
    v
same-AZ Network Firewall endpoint
    |
    v
Compute-private subnet
```

The separate ALB ingress path does not enter this stateful egress path:

```text
Internet Gateway
    |
    v
Ingress-public subnet / route table
    |
    v
Application Load Balancer
    |
    v
VPC-local routing
    |
    v
Compute-private target
```

`firewall_endpoint_ids_by_az` must contain a Network Firewall endpoint ID for every configured Availability Zone.

### `nat_only`

Resources and routes created by this module:

```text
Egress-public subnet
    |
    +-- NAT Gateway
    |
    +-- Egress-public route table
            |
            +-- 0.0.0.0/0 -> Internet Gateway

Ingress-public subnet
    |
    +-- Ingress-public route table
            |
            +-- 0.0.0.0/0 -> Internet Gateway

Compute-private subnet
    |
    +-- Compute-private route table
            |
            +-- 0.0.0.0/0 -> same-AZ NAT Gateway
```

No Network Firewall route resources are created, and neither public route-table family contains an explicit compute-private-to-firewall route.

### `vpc_endpoints_only`

In this mode:

- NAT Elastic IPs are not created
- NAT Gateways are not created
- Compute-private route tables receive no default route
- Firewall-private route tables receive no default route
- Network Firewall route resources are not created
- Ingress-public and egress-public route tables still exist and retain their `0.0.0.0/0 -> Internet Gateway` routes
- Neither public route-table family contains an explicit compute-private return route
- Endpoint-private, data-private, and serverless-private route tables continue to have no default internet route from this module

---

## Inputs

| Name | Type | Default | Required | Description |
|---|---|---|---:|---|
| `name_prefix` | `string` | none | Yes | Prefix used in resource names and tags. |
| `main_vpc_cidr` | `string` | none | Yes | CIDR block assigned to the main VPC. |
| `environment` | `string` | none | Yes | Environment value applied to resource tags. |
| `cloud_name` | `string` | none | Yes | Declared module input. The RC1 `main.tf` and `outputs.tf` do not currently reference this value. |
| `azs` | `list(string)` | none | Yes | Availability Zones used to create per-AZ subnets, route tables, NAT resources, and route associations. |
| `subnet_cidrs` | `map(list(string))` | none | Yes | CIDR lists for each subnet tier, indexed according to `azs`. |
| `firewall_endpoint_ids_by_az` | `map(string)` | `{}` | Conditional | Network Firewall endpoint IDs keyed by Availability Zone. Required for every configured AZ when `egress_mode = "network_firewall"`. |
| `egress_mode` | `string` | none | Yes | Selects `network_firewall`, `nat_only`, or `vpc_endpoints_only` routing behavior. |

### `egress_mode` Validation

The variable accepts exactly:

```text
network_firewall
nat_only
vpc_endpoints_only
```

Any other value fails Terraform variable validation.

### `subnet_cidrs` Structure

`main.tf` directly references these keys:

```text
ingress_public
egress_public
compute_private
data_private
serverless_private
firewall_private
endpoint_private
```

A representative two-AZ non-production structure is:

```hcl
subnet_cidrs = {
  egress_public      = ["10.0.0.0/24", "10.0.1.0/24"]
  ingress_public     = ["10.0.2.0/24", "10.0.3.0/24"]
  compute_private    = ["10.0.16.0/24", "10.0.17.0/24"]
  data_private       = ["10.0.32.0/24", "10.0.33.0/24"]
  serverless_private = ["10.0.48.0/24", "10.0.49.0/24"]
  firewall_private   = ["10.0.64.0/24", "10.0.65.0/24"]
  endpoint_private   = ["10.0.128.0/24", "10.0.129.0/24"]
}
```

Those CIDRs illustrate `main_vpc_cidr = "10.0.0.0/16"`; they are not hard-coded defaults in this module. Baseline derives each default /24 with `cidrsubnet(var.main_vpc_cidr, 8, netnum)` and passes the resolved lists here. The production defaults use three AZs; for the example /16, `egress_public` is `10.0.0.0/24` through `10.0.2.0/24`, while `ingress_public` is `10.0.3.0/24` through `10.0.5.0/24`.

The module does not declare a variable-validation block for the map keys or list lengths. Because `main.tf` indexes each list using the AZ index, missing keys or insufficient CIDR entries will fail when Terraform evaluates the corresponding resource expressions.

### `firewall_endpoint_ids_by_az`

For `network_firewall` mode, the expected shape is:

```hcl
firewall_endpoint_ids_by_az = {
  "us-east-1a" = "vpce-..."
  "us-east-1b" = "vpce-..."
}
```

Both Network Firewall-dependent routing paths enforce a precondition that the map contain the current Availability Zone key.

For `nat_only` and `vpc_endpoints_only`, the default empty map is valid because those route resources are not created.

---

## Outputs

### VPC and Internet Gateway

| Output | Value |
|---|---|
| `vpc_id` | Main VPC ID |
| `main_vpc_cidr` | Resource-backed main VPC IPv4 CIDR |
| `internet_gateway_id` | Internet Gateway ID |

### NAT Gateway Outputs

| Output | Value |
|---|---|
| `nat_gateway_ids_map` | Map of NAT Gateway IDs keyed by Availability Zone |

`nat_gateway_ids_map` is empty when `egress_mode = "vpc_endpoints_only"` because no NAT Gateways are created.

### Subnet Map Outputs

| Output | Value |
|---|---|
| `subnet_cidrs_by_az` | Resource-backed subnet CIDRs keyed by family and AZ |
| `ingress_public_subnet_ids_map` | Ingress-public subnet IDs keyed by AZ |
| `egress_public_subnet_ids_map` | Egress-public subnet IDs keyed by AZ |
| `compute_private_subnet_ids_map` | Compute-private subnet IDs keyed by AZ |
| `data_private_subnet_ids_map` | Data-private subnet IDs keyed by AZ |
| `serverless_private_subnet_ids_map` | Serverless-private subnet IDs keyed by AZ |
| `firewall_private_subnet_ids_map` | Firewall-private subnet IDs keyed by AZ |
| `endpoint_private_subnet_ids_map` | Endpoint-private subnet IDs keyed by AZ |

### Subnet List Outputs

| Output | Value |
|---|---|
| `ingress_public_subnet_ids_list` | List of ingress-public subnet IDs |
| `compute_private_subnet_ids_list` | List of compute-private subnet IDs |
| `data_private_subnet_ids_list` | List of data-private subnet IDs |
| `serverless_private_subnet_ids_list` | List of serverless-private subnet IDs |

Use the map outputs when Availability Zone identity matters. The list outputs are intended for consumers that require `list(string)` rather than an AZ-keyed map.

### Route Table Outputs

| Output | Value |
|---|---|
| `compute_private_route_table_ids_map` | Compute-private route table IDs keyed by AZ |
| `serverless_private_route_table_ids_map` | Serverless-private route table IDs keyed by AZ |
| `endpoint_private_route_table_ids_map` | Endpoint-private route table IDs keyed by AZ |

The module does not currently export ingress-public, egress-public, data-private, or firewall-private route table IDs.

---

## Resource Naming

The module uses `name_prefix` and Availability Zone names for resource tags.

| Resource | `Name` tag pattern |
|---|---|
| VPC | `<name_prefix>-Main` |
| Ingress-public subnet | `<name_prefix>-Ingress-Public-<az>` |
| Egress-public subnet | `<name_prefix>-Egress-Public-<az>` |
| Compute-private subnet | `<name_prefix>-Compute-Private-<az>` |
| Data-private subnet | `<name_prefix>-Data-Private-<az>` |
| Serverless-private subnet | `<name_prefix>-Serverless-Private-<az>` |
| Firewall-private subnet | `<name_prefix>-Firewall-Private-<az>` |
| Endpoint-private subnet | `<name_prefix>-Endpoint-Private-<az>` |
| Internet Gateway | `<name_prefix>-IGW` |
| NAT Elastic IP | `<name_prefix>-NAT-EIP-<az>` |
| NAT Gateway | `<name_prefix>-NAT-Gateway-<az>` |
| Ingress-public route table | `<name_prefix>-Ingress-Public-RT-<az>` |
| Egress-public route table | `<name_prefix>-Egress-Public-RT-<az>` |
| Compute-private route table | `<name_prefix>-Compute-Private-RT-<az>` |
| Firewall-private route table | `<name_prefix>-Firewall-Private-RT-<az>` |
| Endpoint-private route table | `<name_prefix>-Endpoint-Private-RT-<az>` |
| Data-private route table | `<name_prefix>-Data-Private-RT-<az>` |
| Serverless-private route table | `<name_prefix>-Serverless-Private-RT-<az>` |

All resources that support the shared tagging pattern also receive:

```text
Environment = <environment>
Terraform   = true
```

---

## Security Policy Submodule

The repository contains:

```text
modules/networking/security_policy/
```

That submodule is responsible for security-group policy and is intentionally separate from the VPC/subnet/routing resources documented here.

Its detailed inputs, outputs, security-group rules, and dependency behavior should be documented in:

```text
modules/networking/security_policy/README.md
```

---

## Operational Invariants

The current parent module enforces or establishes the following behavior:

- VPC DNS support and DNS hostnames are enabled.
- All seven subnet families disable automatic public IP assignment.
- Ingress-public and egress-public route tables always route `0.0.0.0/0` to the Terraform-owned Internet Gateway.
- Ingress-public route tables do not contain explicit compute-private routes; ALB-to-private-target traffic remains VPC-local.
- NAT Elastic IPs and NAT Gateways exist only when `egress_mode` is not `vpc_endpoints_only`.
- Every NAT Gateway is placed in the `egress_public` subnet for the same Availability Zone.
- `network_firewall` routes compute-private default traffic to per-AZ firewall endpoints and firewall-private default traffic to per-AZ NAT Gateways.
- `network_firewall` installs the corresponding per-AZ compute-private return route only on the same-AZ `egress_public` route table.
- `nat_only` routes compute-private default traffic directly to the per-AZ NAT Gateway and adds no public compute-return override.
- `vpc_endpoints_only` gives compute-private route tables no default route from this module.
- Endpoint-private, data-private, and serverless-private route tables receive no default internet route from this module.
- Network Firewall endpoint mappings fail closed in `network_firewall` mode if an expected Availability Zone key is missing.

---

## Notes

- `firewall_endpoint_ids_by_az` is conditionally required only for `network_firewall`.
- NAT infrastructure is conditional; it is not created in `vpc_endpoints_only`.
- The parent module always creates ingress-public, egress-public, compute-private, firewall-private, endpoint-private, data-private, and serverless-private route tables even when some of them have no default route.
- The parent module does not create Network Firewall endpoints; it consumes their IDs when firewall routing is selected.
- The parent module does not define the `security_policy` submodule's security-group rules.
- `cloud_name` is currently a required declared input but is not referenced by the parent-module resource or output definitions.

## Validation and Sources

`validate-networking.sh` uses the workload-root `network_topology` output rather than assuming `10.0.x.0/24` or `us-east-1a/b/c`. Its live checks include VPC CIDR, the exact seven-family subnet ID/CIDR inventory, route-table associations, NAT placement, same-AZ firewall/return routes, and the separate ingress-public path. `validate-vpc-endpoints.sh` and `validate-ecs-runtime.sh` check downstream endpoint and ALB/task placement.

These checks compare configuration and live state; they do not execute a cross-region recovery exercise or prove application data-plane behavior. Read-only validation is separate from applying a changed CIDR or migrating an existing environment.

Implementation references: [resources](main.tf), [inputs](variables.tf), [outputs](outputs.tf), [baseline input validations](../../baseline/variables.tf), [baseline defaults](../../baseline/locals.tf), and [networking validator](../../scripts/validation/validate-networking.sh).
