# ECS Job Admission Gate Module

This module creates the DynamoDB table that holds approval state for job admission. The broker checks that state before admitting a job. The gate belongs to foundation state and is separate from the application's execution ledger.

## Foundation Configuration

The `dev`, `staging`, and `prod` foundation roots accept an optional application inventory:

```hcl
job_admission_applications = ["reports"]
```

For each application ID, `modules/security` creates a dedicated KMS key and alias, and `baseline` calls this module to create the gate table. The default `[]` creates no gates or admission keys. Application IDs are Terraform resource keys and should remain stable.

The foundation output `job_admission_gates` maps each application ID to `{ table_arn, cmk_arn }`. These references are intended for protected publication and broker configuration; the output does not itself publish them.

## Module Interface

| Input | Purpose |
|---|---|
| `name_prefix` | Resource prefix unique to the application and environment |
| `environment` | Environment tag |
| `admission_gate_cmk_arn` | Exact foundation-controlled KMS key ARN; aliases are not accepted |

All inputs are required. The module creates the table only; the caller supplies the key. Its `admission_gate` output contains `table_arn` and `cmk_arn`.

## Storage and Activation

The table uses on-demand capacity, a string partition key named `pk`, customer-managed KMS encryption, point-in-time recovery, and deletion protection. No TTL or Terraform-managed table items are configured.

Creating an empty gate table does not authorize jobs. The broker receives read/condition-check permissions through its `admission_gate` input; a separate protected controller must initialize and manage eligibility. Controller implementation, protected deployment controls, and live AWS qualification remain pending. Broker execution remains disabled.
