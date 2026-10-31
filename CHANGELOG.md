# Changelog

This changelog is ordered newest-first. A versioned entry documents its
release change set; it does not independently establish that a GitHub release
has been tagged or published. Consult the repository's GitHub Releases for
publication status and retain tested commits and evidence separately.

Historical release entries preserve their then-current functionality and
qualification claims. They are not current deployment instructions or proof
that earlier tests were repeated on subsequent commits. Use the
[README](README.md), [adoption guide](docs/adoption-guide.md), and current
module/runbooks for the implemented contract.

## v1.13.0 — Recovery Assurance & Edge Protection (release candidate)

**Unreleased — M4 qualification and maintainer sign-off pending.** The latest published release remains [v1.12.0](https://github.com/jcub-i0/terraform-secure-baseline/releases/tag/v1.12.0). The work below adds recoverability assurance, ALB traffic evidence, and optional HTTP threat protection to the existing sensitive-data SaaS baseline.

### Added and Changed

- **M1 — Verified RDS recovery:** Private AWS Backup RDS Restore Testing uses an isolated temporary DB and a selectable recovery point. Optional `restore_validation_enabled` adds coordinator/worker Lambdas, read-only PostgreSQL canary validation, failure reporting, and cleanup qualification. It defaults to `false`; production-profile Restore Testing is enabled when effective AWS Backup is enabled, whereas non-production Restore Testing requires explicit opt-in. A configured plan alone does not prove successful recovery.
- **M2 — Protected ALB access logging:** A dedicated, optional SSE-S3 ALB access-log bucket provides versioning, public-access and ownership controls, lifecycle expiration, and constrained delivery/protection policies. Logging defaults **on** for a deployable ingress ALB in the production profile and **off** in development/minimal, subject to explicit overrides. Production retirement retains the approved staged destruction/disposition procedure.
- **M3 — Optional AWS WAF:** One regional WAFv2 Web ACL can protect the existing shared HTTPS ALB. It includes AWS-managed Common Rule Set and Known Bad Inputs Rule Set (priorities 10 and 20), optional per-IP rate limiting over 300 seconds, default-Allow and group-level `count` / `enforce` modes. WAF is disabled by default; request sampling is also disabled by default. Neither an ALB nor WAF materializes for registered ECS services without a selected image digest and ingress configuration.
- **Runtime evidence:** The existing **16-validator** workload suite conditionally inspects WAF outputs and the live ALB Web ACL association, group actions, metrics, sampling, and optional rate rule. Disabled WAF requires no WAF API calls. Existing CI validation structure is preserved; no new baseline validator or WAF-specific workflow step was added.

### Qualification Evidence

- **M1:** [Roadmap](ROADMAP.md#M1--Verified-RDS-Recovery) records positive and deliberately corrupted synthetic SQL restore outcomes, strict failure qualification, alerts, and temporary-resource cleanup. This establishes the tested canary contract, not application-level recovery or an RTO/RPO guarantee.
- **M2:** Real HTTPS requests were retrieved from a delivered `.log.gz` S3 access-log object; [staging baseline validation #40796511254](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/40796511254) passed 16/16.
- **M3:** [staging baseline evidence #41157394879](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41157394879) passed 16/16, including WAF drift checks. The same synthetic managed-rule match was sampled as `COUNT` (HTTP 200) and, after reviewed enforcement, `BLOCK` (HTTP 403), while benign traffic remained HTTP 200. [Protected staging Destroy #41160908973](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41160908973) succeeded (**298 destroyed**); the operator confirmed the workload state was empty. The canonical staging image digest is again `null`.
- **M4:** Offline regression and final release-candidate CI review remain separate sign-off gates. Earlier live evidence is retained under the tested configurations; it is **not** a claim that those tests were rerun against every subsequent commit.

### Upgrade, Cost, and Limitations

No new feature-specific Terraform state migration is intended. **Always review the actual saved plan before Apply**, especially for existing production-profile environments where Restore Testing and ALB logging may create resources when their prerequisites are present. RDS Restore Testing can incur periodic restore charges; access logging incurs storage/operation costs, and enabling WAF incurs AWS WAF charges. The optional rate rule is not exercised by the recorded M3 live tests.

ALB access-log delivery is best-effort, and S3 Lifecycle expiration is not immutable retention. WAF Count at the managed-group level is not exhaustive per-rule qualification; Known Bad Inputs was configured but not independently triggered. Request samples and log objects may reveal sensitive request metadata. Keep validation artifacts private and preserve required evidence, snapshots, and encryption keys before destructive cleanup. These technical controls do not constitute SOC 2 or ISO 27001 certification.

See [ROADMAP.md](ROADMAP.md) and the [ALB module](modules/application_load_balancer/README.md) for scoped implementation and qualification details. **Do not tag/publish v1.13.0 until M4 final CI and maintainer approval are complete.**

---

## v1.12.0 — Application Runtime Extensibility

v1.12.0 is the current release. It introduces three opt-in capabilities for
application-agnostic SaaS workloads handling sensitive data. This entry covers
`v1.11.1` through implementation `7002a4219e4e8146fd7f2496aa121d089dee7be3`:
roadmap #868, M1 #869, M2 #870, M3 #873–#875, and M4 regression in #877.
Publication metadata and reviewer approval are separate from this change record.

### Added and Changed

- **M1 — Application task IAM:** Optional per-service
  `task_role_managed_policy_arns` defaults to `[]` in all workload roots and
  baseline. IAM attaches the selected AWS-managed or same-account
  customer-managed policies in the active partition to application task roles
  only. ARN validation rejects non-policy resources and wildcard forms; policy
  ARNs must be known at plan time and policies must exist by attachment time.
  Optional attachment-ID outputs and per-service readiness dependencies order
  both fixed and autoscaled ECS launches after attachments. Empty sets create
  no attachment/readiness instances; null-digest registrations create no task roles.
- **M2 — Native container health:** Optional `health_check` propagates from
  `ecs_services` into the essential application's ECS `healthCheck`. The default
  `null` omits that field. Commands use `CMD` or `CMD-SHELL`; timing values are
  validated whole numbers. Defaults are interval 30 seconds, timeout 5 seconds,
  retries 3, and start period 0 seconds. The tracked dev registration now includes
  an illustrative check while retaining `image_digest = null`.
- **M3 — Private service access:** `additional_interface_endpoint_services`
  defaults to an empty set at environment, baseline, and endpoint-module levels.
  `bedrock-runtime` is the only approved optional service. The 16 mandatory
  Interface Endpoints keep their service-keyed resource addresses; the optional
  endpoint reuses dedicated endpoint-private subnets, private DNS, shared endpoint
  SG and TCP/443 rules. S3 Gateway associations and GuardDuty endpoint ownership
  are unchanged. Enabled endpoints incur additional hourly/AZ and traffic charges.
- **Workflow input:** Terraform Plan and Terraform Apply's internal Plan job read
  `ADDITIONAL_INTERFACE_ENDPOINT_SERVICES` as
  `TF_VAR_additional_interface_endpoint_services`, falling back to `[]`.
  The protected Apply job continues to consume its reviewed saved plan.
- **Applied metadata:** `ecs_service_configuration` includes sorted task-policy
  ARNs only for nonempty sets and normalized health configuration only when enabled.
  Consumers must tolerate those optional fields.

### Validation and Qualification

- IAM validation compares the **exact** expected/live managed-policy attachment
  sets; unexpected/missing task attachments, inline task policies, and managed
  execution-role attachments fail. Generated execution-policy checks remain
  separate from customer-managed policy semantics.
- Runtime validation compares exact task-definition health settings and checks
  native application health before strict rollout convergence. `UNHEALTHY` fails;
  unresolved/missing health cannot pass after bounded polling. Defaults are 13
  observations five seconds apart; allowed overrides are 1–60 attempts and 0–60
  seconds. Zero desired/running/pending capacity is a skip. Disabled checks add
  no native-health task queries. Batched task descriptions are shared with
  GuardDuty validation, and summaries expose configured/healthy/skipped counts.
- Endpoint validation requires all 16 mandatory services plus only approved
  optional services from applied Terraform-owned IDs. It rejects unsupported,
  missing, duplicate, unmanaged or mismatched endpoints and checks availability,
  VPC, private DNS, exact endpoint subnets/SG, GuardDuty uniqueness, and S3 routes.
  A separate optional-intent output is checked if supplied, but is not emitted by
  the current roots; validation therefore does not compare unapplied input intent.
- **53 offline cases** (M1 13, M2 18, M3 22) passed the three regression steps in
  [Static Analysis run 39368786319](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/39368786319)
  at `7002a421`. Terraform validation/TFLint and Checkov report-integrity checks
  succeeded; this is not a zero-finding security assessment. M4's Plan was skipped.
- Historical M2 dev observations recorded a healthy running application container
  and a deliberately failing standalone task reaching `UNHEALTHY`, with ingress
  disabled. Subsequent workload validation reported `16/16` script success and
  GuardDuty coverage recovery. These tests did not demonstrate ALB integration,
  managed-service rollback, or multi-service scaling.
- Historical M3 observations recorded 17 Terraform-owned endpoints and EC2/Fargate
  private-connectivity probes. The temporary Fargate task used the compute SG;
  endpoint-matching DNS answers and hostname-verified TLS/HTTP responses established
  private reachability, not authenticated model inference or the canonical task-SG
  path. M3's enabled-state `16/16` and converged plan are operator reported with
  incomplete archival provenance. These are not newly executed M4 tests.

### Security Boundaries and Known Limitations

- The baseline owns role/attachment infrastructure, not application authorization
  policy documents. Exact attachment equality does not evaluate effective
  permissions or policy-version changes. No default application privilege is added.
- Native container health, ALB target health, GuardDuty coverage, and successful
  application transactions remain independent. Health commands must exist and
  function inside the selected image; no health probe binary is supplied.
- Optional endpoints add network reachability for existing SG-authorized clients,
  including the existing quarantine path. They do not provide per-service endpoint
  isolation or custom endpoint policies, grant IAM permissions, or prove Bedrock
  model inference. The live Fargate probe used the compute SG, not a canonical
  application task SG. Region/service availability still requires review.
- The maintainer explicitly deferred the additional **M1 live allowed/denied AWS
  API exercise** on October 20, 2026. It is a qualification exception, not PASS.
- `16/16` counts workload-validator results, not every application behavior or
  compliance certification. Existing production, retirement, encryption and
  disaster-recovery boundaries remain unchanged. RDS recovery qualification,
  WAF, and ALB access logs remain future work.

### Migration and Usage

No configuration change is required to retain the three opt-out defaults. There
is no new state-move procedure for these features, but each deployment still
needs its own reviewed plan; no universal no-change/replacement guarantee is made.
Existing users selecting the dev sample's digest must review its newly configured
health command. Enabling a check changes the task definition; removing an attached
policy revokes that attachment, and resetting the endpoint set to `[]` removes
the optional endpoint. Preserve opt-ins consistently across local and CI inputs.

Inside an existing service entry, independently select the needed options:

```hcl
task_role_managed_policy_arns = [
  "arn:aws:iam::123456789012:policy/application/ApprovedAccess"
]
health_check = {
  command      = ["CMD", "/app/healthcheck"]
  interval     = 30
  timeout      = 5
  retries      = 3
  start_period = 10
}
```

Replace the policy ARN with an approved existing policy in your account/partition
and `/app/healthcheck` with a real executable shipped in your image. Exit code 0
must indicate the health condition your application owner intends to check. A
non-null published digest is required to materialize the service.

At the workload root, independently opt into private Bedrock transport:

```hcl
additional_interface_endpoint_services = ["bedrock-runtime"]
```

For CI, set `ADDITIONAL_INTERFACE_ENDPOINT_SERVICES` to `["bedrock-runtime"]`
where the workload `<env>-plan` GitHub Environment resolves its variables. Keep
local inputs aligned; tfvars/explicit CLI settings can override `TF_VAR_*` values.
See the [quickstart examples and upgrade steps](docs/quickstart.md#v1120-opt-in-configuration-and-upgrade).

## v1.11.1 — Security Hardening and Operational Safeguards

This release entry covers the published `v1.11.0` (`18e579f7`) through the
reviewed implementation and production sample reset on `main` at
`bcef1c472a6fe8b1c852be1847fbdc229975d8b3` (October 16, 2026), including
PRs #862–#864 and #866. The maintainer explicitly retained **v1.11.1**, including
the **breaking Identity Center interface change** below, because no external
customers or repository consumers currently depend on those removed interfaces.
This decision does not make the change backward compatible. The release entry
is not proof of publication; CI success alone is not production qualification.

### Hardening and Corrections

- **Partition and tooling:** Standardized partition-aware ARN construction
  across active Terraform modules and relevant validators; EC2 isolation now
  receives the AWS partition for product-ARN verification and aborts isolation
  with an error result if partition or Region is missing. Expanded Terraform
  Static Analysis root coverage, enabled pinned AWS-specific TFLint rules, and
  made Checkov JSON/JUnit report integrity a blocking check instead of relying
  on a successful soft-fail process. Partition-aware strings do not establish
  GovCloud or China deployment qualification. (#829, #830, #834)
- **IAM, encryption, and networking:** Narrowed EC2 isolation, rollback,
  IP Enrichment, and AWS Config remediation permissions. Added Firehose
  customer-managed KMS encryption and relevant delivery permissions; protected
  default VPC security-group ingress/egress; added incomplete S3 multipart
  upload cleanup and RDS snapshot tag propagation. Added missing Backup/ECR
  KMS-key tags. (#835, #843)
- **AWS Config recording and rules:** Replaced the workload recorder's
  selective inclusion list with `ALL_SUPPORTED_RESOURCE_TYPES`, including
  global IAM where supported, and strengthened live recorder identity/status
  validation. This can increase configuration-item volume and costs, and
  deployments outside the currently qualified Region need a global-IAM
  recording review. Removed the duplicate
  `S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED` catalog entry while preserving
  the separate automatic-remediation rule and configuration, which remain
  controlled by `enable_config` independent of `enable_rules.s3_baseline`.
  (#841, #848)
- **Production logs and retirement:** Made centralized workload log-bucket
  `force_destroy` dependent on environment and approved retirement posture.
  Production normal operation uses `false`; approved Stage-1 retirement
  changes this setting before final destruction. Added a required audit-log
  disposition reference and validated the AWS Apply-role identity and live
  bucket-policy deny conditions before irreversible durable cleanup and final
  destroy. These are authorization guards, **not** WORM retention, external
  archival, independent recovery, or proof that approved retirement preserves
  logs. (#844, #845)
- **Lambda and RDS monitoring:** Configured reserved concurrency for the
  three automation Lambda functions (EC2 isolation 5, rollback 1, IP
  enrichment 2). Enabled 60-second RDS Enhanced Monitoring through a
  dedicated service IAM role and encrypted RDS Performance/Database Insights
  with a dedicated rotating customer-managed KMS key. Extended the existing
  live RDS and KMS validators to compare configuration and key status. (#846, #847)
- **Workflow hygiene:** Applied focused Checkov/CI fixes and simplified
  obsolete workflow definitions and naming; report integrity remains
  mandatory while unresolved Checkov findings remain visible. Renamed the
  control-plane exporter workflow to `export-control-plane-evidence.yml`.
  (#837–#839)

### Functional and Operational Changes

- **Saved-plan Lambda deployment:** #855/#856 normalized all three archive resources to
  `output_file_mode = "0644"` to avoid permission-driven ZIP hash drift. The
  internal Plan job in `Terraform Apply` bundles the generated isolation,
  rollback, and enrichment ZIPs with the reviewed plan and appends their SHA-256
  hashes to its manifest. Apply verifies the manifest and restores those ZIPs
  on its separate runner before applying the saved plan; no new plan or separate
  Apply-side archive build is introduced. This fixes missing local ZIPs during
  saved-plan application. (#855, #856) [#862](https://github.com/jcub-i0/terraform-secure-baseline/pull/862)
  subsequently replaced the managed archives with `data.archive_file` data sources so all
  three ZIPs are generated during planning, including from fresh state, before
  the workflow bundles them.
- **Fargate runtime and application qualification:** Expose
  `fargate_platform_version` through the workload roots and baseline; its default
  changes from `1.4.0` to `LATEST`. The minimal HTTP fixture now runs as a non-root
  user and declares a Docker health check. The existing OIDC image-publisher and
  separate repository-write jobs published a digest and generated the `dev`
  release PR; Terraform deployed the smoke-test service. Those publication,
  scaling, health-alarm, and GuardDuty runtime capabilities predate this patch.
  Temporary digest selection and disabled ingress were restored to the original
  null-digest, optional-ingress sample by #861. (#835, #850, #853, #854, #861)
- **Application base image:** [#863](https://github.com/jcub-i0/terraform-secure-baseline/pull/863)
  changed the minimal HTTP application's Alpine base image from Amazon ECR
  Public to Docker Hub, resolving the ECR Public HTTP 429 failures encountered
  during production image publication.
- **Inspector/ECR validation:** Require registry-level `ENHANCED` scanning and
  effective `CONTINUOUS_SCAN` for each managed repository when Inspector ECR is
  enabled. Legacy `scanOnPush=false` is not treated as missing enhanced scanning.
  Disabled Inspector and empty repository inventories do not demonstrate scan
  coverage. This strengthens validation without changing registry ownership.
  (#857, #858)
- **Reproducible tooling:** Retain the existing Terraform `1.15.8`, AWS provider
  `6.66.0`, and committed per-root provider selections; these are not new version
  upgrades in this delta. Static analysis now pins TFLint `0.64.0`, its AWS
  ruleset `0.49.0`, and Checkov `3.3.26`, scans the previously omitted
  security-operations roots, and repairs Checkov parsing of existing expressions.
  The retirement policy/role guard has focused offline regression coverage.
  (#830, #834, #845)

### Compatibility and Migration Requirements

- **Breaking Identity Center interface change (#836):** The baseline no
  longer owns the optional `SecOps-Analyst` or `SecOps-Engineer` groups,
  permission sets, policies, or assignments. It retains workload
  `SecOps-Operator` and security-operations `SecOps-Administrator`; other
  workforce access is customer-owned. Prior deployments using the optional
  personas may plan **destructive removal of existing access**. Before
  applying, inventory assignments, provision replacement access, remove
  retired inputs, and review the complete Identity Center plan and downstream
  cleanup. Removed interfaces include `enable_secops_analyst`,
  `enable_secops_engineer`, their group-name inputs, customer-managed-policy
  reference/path inputs, and their permission-set output keys. The Engineer
  response policy and persona policy attachments are removed; workload log-read
  and decrypt policies remain available for customer-owned access. Update local
  module calls and GitHub Identity Center input objects. Workload Destroy no
  longer performs an Identity Center cleanup plan/apply: migrate legacy
  attachments separately before deleting workload-owned IAM policies.
- **Existing RDS Insights key:** Switching a previously enabled database
  to a different Insights KMS key can fail at `ModifyDBInstance` even when
  Terraform plans an in-place update. The disposable `dev` database was
  deliberately rebuilt; **do not infer authorization to replace an
  existing populated staging/production database**. Plan and approve a
  workload-specific migration or recreation before deploying this change.
- **AWS Config catalog consolidation (#848):** Applied environments with
  the old duplicate rule must have a reviewed plan showing deletion of
  only the redundant managed-catalog rule, without deletion/replacement of
  `s3_public_access_block[0]` or its remediation configuration. Removing the
  duplicate also removes its historical Config-rule evaluations. Fresh-stack
  CI plans do not qualify this existing-state transition.
- **Existing resource/module callers:** Default security-group adoption clears
  existing ingress and egress rules; inspect attachments and move dependent
  workloads to appropriate explicit groups before applying. Direct storage-module
  callers must provide `centralized_logs_force_destroy` and
  `rds_performance_insights_cmk_arn`. Archive mode normalization can cause a
  one-time archive regeneration/Lambda code update. Review Fargate `LATEST`
  behavior and any explicit platform override rather than assuming the former
  fixed platform selection remains in effect.
- **Runtime limits:** Lambda concurrency reservations require account
  quota headroom for all eight reserved executions and the required unreserved
  pool; low-quota accounts may need a quota increase before deployment.
  Broader AWS Config recording may change ongoing cost.
  Workload KMS keys and centralized logs still require a separately reviewed
  preservation strategy when operational evidence must survive retirement.

### Validation Evidence

- **Production lifecycle (October 16, 2026):**
  [Fresh Apply run 38928131042](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38928131042)
  at `62a0ae8107fe82abb4a5f7d10b70a175d15bbc9a` (#862) passed with
  **312 added, 0 changed, 0 destroyed**; the Apply log confirms all three Lambda
  ZIP checksums `OK`.
  [Publication run 38936199393](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38936199393)
  passed from source `de00f93fabca5f6591766c0ae63b7dc7bd0936d3` (#863), resolving
  `sha256:b0fab9cf198b8503b1f2909f8415a0a7d947c569d578e7feefc7d9d2ceebc6a1`
  for `tf-secure-baseline-prod-test` and generating
  [#864](https://github.com/jcub-i0/terraform-secure-baseline/pull/864).
  [Application Apply run 38939703297](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38939703297)
  passed at `4598219b31c9f904ec3e644523c24c699d364c15` with **21 added, 2 changed,
  0 destroyed**.
  [Production baseline evidence run 38942204719](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38942204719)
  at `4598219b31c9f904ec3e644523c24c699d364c15` retained artifact
  `baseline-validation-prod-38942204719-1` (ID `12063493033`), recording
  **16/16 PASS, 0 failures** at **2026-10-16T17:46:25Z**, including three Fargate
  tasks, three running GuardDuty agents, healthy runtime coverage, ALB, and
  operational alarms.
  [Retirement Stage 1 run 38943444739](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38943444739)
  passed with **0 added, 5 changed, 0 destroyed**, and
  [Destroy run 38944960317](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38944960317)
  passed with **333 resources destroyed**, both at the same `4598219b` revision.
  The production workload was intentionally destroyed; these results do not
  imply active infrastructure. After retirement deleted the qualification
  image, [#866](https://github.com/jcub-i0/terraform-secure-baseline/pull/866)
  (`3fa42a7131a5571b85641a2da4423f62899eaa3e`) restored only the production
  sample's `image_digest` to `null`, preserving its registered service settings.
- **Historical deployment:** [Publication run 38669309326](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38669309326)
  generated #853 from source `78b989de47decf801e2e497dabd86f16bb299461`, selecting
  `sha256:24a0c180dd0325ee56870c040be565e152a3bf035011ace67363009c0be526ec`
  for `tf-secure-baseline-dev-test`.
  [Terraform Apply run 38675095713](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38675095713)
  succeeded on October 15 at `717823ec1a187d3a2beca9a32fc670e90ca45d45`, after
  the ZIP-handoff fix. Its retained Apply log reports all three ZIP checksums
  `OK` and `0 added, 0 changed, 0 destroyed`. This successful convergence run is
  distinct from the subsequent validation revision.
- **Retained workload evidence:** [Baseline evidence run 38680334147](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38680334147)
  succeeded using GitHub OIDC at
  `c3bc2e6cef839559c9cdf678bcb972890344fec8`. Artifact
  `baseline-validation-dev-38680334147-1` records **16/16 PASS, 0 failures** at
  **2026-10-15T04:13:47+00:00**, account `955775177042`, `us-east-1`, environment
  `dev`, profile `development`, effective egress `nat_only`. Its logs confirm
  one ECS service, three running application tasks with three running GuardDuty
  agents, `AUTO_MANAGED` / `HEALTHY` ECS coverage, and `ENHANCED` /
  `CONTINUOUS_SCAN` on the managed ECR repository. No ALB was deployed and
  scheduled AWS Backup was disabled; the Backup-CMK check was consequently
  skipped with a warning. RDS monitoring/Insights configuration and the Insights
  CMK passed their checks. Script totals are not counts of behavioral tests.
- **Separate maintainer-reported results:** The deployed qualification
  configuration converged to a state-backed zero-change plan, and local
  `validate-baseline.sh` passed **16/16, 0 failed**. After #861 restored
  `image_digest = null` and the original optional ingress object, the maintainer
  separately confirmed intended local cleanup, another no-change plan, and
  passing local validation before beginning intentional dev teardown. Those
  local confirmations have no separate timestamped artifact identified here;
  they are not the three-task evidence above or post-destruction plans. The
  restored canonical registration preserves ECR derivation but selects no image
  to deploy. Teardown does not invalidate historical qualification or imply
  those AWS resources remain active.
- **Config transition evidence:** The maintainer reported successful deployment
  reconciliation and later zero-change planning. Source preserves the separate
  remediation rule/configuration; the retained baseline report does not prove
  the exact deleted rule identity or execution of automatic remediation.
  Earlier SSM remediation success reported in [#835](https://github.com/jcub-i0/terraform-secure-baseline/pull/835)
  (October 10, execution `a211cbca-2b60-4455-aa84-17cb5f2c622d`) retains that
  original provenance, not final-candidate retest status.
- **Static analysis:** [Candidate scan 38682111443](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38682111443)
  at `dc16feeb912c03c6eb3413a34654ffae1284674b` and
  [main scan 38681959140](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/38681959140)
  at `4aac66a71153d5afa2c70a568f1d46fdcef8dd48`, both October 15, retained
  matching Checkov `3.3.26` results in `ci-evidence`,
  `repository/checkov.json`: Terraform **915 passed / 23 failed / 29 skipped**
  (16 distinct failing check IDs); GitHub Actions **765 / 0 / 7**; Dockerfile
  **24 / 0 / 0**; **zero parsing errors** in each framework. These are dated
  scan snapshots, not a claim of zero security findings. JSON/JUnit report
  integrity is independently enforced while Checkov uses `--soft-fail`.

### Known Limitations and Deferred Work

- **Resource-local scanner exceptions:** `CKV_AWS_163` reflects Inspector
  enhanced scanning rather than legacy repository scan-on-push; the retained
  dev evidence verifies effective coverage. `CKV_AWS_378` documents HTTPS
  termination at the ALB with HTTP to private Fargate targets, **not end-to-end
  TLS**. `CKV_AWS_117` documents IP Enrichment outside the customer VPC for public
  AbuseIPDB HTTPS access without private-resource dependencies; that egress
  bypasses VPC Network Firewall. Other local exceptions cover existing Lambda
  async failure destinations/separate EventBridge DLQs (`CKV_AWS_116`),
  cross-module Flow Logs, centrally governed GuardDuty, the intentionally unused
  quarantine SG, configurable Container Insights/Fargate values, and disabled
  minimal-profile Config recording. Workflow dispatch exceptions retain
  operator/evidence inputs. Skips do not establish runtime effectiveness.
- **Remaining findings:** [#688](https://github.com/jcub-i0/terraform-secure-baseline/issues/688)
  remains open for WAF, ALB access logs, RDS query logging/IAM authentication,
  secret rotation, Lambda code signing, S3 access logs/notifications/replication,
  CloudTrail SNS, Network Firewall CMKs, and outstanding KMS-policy/AZ-discovery
  findings. The maintainer deferred broader remediation to separately scoped
  work; deferral is neither remediation nor blanket security-risk acceptance.
  Encryption, secret storage, and scanning do not rotate credentials or remediate
  vulnerabilities automatically. No bulk suppressions are introduced here.
- **Qualification limits:** The dev `nat_only` run does not retest production
  three-AZ topology, RDS failover, AWS Backup Restore Testing execution,
  production retirement/durable cleanup, Network Firewall egress, or optional
  ALB ingress. Historical tests retain their original revision/configuration.
  The separate October 16 production lifecycle above qualifies application
  publication/deployment, retained live validation, retirement, and destroy;
  it does not establish RDS failover, completed AWS Backup Restore Testing,
  or additional behavioral tests not recorded here.
  Neither these results nor the configured controls establish zero residual
  risk, immutable retention, guaranteed recovery, or SOC 2 / ISO 27001
  certification. Scope decisions are tracked in
  [#840](https://github.com/jcub-i0/terraform-secure-baseline/issues/840).

## v1.11.0 — Production Resilience and Operator Contracts

This section records the implemented changes since `v1.10.0` and their
documentation reconciliation. Earlier behavioral qualifications and new
configuration-level checks retain their own test revisions, inputs, and evidence.

### Networking and Region Authority

- Added production-default three-AZ topology, retaining two-AZ defaults for the other
  profiles and requiring complete explicit subnet families for additional AZs.
- Separated ingress-public subnets for the ALB from egress-public subnets for NAT,
  preserving the VPC-local ingress path and same-AZ inspected compute return routes.
- Added canonical IPv4 `/16` workload CIDR validation and derived `/24` subnet families.
  Explicit subnet overrides must contain the seven required families and match the
  selected AZ inventory without overlaps.
- Made workload `primary_region` agree with the AWS provider and constrained explicit
  AZs to the discovered standard AZ inventory. State-resource `state_region` remains
  distinct from service Region and literal S3 backend `region`.
- Extended resource-backed topology outputs and exact networking/endpoint comparisons.
  Region-authoritative configuration is not evidence of cross-Region recovery.

Sources: [baseline inputs](baseline/variables.tf), [derived settings](baseline/locals.tf),
[composition](baseline/main.tf), [outputs](baseline/outputs.tf), and
[networking validation](scripts/validation/validate-networking.sh).

### Availability, Backups, and Restore Testing

- Enforced RDS Multi-AZ for production while retaining the PostgreSQL DB-instance
  resource model. Production normal-operation deletion protection, final-snapshot
  requirements, and automated-backup retention are explicit lifecycle settings.
- Added normal-operation production ECS capacity requirements: at least two fixed
  tasks or an autoscaling minimum of two, with explicit AZ rebalancing and a retirement
  exception. Three-AZ networking does not independently prove task distribution.
- Added profile-derived ALB/firewall deletion protection, ECR/ECS force-delete settings,
  and Backup-vault force-destroy settings. Workload logs and KMS keys do not gain
  equivalent preservation guarantees from the production profile.
- Added AWS Backup Restore Testing for the exact managed RDS instance when production
  scheduled backup is enabled. The selection uses eligible snapshots from the workload
  vault and private Single-AZ temporary restore metadata.
- Expanded Backup validation to compare RDS resilience and Backup/Restore Testing
  configuration and report restore execution, application-validation, and cleanup
  status separately. No application-data validation handler is supplied by the Backup
  module, and some warning outcomes can coexist with a passing validator.
- Production scheduled backup remains an overridable default: explicit
  `backup_enabled=false` disables its plan/selection and profile-derived Restore
  Testing. RDS-native automated backups are a separate configuration.

Sources: [profile and lifecycle derivation](baseline/locals.tf),
[storage](modules/storage/main.tf), [backup resources](modules/backup/main.tf), and
[Backup validator](scripts/validation/validate-backup.sh).

### Staged Production Retirement

- Added `production_retirement_mode` and a reviewed Stage-1 transition that derives
  zero ECS capacity while relaxing only the selected deletion protections.
- Added exact Stage-1 plan validation, retirement readiness checks, and separately
  authorized durable-data cleanup before saved-plan workload destruction.
- Kept production ECR/ECS force deletion and Backup-vault force destruction disabled.
  Durable cleanup is an explicit operation, not an implicit force-delete setting.
- Preserved separately planned and approved Identity Center cleanup before final
  workload-destroy approval. Rejecting a later gate does not undo earlier cleanup.
- The complete durable-cleanup path is `prod`-only and re-inventories at execution;
  its inventory is not an immutable item manifest replayed at cleanup time.

Sources: [retirement procedure](docs/production-retirement.md),
[Destroy workflow](.github/workflows/terraform-destroy.yml),
[Stage-1 plan validator](scripts/deployment/validate-production-retirement-plan.sh), and
[readiness validator](scripts/deployment/validate-retirement-readiness.sh).

### Publication, Tooling, and Distribution Defaults

- Replaced explicit ECR `docker login` in publication with the Amazon ECR Docker
  credential helper, a temporary push-only Docker configuration, disabled helper
  token-file caching, and cleanup handling. The workflow supplies the helper.
- Standardized workflow Terraform CLI selection and committed per-root dependency
  locks for reproducible initialization. External service behavior and most-recent
  AMI selection remain separate sources of change.
- Reset the production sample service to `image_digest=null`, retaining registration
  and its required ECR repository without selecting a qualification image for deployment.

Sources: [publication script](scripts/deployment/deploy-application.sh),
[publication workflow](.github/workflows/deploy-application.yml),
[Plan workflow](.github/workflows/terraform-plan.yml), and
[production workload configuration](environments/prod/container-workloads.auto.tfvars.json).

### Operator Rollback Authorization

- Corrected the workload Operator's IAM Identity Center EventBridge ARN to
  derive the same `<cloud_name>-<environment>-secops-bus` name as workload
  automation; the Identity Center root now accepts `cloud_name` with a `tf-secure-baseline` default.
- Scoped the `custom.rollback` EventBridge bus-policy Allow to matching
  `AWSReservedSSO_SecOps-Operator-<environment>_*` IAM role ARNs (including
  their generated suffixes) and explicitly denied publication by other
  principals for that source. Separate `aws.securityhub` forwarding remains.
- Development testing reported an explicit resource-policy denial for an
  unauthorized IAM user and a successful rollback submitted through an IAM
  Identity Center `SecOps-Operator-dev` session. This point-in-time dev
  result does not qualify staging or production; retain individual run evidence.
- The handler still treats `approved_by` and `ticket_id` as caller-supplied
  metadata, not an independently authenticated approval check.

Sources: [Identity Center caller](bootstrap/control_plane/identity_center/main.tf),
[EventBridge bus policy](modules/automation/main.tf),
[rollback handler](modules/automation/lambda/ec2_rollback.py), and
[manual test guide](docs/lambda_tests/ec2_rollback.md).

### Documentation and Evidence Boundaries

- Reconciled deployment, state, retirement, module, validation, response-test, adoption,
  and assurance references with implemented interfaces and operational boundaries.
- Distinguished source configuration, point-in-time assertions, behavioral exercises,
  and ongoing operating evidence. Earlier qualification retains its original run and
  input provenance; it is not relabeled as testing performed during documentation work.
- Corrected claims of immutable workload logging, universal least privilege,
  authenticated rollback approval, complete DLQ coverage, and production-wide key
  destruction guards. Recording those limitations does not repair or accept them.
- Removed the superseded planning document and replaced root release narration with
  behavior-based guidance. Historical milestones remain below, not as future commitments.
- Clarified private vulnerability reporting without inventing contact information,
  response deadlines, or support guarantees. Existing license terms and ownership
  notices are not amended by this documentation work.

The maintained [validation reference](scripts/validation/README.md),
[evidence guide](docs/assurance/validation-evidence-guide.md), and
[control narratives](docs/assurance/control-narratives.md) identify what each check
can establish. The validation architecture retains four layers, with sixteen child scripts in
the workload-baseline layer; counts are not an assurance opinion.

## v1.10.0 — ECS Runtime Security

v1.10.0 extends the ECS/Fargate platform with GuardDuty Runtime Monitoring, deployment-profile-driven cluster enrollment, least-privilege managed-agent prerequisites, runtime coverage-health notification, and exact live validation. The release also corrects the profile-aware AWS Backup contract discovered during live qualification.

### Added

- Enabled the centralized GuardDuty Fargate automated-agent organization contract:
  - `RUNTIME_MONITORING = ALL`;
  - `ECS_FARGATE_AGENT_MANAGEMENT = ALL`;
  - `EC2_AGENT_MANAGEMENT = ALL`; and
  - `EKS_ADDON_MANAGEMENT = NONE`.
- Added deployment-profile-driven GuardDuty Fargate Runtime Monitoring intent:
  - `production` -> enabled;
  - `development` -> enabled; and
  - `minimal` -> disabled.
- Added the exact AWS-defined ECS cluster participation tag:
  - enabled profiles -> `GuardDutyManaged=true`;
  - minimal -> `GuardDutyManaged=false`.
- Added resource-backed ECS cluster outputs for Runtime Monitoring expectation and live Terraform tag value.
- Added a Region-aware GuardDuty Fargate agent ECR account mapping and exact repository ARN derivation for `repository/aws-guardduty-agent-fargate`.
- Added profile-aware ECS task execution-role image-pull authority for the GuardDuty agent using only:
  - `ecr:BatchCheckLayerAvailability`;
  - `ecr:GetDownloadUrlForLayer`; and
  - `ecr:BatchGetImage`.
- Added a default-bus EventBridge rule for both:
  - `GuardDuty Runtime Protection Unhealthy`; and
  - `GuardDuty Runtime Protection Healthy`
  ECS coverage-state events.
- Added the GuardDuty coverage target to the existing SecOps SNS topic with:
  - the shared security-notification EventBridge DLQ;
  - three retry attempts;
  - 3600-second maximum event age; and
  - an input transformer preserving workload account, Region, ECS cluster, current/previous status, issue, GuardDuty update time, and event time.
- Added the `guardduty_ecs_runtime_coverage_notification` workload output for exact validation.
- Added `guardduty.sh` to the internal ECS runtime validator helpers while preserving `validate-ecs-runtime.sh` as the single workload-baseline ECS entry point.
- Added live GuardDuty task-instrumentation validation that accepts either `aws-gd-agent` or AWS-generated `aws-guardduty-agent-<suffix>` names while requiring exactly one running agent.
- Added GuardDuty ECS coverage validation for:
  - expected detector/account/cluster identity;
  - `ResourceDetails.ResourceType = ECS`;
  - Fargate `ManagementType = AUTO_MANAGED`;
  - `CoverageStatus = HEALTHY`; and
  - no unresolved coverage issues.
- Added disabled-state Runtime Monitoring validation for `minimal`, including `GuardDutyManaged=false`, no GuardDuty-agent ECR authority, and valid absent/`DISABLED` coverage semantics.

### Changed

- Kept GuardDuty organization Runtime Monitoring ownership in `security-operations`; workload Terraform now expresses ECS cluster participation and owns only workload-local IAM, networking, service configuration, and validation expectations.
- Kept the canonical Terraform ECS task definition application-only. GuardDuty service-manages agent injection, upgrades, and runtime telemetry.
- Reused the existing Terraform-owned `guardduty-data`, `ecr.api`, `ecr.dkr`, and S3 endpoint paths; v1.10 does not introduce a parallel GuardDuty-managed VPC endpoint/security-group model.
- Extended `validate-vpc-endpoints.sh` to require the complete live Interface Endpoint ID map to match Terraform and to prove exactly one Terraform-owned `guardduty-data` endpoint exists.
- Extended `validate-iam.sh` to compare the complete ECS execution-role ECR authority against exact application and GuardDuty repository requirements, rejecting broad or unexpected ECR grants.
- Extended `validate-eventbridge.sh` to validate the exact GuardDuty Runtime coverage rule, SNS target, shared DLQ, retry policy, and evidence-preserving transformer.
- Changed security-operations GuardDuty feature validation to compare the Terraform-managed feature subset exactly while allowing AWS-returned features outside Terraform management only when their feature and additional-configuration values remain `NONE`.
- Corrected AWS Backup profile semantics:
  - the KMS-encrypted backup vault is retained regardless of scheduled-backup enablement;
  - the backup plan and selection exist only when backups are enabled;
  - effective backup schedule/retention resolve to `null` when disabled;
  - production defaults to daily scheduling with 30-day retention;
  - explicitly enabled non-production backup defaults to 7-day retention unless overridden; and
  - EC2/RDS `Backup` tags now exactly match effective backup enablement.
- Updated workload-security validation to delegate detailed disabled-state Backup semantics to `validate-backup.sh` instead of reporting unqueried zero counts.

### Fixed

- Fixed live GuardDuty agent validation so AWS-generated `aws-guardduty-agent-<suffix>` container names are recognized instead of assuming only `aws-gd-agent`.
- Fixed GuardDuty coverage parsing to read resource type from `.ResourceDetails.ResourceType`, matching the live AWS coverage response shape.
- Fixed centralized GuardDuty organization validation that previously treated AWS-returned disabled, unmanaged feature inventory as drift.
- Fixed the Backup module behavior that created a backup plan and selection even when `effective_backup_enabled=false`.
- Added Terraform `moved` blocks so the conditional Backup plan/selection resources preserve state addresses when enabled.
- Fixed workload EC2 and RDS Backup tagging so disabled profiles use `Backup=false`.
- Fixed Backup validation for nullable root outputs by treating omitted null schedule/retention outputs from `terraform output -json` as `null`.
- Fixed misleading disabled-backup summary reporting in `validate-security-workload.sh`.

### Security

- Makes GuardDuty Fargate Runtime Monitoring secure-by-default for `production` and `development` while preserving an explicit cost-minimized `minimal` exclusion.
- Preserves least privilege by adding only the exact AWS-hosted GuardDuty agent repository pull scope required for protected services.
- Preserves Terraform ownership of private Runtime Monitoring networking and rejects duplicate/unexpected `guardduty-data` endpoint state.
- Adds operational visibility when GuardDuty ECS Runtime Monitoring coverage becomes unhealthy or recovers.
- Keeps Runtime Monitoring separate from automatic Fargate containment. v1.10 does not attempt to modify AWS-managed task ENIs or copy the EC2 quarantine model to ECS.

### Validation

- Live development qualification confirmed centralized `ECS_FARGATE_AGENT_MANAGEMENT = ALL`.
- Live development qualification confirmed `GuardDutyManaged=true` on the Terraform-managed ECS cluster.
- A real Fargate service received one GuardDuty agent that reached `RUNNING` while the application remained healthy.
- GuardDuty ECS coverage reported `AUTO_MANAGED`, `HEALTHY`, and zero unresolved coverage issues.
- Validation confirmed reuse of the unique Terraform-owned `guardduty-data` endpoint and exact GuardDuty-agent ECR IAM scope.
- `validate-ecs-runtime.sh` passed against the qualified development runtime.
- The full workload baseline completed with `16/16` validators passing.
- Security-operations validation passed the centralized GuardDuty organization contract after aligning validation with AWS's returned feature inventory.
- The corrected disabled-backup contract was applied and validated in development: retained encrypted vault, absent plan/selection, and `Backup=false` workload tags.
- `export-baseline.sh` produced an overall `PASS` workload evidence package after the final R6 corrections.

### Deferred / Future

- Automatic ECS/Fargate task containment or remediation remains deferred pending a separate fail-closed design.
- The ReconoSense reference deployment remains future work.
- Scheduled/run-to-completion task abstractions, audited ECS Exec, advanced WAF/DNS ownership, multi-container services, application database-user lifecycle, more sophisticated historical ECR retention, and broader platform-resilience work remain future design areas.

## v1.9.0

v1.9.0 extends the v1.8 ECS/Fargate runtime with explicit service-count ownership, Application Auto Scaling, deployment-health controls, operational alarms, exact runtime validation, and additional EC2 isolation hardening. The implementation completed live qualification and release documentation.

### Added

- Added an optional canonical `ecs_services.<service>.scaling` object with:
  - `min_capacity`;
  - `max_capacity`;
  - optional CPU target tracking through `cpu_target_percent`;
  - optional memory target tracking through `memory_target_percent`;
  - optional ALB request-count target tracking through `alb_requests_per_target`; and
  - configurable scale-in and scale-out cooldowns, defaulting to 300 seconds.
- Added one ECS Application Auto Scaling target for each deployable service with non-null scaling configuration.
- Added target-tracking scaling policies using AWS predefined metrics:
  - `ECSServiceAverageCPUUtilization`;
  - `ECSServiceAverageMemoryUtilization`; and
  - `ALBRequestCountPerTarget`.
- Added Terraform-backed ALB and target-group ARN suffix outputs so ALB request scaling and operational monitoring use resource identities rather than reconstructing AWS identifiers in validation code.
- Added an optional canonical `ecs_services.<service>.deployment` object with:
  - `minimum_healthy_percent`, defaulting to `100`;
  - `maximum_percent`, defaulting to `200`; and
  - `health_check_grace_period_seconds`, defaulting to `0`.
- Added Terraform-owned ECS operational alarms:
  - sustained desired-versus-running task deficit using `ECS/ContainerInsights`; and
  - sustained unhealthy ALB targets for ingress-enabled services using `AWS/ApplicationELB`.
- Added resource-backed baseline outputs for:
  - validator-relevant ECS service configuration;
  - Application Auto Scaling targets;
  - CPU target-tracking policies;
  - memory target-tracking policies;
  - ALB request-count target-tracking policies;
  - task-deficit alarms; and
  - ingress unhealthy-target alarms.
- Refactored `validate-ecs-runtime.sh` into one stable validator entry point backed by focused helpers under `scripts/validation/lib/ecs-runtime/` for contract, cluster, services, autoscaling, ingress, alarms, and summary validation.
- Added workload-level `ec2_auto_isolation_severities` configuration. The supported automatic-isolation severity set is `HIGH` and/or `CRITICAL`, with `CRITICAL` as the default.

### Changed

- Split ECS service ownership into fixed-count and autoscaled Terraform resources because `lifecycle.ignore_changes` cannot be selected conditionally per `for_each` instance.
- Fixed-count services continue to use Terraform-owned `desired_count`.
- Autoscaled services treat configured `desired_count` as bootstrap capacity; Application Auto Scaling owns subsequent live desired count changes within the configured minimum and maximum.
- Autoscaled ECS services ignore later Terraform reconciliation of `desired_count`, preventing legitimate runtime scaling from being forced back to the bootstrap value.
- `scaling = null` means the service has no platform-owned Application Auto Scaling target or scaling policies.
- Registered-but-unreleased services with `image_digest = null` continue to create no ECS runtime or scaling resources.
- ALB request-count scaling now requires canonical ingress configuration and uses the resource-backed ALB/target-group identity produced by Terraform.
- ECS deployment minimum/maximum percentages and health-check grace period are now part of the canonical service contract and are applied to both fixed and autoscaled services.
- ECS operational alarms remain separate from AWS-managed target-tracking alarms. Terraform does not adopt, edit, or repurpose the CloudWatch alarms created internally by Application Auto Scaling.
- The workload validation architecture remains four layers. ECS runtime operations stay inside the existing workload-baseline layer; no fifth validation/evidence layer was introduced.
- Application release ownership remains unchanged: `Deploy Application` publishes an image and the release mutation changes only `ecs_services.<service>.image_digest`; it does not change scaling or deployment configuration.
- The protected exact-saved-plan Terraform Apply workflow remains unchanged.

### Fixed

- Fixed autoscaled service drift so Terraform no longer reasserts the configured bootstrap `desired_count` after Application Auto Scaling legitimately changes the service count.
- Fixed automatic EC2 isolation scope so broad HIGH/CRITICAL Security Hub findings from products such as Inspector cannot independently trigger containment.
- Fixed the EC2 Isolation Lambda to fail closed when `RecordState` is missing instead of treating a missing value as `ACTIVE`.

### Security

- Restricted the EC2 isolation EventBridge rule to GuardDuty findings imported through Security Hub with:
  - GuardDuty `ProductArn`;
  - `HIGH` or `CRITICAL` severity;
  - `AwsEc2Instance` resource type;
  - `Workflow.Status = NEW`; and
  - `RecordState = ACTIVE`.
- Kept the EventBridge rule broad enough to admit both HIGH and CRITICAL GuardDuty EC2 findings while allowing the Lambda's configured severity set to decide which severities are eligible for automatic containment.
- The EC2 Isolation Lambda independently revalidates GuardDuty product identity, configured severity, workflow status, and record state before evaluating instance-level isolation gates.
- Automatic isolation continues to require `IsolationAllowed=true`, an isolatable instance state, a non-isolated target, and successful pre-isolation EBS snapshot requests before quarantine.
- The separate IP Enrichment Security Hub HIGH/CRITICAL rule remains broad and is not restricted to GuardDuty or EC2 findings.

### Validation

- Live qualification confirmed CPU target-tracking scale-out and scale-in behavior.
- Live qualification confirmed memory target-tracking behavior.
- Live qualification confirmed ALB request-count target tracking when ingress is configured.
- Fixed-count services were verified to remain Terraform-owned at the configured `desired_count`.
- Autoscaled services were verified to allow Application Auto Scaling to own live desired count within configured bounds.
- Digest-pinned application release was exercised while the service was scaled.
- Deployment-health settings were verified against live ECS service configuration.
- Task-deficit and ingress unhealthy-target operational alarms were verified against Terraform-owned configuration.
- `validate-ecs-runtime.sh` passed against the qualified development runtime after the validator refactor.
- The full workload baseline validation completed with `16/16` validators passing.
- Strict workload bootstrap validation completed with `1/1` validator passing.
- The final Terraform plan after qualification reported no changes.

### Deferred / Future

- GuardDuty Fargate managed-agent enablement remains outside the current release boundary.
- Fail-closed ECS task-level containment/remediation remains future work.
- The ReconoSense reference deployment remains future work.
- Scheduled/run-to-completion task abstractions, audited ECS Exec, advanced WAF/DNS ownership, multi-container services, application database-user lifecycle, and more sophisticated historical ECR retention remain future design work.

## v1.8.0 — Secure Container Workloads

v1.8.0 adds a generic secure ECS/Fargate application runtime and release path while retaining EC2 as a supported host-based workload pattern. The runtime, image-publication workflow, digest-promotion workflow, protected exact-plan deployment path, and workload validation are implemented and live-tested.

### Added

- Added separate reusable `modules/ecr`, `modules/ecs_cluster`, `modules/application_load_balancer`, and `modules/ecs_service` modules rather than combining ECS with the EC2-only `modules/compute`.
- Added one shared ECS cluster per workload environment with configurable Container Insights and an `enhanced` default.
- Added the canonical environment-level `ecs_services` map. Baseline derives the narrower ECR, IAM, ALB, security-policy, and ECS-runtime maps instead of requiring operators to maintain parallel service inventories.
- Added registered-but-unreleased services through nullable `ecs_services.<service>.image_digest`. A null digest preserves the required ECR repository while withholding the task definition, service, per-service IAM roles, task security group, and runtime log group until an exact digest is selected.
- Added digest-pinned Fargate task definitions using Linux, `awsvpc`, compute-private subnets, no public task IP, per-service execution/task roles, Terraform-owned KMS-encrypted log groups, deployment circuit breaking, and automatic rollback.
- Added Terraform-owned ECS service log groups under `/aws/ecs/<name-prefix>/<service>` and a cluster-owned Container Insights performance log group under `/aws/ecs/containerinsights/<cluster-name>/performance`, both using effective retention and the workload logs CMK.
- Added a conditional shared internet-facing HTTPS ALB with explicit host/path listener rules, `ip` target groups, a fixed 404 default action, a caller-supplied ACM certificate, and the default TLS policy `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`.
- Added per-service task security groups and cross-component ECS rules under `modules/networking/security_policy`, including Interface Endpoint, S3 managed prefix-list, optional database, optional ALB, and egress-mode-aware HTTPS relationships.
- Added resource-granular ECS launch readiness through `terraform_data.ecs_execution_policy_ready` and `terraform_data.ecs_security_policy_ready` without module-level dependency cycles.
- Added private ECR connectivity through `ecr.api`, `ecr.dkr`, and the existing S3 Gateway Endpoint path.
- Added KMS-encrypted immutable ECR repositories, 30-day untagged-only lifecycle cleanup, effective repository derivation from explicit repositories plus ECS requirements, and exact non-secret repository metadata outputs.
- Added separate least-privilege ECS task execution and application task roles per service. Execution policies scope ECR pulls, CloudWatch Logs, declared Secrets Manager/SSM references, and optional execution-time KMS decrypt permissions; task roles initially carry no broad application permissions.
- Added non-secret RDS consumer outputs and validator-facing resource-backed outputs for ECS platform version, Container Insights, ECR/logging CMKs, database-access intent, ALB HTTPS listener metadata, and the S3 managed prefix-list ID.
- Added `validate-ecr.sh` and `validate-ecs-runtime.sh`; the existing IAM validator now validates ECS role trust and policy separation. The workload baseline layer now contains 16 validators and remains one of the existing four validation/evidence layers.
- Added `scripts/deployment/deploy-application.sh` and `update-application-digest.sh`, plus the `Deploy Application` workflow, for platform-aware Docker builds, ECR publication, authoritative digest resolution, and one-field release-PR generation.
- Added an optional, environment-specific GitHub OIDC image-publisher role with branch-scoped trust and ECR-only publication/query authority. The AWS publisher job and GitHub release-PR job use separate credentials and permissions.

### Changed

- ECS/Fargate is now the preferred modern SaaS/application runtime; EC2 remains supported and `modules/compute` remains EC2-only.
- ECR repositories required by `ecs_services` are merged with explicitly configured repositories. A repository can be created first through `repositories` and later retained under the same map key when it becomes service-derived.
- Application releases now use tracked `environments/<env>/container-workloads.auto.tfvars.json` files and change only the selected service's `image_digest`; Terraform continues to own runtime materialization and never builds or pushes images.
- Network Firewall domain targets are now the Terraform-owned union of platform-required and environment-approved application domains when Network Firewall is active.
- Standardized ECS application log-group names as `/aws/ecs/<name-prefix>/<service>` and finalized the optional task-startup KMS field name as `task_execution_kms_key_arns`.
- Runtime and IAM validation now compare resource-backed expected values with live AWS state for ECR CMK identity, ECS and Container Insights log-group CMK identity and retention, Container Insights configuration, Fargate platform version, task-execution KMS scope, database SG intent, ALB listener/certificate/TLS metadata, and S3 prefix-list identity.
- Workload Terraform Plan and Apply paths now require a valid `DEPLOYMENT_PROFILE`. The standalone Plan workflow remains informational, while the self-contained Apply workflow generates, records, checksums, obtains approval for, verifies, and applies its own exact saved binary plan without replanning.
- Application source, Docker builds, tests, image publication, digest promotion, schema migrations, and release sequencing remain outside Terraform ownership. ECS infrastructure remains in the existing workload environment state.

### Validation

- The application publication and release-PR path, protected exact-saved-plan Apply, and ECS/Fargate runtime were exercised against live development workload infrastructure.
- `validate-ecs-runtime.sh` verifies cluster state, exact service inventory, service steady state and completed primary rollout, Fargate networking, one essential service container, immutable image references, logging, task security policy, conditional database access, and conditional ALB relationships.
- `validate-iam.sh` verifies exact optional `task_execution_kms_key_arns` scope and rejects `kms:Decrypt` when the configured set is empty.
- `validate-logging.sh` verifies that matching workload CloudWatch groups with explicit retention use the effective retention period.
- Empty `repositories = {}` and `ecs_services = {}` configurations remain valid; the environment ECS cluster still exists while per-service runtime resources and the ALB are absent.
- Final development workload validation completed successfully with all 16 workload validators passing, followed by a converged Terraform plan with no changes.

### Deferred / Future

- ECS Service Auto Scaling, GuardDuty Fargate agent management, ECS task-level containment, and the ReconoSense reference deployment are post-v1.8.0 work, not release blockers.
- GuardDuty `ECS_FARGATE_AGENT_MANAGEMENT` remains `NONE`; operating the ECS runtime does not itself enable central Fargate agent management.
- Scheduled/run-to-completion tasks, migration-task abstractions, audited ECS Exec, advanced WAF/DNS ownership, multi-container services, and application database-user lifecycle remain future design work.

## v1.7.0

This update introduces a dedicated `security-operations` administration layer and centralizes Security Hub CSPM, GuardDuty, and Security Hub V2 governance while preserving workload-local configuration, detection, remediation, and response responsibilities.

### Added

- Added dedicated `bootstrap/security_operations` Terraform roots for:
  - protected remote Terraform state;
  - account bootstrap and GitHub OIDC roles; and
  - centralized security-service administration.
- Added a root-level `Security` OU and placed the `security-operations` account in that dedicated administration boundary.
- Added Security Hub and GuardDuty delegated-administrator registration and the Organizations trusted-service prerequisites required by centralized security.
- Added centralized Security Hub CSPM administration with:
  - a finding aggregator;
  - CENTRAL organization configuration;
  - per-workload configuration policies;
  - workload policy associations; and
  - FSBP and CIS v5.0 standard selection through the policy input model.
- Added centralized GuardDuty organization governance with:
  - automatic organization member enrollment;
  - S3 data events;
  - EBS malware protection;
  - Lambda network logs; and
  - Runtime Monitoring with EC2 agent management enabled while unused ECS/Fargate and EKS agent-management integrations are explicitly disabled.
- Added GuardDuty Malware Protection Organizations trusted-service access for centralized EBS malware protection.
- Added Security Hub V2 organization-management prerequisites, including:
  - `SECURITYHUB_POLICY` enablement;
  - the management-account Security Hub V2 service-linked role; and
  - an Organizations resource policy allowing the delegated administrator to manage and tag Security Hub organization policies.
- Added Security Hub V2 administrator enablement in `security-operations` and a `SECURITYHUB_POLICY` attached to the `Workloads` OU for the primary Region.
- Added staged rollout controls for centralized Security Hub CSPM, GuardDuty, and Security Hub V2 organization configuration.
- Added workload ownership flags so reusable security modules can still manage Security Hub/GuardDuty locally while centrally governed `dev`, `staging`, and `prod` environments defer those resources.
- Added the required `SecOps-Administrator` IAM Identity Center group, permission set, and security-operations account assignment.
- Added consolidated Identity Center configuration inputs:
  - `IDENTITY_CENTER_WORKLOADS`; and
  - `IDENTITY_CENTER_SECOPS`.
- Added strict JSON/schema validation for consolidated Identity Center inputs in control-plane CI and evidence paths.
- Added `security-operations` as a supported `migrate-state-stack.sh` target.
- Added `guardduty-data` to the Terraform-managed Interface VPC Endpoint set so GuardDuty Runtime Monitoring does not create an unmanaged workload endpoint.
- Added Interface Endpoint ID outputs and a compute endpoint-readiness dependency so EC2 instances wait for Terraform-managed Interface Endpoints before launch.
- Added `validate-security-operations.sh` and `export-security-operations.sh` for delegated-administrator validation and evidence export.
- Added the `Export Security Operations Evidence` GitHub Actions workflow using the `security-operations-plan` environment and Plan role.
- Added the `bootstrap/security_operations/security_services` stack to the standalone Terraform Plan matrix.
- Added machine-readable validation metadata that distinguishes cross-layer evidence workflows from genuinely manual/live validation activities.
- Added `bootstrap/security_operations/README.md` and refreshed architecture, adoption, quickstart, design, module, assurance, validation, root README, and release documentation for the centralized-security model.

### Changed

- Changed the platform account model from control-plane plus three workloads to five explicit accounts:
  - `control-plane`;
  - `security-operations`;
  - `dev`;
  - `staging`; and
  - `prod`.
- Changed workload Security Hub CSPM ownership from local standards subscriptions to centrally associated CSPM policies in the managed environments.
- Changed workload GuardDuty ownership so centrally governed environments defer detector/feature management to the delegated administrator.
- Changed workload Security Hub V2 ownership so centrally governed environments inherit the Organizations policy instead of managing V2 locally.
- Preserved standalone module defaults for local Security Hub/GuardDuty ownership outside the centralized deployment model.
- Changed GuardDuty Runtime Monitoring additional configuration from an unordered map representation to an ordered structure matching AWS/provider return ordering and avoiding perpetual replacement plans.
- Imported the existing AWS Organization into Terraform ownership and enabled `SECURITYHUB_POLICY` through the managed `aws_organizations_organization` resource with destroy protection.
- Changed the Organizations stack to own strict account placement for:
  - `dev` and `staging` under `Workloads/NonProd`;
  - `prod` under `Workloads/Prod`; and
  - `security-operations` under `Security`.
- Refactored duplicated workload IAM Identity Center module calls into one `for_each` workload map while keeping the security-operations access model separate.
- Replaced previous per-environment Identity Center variables and outputs with consolidated workload/security-operations structures.
- Changed validation architecture from three layers to four current layers:
  - control plane;
  - security operations;
  - workload bootstrap; and
  - workload baseline.
- Changed workload security validation from the previous `validate-security-services.sh` naming/scope to `validate-security-workload.sh`, reflecting the split between centralized and member-account responsibilities.
- Changed validation/evidence language so checks performed by another evidence workflow are reported as outside the current report rather than incorrectly labeled manual.
- Changed compute launch ordering so EC2 waits for both security-policy rule readiness and the Terraform-managed Interface Endpoint set.
- Updated the Terraform Plan workflow to pass security-operations rollout flags and CSPM workload policy configuration through the `security-operations-plan` GitHub Environment.
- Kept GuardDuty organization feature defaults in source-controlled Terraform rather than duplicating that policy object in GitHub variables.
- Kept security-operations out of the generic workload Apply and Destroy workflows; centralized security remains a deliberately separate platform lifecycle because of its organization-wide blast radius.

### Fixed

- Fixed GuardDuty Runtime Monitoring drift caused by AWS returning disabled ECS/Fargate and EKS sub-configurations alongside enabled EC2 agent management.
- Fixed centralized EBS malware protection by enabling the required `malware-protection.guardduty.amazonaws.com` Organizations trusted service.
- Fixed Security Hub V2 organization-policy creation from the delegated administrator by granting required Organizations policy tagging permissions.
- Fixed fresh Organizations deployment ordering so managed organization attributes exist before dependent OU/account discovery consumes them.
- Fixed conditional centralized-security resources and outputs when rollout controls are disabled.
- Fixed control-plane validation paths that referenced removed per-environment account and permission-set outputs.
- Fixed optional Identity Center group validation so advisory/required behavior follows configured role enablement.
- Fixed Destroy-side Identity Center cleanup to modify only the selected workload entry in the consolidated map.
- Fixed unmanaged GuardDuty Runtime Monitoring VPC endpoint drift by pre-creating `guardduty-data` in the workload VPC.
- Fixed a potential EC2/GuardDuty sequencing problem by making compute wait for the Interface Endpoint resources before instance launch.
- Fixed VPC endpoint validation to match the Terraform-owned endpoint set, including `guardduty-data`.
- Fixed stale validation-report references so workload security evidence uses `validate-security-workload.log`.

### Security

- Centralized Security Hub CSPM standards and control governance to reduce workload-account drift.
- Centralized GuardDuty membership and protection-plan governance in the dedicated delegated-administrator account.
- Added Security Hub V2 workload enablement through an Organizations policy attached to the `Workloads` OU.
- Preserved management-account versus delegated-administrator ownership boundaries for organization prerequisites and service configuration.
- Preserved workload-local Config, Inspector, remediation, incident-response automation, and supporting controls while centralizing account-level Security Hub/GuardDuty governance.
- Added a dedicated `SecOps-Administrator` access model rather than reusing workload Operator permissions in the security-operations account.
- Kept optional Analyst and Engineer access disabled by default until required target-account policies exist.
- Added stricter account identity, OU placement, policy-association, and effective-policy validation across control-plane and security-operations evidence.
- Made GuardDuty Runtime Monitoring networking deterministic by keeping `guardduty-data` under Terraform ownership and sequencing it before eligible EC2 instances.

### Validation and Evidence

- Control-plane evidence validates Organizations topology, strict account placement, delegated-administrator prerequisites, and Identity Center assignments.
- Security Operations evidence validates centralized Security Hub CSPM, GuardDuty, Runtime Monitoring, and Security Hub V2 delegated-administrator state.
- Workload bootstrap evidence validates state/OIDC readiness and current workload CMK references.
- Workload baseline evidence validates workload-local control areas, including workload security realization and VPC endpoints.
- Security-operations and production workload evidence runs completed successfully for the released validator inventories.

### Notes

- Centralized Security Hub CSPM, GuardDuty, and Security Hub V2 organization governance are implemented for the current architecture.
- Security-operations planning and validation/evidence are integrated with GitHub Actions through `security-operations-plan`.
- The generic workload Apply and Destroy workflows intentionally do not include security-operations stacks.
- Configure `IDENTITY_CENTER_WORKLOADS` and `IDENTITY_CENTER_SECOPS` as raw JSON in both `control-plane-plan` and `control-plane` GitHub Environments.
- Configure `ACCOUNT_ID` in each workload Plan/Apply GitHub Environment pair and in `security-operations-plan` for centralized-security planning/evidence.
- The top-level deployment sequence is `control-plane -> security-operations -> bootstrap-workloads -> workloads`.
- Centralized CSPM policy associations depend on required workload-local services such as AWS Config being correctly realized; validate both the central association and workload state before treating the control as healthy.

## v1.6.0

This update hardens EC2 provisioning, boot-time vulnerability remediation, and automated isolation after testing the Amazon Inspector remediation path against fresh development deployments.

### Added

- Added strict first-boot Ubuntu patching that:
  - rewrites Ubuntu APT sources to HTTPS;
  - waits for package-manager locks and retries transient repository failures;
  - forces IPv4 for APT operations in the IPv4-only workload network;
  - treats any incomplete APT metadata refresh as a provisioning failure;
  - performs a noninteractive `dist-upgrade` before installing required
    bootstrap packages; and
  - records relevant package versions and reboot-required state in the instance
    bootstrap log.
- Added `user_data_replace_on_change = true` so EC2 instances are replaced when their bootstrap configuration changes.
- Added a compute security-policy readiness object from the standalone `security_policy` module and passed it directly into `compute`.
- Added a `terraform_data` dependency bridge so EC2 instances wait for required security-group rules, including public HTTPS egress when enabled, before launching and executing cloud-init.
- Added explicit EC2 isolation eligibility checks for configured severity, finding workflow and record state, valid EC2 resource IDs, instance state, duplicate resources, and already-isolated instances.
- Added explicit `ISOLATION_ALLOWED` Boolean validation to workload Plan paths; Terraform Destroy uses a safe `false` fallback when the setting is absent.

### Changed

- Changed compute bootstrap handling to use a literal shell script instead of a Terraform template when no Terraform interpolation is required.
- Changed environment-root `isolation_allowed` defaults to `false` so automatic isolation requires an explicit environment-level decision.
- Configured development to opt into automatic isolation while staging and production remain opted out.
- Changed automatic EC2 isolation to default to `CRITICAL` findings while still allowing the accepted severity set to be configured by the Lambda environment.
- Changed EC2 auto-isolation authorization to require `IsolationAllowed=true` explicitly after trimming whitespace and normalizing case.
- Changed the isolation workflow to require `NEW`, `ACTIVE` findings and `running` or `stopped` instances before containment.
- Changed the isolation workflow to request and tag attached EBS snapshots only after all eligibility checks pass and before replacing security groups.
- Changed the isolation workflow to preserve the Terraform-managed `IsolationAllowed` policy tag instead of changing it after isolation.
- Changed EC2 lifecycle handling so Terraform ignores runtime quarantine security-group replacement and Lambda-managed incident-response tags while an instance is isolated.
- Changed provisioning dependencies so the compute security group can still be created early for security-policy rules while only the EC2 instances wait for the completed rules.
- Updated the automation module README and root README to document managed Lambda packaging, clean-runner saved-plan deployment, and the current EC2 isolation safeguards.

### Fixed

- Fixed a fresh-deployment race where EC2 cloud-init could execute before required compute security-group rules, including public HTTPS egress when enabled, were ready, causing Ubuntu repository connections to time out.
- Fixed bootstrap behavior that allowed `apt-get update` repository failures to fall back to stale package indexes, report `0 upgraded`, and incorrectly complete successfully with vulnerable AMI package versions still installed.
- Fixed Terraform template parsing failures caused by Bash/dpkg expressions such as `${binary:Package}` being interpreted as Terraform interpolation.
- Fixed the risk of a later Terraform apply restoring the normal compute security group or removing active Lambda isolation evidence.

### Security

- Added deterministic boot-time installation of available Ubuntu security updates before instances enter normal service.
- Made isolation authorization fail closed unless the environment explicitly enables isolation and the instance has `IsolationAllowed=true`.
- Limited automatic isolation to `CRITICAL` findings by default and required eligible finding, instance, and current-isolation state before containment.
- Required pre-isolation EBS snapshot requests to succeed before security-group replacement proceeds.
- Preserved policy ownership of `IsolationAllowed` in Terraform while retaining Lambda-owned evidence tags for isolation status, finding ID, timestamp, and original security groups.
- Prevented normal Terraform reconciliation from silently reversing an active quarantine action.
- Added explicit workflow validation so workload plans accept only `ISOLATION_ALLOWED=true` or `ISOLATION_ALLOWED=false`.

### Notes

- The existing weekly SSM Patch Manager maintenance window remains the ongoing patching control; boot-time patching provides the initial remediation layer for newly launched instances.
- Development deployments continue to use the `nat_only` egress mode. Testing confirmed that the completed NAT, Internet Gateway, route-table, security-group, and NACL path was healthy; the launch-time failure was addressed by waiting for required compute security-group rules.
- Configure `ISOLATION_ALLOWED` in workload Plan GitHub Environments. The current deployment policy enables it for development and disables it for staging and production.
- Managed Lambda archive resources shipped in `v1.5.0` but were omitted from the original changelog entry; the `v1.5.0` history below now records them.

## v1.5.0

This release completes the workload CI/CD integration (for now) by moving baseline and workload-account changes to a plan-before-approval model with exact saved-plan application, protected GitHub environments, and stronger AWS account safety validation.

### Added

- Added a plan-first `Terraform Apply` workflow that:
  - generates the workload plan through the matching `*-plan` GitHub
    environment and GitHub Plan role;
  - publishes readable plan output before deployment approval;
  - uploads the binary plan, readable plan, checksum, and workflow metadata as
    a short-lived artifact;
  - waits for approval on the protected workload Apply environment; and
  - downloads, verifies, and applies the exact saved plan after approval.
- Added optional post-baseline workload-account reconciliation to the `Terraform Apply` workflow.
- Added plan-first `Reconcile Workload Account` workflow modes:
  - `plan-only`;
  - `plan-and-apply`.
- Added protected Apply-job approval and exact saved-plan handoff to workload account reconciliation.
- Added `--plan-file <path>` to `scripts/bootstrap/reconcile-workload-account.sh` for retaining a generated reconciliation plan after the script exits.
- Added `--apply-plan <path>` to `scripts/bootstrap/reconcile-workload-account.sh` for applying an existing reviewed plan without generating a replacement plan.
- Added Plan and Apply job validation for:
  - required 12-digit `ACCOUNT_ID`;
  - configured IAM role ARN account ownership; and
  - active AWS caller account identity.
- Added saved-plan checksum and metadata verification before baseline and reconciliation Apply jobs.
- Added expected AWS account information to the baseline saved-plan metadata so the protected Apply job can verify that the reviewed plan belongs to the configured workload account.
- Added managed `archive_file` resources for the EC2 Isolation, EC2 Rollback, and IP Enrichment Lambda deployment packages.

### Changed

- Changed workload deployment sequencing so the Terraform plan is generated before the reviewer is asked to approve the Apply job.
- Standardized workload CI/CD around paired GitHub environments:
  - `dev-plan` / `dev`;
  - `staging-plan` / `staging`;
  - `prod-plan` / `prod`.
- Changed the protected `dev`, `staging`, and `prod` environments to guard only the privileged Apply jobs, while the matching `*-plan` environments provide the Plan roles and allow plans to complete before approval.
- Changed workload reconciliation automation to apply the exact reviewed account-stack plan after approval instead of regenerating the plan in the Apply job.
- Preserved the existing one-step reconciliation `--apply` mode while adding a durable two-invocation review path through `--plan-file` and `--apply-plan`.
- Changed GitHub OIDC execution so an unset `AWS_PROFILE` uses the AWS default credential provider chain instead of attempting to load an empty AWS CLI profile.
- Updated the root README, quickstart, validation checklist, adoption guide, and bootstrap-script README for the v1.5.0 plan-before-apply model.
- Changed Lambda packaging from plan-time archive data sources to managed Terraform resources so the protected Apply runner can create required ZIP files while applying the exact reviewed saved plan.

### Fixed

- Fixed saved-plan artifact upload failures caused by storing plan files in the hidden `.terraform-plan-artifact` directory, which `actions/upload-artifact` ignored by default.
- Fixed strict post-reconciliation validation under GitHub OIDC by omitting `AWS_PROFILE` when no profile is configured instead of exporting `AWS_PROFILE=""`.
- Fixed fresh-runner Terraform Apply failures where Lambda ZIP files created on the separate Plan runner were unavailable during exact saved-plan Apply.

### Security

- Reduced blind-approval risk by ensuring reviewers can inspect Terraform plan output before approving a deployment.
- Reduced plan substitution and time-of-check/time-of-use risk by applying the exact saved plan produced before approval.
- Added account-bound role and caller validation to reduce the risk of planning or applying against the wrong AWS account.
- Kept Plan and Apply OIDC trust paths separated through distinct GitHub environments and IAM roles.
- Limited saved Terraform plan artifacts to short retention because binary plan files may contain sensitive configuration values.

### Notes

- Configure the same workload `ACCOUNT_ID` in both members of each GitHub environment pair, such as `dev-plan` and `dev`.
- Configure `PLAN_ROLE_GITHUB_ARN` in the `*-plan` environment and `APPLY_ROLE_GITHUB_ARN` in the matching protected Apply environment.
- Keep shared values such as `PRIMARY_REGION`, `CLOUD_NAME`, `TF_STATE_BUCKET_ARN`, and `TF_STATE_BUCKET_CMK_ARN` synchronized across each Plan/Apply environment pair.
- The standalone Terraform Plan workflow remains useful for pull requests, pushes, and independent review. The Terraform Apply workflow generates its own saved plan so the approved Apply job consumes an artifact from the same workflow run.
- The reconciliation helper continues to run strict workload bootstrap validation after apply unless `--skip-validation` is explicitly used.
- Generated Lambda ZIP files are Terraform-managed build artifacts and are not manually maintained or committed as source files.

## v1.4.2

### Added

- Added `scripts/bootstrap/reconcile-workload-account.sh` to resolve current workload Lambda and Secrets Manager CMK outputs, safely reconcile them into the workload GitHub Apply role, and run strict post-apply bootstrap validation.

### Changed

- Updated deployment and validation guidance to use `scripts/bootstrap/reconcile-workload-account.sh <env>` instead of manually copying workload CMK outputs and re-applying `bootstrap/<env>/account`.

## v1.4.1

### Changed

- Replaced tracked runtime `terraform.tfvars` files with `terraform.tfvars.example` templates.
- Updated GitHub Actions to provide required Terraform values through workflow matrices, GitHub variables, and secrets.
- Updated onboarding instructions for creating ignored local variable files.

### Security

- Added Git ignore coverage for runtime Terraform variable files to reduce the risk of committing client-specific or sensitive configuration.

## v1.4.0

This release improves client-readiness and operational safety by adding layer-specific validation evidence exports, migrating bootstrap state stacks to protected remote S3 backends, and adding GitHub Actions workflows for repeatable validation evidence collection.

### Added

- Added workload bootstrap evidence export through `scripts/validation/export-bootstrap.sh`.
- Added control-plane evidence export through `scripts/validation/export-control-plane.sh`.
- Added timestamped workload bootstrap evidence packages under `validation-results/<environment>/bootstrap/<timestamp>/`.
- Added timestamped control-plane evidence packages under `validation-results/control-plane/<timestamp>/`.
- Added `scripts/bootstrap/migrate-state-stack.sh` for guarded migration of workload and control-plane state stacks from initial local state to their own S3 backends.
- Added `scripts/bootstrap/README.md` documenting state-stack migration, verification, repository behavior, and safety expectations.
- Added tracked post-migration backend templates named `backend.tf.migrated.example` for workload and control-plane state stacks.
- Added strict remote state-stack validation through `REQUIRE_STATE_STACK_REMOTE`.
- Added validation coverage for active state-stack S3 backends, shared backend bucket and region consistency, distinct state object keys, migrated state object readability, successful `terraform state pull`, and state bucket output consistency.
- Added manual GitHub Actions evidence workflows for workload bootstrap, workload baseline, and control-plane validation.
- Added GitHub Actions artifact upload behavior for generated validation evidence packages.
- Added runtime materialization of ignored state-stack `backend.tf` files from tracked `backend.tf.migrated.example` templates during evidence workflows.

### Changed

- Renamed `scripts/validation/export-all.sh` to `scripts/validation/export-baseline.sh`.
- Standardized validation evidence around three layers:
  - workload bootstrap;
  - workload baseline;
  - control plane.
- Changed state stacks from long-lived local state to a two-phase lifecycle:
  - initial local initialization and apply;
  - guarded migration into encrypted remote S3 state with native lockfiles.
- Changed state-stack backend handling so active `bootstrap/*/state/backend.tf` files are ignored by Git while post-migration templates remain tracked.
- Updated workload bootstrap and control-plane validators to support strict or advisory remote state-stack checks.
- Updated evidence workflows to initialize state, account, workload, organizations, and Identity Center Terraform roots before validation where applicable.
- Updated validation documentation, architecture documentation, design principles, quickstart guidance, adoption guidance, root README, and validation checklist to describe the remote state-stack lifecycle and evidence workflows.
- Updated workload baseline evidence output paths to `validation-results/<environment>/baseline/<timestamp>/`.
- Updated deployment and validation guidance to use `scripts/bootstrap/migrate-state-stack.sh <target>` after the initial state-stack apply.
- Updated teardown guidance to account for state stacks whose Terraform state is stored in the S3 bucket they manage.

### Removed

- Removed the long-lived local-state expectation for workload and control-plane state stacks.
- Removed obsolete guidance that treated the absence of `bootstrap/<target>/state/backend.tf` as the expected post-deployment state.
- Removed stale DynamoDB state-locking references from current deployment and validation guidance.
- Removed obsolete lock-table output and GitHub environment variable references from the quickstart.

### Notes

State stacks still require an initial local apply because they create their own backend resources. After that apply, `scripts/bootstrap/migrate-state-stack.sh` validates the selected AWS account and backend template, creates external backups, refuses to overwrite an existing remote state object, runs interactive `terraform init -migrate-state`, and verifies the resulting S3 state object with `terraform state pull`.

The active state-stack `backend.tf` files are intentionally ignored by Git. The tracked `backend.tf.migrated.example` files define the intended post-migration configuration and are also used by GitHub evidence workflows to materialize the runtime backend before initialization.

Direct validation script runs default `REQUIRE_STATE_STACK_REMOTE` to `false` so transitional findings can remain advisory. The GitHub workload bootstrap and control-plane evidence workflows default remote state-stack validation to strict behavior.

Generated validation evidence remains ignored by Git and does not replace live GitHub Actions execution testing, IAM Identity Center end-user access testing, Lambda workflow tests, tamper tests, break-glass tests, or destroy safety review.

## v1.3.4

This release completes the validation architecture cleanup by organizing validation into workload bootstrap, workload baseline, and control-plane validation layers while standardizing Terraform state-locking validation around S3 native lockfiles.

### Added

- Added automated workload bootstrap validation with `scripts/validation/validate-bootstrap.sh`.
- Added automated read-only control-plane validation with `scripts/validation/validate-control-plane.sh`.
- Added validation coverage for workload bootstrap directory structure, backend lockfile configuration, state bucket security, state CMK configuration, GitHub OIDC roles, and GitHub role access to Terraform state resources.
- Added control-plane validation coverage for state backend resources, GitHub OIDC roles, AWS Organizations OU structure, IAM Identity Center basics, optional account assignments, and expected GitHub repository trust conditions.
- Added CI-safe bootstrap validation behavior that does not require local `terraform.tfstate` from `bootstrap/<env>/state`.
- Added backend-file-based state bucket resolution for workload bootstrap validation.
- Added live S3 and KMS validation for Terraform state bucket versioning, public access block, SSE-KMS encryption, and customer-managed state CMK status.
- Added validation that workload and control-plane remote backends use Terraform S3 native locking with `use_lockfile = true`.
- Added `scripts/validation/README.md` to document validation layers, usage, safety boundaries, troubleshooting, and recommended validation order.

### Changed

- Renamed `scripts/validation/validate-all.sh` to `scripts/validation/validate-baseline.sh`.
- Preserved `scripts/validation/validate-all.sh` as a deprecated compatibility wrapper for `validate-baseline.sh`.
- Updated validation documentation to distinguish workload bootstrap validation, workload baseline validation, control-plane validation, and manual live workflow testing.
- Updated root-level README validation guidance to describe all three validation layers.
- Updated `docs/validation-checklist.md` to reflect CI-safe bootstrap validation, control-plane validation, and S3 native lockfile behavior.
- Changed bootstrap validation to treat remote backend files as the source of truth for state bucket location, backend region, state object keys, and `use_lockfile = true`.
- Changed bootstrap validation to resolve the state CMK from the live S3 bucket encryption configuration instead of relying on local bootstrap state outputs.
- Standardized validation language around Terraform S3 native locking with `use_lockfile = true`.

### Removed

- Removed stale DynamoDB state-locking expectations from validation guidance.
- Removed the bootstrap validator's dependency on local Terraform outputs from `bootstrap/<env>/state`.
- Removed local `terraform.tfstate` presence checks from workload bootstrap validation.

### Notes

DynamoDB state locking is not expected because this project uses Terraform S3 native locking with `use_lockfile = true`; DynamoDB-based locking for the S3 backend is deprecated.

`validate-bootstrap.sh` remains read-only. It does not run `terraform init`, `terraform apply`, `terraform destroy`, backend migration, role assumption, or live workflow execution. For fresh checkouts or manual GitHub workflow runs, initialize the remote-backed account and workload stacks before running bootstrap validation so Terraform outputs can be read from the S3 backend.

`validate-control-plane.sh` remains read-only. It validates control-plane state backend resources, GitHub OIDC roles, AWS Organizations structure, IAM Identity Center basics, and optional account assignment evidence, but it does not execute GitHub workflows, move accounts between OUs, modify Identity Center assignments, assume privileged roles, or perform destructive operations.

## v1.3.3

### Added

- Added `scripts/validation/validate-control-plane.sh` for safe, read-only control-plane validation.
- Added validation coverage for control-plane Terraform state backend resources.
- Added validation coverage for control-plane GitHub OIDC provider and plan/apply roles.
- Added validation coverage for AWS Organizations OU structure.
- Added validation coverage for IAM Identity Center instance, SecOps groups, permission sets, and account assignments.

### Changed

- Updated validation checklist to make automated control-plane validation the preferred path.
- Clarified that manual validation is still required for GitHub Actions execution, end-user SSO testing, live Lambda tests, tamper tests, break-glass tests, and destroy safety review.

### Notes

- AWS Organizations account placement warnings are treated as warnings unless account placement is explicitly managed by Terraform.

## v1.3.2

### Fixed

- Fixed AWS Network Firewall resource naming so the firewall name includes the environment-specific name prefix.
- Fixed networking validation to match the exact expected Network Firewall name instead of using broad prefix containment.
- Fixed networking validation for Network Firewall routes where AWS may expose firewall endpoint targets through `GatewayId` instead of `VpcEndpointId`.

### Changed

- Added `create_before_destroy` lifecycle behavior to the Network Firewall resource to support safer forced replacements during firewall renames.
- Enhanced networking validation to normalize route targets into consistent target types such as VPC endpoint, NAT Gateway, Internet Gateway, local route, transit gateway, and network interface.
- Expanded networking validation for `network_firewall` mode to validate the full inspected egress path:
  - compute private route tables route default traffic to firewall VPC endpoints;
  - firewall private route tables route default traffic to NAT Gateways;
  - public route tables route default traffic to Internet Gateways;
  - public route tables return compute private subnet CIDRs through firewall VPC endpoints.

## v1.3.1

### Added

- Added a dedicated security notifications SQS queue subscribed to the security notifications SNS topic.
- Added a security notifications SQS DLQ for repeatedly unprocessed security notification messages.
- Added a shared security notifications EventBridge DLQ for failed EventBridge deliveries to the security notifications SNS topic.
- Added a CloudWatch alarm for visible messages in the security notifications EventBridge DLQ.
- Added workflow-specific DLQs for EC2 Isolation, EC2 Rollback, and IP Enrichment automation workflows.
- Added EventBridge target DLQ configuration and retry policies for protected automation and security notification targets.
- Added Lambda asynchronous failure handling for the EC2 Isolation, EC2 Rollback, and IP Enrichment workflows.
- Added CloudWatch DLQ alarms for security automation failure paths.
- Added notification and DLQ validation guidance to `docs/validation-checklist.md`.
- Added DLQ triage and safe message inspection guidance to `docs/validation-checklist.md`.

### Changed

- Updated security notification routing to support both human alert delivery and durable SQS-backed message retention.
- Updated EventBridge security notification targets to use retry policies and a shared EventBridge DLQ.
- Updated automation workflows so EventBridge delivery failures are retained in workflow-specific DLQs.
- Updated SQS validation to include compliance, security notification, security notification DLQ, security notification EventBridge DLQ, and security automation DLQ resources.
- Updated EventBridge validation to verify target DLQs, retry policies, expected target ARNs, and expected DLQ ARNs.
- Updated monitoring, automation, security, tamper detection, and root-level documentation to reflect the new notification and DLQ architecture.
- Condensed the monitoring module README and moved detailed notification/DLQ validation and response guidance into `docs/validation-checklist.md`.

### Notes

- Workflow DLQs are terminal failure-retention queues intended for SecOps review, troubleshooting, and manual replay or remediation where appropriate.
- The security notifications EventBridge DLQ covers EventBridge-to-SNS delivery failures.
- The security notifications SQS DLQ covers repeated processing failures after messages have already reached the security notifications SQS queue.
- The compliance and security notification queues may accumulate visible messages when no downstream consumer is configured. This is expected when the queues are used as durable notification subscribers.
- The new DLQ hardening improves alert-delivery resilience but does not automatically replay failed security automation or notification events.

## v1.3.0

### Added

- Added validation report export workflow through `scripts/validation/export-baseline.sh`.
- Added timestamped validation result directories under `validation-results/<environment>/<timestamp>/`.
- Added per-script validation log capture.
- Added generated Markdown validation summaries through `summary.md`.
- Added generated machine-readable validation summaries through `summary.json`.
- Added validation report template under `docs/assurance/validation-report-template.md`.
- Added validation evidence guide under `docs/assurance/validation-evidence-guide.md`.

### Changed

- Updated validation documentation to describe exported validation evidence packages.
- Updated project documentation to position validation reports for client handoff, troubleshooting, and deployment evidence.

### Notes

- Generated validation output is ignored by Git by default.
- Validation reporting is intended to support deployment evidence and audit-readiness discussions.
- Validation reports do not replace formal SOC 2 or ISO 27001 audits, control owner review, policy review, risk assessment, or ISMS activities.

## v1.2.1

### Fixed

- Fixed Amazon Inspector enablement wiring so the security module respects the resolved `effective_inspector_enabled` value.
- Updated Inspector validation to check the effective Inspector resource types instead of assuming EC2, Lambda, and Lambda code scanning are all enabled.
- Removed unnecessary Amazon Inspector access from the Lambda KMS key policy.

### Changed

- Added configurable `inspector_resource_types` support.
- Defaulted Amazon Inspector resource types to EC2 scanning only.
- Disabled Lambda and Lambda code scanning by default because the baseline uses customer-managed KMS encryption for Lambda resources.
- Updated security module documentation to reflect configurable Inspector behavior and Lambda CMK policy changes.

## v1.2.0

### Added

- Added a safe, read-only post-deployment validation suite for workload environments.
- Added `validate-all.sh` as the primary validation entry point for `dev`, `staging`, and `prod`.
- Added workload validation scripts for:
  - Environment outputs and account identity
  - Networking and controlled egress
  - VPC endpoints
  - Logging
  - Security services
  - KMS
  - AWS Backup
  - SNS
  - SQS
  - EventBridge
  - Lambda
  - SSM
  - Compute
  - IAM
- Added expected AWS account validation through `EXPECTED_ACCOUNT_ID`.
- Added profile-aware validation behavior for AWS Config, AWS Backup, Inspector, and effective egress mode.
- Added validation coverage for SNS-to-SQS delivery paths, queue policies, queue encryption, visible messages, and not-visible messages.
- Added validation coverage for Lambda runtime, state, execution role, timeout, memory, KMS configuration, VPC configuration, environment variables, resource policies, and EventBridge permissions.
- Added validation coverage for EC2 compute instance placement, public IP absence, IMDSv2 enforcement, detailed monitoring, instance profiles, security groups, required tags, isolation eligibility, and EBS encryption.
- Added validation coverage for Backup vaults, plans, selections, schedules, retention, tagged resources, recent jobs, and recovery point reporting.

### Changed

- Updated `docs/validation-checklist.md` to make automated workload validation the default validation path.
- Updated validation guidance to distinguish safe read-only checks from live workflow tests, tamper tests, break-glass tests, and destroy safety checks.
- Improved validation summary output across SNS, SQS, KMS, Backup, Lambda, SSM, Compute, and related scripts.
- Improved validation output readability by shortening long resource names, ARNs, and table columns where appropriate.
- Updated root-level documentation to include the validation suite and v1.2.0 release highlights.

### Notes

- The automated validation suite is intentionally read-only and does not perform live isolation, rollback, tamper, break-glass, GitHub Actions, Identity Center, or destroy workflow tests.
- Live workflow validation remains manual and should only be run in approved environments.
- A successful full workload validation run should report every script in that release's validator inventory as passed.

## v1.1.1

### Changed
- Refactored IAM, SNS topic, EventBridge bus, and S3 bucket policies to use `aws_iam_policy_document` data sources instead of inline `jsonencode()` policy documents.
- Improved policy readability, consistency, and maintainability across IAM roles, managed policies, inline policies, trust policies, and resource-based policies.
- Removed redundant Lambda principals from the SecOps SNS topic policy, relying instead on Lambda execution role permissions for direct SNS publishing.
- Added stronger bucket policy protections for state and centralized logging buckets using explicit deny controls and admin-principal exceptions.

## v1.1.0

### Added

- Added deployment profiles for `production`, `development`, and `minimal`.
- Added configurable egress modes:
  - `network_firewall`
  - `nat_only`
  - `vpc_endpoints_only`
- Added dedicated private subnets for Interface VPC Endpoints.
- Added profile-aware defaults for AWS Config, AWS Backup, Inspector, and CloudWatch Logs retention.
- Added effective Terraform outputs for deployment profile and resolved feature settings.
- Added documentation validation workflow.
- Improved Terraform static analysis workflow coverage.

### Changed

- Network Firewall is now deployed only when required by the effective egress mode.
- NAT Gateways are now deployed only when required by the effective egress mode.
- Interface VPC Endpoints now deploy into dedicated endpoint private subnets.
- S3 Gateway Endpoint route table behavior is now explicitly controlled by the baseline stack.
- IAM module policies were refactored from inline `jsonencode()` policy JSON to `aws_iam_policy_document` data sources.
- Documentation updated for deployment profiles, egress modes, and dedicated VPC endpoint subnets.

### Notes

- `production` defaults to `network_firewall`.
- `development` defaults to `nat_only`.
- `minimal` defaults to `vpc_endpoints_only`, with no NAT Gateway, no Network Firewall, and no general internet route for compute private subnets.

## v1.0.0

### Added

- Added initial stable release of `tf-secure-baseline`.
- Added multi-account environment structure for:
  - `dev`
  - `staging`
  - `prod`
  - `control-plane`
- Added Terraform remote state bootstrap pattern using S3, DynamoDB, and KMS.
- Added GitHub Actions OIDC federation for plan/apply workflows.
- Added IAM Identity Center integration for centralized human access.
- Added private-first VPC architecture with segmented subnet tiers.
- Added AWS Network Firewall-based egress inspection.
- Added VPC endpoints for private AWS service access.
- Added centralized CloudTrail, AWS Config, VPC Flow Logs, and CloudWatch logging.
- Added GuardDuty, Security Hub, Inspector, and AWS Config baseline controls.
- Added EventBridge-driven security automation.
- Added EC2 isolation and rollback workflows.
- Added IP threat intelligence enrichment workflow.
- Added tamper detection for critical security services.
- Added break-glass role monitoring.
- Added KMS-backed encryption across logs, Lambda, EBS, Secrets Manager, and backups.
- Added AWS Backup and SSM Patch Manager support.
- Added completed system-level documentation and module README files.

### Documentation

- Added quickstart guide.
- Added architecture overview.
- Added design principles.
- Added adoption guide.
- Added validation checklist.
- Added SOC 2 control mapping.
- Added ISO 27001 control mapping.
- Added control narratives.
- Added Lambda test documentation.
- Added module-level README files.

### Notes

- This baseline supports SOC 2 and ISO 27001 readiness, but does not replace a complete compliance program, ISMS, formal risk management process, or audit.
- AWS Network Firewall, NAT Gateway, VPC endpoints, CloudWatch Logs, GuardDuty, Security Hub, Inspector, and Backup may generate ongoing AWS costs.
- Production deployments should review deletion protection, Object Lock, retention periods, KMS `prevent_destroy`, and environment-specific access controls before use.
