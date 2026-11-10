# v1.15.0 — M0-D/E/F: Consolidated Architecture Closeout

**Status:** Draft decision and acceptance register — security, cost and licensing approvals **OPEN**
**Baseline:** \`main\` at PR #964 merge \`30f916bccfbd123ce189c65330070b2e4845551e\`
**Scope:** One **documentation-only** M0-D (security/operations), M0-E (economics/IP) and M0-F (architecture acceptance) work package
**Reference application:** ReconoSense, private contract \`infra/terraform/BASELINE_INTEGRATION.md\` in \`~/recon-engine/\`
**No authorization:** This PR cannot create Terraform/IAM/SSM/network resources, change workflows/state, deploy to AWS or execute licensing documents.

## 1. Scope, decisions already established and release boundary

M0-A inventory, M0-B two-state ownership, M0-C1 publication design, M0-C2–C4 reusable-interface design, and the merged M0-C5 source-based dependency/compatibility review have been accepted **at the architecture/design level**. The last merger was PR #964. Source-reviewed design **is not** executable Terraform graph validation, live IAM enforcement, RDS qualification, or a ReconoSense deployment.

**Non-negotiable foundations:**

1. The **foundation state** owns shared VPC/subnets, endpoints, centralized security, KMS, ECS cluster, foundation ECR inventory, and the RDS instance/configuration/deletion. The **separate application state** owns app ECS services/tasks, app ALB/WAF, schedules, app IAM under platform controls, app secrets/data/identity. No duplicate resource instance or reverse state dependency.
2. The initial integration is **synthetic data in the existing baseline staging AWS account**. ReconoSense's dedicated account and standalone Terraform root remain unchanged. The application consumes a version-pinned, non-secret SSM foundation contract, **not** the foundation state snapshot.
3. B-5 permits a distinct **application run-state controller** for one designated, exclusively used staging RDS instance, **not** application authority over RDS configuration/master secret/deletion. Actual Start/Stop grants remain unimplemented.
4. **C3-D3**: Future extraction of RDS from \`modules/storage\` into \`modules/database\` is optional, **within the same foundation state**, guarded by complete Terraform \`moved\` address mappings and a reviewed non-destructive plan. It is not a prerequisite for M1 or automatic part of M3.
5. New capabilities are generic/optional, preserve existing single-container ECS addresses and defaults, and put ReconoSense-specific job names/SQL/model selection behind the application-owned composition.
6. **No runtime implementation or permission grant is approved by this document.** M1–M5 carry out Terraform implementation and positive/negative testing through separately approved changes.

**Decision classification:** \`APPROVED DESIGN\` means architecture already accepted; \`PROPOSED\` means a recommendation awaiting owner decision; \`BLOCKING BEFORE DEPLOY\` means approval/implementation evidence is mandatory before first integration Apply. Do **not** mark M0 final acceptance as complete when any owner, pricing, or IP authorization question below remains unresolved.

## 2. M0-D — Identity, deployment and security authority

### 2.1 IAM/OIDC/CI role ownership matrix (design, no grants)

| Principal / operation | Protected owner | Required minimum scope | Deny/negative-proof obligation |
|---|---|---|---|
| Account and state/bootstrap administrators | Existing protected platform/bootstrap authority | OIDC provider, state bucket/key policies, mandatory permission boundaries, trust and IAM ceilings | Application CI cannot impersonate, edit, weaken or detach boundary/trust, read platform state, or self-grant admin rights. |
| Foundation Plan role | Foundation CI, independent of application | Approved read-only foundation discovery plus **its own** backend object/lock operations; no production mutations | Deny application state snapshots, application secrets and arbitrary AWS writes. Backend \`.tflock\` operations are an explicit narrowly scoped Plan exception. |
| Foundation Apply role | Protected foundation CI/environments | Own foundation resource instances and **sole** Terraform writer to the SSM publication parameter | Application cannot assume this role, modify baseline security/RDS or gain its permissions via repository/branch/environment spoofing. Existing broad \`AdministratorAccess\` baseline role is **not reusable as app role**. |
| Application Plan role | Platform/bootstrap-provisioned application identity, app CI | Exact SSM parameter \`GetParameter\`, approved non-sensitive discovery, **application** state read and lockfile only | No \`terraform_remote_state\`/foundation state object or versions, no SSM parameter write, recursive parent-path reads, master-secret retrieval, role/trust mutation or arbitrary resource changes. |
| Application Apply role | Platform/bootstrap-governed protected environment and review | Application state and approved app-owned ALB/ECS/IAM/network resources within mandatory boundary, scoped \`PassRole\` | Cannot change foundation SGs, configuration/deletion RDS, key policies, bootstrap, foundation ECR ownership or security evidence. Explicitly deny unapproved SG attachments and direct alternate task launches where enforceable. |
| Image publisher | App CI under separate trust subject | Push only approved ECR repository digests and read only required image metadata | No ECS service promotion, foundation repo administration, state writes, wildcard repository/broad IAM grants. |
| Release coordinator | Independently protected authority outside ordinary app Plan | Durable publication eligibility/epoch, cross-repository admission/lease, saved-plan checksum validation, full-release serialization and protected operator reconciliation | App repository cannot forge \`ELIGIBLE\`, move an epoch backward, bypass stale-plan checks, release a lease during unresolved mutation, or grant itself foundation privileges. |
| Application ECS task/execution/Scheduler roles | Application state within protected IAM ceiling | Separated task vs execution role, exact Secrets Manager and KMS grants, GuardDuty agent ECR pull, app-specific RunTask/Schedule/PassRole | Deny master credential, cross-tenant/object/model access, unrelated task families, unrelated schedule/DLQ manipulation and wildcard role assumption. |
| Staging RDS operational controller | Application Apply under separately approved platform restriction | Only \`rds:StartDBInstance\`/\`rds:StopDBInstance\` for the **exact** eligible staging DB ARN/Region, necessary describe access | Deny \`ModifyDBInstance\`, \`DeleteDBInstance\`, master-secret access, other DB ARNs, production DBs; enforce exclusive use, drain and operation sequencing. |

**IAM implementation findings:** Current \`modules/github_oidc/main.tf\` grants broad state-bucket reads to foundation Plan and attaches \`AdministratorAccess\` to foundation Apply. The current platform-wide \`modules/iam/ecs.tf\` does not impose mandatory per-role boundaries. Neither module should simply be reused to create application deployment principals. Separate bootstrap-administered application identities, permissions-boundary ceiling, trust conditions, state key/lockfile restrictions and KMS conditions are required.

**State backend alternative:** \`applications/<app>/<env>.tfstate\` within the foundation state bucket is **only a candidate** if exact per-key versions, bucket-list conditions, object/lockfile IAM and KMS isolation can be proved. Otherwise approve a distinct application bucket with independent protected policy. No shared \`bucket/*\` application access.

**GuardDuty and data protection:** Execution-role pulls for the regional GuardDuty Fargate agent must use the exact C1-published AWS-owned ECR repository ARN; \`ecr:GetAuthorizationToken\` may require its separate \`*\` statement. KMS decrypt must target the appropriate application secret keys and encryption contexts without exposing foundation RDS master. Application alerts, DLQs, logs and data buckets require service-compatible key policies, source restrictions and evidence-retention guards. ReconoSense's current execution/alert policies are **not** qualification evidence.

### 2.2 Security-group admission: C4-D2 remains UNAPPROVED

The C2–C4 design offers **foundation-created connectivity-grant SGs** as a candidate to provide DB/endpoint ingress without a reverse Terraform reference. This candidate is **not** approved for deployment.

**Critical constraint:** AWS combines the rules of multiple attached SGs as an **allow union**. A restrictive grant SG does not restrict a permissive application SG. Simply denying edits to the foundation grant's rules also does **not** prevent arbitrary attachment or an alternate broad SG. ECS authorization must not be assumed to support a fine-grained SG-ID condition where it does not.

**M0-D authority requirements before connectivity implementation:**

1. Enumerate **every** network-capable entry point: ECS service create/update, task-definition and task-role change, direct \`RunTask\`, Scheduler create/update and target launch, deployment break-glass, and any console/CLI bypass. Distinguish who controls task subnets, SG attachments and policies.
2. Protect all relevant launch paths via independent deployment admission, least-privilege IAM, permission ceilings and monitored resource mutations. Reject arbitrary task SGs, permissive task rules, unrelated role assumption and unreviewed alternate egress. Repository validation alone is insufficient.
3. Assign each foundation DB/endpoint ingress rule exactly one state owner. Platform-managed grants should be provisioned **without** referring to an app-created SG. Existing foundation \`security_policy\` module cannot be called wholesale from app state.
4. If AWS IAM/controls cannot enforce the desired attachment and network restrictions in practice, **reject** the SG-grant candidate and obtain an owner-approved two-state alternative **before any deployment**. Never silently widen foundation SG authority or add a third workload state.
5. Prove positive allowed traffic and negative unauthorized SG, RDS, endpoint and direct-launch scenarios under M3–M5; document effective controls and any monitoring/detection assumptions. Do not call detection-only controls prevention.

**Disposition:** Candidate evaluation and test requirements are approved architecture work; the *concrete* connectivity mechanism, IAM enforcement and operational grant remain **BLOCKING BEFORE DEPLOY** and need an explicit security approval.

### 2.3 Protected SSM publication, release and lifecycle coordination

C1's Terraform-owned SSM parameter contains versioned, non-secret resource identifiers. **Only foundation Terraform writes it.** An independently protected coordinator maintains a durable \`BLOCKED\`/\`ELIGIBLE\` publication eligibility record plus monotonic approval epoch and serializes actions across **both repositories**.

| Transition | Required gate | Failure behavior |
|---|---|---|
| Before foundation mutation/retirement | Acquire environment-wide exclusion; set publication eligibility \`BLOCKED\` **before** Terraform/AWS mutation | A failed, interrupted or partially successful Apply leaves the environment blocked. Existing SSM values alone do not reauthorize. |
| After successful foundation Apply | Validate AWS resource/interface state, account/Region and protected controls; record SSM ARN/name, AWS version, raw-UTF-8 SHA-256, full foundation source SHA and eligibility epoch | Any post-Apply qualification failure stays blocked. No competing CLI SSM writer. |
| Application saved Plan | Read only approved exact SSM and eligibility; bind publication identity, epoch, app revision and saved-plan digest in protected manifest | Unsupported schema, stale/missing publication, account mismatch or unauthorized capability fails closed. |
| Immediately before application Apply | Obtain same environment lease; re-read current SSM/epoch and compare against reviewed plan manifest; **hold lease through Apply, worker/migration/API promotion and acceptance** | A/B publication mismatch or mutation race aborts. Failed migration blocks promotion. |
| Pause, resume, rollback and teardown | Fence *new* job launches before draining app-specific tasks; reconcile autoscaling; resume DB before migrations; coordinate protected rollback and retirement | Coordinator crash, stale lease, background AWS operation or unclear outcome is **not** resolved merely by lease timeout. Keep blocked pending operator reconciliation. |

**Ownership and implementation gate:** Platform/bootstrap owns the coordinating authority and its write privileges; the app release initiates controlled requests but cannot forge approval. No third workload Terraform state is needed. The mechanism (lock store, atomic admission, operator recovery, lifecycle permissions, rollback fencing) and trust boundary are a **mandatory M0-D design signoff**, with implementation and race/negative tests allocated to M4/M5. GitHub Actions repository-local concurrency alone does not serialize different repositories.

### 2.4 Other downstream security obligations

- **Ingress/WAF:** app owns ALB, ACM records and scoped Web ACL; handle \`SizeRestrictions_BODY\` narrowly for approved upload routes, never blanket-allow; WAF does not inspect the full 50 MiB upload. M5 validates accepted large uploads and denied oversized/malicious requests.
- **Network reachability:** private task networking and C1 \`effective_egress_mode\` do not prove Cognito/JWKS, Bedrock, ClamAV updates or external APIs are reachable. Establish approved endpoints/DNS/domains, negative no-unrestricted-egress evidence and traffic flow tests.
- **Database-owner bootstrap:** foundation master remains platform-only; authorized first-install process creates a distinct application SQL owner with required PostgreSQL 16 roles/extensions/grants; no substitution with master credentials. Document rotation/recovery and migration privileges.
- **Release and observability:** ECS listener+forwarding route, IAM and SG readiness precede service start; applications scope task failures by their own task-family identity and correctly attribute per-container exits; test KMS-compatible alert publisher/consumer roles.
- **Retention:** application teardown cannot destroy foundation RDS, state, backup or centralized evidence. Object Lock/legal hold bypass cannot become normal application privilege. Preserve deletion protection on any production-profile component.

## 3. M0-E — Architecture economics and operational tradeoffs

### 3.1 Pricing assumptions and sources

This is a **priced scenario model of selected infrastructure components**, **not an AWS Pricing Calculator quote, all-in budget, current bill or deployment approval**. Reconfirm rates using the [AWS Pricing Calculator](https://calculator.aws/) and actual Terraform variables before committing spend. Indicative rates are in USD in **us-east-1 (N. Virginia)** and use a **30-day / 720-hour month**, not 730 hours. Prices, credits and free tiers can change. Source checks: 2026-11-09.

| Component / unit | Model rate | Pricing source / qualification |
|---|---|---|
| Interface VPC endpoints (per endpoint ENI per AZ-hour) | **$0.01/hour** plus **$0.01/GB** processing in initial tier | [AWS PrivateLink](https://aws.amazon.com/privatelink/pricing/). The baseline defines **16** required interface services in \`modules/vpc_endpoints/main.tf\`; additional services increase costs. S3 *Gateway* endpoint hourly charge not modeled. |
| NAT gateway | **$0.045/hour/AZ** plus **$0.045/GB** data processed | [AWS VPC](https://aws.amazon.com/vpc/pricing/). Each NAT public IPv4 address modeled at **$0.005/hour**. Confirm current regional/endpoint rebates. |
| AWS Network Firewall | **$0.395/hour/endpoint/AZ** plus **$0.065/GB** processed | [AWS Network Firewall](https://aws.amazon.com/network-firewall/pricing/). NAT gateway hourly and processing allowances may apply when eligibility is met; do not double-charge qualifying traffic. |
| ECS Fargate Linux/x86 | **$0.04048/vCPU-hour**, **$0.004445/GB-hour** | [AWS Fargate](https://aws.amazon.com/fargate/pricing/); model uses 1 vCPU, 2 GiB/task, ordinary on-demand, excludes task storage beyond default and image transfer. |
| ALB | **$0.0225/hour** + **$0.008/LCU-hour** | [AWS ELB](https://aws.amazon.com/elasticloadbalancing/pricing/); model assumes **one LCU**, but real loads and traffic may exceed it. |
| RDS PostgreSQL \`db.t4g.medium\` | **$0.065/hour Single-AZ; $0.129/hour Multi-AZ** | Indicative PostgreSQL/us-east-1 engine-specific rates from [Cloud Credits (2026-10)](https://cloud-credits.org/prices/rds/db-t4g-medium/us-east-1); **reverify official AWS calculator quote**. Storage, snapshots/backup and CPU-credit bursts excluded. |
| AWS WAF base | **$5/Web ACL-month + $1/rule-month** | [AWS WAF](https://aws.amazon.com/waf/pricing/), plus $0.60/million requests, extra rule groups/capacity and special features. Model assumes two managed groups. |
| KMS keys and Secrets Manager | **$1/customer-managed KMS key-month; $0.40/secret-month** | [AWS KMS](https://aws.amazon.com/kms/pricing/) and [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/pricing/). Request charges and rotation surcharge not included. |

**Observed source profiles:** \`baseline/locals.tf\` defaults to **2 AZs** for development/minimal and **3 AZs** for production, with effective egress \`nat_only\` for development, \`network_firewall\` for production and \`vpc_endpoints_only\` for minimal. Explicit overrides can change these. The 16-endpoint inventory is a **source count**, not proof that every endpoint service deploys successfully or that all ReconoSense egress paths are covered.

### 3.2 Three transparent monthly scenarios (not all-in)

| Modeled component, USD/month | A: Entire synthetic dev foundation **80 h** | B: Dev foundation **720 h**, app **80 h** | C: Production-profile **720 h** |
|---|---:|---:|---:|
| AZs / interface endpoint ENIs | 2 AZ / 32 | 2 AZ / 32 | 3 AZ / 48 |
| Interface endpoint hourly subtotal | **$25.60** | **$230.40** | **$345.60** |
| NAT gateway hours + public IPv4 (unrebated dev; production assumes qualifying firewall NAT-hour rebate, but includes EIPs) | **$8.00** | **$72.00** | **$10.80** |
| Network Firewall endpoint hours | **$0** | **$0** | **$853.20** |
| Fargate compute (A/B: 1 task × 80 h; C: 2 tasks × 720 h) | **$3.95** | **$3.95** | **$71.09** |
| ALB hourly + modeled 1 LCU (app-active hours) | **$2.44** | **$2.44** | **$21.96** |
| RDS instance hours (A/B: Single-AZ 80 h; C: Multi-AZ 720 h) | **$5.20** | **$5.20** | **$92.88** |
| Six illustrative KMS keys (prorated) | **$0.67** | **$6.00** | **$6.00** |
| Ten illustrative Secrets Manager secrets (prorated) | **$0.44** | **$4.00** | **$4.00** |
| One WAF ACL + two rules/groups (app-active prorated) | **$0.78** | **$0.78** | **$7.00** |
| **Priced subset subtotal** | **~$47.08** | **~$324.77** | **~$1,412.53** |

**Formula examples:** Interface endpoint charge = **16 services × AZ count × active foundation hours × $0.01**. Fargate task-hours = active task hours × **(1 × $0.04048 + 2 × $0.004445)**. Scenario C assumes the current firewall NAT hourly discount is fully eligible; absent that discount add approximately **$97.20** for three NAT gateway hours per AZ over 720 hours, subject to current AWS discount rules. Endpoint/NAT/Firewall data processing, transfer, public IPv4 other than NAT EIPs, and request volume are **not** included in the subtotals.

**Excluded and potentially material:** RDS gp3 allocated storage **billed even while RDS is stopped**, backup/restore, S3 log and document storage, retained evidence, CloudWatch Logs/metrics/Container Insights, CloudTrail/Config, GuardDuty/Security Hub/Inspector, Lambda/EC2, network/firewall/endpoint GB processed, internet egress, CloudWatch alarms, SNS/SQS, Cognito MAUs, Bedrock token/usage fees, SSM API charges, WAF requests, application background job compute, extra ALB LCUs, licensing, support and taxes. The six-key/ten-secret assumptions are **not a verified count** of existing baseline resources. The synthetic/dev scenario assumes allowed deletion of disposable foundation components; protected state and retained evidence may persist and still accrue cost.

### 3.3 Operating conclusions and pre-deployment cost signoff

- **Parking the application is not the same as parking the foundation.** NAT and interface endpoints stay provisioned and billable when ECS scales to zero or RDS is stopped. Scenarios A/B make that fixed-cost difference visible; S3 evidence retention can outlive both.
- A \`minimal\` endpoint-only profile might avoid NAT/firewall hours, but is **not approved** for ReconoSense until Cognito/JWKS, Bedrock, ClamAV image/update and other egress is proven. Do not trade away mandatory connectivity/security just for lower bills.
- Production-profile Network Firewall adds a large fixed hourly component; compare approved egress architectures using same traffic assumptions and AWS discount terms. Never silently switch the approved production posture to NAT-only without security signoff.
- **Before first integrated Apply:** platform/finance owner validates an official AWS Pricing Calculator estimate with actual AZ count, endpoint list, RDS Multi-AZ/storage/backup, tasks/hours, security services and data volume; defines maximum staging budget, AWS Budgets alarms and evidence retention cost. Record planned vs actual usage in M5.
- **Decision E1 (PROPOSED):** Treat the above numbers only as **indicative line-item estimates**, not an approved financial commitment. Actual spend approval remains **OPEN** until modeled totals, exclusions and Budget alerts are signed off.

## 4. M0-E — Proprietary IP and ReconoSense licensing

The repository root [\`LICENSE\`](../LICENSE) identifies **“Jacob Molland, doing business as Nano Nexus Holdings LLC”** as its stated copyright owner and allows use/deployment, derivative modifications, distribution, commercialization or incorporation **only under a separate written agreement signed by the Copyright Owner**. Prior Apache-licensed revisions retain the rights previously granted. No general license is granted by GitHub visibility alone.

**Ownership and authority must be verified rather than inferred:** The current license text names **Nano Nexus Holdings LLC** and an individual doing business as that entity. Other Nano Nexus entities/names may exist in prior business records; **do not assume they are the same legal person** or that any corporation can sign for the stated owner without a confirmed rights chain. Likewise, the ReconoSense legal entity, authorized signatories and 50/50 cofounder governance must be verified from executed company documents, not from a proposed founder bio.

**Decision E2 (PROPOSED; legal signoff required before ReconoSense use):** Negotiate and execute a separate **no-fee/royalty-free written permission or license** granting the correctly identified ReconoSense legal entity authorized internal development, synthetic testing, hosted production use, configuration changes, modifications/derivative works and continued access to approved baseline versions, while retaining baseline background IP ownership with its verified owner. Explicitly decide customer sublicensing/resale, distribution of Terraform source/modules, use by affiliated contractors, and termination/continuity rights; **do not assume these are included**. Confirm whether the company will only operate a hosted SaaS service (no source distribution) or provide customers with infrastructure code. Define confidentiality, third-party dependencies, security/update support, limitations, governing law, and change-of-control rights with counsel.

**Document/evidence required:** owner identity and chain of title; exact licensed repo/version/IP; ReconoSense legal name; executed permission/license signed by all authorized parties; approval of no-fee/royalty conditions and customer-facing rights; record/repository location for executed documents **outside the public repo**. Do not publish signatures, addresses, private license exhibits or trade secrets in these docs.

**Current status:** **BLOCKING BEFORE ANY USE/DEPLOYMENT of this proprietary baseline by ReconoSense** unless existing valid written authorization is independently produced and confirmed. This PR does not change \`LICENSE\`, transfer IP or grant any permission; **M0 cannot claim license closeout without executed evidence**. Seek legal advice for binding IP agreements.

## 5. M0-F — Final acceptance register and milestone handoff

| Gate | Evidence / decision | Status |
|---|---|---|
| F-1 M0-A/B ownership and 17-contract coverage | Prior approved M0 inventory/B document, C1 publication, C2–C4 interfaces; no overlapping workload state ownership | **Design accepted** |
| F-2 M0-C5 dependencies/compatibility | PR #964 merged; local independent review \`ACCEPT WITH DEFERRED ITEMS\`; executable graphs/plans intentionally moved to M1–M5 | **Design accepted** |
| F-3 Application IAM, SG connectivity and SSM coordinator | Role/authority and bypass matrix in §§2.1–2.3; connectivity candidate specifically unapproved | **Open — security design/owner approval required**, then implementation+negative tests |
| F-4 Operating costs | Three transparent priced subsets and excluded costs; official workload quote and AWS Budget limits not yet verified | **Open — cost approval required before deployment** |
| F-5 Licensing and third-party rights | Root LICENSE restriction, entity/rights chain, proposed royalty-free agreement | **Open — executed authorization required before ReconoSense use** |
| F-6 C3-D3 future database module separation | Optional same-state refactor, non-destructive reviewed plan, postpone if unsafe | **Design accepted; optional implementation** |
| F-7 Release implementation authorization | M1–M5 tasks need **separate owner-approved technical PRs** with Terraform graph/plan, least-privilege and failure tests | **Not authorized by M0 documentation** |
| F-8 Final M0 checkpoint acceptance | Resolve F-3/4/5 appropriately and independently review this document's assumptions; do not equate docs CI with enforcement | **Pending; do not mark M0 complete** |

### 5.1 One-package owner decision requests

Decide together, without another series of nested M0 PRs:

1. **Security authority:** Approve the direction of distinct platform-owned app CI identities and a protected cross-repository SSM/lease coordinator; keep SG grant attachment mechanisms **unapproved** until bypass-resistant controls and tests are demonstrated. Accept a design-only M0-D closeout if enforcement is explicitly a later deployment blocker.
2. **Finances:** Approve a staging spending envelope and the required official calculator/Budget evidence before provisioning. Do not treat §3.2 priced subtotals as the actual invoice.
3. **Licensing:** Confirm verified copyright owner and ReconoSense legal entity; authorize drafting the required written agreement. **An M0 doc merge cannot stand in for an executed license.**
4. **Architecture:** Confirm M0-D/E/F as one final planning package and delegate executable verification to M1–M5; no Terraform/configuration/IAM/deployment changes until separately approved.

### 5.2 Conditions for handoff to M1

- Independent architectural review accepts the **decision boundaries** and dispositions of the remaining security, cost and legal matters; no high-risk mechanism may be mistaken as approved simply because this PR is merged.
- The owner explicitly approves the final M0 design/handoff and authorizes M1 technical planning/implementation **in a separate change**. Until then, the PR remains a proposal.
- The first live ReconoSense integration Apply is **blocked** until IAM/SG/lease enforcement is implemented and negatively tested, a verified cost envelope is approved, the license is executed and foundation credentials/data separation is proven.
- M1 may develop generic modules against an isolated local/synthetic test fixture **only following an explicit authorization** and without deploying ReconoSense proprietary code under an unresolved license.
- Evidence at release closeout must include Terraform plans/graphs, control tests, approved application SHA/digests, costs, retained-state/evidence inventory and safe teardown, not just M0 documents.

**Do not claim:** a completed Terraform graph for future modules, AWS Plan/Apply, provisioned SSM parameter, deployed release coordinator, enforced IAM/SG permissions, live synthetic integration, verified official AWS calculator bill, executed Nano Nexus–ReconoSense agreement, SOC 2/ISO certification, or M0 final acceptance.
