# v1.15.0 — R3 Architecture Refactor Validation and Closeout

**Status:** Proposed for owner technical acceptance  
**Scope:** R0–R3 IAM/database module-boundary refactor  
**Release status:** This acceptance does not complete or authorize tagging v1.15.0.

## 1. Scope and decision

R3 validates that the accepted R1 IAM decomposition and R2 database/storage decomposition preserve the baseline's intended infrastructure behavior.

R1 relocated 42 IAM managed-resource declarations into capability-aligned modules. R2 relocated 10 database declarations from `modules/storage` into `modules/database`.

**Recommended disposition: ACCEPT WITH DOCUMENTED EXCEPTIONS.**

No new managed-resource or root-output regression was identified in the final qualification. The original 16-root comparison completed successfully, and the three outstanding bootstrap differences were subsequently reconciled.

No workload state migrations, imports, or Terraform `moved` blocks were required because the workload roots were undeployed.

## 2. Qualification evidence

| Reference | Identifier |
|---|---|
| Original R0 commit | `f0581fc1db4b01d279ba25f8429e893066411cc0` |
| Final R3 source commit | `53bb0393519606d3ec4106c542a34262ec8144dd` |
| Final R3 source tree | `370c64ef2b6d2c45bd64f06c511bcb8379c0a1c8` |
| R0 evidence ID | `r0-baseline-f0581fc1db4b-20261118T022726Z` |
| R3 evidence ID | `r3-final-53bb03935196-20261119T061125Z` |
| R3 manifest SHA256 | `194d655830637acdb658387d3b18747b1af78f6b390999c93bce6746f212bd5b` |
| Qualification coverage | 16 Terraform roots |

Original evidence remains in private local storage. Raw state, sensitive plan contents, and credentials are not published.

### Equivalence results

| Environment | Planned creations | Relocated instances | Root outputs |
|---|---:|---:|---:|
| Dev | 281 | 48 | 59 preserved |
| Staging | 341 | 51 | 59 preserved |
| Prod | 313 | 48 | 59 preserved |

All 935 workload managed-resource records matched after exact approved address normalization, except for eight EC2 AMI selections caused by the unchanged `most_recent = true` lookup.

The original AMI `ami-08b275ac6cc5dbefb` was superseded by `ami-0719278fd447e399f`. This historical time-dependent difference was explicitly classified and not globally excluded from comparisons.

A previously documented dependency-ordering addition affects six Security Hub insights per environment following Config remediation IAM relocation. No new R3 dependency regression was identified.

## 3. Bootstrap reconciliation

Following the original R3 capture, the owner applied the three pre-existing bootstrap changes.

| Root | Applied correction | Post-Apply verification |
|---|---|---|
| Control-plane state | Created seven-day incomplete-multipart-upload lifecycle configuration; standardized root output to `account_id` | S3 lifecycle verified; output verified; Terraform no-change plan |
| Security-operations state | Created seven-day incomplete-multipart-upload lifecycle configuration | S3 lifecycle verified; Terraform no-change plan |
| Staging account | Updated GitHub Plan and Apply IAM policies to remove obsolete Lambda and Secrets Manager KMS grants | 0 added, 2 changed, 0 destroyed; Terraform no-change plan |

No unexpected resource creation, deletion, or replacement was reported during the approved staging IAM reconciliation.

These post-capture corrective Applies are recorded separately from the original R0-to-R3 equivalence evidence. The original evidence bundles remain unchanged.

## 4. Qualification limitations

The following limitations remain explicitly documented:

- Two auxiliary variant-input references were absent from the captured input manifests; all 16 required root inputs verified.
- Nested manifests were not themselves covered by the top-level checksum manifest.
- Raw state-stream byte identity was not established for nine roots, although recorded S3 object versions and relevant state metadata remained consistent.
- Eleven plan-time checks remained unknown, matching historical qualification.
- Not every ECS IAM declaration was instantiated in the captured configurations.
- The previously approved staging workload state serial transition from 619 to 620 remains recorded.
- Terraform plan equivalence does not prove successful future Apply operations, operational readiness, or absence of live infrastructure drift.

These limitations do not establish a new R3 implementation defect.

## 5. Deferred follow-ups

The following work remains outside the R3 refactor closeout:

- Evaluate automated post-Destroy workload-account IAM reconciliation.
- Enforce and verify intended SSE-KMS encryption for Terraform S3 backends before v1.15.0 release closeout.
- Address remaining M0 security, evidence-retention, cost and licensing gates.
- Complete M2 background-task launch/scheduling requirements and subsequent M3–M5 integration qualification.

The deferred work does not imply that the R1/R2 refactor requires additional source changes.

## 6. Owner acceptance

**Proposed decision:** ACCEPT WITH DOCUMENTED EXCEPTIONS.

The owner accepts the R1/R2 refactor's demonstrated planned-resource equivalence, subject to the recorded limitations and historical exceptions.

Acceptance authorizes closing the R0–R3 architecture-refactor track. It does not authorize deployment, additional AWS mutations, or release tagging.

**Owner acceptance:** Pending explicit approval and recording.
