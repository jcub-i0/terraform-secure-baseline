# Adoption Guide - tf-secure-baseline

## Purpose

This guide helps teams determine when and how to adopt `tf-secure-baseline`.

It explains:

- Who this baseline is designed for
- What problems it helps solve
- What maturity level it assumes
- How teams should customize it
- What should be completed before production use
- What this baseline does and does not provide

For deployment instructions, see the [quickstart](quickstart.md). For system
structure, see the [architecture overview](architecture-overview.md). This guide
is a decision and acceptance aid, not a substitute for those procedures or an
executed qualification report.

---

## Authorization to Adopt

Read [LICENSE](../LICENSE) before copying, modifying, deploying, redistributing,
or providing services derived from the repository. The license supplies no
general deployment or consulting permission; those uses require the authorization
described there, including any applicable separate written agreement. Public
visibility and the examples below are not a grant of use rights.

This guide addresses technical planning for authorized adopters. It does not
change license terms, resolve inconsistent ownership notices, grant rights in
third-party dependencies, or promise support, security, availability, compliance,
or suitability. Confirm authorized scope, maintenance/support responsibilities,
and ownership of client-specific changes in the relevant agreement.

---

## Intended Audience

`tf-secure-baseline` is designed for teams that need a secure AWS foundation without building every control from scratch.

It is especially useful for:

- SaaS companies handling customer PII
- Startups preparing for SOC 2 or ISO 27001
- Small and mid-sized engineering teams
- Cloud security teams building reusable AWS patterns
- Platform teams standardizing environment deployments
- Consultants implementing secure AWS foundations for clients

The baseline is opinionated, but it is intended to be adaptable.

---

## When to Use This Baseline

Use this baseline when your AWS environment needs:

- Multi-account environment separation
- Private-by-default infrastructure
- Centralized logging
- Continuous monitoring
- IAM Identity Center-based human access
- GitHub OIDC-based CI/CD access
- Centralized Security Hub CSPM and GuardDuty governance
- Security Hub V2 workload policy governance
- AWS Config posture monitoring
- Event-driven incident response
- Automated EC2 isolation
- Event-driven rollback with separately reviewed authorization and approval boundaries
- IP threat enrichment
- Tamper detection
- Break-glass monitoring
- Backup and patch management foundations
- Configurable cost/security profiles
- Configurable egress behavior
- Private AWS service access through dedicated VPC endpoint subnets

This project is most appropriate when the environment is expected to host persistent workloads that handle sensitive data or support production-like systems.

---

## Target Use Cases

### SaaS Application Environments

This baseline is well suited for SaaS applications that process or store sensitive customer data.

Examples:

- Customer portals
- Internal admin applications
- APIs handling PII
- Data processing services
- Tenant-facing workloads
- Backend services supporting regulated workflows

---

### SOC 2 / ISO 27001 Readiness

This baseline can support evidence collection and technical control implementation for areas such as:

- Access control
- Logging and monitoring
- Change management
- Encryption
- Incident response
- Vulnerability management
- Backup and recovery
- Infrastructure security
- Network segmentation
- Controlled egress

It does **not** guarantee compliance or certification by itself.

Policies, procedures, human review, vendor management, risk management, and audit evidence are still required.

---

### Consulting and Client Deployments

Subject to the required written authorization, the baseline can serve as an implementation foundation for client environments.

It provides a repeatable structure for:

- Account and OU separation
- Terraform state management
- GitHub OIDC setup
- Centralized identity
- Delegated security administration
- Logging
- Detection
- Response automation
- Deployment profile selection
- Egress mode selection
- Private AWS service connectivity

Authorized customization can adapt modules, naming, recipients, Regions, and service settings. Verify which options are actually exposed by the selected root: a child-module input is not automatically an environment-root input. Changes to ownership, backend coordinates, topology, or access policy require separate planning and qualification.

---

## Problems This Helps Solve

This baseline helps address common AWS security and operational problems, including:

- Workloads deployed with public IPs by default
- Flat single-account AWS environments
- Lack of environment separation
- Long-lived CI/CD access keys
- Terraform applies approved before a reviewable plan exists
- Weak or inconsistent logging
- No centralized detection or security-administration layer
- Inconsistent Security Hub / GuardDuty / Config coverage
- Limited incident containment capability
- Manual and inconsistent incident response
- Lack of tamper detection
- No defined rollback mechanism or reviewed recovery procedure
- Poor visibility into break-glass access
- Unclear Terraform state ownership
- Long-lived bootstrap state stored only on an operator workstation
- Terraform stacks destroying their own execution roles
- IAM policy delete conflicts caused by unmanaged dependencies
- Unrestricted outbound access through NAT Gateway
- Unclear cost/security tradeoffs between environments
- VPC endpoint ENIs competing with workload ENIs in compute subnets

---

## What This Baseline Provides

The repository configures the following AWS infrastructure mechanisms. Their presence is not automatic production acceptance:

- Multi-account architecture with dedicated `control-plane`, `security-operations`, `dev`, `staging`, and `prod` accounts
- Control-plane and delegated security-administration separation
- Environment-specific, encrypted remote Terraform state with S3 native locking
- GitHub OIDC CI/CD roles
- Plan-before-apply deployment workflows with protected approvals and exact saved-plan application
- IAM Identity Center groups and permission sets
- Private VPC networking
- Deployment profiles
- Configurable egress modes
- AWS Network Firewall egress inspection, when enabled
- NAT Gateway egress, when required
- Dedicated private subnets for Interface VPC Endpoints
- VPC endpoints
- A preferred ECS/Fargate application runtime with one shared cluster per environment
- KMS-encrypted ECR repositories, digest-pinned task definitions, per-service IAM/task SGs, optional target-tracking ECS Service Auto Scaling, configurable deployment health, and an optional shared HTTPS ALB
- Workload-local centralized log storage with explicit retention/destruction limits
- KMS-backed encryption
- CloudTrail
- AWS Config, when enabled
- Centralized GuardDuty organization administration and Runtime Monitoring
- Centralized Security Hub CSPM configuration and workload policy associations
- Security Hub V2 organization policy governance for the `Workloads` OU
- Inspector, when enabled
- EventBridge rules
- SNS alerts
- EC2 isolation automation
- EC2 rollback mechanism with recorded authorization and partial-failure limitations
- IP enrichment workflow
- Tamper detection
- Break-glass monitoring
- AWS Backup, when enabled
- SSM Patch Manager

**Resource footprint:** [Baseline composition](../baseline/main.tf) creates the
EC2 and RDS modules independently of ECS service deployment. EC2 creates one
standalone instance per compute-subnet map entry; RDS is not optional in this
composition. Registering no deployable ECS services does not create an empty,
free, or database-free environment. It also does not remove the shared ECS
cluster, endpoint resources, keys, logging, or other unconditional controls.
Inspect the selected plan rather than inferring the resource inventory from
`image_digest = null` or a profile name.

---

## What This Baseline Does Not Provide

This baseline is not a complete security program by itself.

It does **not** provide:

- Guaranteed SOC 2 or ISO 27001 certification
- 24/7 SOC monitoring
- Managed incident response
- Full enterprise landing zone functionality or safe adoption of every existing organization
- Account vending automation
- Complete SCP strategy
- Application-layer zero trust
- Service mesh
- Full SIEM integration
- Threat hunting operations
- Secure SDLC process
- Application vulnerability scanning
- Vendor risk management
- Business continuity planning
- Human policy enforcement
- General internet access in `vpc_endpoints_only` mode
- Cross-Region failover, Aurora, or RDS Multi-AZ DB clusters
- An Auto Scaling Group or supplied application recovery mechanism for EC2
- First-class scheduled/bounded Fargate jobs, application sidecar definitions, or a general application task-permission interface
- Immutable log retention, guaranteed key preservation, or an independent fallback alert channel
- An authenticated ticket/approval engine inside the rollback handler
- Private connectivity to AWS services that do not have configured VPC endpoints

It provides technical cloud security foundations that should be paired with organizational controls and operational processes.

---

## Baseline, Not One-Size-Fits-All

`tf-secure-baseline` is intended to be a **secure starting point**, not a universal product that fits every organization without changes.

It provides opinionated defaults for common SaaS security needs, but every organization should review and adapt the baseline based on:

- Application architecture
- Data sensitivity
- Compliance requirements
- Network requirements
- Existing identity model
- CI/CD tooling
- Budget constraints
- Operational maturity
- Required egress behavior
- Required AWS service endpoint coverage

The goal is to provide a strong foundation that teams can safely extend, not to replace environment-specific design decisions.

---

## Deployment Profiles and Egress Modes

The baseline supports deployment profiles that set environment-appropriate defaults.

| `deployment_profile` | Default `egress_mode` | AWS Config | Backup | Inspector | CloudWatch retention | Intended use |
|---|---|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled by default | Enabled | 90 days | Production resilience policy; separate readiness review required |
| `development` | `nat_only` | Enabled | Disabled | Enabled | 30 days | Lower-cost development and testing |
| `minimal` | `vpc_endpoints_only` | Recording disabled | Scheduling disabled | Disabled | 14 days | Reduced-service AWS-private testing; retained resources still incur cost |

The `egress_mode` controls private compute subnet outbound routing.

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route |
|---|---:|---:|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint |
| `nat_only` | No | Yes | NAT Gateway |
| `vpc_endpoints_only` | No | No | No default route |

When `egress_mode = "auto"`, the effective egress mode is selected from the `deployment_profile`.

Profiles combine **defaults and enforced constraints**. Production requires at
least three standard AZs and RDS Multi-AZ. AWS Backup is enabled by default,
but `backup_enabled=false` is an explicit supported override at baseline resolution;
it also disables profile-derived Restore Testing. Record the intended backup and
recovery policy separately rather than calling the default an enforced prohibition.
In normal operation, deployable
production ECS services require at least two fixed tasks or an autoscaling minimum
of two, with AZ rebalancing enabled. Normal production enables RDS/ALB/Network
Firewall deletion protection; ECR, ECS service, and backup-vault force deletion
remain disabled even in retirement. Do not treat these as freely removable
cost defaults.

Other settings can have supported overrides, but only where the selected root
actually exposes and forwards them. The tables describe automatic choices, not
an assurance that every override passes Terraform and runtime validation. Read
[profile resolution](../baseline/locals.tf), [input constraints](../baseline/variables.tf),
and the selected environment root together.

Example:

```hcl
deployment_profile = "development"
egress_mode        = "network_firewall"
```

This allows a development environment to use production-style Network Firewall inspection when required.

Important:

When `egress_mode = "vpc_endpoints_only"`, NAT Gateways and Network Firewall are not deployed, and private compute subnets do not receive a default internet route. This mode is intended for AWS-private testing or workloads that do not require external package repositories, public container registries, third-party APIs, or general internet access.

A disabled Config setting retains recorder/channel resources while stopping
recording and omitting rules/remediation; disabled scheduled Backup retains its
vault. A minimal profile does not disable every central security service or
remove the RDS/EC2 footprint. Endpoint-only access also does not make the supplied
first-boot Ubuntu package upgrade succeed without a reachable package source.

Production resilience follows `deployment_profile`, not simply the environment
directory. However, the complete approved durable-cleanup workflow is `prod`-only.
A production-profile staging environment therefore needs its own reviewed lifecycle
plan; do not assume the full production Destroy path supports that environment.

---

## Adoption Maturity

### Good Fit

This baseline is a good fit if your team:

- Has or plans to have multiple AWS accounts
- Uses Terraform or wants to standardize on Terraform
- Uses GitHub Actions or wants OIDC-based CI/CD
- Needs secure defaults for AWS infrastructure
- Wants centralized access through IAM Identity Center
- Needs better logging, detection, and response
- Is preparing for audit or customer security review
- Wants clear cost/security profiles for dev, staging, and prod
- Has named operational owners and sufficient AWS/Terraform/security expertise to review IAM, recovery, networking, state, and incident-response behavior
- Can use the implemented long-lived Linux ECS/Fargate pattern and has reviewed the standalone EC2 and RDS resources that are still created

---

### Possible Fit with Customization

This baseline may still work, but will require more customization if your team:

- Uses GitLab, Azure DevOps, or another CI/CD system
- Uses a different identity provider model
- Needs different region or naming conventions
- Already has a central networking account
- Already has a SIEM/logging pipeline
- Requires multi-region failover
- Uses Kubernetes or another container orchestrator instead of the implemented ECS/Fargate runtime
- Requires a different centralized security-services ownership model
- Requires custom egress paths or proxy-based internet access
- Requires additional VPC endpoints beyond the default endpoint set

---

### Poor Fit

This baseline may not be appropriate if your environment is:

- Fully air-gapped
- Extremely short-lived or experimental
- Not intended to host persistent workloads
- Already managed by a mature enterprise landing zone
- Required to follow a very different internal cloud operating model
- Optimized primarily for lowest possible AWS cost
- Designed for hyperscale workloads out of the box
- Dependent on broad unrestricted outbound internet access from private workloads

---

## Recommended Adoption Path

Adopt the baseline in stages.

Separate mandatory pre-deployment decisions from later extensions. Licensing,
account/backend identity, approved Regions/CIDRs, credentials, recipients,
automatic-response policy, and destructive-lifecycle requirements must be resolved
before the first Apply. Use a dedicated development deployment for evaluation;
do not postpone those decisions until after resources and responders exist.

---

## Phase 1 - Review Architecture

Start by reviewing:

```text
docs/architecture-overview.md
docs/design-principles.md
docs/quickstart.md
```

Confirm that the model aligns with your intended AWS account strategy.

Key decisions:

- Will you use `dev`, `staging`, and `prod` workload accounts?
- Will you use separate `control-plane` and `security-operations` accounts?
- Will the `security-operations` account be the delegated administrator for centralized Security Hub and GuardDuty?
- Will GitHub Actions manage Terraform?
- Will IAM Identity Center be used for human access?
- Which AWS region will be primary?
- Who receives security notifications?
- Which deployment profile should each environment use?
- Which egress mode should each environment use?
- Will the workload use EC2, ECS/Fargate, or both?
- Which immutable ECR digest, fixed-versus-autoscaled capacity model, target-tracking metrics, deployment-health settings, and optional ALB ingress rules will each ECS service use?

### Terraform Variable Templates

The repository provides tracked `terraform.tfvars.example` templates. Copy a
reviewed template only when the destination input file does not already exist;
never overwrite an established deployment's values. Replace example identities
and keep local sensitive inputs out of Git. CI/CD variables and secrets must
match the selected root and workflow input contract.

The canonical `environments/<env>/container-workloads.auto.tfvars.json` files are
an intentional **tracked** workload-definition input, not disposable local secret
files. They contain service configuration and selected digests; do not put secret
values into them. Follow the [deployment reference](../scripts/deployment/README.md)
for release mutation and secret-reference boundaries.

### Required Technical Decisions Before Apply

Review the [quickstart](quickstart.md), [IAM reference](../modules/iam/README.md),
[automation reference](../modules/automation/README.md), and
[retirement runbook](production-retirement.md) before using live data.

| Decision | Implementation boundary to review |
|---|---|
| Privileged access | Apply attaches `AdministratorAccess`; Plan can write state and read selected secrets. Environment subjects do not themselves configure GitHub reviewers or branch restrictions. |
| Human recovery access | Operator's unprefixed bus ARN differs from the created prefixed bus; the bus has a wildcard-principal source allow. Approver/ticket payload fields are not authenticated. |
| Automatic isolation | All three supplied workload roots default `isolation_allowed` to true; reusable compute defaults false. Choose explicitly before deployment and verify the live tags. |
| Retention and exit | Logs have Object Lock disabled and allow force destruction; workload keys lack production destruction guards. Decide how required records and usable keys survive approved teardown. |
| Remediation | Config's separate S3 automatic remediation follows `enable_config`, not the S3 family toggle, and is not scoped by workload prefix/tag. |
| Application fit | Task IAM scaffolding, private networking and RDS do not implement tenant isolation, migrations, background-job orchestration, or application-specific restore validation. |

These are implementation limitations or explicit design decisions, not items
cleared by this guide. Assign owners and record remediation or risk decisions
before making production-suitability claims.

---

## Phase 2 - Prepare AWS Accounts

Create or identify the required AWS accounts:

```text
control-plane
security-operations
dev
staging
prod
```

The control-plane account should manage:

- AWS Organizations
- IAM Identity Center
- Control-plane Terraform state and GitHub OIDC roles
- Organization-level prerequisites for delegated Security Hub, GuardDuty, and Security Hub V2 governance

The security-operations account should host:

- its own Terraform state and GitHub OIDC roles
- delegated Security Hub CSPM administration
- delegated GuardDuty administration and organization protection-plan configuration
- Security Hub V2 administrator-side configuration and workload organization policy management

Workload accounts should host:

- Dev, staging, and prod baseline infrastructure and workload GitHub OIDC resources
- workload-local Config, Inspector, logging, remediation, and response automation
- workload-local ECR, ECS/Fargate, ALB, IAM, and security-policy resources configured through the canonical `ecs_services` map

Existing organizations are not adopted safely merely by selecting familiar
account names. Inventory existing Organizations policy types, delegated service
administrators, Identity Center, service-linked roles, Config recorder/channel,
security services, and backend resources. Review import/ownership changes and
potential whole-policy replacement before Apply; the repository does not vend
accounts or automatically reconcile arbitrary existing landing zones.

Identity Center must already be available to discovery. Central security-services
configuration discovers a GuardDuty detector rather than creating it there.
Follow the [administrative root procedures](../bootstrap/control_plane/README.md)
and [security-operations procedures](../bootstrap/security_operations/README.md).
A Terraform `check` warning is not a blocking account safeguard; independently
verify the intended caller and inputs.

---

## Phase 3 - Choose Deployment Profiles

Before deploying each environment, choose the deployment profile and egress behavior.

Recommended starting point:

| Environment | Recommended `deployment_profile` | Recommended `egress_mode` |
|---|---|---|
| `dev` | `development` | `auto` |
| `staging` | `development` or `production` | `auto` |
| `prod` | `production` | `auto` |

For early testing, deploy `dev` first with:

```hcl
deployment_profile = "development"
egress_mode        = "auto"
```

This provides a lower-cost development environment while keeping key detection and posture services enabled.

Use `production` for workloads that need the full security baseline, including Network Firewall egress inspection and backup by default.

Use `minimal` only when the lack of general internet access is acceptable.

Confirm expected topology and lifecycle as well as service flags. The canonical
VPC input is an IPv4 `/16`; default `/24` subnets span all seven families. Default
AZ selection uses sorted standard AZs in the service Region. Explicit AZ counts
beyond the profile default require a complete compatible subnet map; additional
AZs are not obtained by changing one count alone.

Review address overlap, quotas, actual AZ names in the target account, service
support, required endpoints, firewall domains, and recovery costs. A Region input
or multi-Region trail is not proof of deployment qualification in another Region
or a multi-Region recovery design.

---

## Phase 4 - Deploy the Baseline

Follow `docs/quickstart.md` for the full deployment sequence. At a high level: bootstrap/control-plane and security-operations foundations first, then workload state/account stacks, then workload environments, reconciliation, Identity Center, and the four validation/evidence layers.

For ECS/Fargate applications, register each service in the tracked canonical `environments/<env>/container-workloads.auto.tfvars.json`. A new service may use `image_digest = null` so Terraform can create/retain its required ECR repository without creating the runtime before an image exists.

For services that need elastic capacity, configure the canonical `scaling` object rather than maintaining a second scaling inventory. `scaling = null` keeps Terraform ownership of `desired_count`; a non-null object makes `desired_count` bootstrap capacity and hands subsequent runtime count ownership to Application Auto Scaling within the configured bounds. CPU, memory, and conditional ALB request-count target tracking are supported.

Application release then follows the implemented workflow:

```text
registered service
  -> Deploy Application
  -> branch-trusted Image Publisher role builds/pushes image
  -> authoritative ECR digest
  -> separate GitHub-only release job updates one digest
  -> release PR
  -> human review/merge
  -> separate protected Terraform Apply
  -> ECS convergence
  -> separate validation/evidence
```

Terraform does not build or push images. `Deploy Application` does not automatically merge the release PR, invoke Terraform Apply, or run evidence. This separation keeps application artifact publication, source-control mutation, infrastructure approval, and validation independently reviewable.

Deploy `dev` first and prove the full path before extending the same service/application configuration to staging or production.

### Tooling, Inputs, and Application Boundaries

Use the Terraform CLI selection declared by the relevant workflows and the
committed lockfile for each root; do not silently upgrade providers to make a
plan succeed. Use AWS CLI commands supported by the repository's workflows,
Bash and `jq`, plus Docker and the ECR credential helper for image publication.
See the [bootstrap reference](../scripts/bootstrap/README.md) and
[deployment reference](../scripts/deployment/README.md) for exact prerequisites.

Deploy from `environments/<env>`, not directly from the reusable `baseline/`
directory. Initialize the correct reviewed backend and apply the same effective
inputs used in planning. Changing `cloud_name` or an IAM state-bucket ARN does not
rewrite literal backend bucket/key/Region coordinates.

Application log groups, execution/task roles, and networking materialize for a
non-null digest, but application task roles initially have no application policy.
Execution-role secret/KMS permissions concern task startup, not automatic runtime
application access. The optional ALB frontend is HTTPS and its target-group path
is HTTP; database/application TLS, migrations, least-privilege database access,
tenant isolation, application observability and recovery need separate design.

A digest is an image selector, not evidence of signing, vulnerability acceptance,
application correctness, or immutable runtime behavior. Do not assume scheduled
jobs or sidecars exist because the underlying AWS service supports them.

## Phase 5 - Validate Controls

After deployment, review:

```text
docs/validation-checklist.md
```

Review the Lambda test guides, then run only the explicitly authorized cases on dedicated targets:

```text
docs/lambda_tests/ec2_isolation.md
docs/lambda_tests/ec2_rollback.md
docs/lambda_tests/ip_enrichment.md
```

Do not treat a successful validator suite as production acceptance by itself.
Complete the selected assertion checks, review warnings/skips, and retain the
approved behavioral and application evidence needed for the actual workload.
Direct Lambda tests can modify EC2 security groups, create snapshots, send
notifications, disclose indicators externally, or change Security Hub notes.
They are not an unconditional follow-up to a read-only validation run.

Verify each migrated state stack using the account/Region setup and
`migrate-state-stack.sh --verify-only` procedure in the
[bootstrap reference](../scripts/bootstrap/README.md). Resolve the expected
account independently; do not derive both the expected and actual identities
from the same caller read and call that an account check.

For client-readiness or deployment acceptance evidence, use `REQUIRE_STATE_STACK_REMOTE=true` for direct bootstrap and control-plane validation. The GitHub evidence workflows enforce this by default.

Run the layer-specific evidence paths rather than treating workload validation as proof of central governance:

- **Export Control Plane Evidence** for Organizations topology, account placement, delegated-administrator prerequisites, and Identity Center.
- **Export Security Operations Evidence** for centralized Security Hub CSPM, GuardDuty, and Security Hub V2.
- **Export Bootstrap Evidence** for workload bootstrap/state/OIDC controls.
- **Export Baseline Evidence** for workload-local control realization.

Also confirm:

- Effective deployment profile outputs are correct.
- Effective egress mode resolved as expected.
- Network Firewall and NAT Gateway deployment matches the selected egress mode.
- Dedicated endpoint private subnets exist.
- Terraform manages the `guardduty-data` Interface Endpoint in those endpoint subnets.
- Interface VPC Endpoints are created before EC2 and are deployed into endpoint private subnets.
- S3 Gateway Endpoint is associated with the intended private route tables.
- AWS Config, Backup, Inspector, and CloudWatch retention match the selected profile or explicit overrides.

Use [validation guidance](validation-checklist.md), the
[evidence guide](assurance/validation-evidence-guide.md), and
[report template](assurance/validation-report-template.md). The 16-script workload
suite counts successful exits, not all assertions. An empty ECS service inventory
does not exercise live agent injection or application transactions; an `OK` alarm
with missing data does not establish availability. Exporting baseline evidence
reruns the validators rather than packaging a prior execution.

Record the exact deployment and validation commits, effective inputs and image
digests, account/Region, timestamps, warnings, scope exclusions, actual approvals,
and evidence locations. Earlier qualification retains its original configuration
and provenance. Generated metadata is not a signed custody record or proof that
its static manual-test list reflects work actually performed.

Production recovery acceptance should separately cover live ECS placement and
replacement, RDS failover, completed restore execution, application/data validation,
cleanup, measured recovery objectives, and final convergence. A configured Restore
Testing plan or a backup-validator PASS with warnings is not complete recovery
acceptance. Do not repeatedly disrupt production solely to reproduce an example.

---

## Phase 6 - Customize for Your Organization

After resolving mandatory pre-deployment decisions and completing an authorized evaluation, introduce further customization in reviewed, qualified increments.

Common customization areas include:

- Naming conventions
- State backend bucket names, object keys, regions, and `backend.tf.migrated.example` templates
- AWS regions
- CIDR ranges
- Number of Availability Zones
- Deployment profile per environment
- Egress mode per environment
- SecOps email recipients
- GitHub organization and repository names
- IAM Identity Center groups
- Permission set behavior
- Central Security Hub CSPM policy/standard selection
- GuardDuty organization protection-plan settings
- AWS Config rules
- VPC endpoint coverage
- Canonical `ecs_services` definitions, immutable image digests, scaling/deployment settings, and optional shared-ALB routing
- Backup retention
- Patch windows
- Tags
- KMS key aliases and policies
- Network Firewall rules
- Lambda alert formatting

Check the full input path before choosing an override: environment declaration,
module-call forwarding, baseline resolution/validation, child resource, workflow
propagation, and live validator expectation. Some child controls (such as patch
schedule) are not exposed by the supplied workload roots. A new `TF_VAR_...` alone
does not make an unwired option effective. Avoid ownership changes or profile
switches as a shortcut around protected retirement.

---

## Phase 7 - Production Readiness Review

Before using the baseline for production workloads, review:

- Terraform state protection and successful state-stack migration
- GitHub environment protections
- Required reviewers for prod apply workflows
- IAM Identity Center assignments
- Break-glass access procedure
- SNS subscription confirmation
- CloudTrail logging status
- Security Hub and GuardDuty delegated-administrator state
- Security Hub CSPM workload policy associations
- GuardDuty organization protection plans and Runtime Monitoring
- Security Hub V2 effective workload policy
- Workload-local AWS Config and Inspector status
- Backup policies
- Patch management settings
- Egress mode behavior
- VPC endpoint coverage
- Dedicated endpoint subnet placement
- Cost estimates
- Destruction/cleanup procedure
- Incident response runbooks

Acceptance must include application-specific recovery and transport, actual
privileged rights and human memberships, externally configured GitHub approvals,
notification delivery and shared-failure handling, immutable-record requirements
where applicable, key preservation, and disposition of the implementation limits
identified before Apply. Neither this guide nor a passing infrastructure script
records the organization's approval of those risks.

---

## Configuration Decisions

Before adopting this baseline, answer the following questions:

### Account Strategy

- Will each workload environment use a separate AWS account?
- Which account is the AWS Organizations management account?
- Will `control-plane` and `security-operations` be separate from workload accounts?
- Will `security-operations` be the delegated administrator for centralized Security Hub and GuardDuty?
- Who owns each account?

---

### Terraform State Strategy

- What bucket name will each workload, control-plane, and security-operations state stack use?
- What distinct object key will each Terraform root use?
- Who is authorized through `bucket_admin_principals`?
- Where will migration backups be retained?
- Who is responsible for running and approving state-stack migration?
- Are the tracked `backend.tf.migrated.example` files customized before deployment?
- Is `REQUIRE_STATE_STACK_REMOTE=true` required for release and client evidence?

Distinguish the state-resource Region from each backend's literal Region and
from the workload service Region. Review the complete set of existing keys before
changing any coordinate. Preserve migration backups with the same sensitivity as
state; migration away from a bucket does not remove `prevent_destroy` guards.

---

### Region Strategy

- What is the primary AWS region?
- Are additional regions required?
- Should CloudTrail be multi-region?
- Are disaster recovery requirements regional or multi-region?

`primary_region` governs workload services, `state_region` configures state
resources, and backend `region` identifies state access. Organizations and
Identity Center roots inherit provider context rather than exposing a uniform
`primary_region` interface. Choose and verify administrative context explicitly.
No supplied input turns the baseline into active/active or cross-Region failover.

---

### Identity Strategy

- Who administers IAM Identity Center?
- Which users need workload `SecOps-Operator` access?
- Who receives `SecOps-Administrator` access to the security-operations account?
- Will optional `SecOps-Analyst` and `SecOps-Engineer` roles be enabled for workloads or security-operations?
- Who owns break-glass credentials?
- How is break-glass access reviewed?

Review group membership and assignment principal IDs, not only named resource
presence. Validate the intended Operator bus identity and effective PutEvents
permissions before relying on that persona for recovery. Do not silently use an
administrator as proof that the restricted persona works.

---

### CI/CD Strategy

- Will GitHub Actions manage Terraform and application image publication?
- Which paired Plan/Apply environments are required?
- Who can approve the protected workload Apply environments?
- Is `DEPLOYMENT_PROFILE` configured in every workload Plan path and synchronized with the intended environment posture?
- Which branches may assume each environment's Image Publisher role through `BRANCHES_IMAGE_PUBLISHER_GITHUB`?
- Is the repository configured to allow GitHub Actions to create release pull requests?
- Are Plan, Apply, and Image Publisher AWS authorities separated by IAM role and trust policy?
- Is the release/PR job kept free of AWS credentials while the publisher job is kept free of repository write permission?
- Will application build contexts reside inside the checked-out repository as required by `Deploy Application`?
- Are release PRs reviewed before merge?
- Will workload Apply use its internally generated saved binary plan rather than the standalone Plan workflow output?
- Are exact saved-plan metadata/checksum checks and protected approvals retained?
- Are application deployment and validation/evidence treated as separate post-merge stages?
- Are static AWS keys prohibited for CI/CD?

Plan/Apply role names are not permission limits. Review Plan's state-write/secret
access and Apply's administrator policy. Verify actual GitHub Environment and
branch protections separately from OIDC trust. Keep source-mutation permissions
separate from AWS publication credentials and protect saved-plan artifacts.

### Deployment Profile Strategy

- Which deployment profile should be used for each environment?
- Should `dev` and `staging` use `development` or `production` defaults?
- Should any environment use `minimal`?
- Which profile defaults should be overridden?
- Should AWS Config remain enabled in lower-cost environments?
- Should Backup be enabled outside production?
- Should Inspector be enabled in minimal environments?

Document enforced production invariants and the separate environment-specific
retirement support boundary. Explicitly choose automatic isolation policy; all
supplied environment roots default it to true, and rollback writes true again.

---

### Network Strategy

- What VPC CIDR ranges will be used?
- How many Availability Zones are required?
- What outbound internet access is required?
- Which `egress_mode` should each environment use?
- Is AWS Network Firewall required in all environments?
- Is NAT Gateway required in all environments?
- Is `vpc_endpoints_only` acceptable for any environment?
- Which VPC endpoints are required?
- Are dedicated endpoint subnet CIDRs sized appropriately?
- Are any workloads expected to be publicly reachable?

Plan all seven subnet families from a canonical IPv4 `/16`. Additional AZs require
compatible `/24` family maps. Domain-filtering scope is the inspected compute
path; endpoint permissions and non-VPC Lambda traffic need separate review.
Record ALB frontend/backend and database transport requirements explicitly.

---

### Logging and Monitoring Strategy

- Who receives SecOps alerts?
- Who receives compliance alerts?
- How long should logs be retained?
- Should Object Lock be enabled?
- Which Security Hub CSPM standards and disabled controls should be assigned centrally to each workload?
- Which GuardDuty organization protection plans should be enabled?
- What AWS Config rules are required locally in workload accounts?
- Should findings be exported to an external SIEM?
- Should CloudWatch retention follow deployment profile defaults or explicit overrides?

Object Lock is not enabled by the supplied storage resource and is not a simple
profile toggle. The logs bucket and workload keys have permissive destruction
postures that require a deliberate preservation design. Confirm actual fresh
archival and performed integrity checks, not only metadata.

No supplied queue consumer, SNS subscription DLQ, or independent fallback alert
channel completes the notification path. Assign queue/recipient operations and
coverage-gap handling before treating notification configuration as reliable paging.

---

### Incident Response Strategy

- Which environments are authorized for automatic isolation?
- Which GuardDuty severities are allowed by `ec2_auto_isolation_severities` (default `CRITICAL`; optionally `HIGH` plus `CRITICAL`)?
- Which workloads may receive `IsolationAllowed=true`?
- Are quarantine security-group behavior and snapshot permissions validated?
- Who reviews EC2 isolation events and is allowed to trigger rollback?
- Are the SNS notification and rollback paths tested before enabling production isolation?
- What ticketing, approval, and escalation processes apply to containment, tamper alerts, and break-glass use?

Account for snapshot requests without completion waits, group changes before
recovery tags, handled errors that do not enter a DLQ, and rollback's true-valued
isolation tag. Preserve independent pre-state and authenticated approval records;
payload approver/ticket fields are not an approval service.

---

### Backup and Patch Strategy

- Which resources should be backed up?
- What retention periods are required?
- Should Backup follow deployment profile defaults or explicit overrides?
- What patch windows are acceptable?
- Who reviews patch compliance?
- What recovery testing is required?

Separate RDS-native backups, AWS Backup plans, production Restore Testing,
application/data validation, and restore cleanup. Preserve required keys along
with backup copies. Patching targets one tag and permits reboots; it supplies no
application drain/health gate or quarantine exclusion. Inspect per-target outcomes
and required reboots rather than relying on SSM registration.

---

## Operational Considerations

### Terraform State

Terraform state is sensitive and must be protected.

State buckets are deployed with:

- KMS encryption
- Versioning
- Restricted access
- S3 native lockfiles
- Controlled bucket administration

Each state stack uses a two-phase lifecycle:

1. Apply it locally without an active `backend.tf`.
2. Migrate it into the S3 backend it created with `scripts/bootstrap/migrate-state-stack.sh`.

The repository tracks `backend.tf.migrated.example`, while the active runtime `backend.tf` is ignored by Git and is only created after the backend exists.

Before adopting the baseline for a client or another organization:

- Customize every state-stack backend template for the intended bucket, key, and region.
- Set `EXPECTED_ACCOUNT_ID` during migration.
- Retain the external pre- and post-migration backups.
- Verify the migration with `--verify-only`.
- Require remote-state validation for deployment acceptance evidence.

The existence of `backend.tf` alone is not proof of migration. The remote S3 object and `terraform state pull` must also succeed.

---

### GitHub OIDC Roles

GitHub OIDC roles are critical CI/CD access components. Workload environments use separate Plan and Apply roles, plus an optional dedicated Image Publisher role per workload account.

```text
<env>-plan / Plan role
<env>      / protected Apply role
allowed branch / Image Publisher role
```

The Image Publisher role is deliberately narrow: ECR publication/query authority only, with exact branch-based trust. The `Deploy Application` publisher job must not declare a GitHub Environment because environment-based OIDC subjects differ from the branch-based trust contract.

The release/PR job has the opposite authority boundary: GitHub `contents: write` and `pull-requests: write`, but no AWS credentials and no `id-token`. This separates the workflow-declared grants between jobs; it does not prove that every injected credential, action, or external permission respects that boundary.

The standalone Terraform Plan workflow and Terraform Apply's internal Plan job are distinct. The protected Apply job consumes only the saved plan produced inside the same Apply workflow run, after checksum/metadata verification.

Automated workload bootstrap validation checks its implemented Plan/Apply state/KMS relationships and the Image Publisher role when its Terraform output is present; it is not a complete effective-access or GitHub-protection audit. For publisher-enabled deployment/client evidence, require it explicitly with `REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true` and supply the exact expected repository/branch set so trust and ECR policy scope are checked against the Terraform contract.

Modify workload account stacks carefully and reconcile them when required. Do not destroy account/OIDC stacks before the infrastructure that depends on their roles.

### IAM Identity Center

Identity Center access is centralized from the control plane.

Some optional Identity Center permissions depend on IAM policies created by workload baselines.

This is expected.

The intended pattern is:

```text
1. Configure workload Operator access and required SecOps-Administrator access
2. Deploy workload baselines
3. Confirm workload-created policy names
4. Enable optional Analyst/Engineer roles as needed
5. Re-apply Identity Center
```

The security-operations access model is separate from workload access: `SecOps-Administrator` is required there, `SecOps-Operator` is disabled, and Analyst/Engineer access remains optional.

The intended persona lifecycle does not fix the Operator caller/bus mismatch.
Resolve effective authorization and inspect membership, assignment principals,
policy contents, and actual access. Required customer-managed policies must exist
in the target account before corresponding access is relied upon.

---

### Deployment Profiles Affect Resource Creation

Deployment profiles and egress modes affect which resources are created.

Examples:

- `production` with `egress_mode = "auto"` deploys Network Firewall and NAT Gateway.
- `development` with `egress_mode = "auto"` deploys NAT Gateway but not Network Firewall.
- `minimal` with `egress_mode = "auto"` does not deploy Network Firewall or NAT Gateway.

Always review the Terraform plan before applying a profile or egress mode change.

---

### Dedicated Endpoint Subnets

Interface VPC Endpoints are deployed into dedicated endpoint private subnets.

These subnets have their own route tables and do not require a default internet route.

Workloads reach Interface Endpoints over VPC-local routing and security group rules.

The endpoint set includes Terraform-managed `guardduty-data`. Compute waits for the Interface Endpoint resources before EC2 launches so GuardDuty Runtime Monitoring can use the existing endpoint instead of creating one outside the Terraform dependency graph.

The S3 Gateway Endpoint is associated with the private route tables that need S3 access.

---

### Destroy Order

Destroy order matters.

Incorrect destroy order can cause:

- IAM policy delete conflicts
- Broken GitHub Actions access
- Orphaned resources
- State backend deletion before dependent stacks are gone

Before teardown, follow the [production retirement runbook](production-retirement.md) and the [quickstart](quickstart.md) for the applicable environment.

Workload Apply/Destroy automation is intentionally separate from centralized security-services lifecycle. Destroy workload environments before foundational account, security-operations, control-plane, or state stacks.

A state stack must be migrated away from the S3 bucket it manages before that bucket is destroyed. Preserve an external state backup and do not run a self-destructive teardown while the active backend still points to the same bucket.

For `prod`, use reviewed Stage-1 retirement planning/application and verify
quiescent ECS state. The protected Destroy workflow separately authorizes durable
data cleanup, then checks readiness and plans workload destruction. Identity
Center cleanup precedes final workload-destroy approval. Durable cleanup
re-inventories during execution rather than replaying a frozen item list; later
rejection does not undo earlier changes. Consult the runbook for the exact gates
and input requirements rather than manually setting every force-delete flag.

Preserve required records, recovery artifacts, images and usable keys outside
approved deletion scope. State migration alone does not remove literal state
resource destruction guards. The complete durable-cleanup path is `prod`-only;
central and state roots have their own lifecycle and are not automatically
retired by the workload workflow.

---

## Cost Considerations

This baseline prioritizes security and visibility for production environments.

Some services can create meaningful cost, especially when deployed across `dev`, `staging`, and `prod`.

Common cost drivers include:

- AWS Network Firewall
- NAT Gateway
- VPC endpoints
- CloudWatch Logs
- VPC Flow Logs
- GuardDuty
- Security Hub
- Inspector
- KMS requests
- Backup storage
- EC2 instances
- The always-composed RDS instance, including production Multi-AZ capacity
- Fargate tasks, the optional ALB, Container Insights, ECR scanning/storage, and temporary restore-test resources

Deployment profiles and egress modes help make cost/security tradeoffs explicit.

| `deployment_profile` | Cost/security intent |
|---|---|
| `production` | Required resilience plus default inspected egress; estimate the full deployment |
| `development` | Lower-cost development baseline with NAT-only egress |
| `minimal` | Reduced-service AWS-private testing; retains database, EC2, endpoints and other resources |

| `egress_mode` | Cost/security intent |
|---|---|
| `network_firewall` | Adds the inspected firewall/NAT path; estimate applicable service and traffic charges |
| `nat_only` | Lower-cost internet egress without Network Firewall |
| `vpc_endpoints_only` | Removes the general compute internet route, NAT and firewall; endpoints and other resources remain |

Teams should review cost expectations before deploying all environments.

Recommended adoption pattern:

- Deploy and validate `dev` first
- Review cost
- Deploy `staging`
- Review cost again
- Deploy `prod`

Estimate from the actual selected Region, AZ count, services, usage, retention,
logging volume, backup/restore frequency and current AWS pricing. These tables are
architectural comparisons, not quotations or guaranteed monthly rankings. Include
fixed endpoint/AZ and database costs even with no application digest selected,
as well as data processing/transfer, scanning, archives, snapshots, key requests,
restores, and retained resources after cleanup. The repository does not implement
a universal cost cap or an automatic response to budget overruns.

Assign ongoing maintenance for provider/toolchain changes, AWS service behavior,
image/OS dependencies, certificates, secret refresh, customer extensions, validators,
and operating procedures. A successful initial deployment does not supply that
service or a support commitment.

---

## Security Review Checklist Before Production Use

Before using this baseline for production workloads, confirm:

- Required AWS accounts exist and are controlled.
- Terraform state resources are protected.
- Every state stack has been migrated and passes `migrate-state-stack.sh --verify-only`.
- Deployment acceptance evidence requires remotely readable state stacks.
- GitHub OIDC Plan, Apply, and Image Publisher roles are working, with the publisher role restricted to approved branches and ECR publication/query authority.
- GitHub Actions is permitted to create release PRs if `Deploy Application` automation is used.
- A registered-but-unreleased ECS service can retain its ECR repository with `image_digest = null` without creating runtime resources.
- The application release path has been proven through image publication, authoritative digest resolution, one-field release PR, protected exact-plan Apply, ECS steady state, and workload validation.
- Fixed ECS services retain Terraform `desired_count` ownership; autoscaled services use only approved target-tracking policies and keep live desired count within configured bounds without Terraform reasserting the bootstrap count.
- Deployment-health settings and Terraform-owned task-deficit / ingress unhealthy-target alarms match the intended production operating model.
- GitHub environments have appropriate protections.
- IAM Identity Center groups are assigned correctly.
- Break-glass access is documented and tested.
- CloudTrail is logging.
- The security-operations account is the expected Security Hub and GuardDuty delegated administrator.
- Security Hub CSPM central policies are associated successfully with intended workload accounts.
- GuardDuty organization features and Runtime Monitoring match the approved configuration.
- Security Hub V2 policy is attached to `Workloads` and resolves correctly for workload accounts.
- AWS Config is recording in workload accounts where expected.
- SNS subscriptions are confirmed and correlated delivery/receipt is observed; queue operations and shared-notification failures have assigned owners.
- Approved EC2 response tests establish actual containment/recovery with independent pre-state, partial-failure handling, and authenticated approval records; Operator authorization is reviewed separately.
- Automatic isolation is explicitly configured and approved; do not assume it is disabled by production/staging defaults. Confirm live `IsolationAllowed` tags and post-rollback policy.
- Snapshot creation, quarantine networking, SNS notification, and rollback permissions are validated.
- IP enrichment tests pass.
- Backup scope and usable keys are preserved; restore execution, application/data validation, cleanup, and required recovery objectives have their own accepted evidence.
- Patch targeting/reboot impact and per-target results are reviewed; no application health gate or quarantine exclusion is assumed.
- Production uses the expected deployment profile.
- Production uses the expected egress mode.
- Network Firewall routing is active if required.
- VPC endpoint coverage is sufficient for private AWS service access.
- Dedicated endpoint subnets are deployed and validated.
- `guardduty-data` is Terraform-managed and deployed before workload EC2.
- Cost estimates are understood.
- Destroy procedure is understood.

The checklist is an acceptance record to complete, not a declaration that the
repository meets every item. Use the [assurance narratives](assurance/control-narratives.md)
and [validation report](assurance/validation-report-template.md) to record
implementation gaps, evidence scope, owners, exceptions, and decisions. No item
is implicitly satisfied by a module name, default profile, passing child-script
exit, or historical demonstration.

---

## How to Extend the Baseline

Common extension areas include:

- Adding Service Control Policies
- Expanding centralized security governance to additional services or Regions
- Adding external SIEM forwarding
- Adding additional AWS Config rules
- Adding additional VPC endpoint services
- Adding additional Lambda responders
- Adding ECS task-role capabilities through reviewed typed interfaces
- Adding support for alternative CI/CD providers
- Adding more granular Identity Center roles
- Adding Kubernetes or other workload patterns beyond the supported EC2 and ECS/Fargate runtimes
- Adding multi-region disaster recovery patterns
- Adding additional deployment profiles or profile-controlled services
- Adding additional egress modes or proxy-based egress support

Extensions should preserve the core design principles:

- Keep control-plane resources separate
- Keep state isolated
- Avoid circular dependencies
- Prefer least privilege
- Preserve logging and detection integrity
- Avoid introducing long-lived CI/CD credentials
- Keep cost/security tradeoffs explicit
- Keep private AWS service access scoped through VPC endpoints where practical

---

## Summary

`tf-secure-baseline` is a candidate foundation for authorized teams whose AWS architecture, operating capabilities, and risk requirements fit the implemented model.

It provides implementation patterns for:

- Multi-account AWS structure
- Secure CI/CD access
- Centralized identity
- Delegated security administration
- Private networking
- Configurable deployment profiles
- Configurable egress behavior
- Dedicated VPC endpoint subnets
- Logging and monitoring
- Event-driven incident response
- Audit-readiness

Adoption requires the relevant license authorization, reviewed implementation boundaries, actual deployment and operating evidence, application-specific controls, and named maintenance and response owners. Neither this guide nor a successful infrastructure deployment substitutes for those decisions.
