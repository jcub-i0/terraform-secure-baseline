#!/usr/bin/env bash
set -euo pipefail

# Offline M1-A restore-networking contract tests. Exercises the production
# validate-backup.sh against synthetic Terraform outputs and mocked AWS replies.
# No live AWS calls, Terraform plans, applies, or state mutations.
# Usage: bash scripts/tests/test-rds-restore-isolation.sh

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="${root}/scripts/validation/validate-backup.sh"
common="${root}/scripts/validation/lib/common.sh"
for required in bash jq git cp mktemp; do
  command -v "$required" >/dev/null 2>&1 || {
    printf '[FAIL] Missing command: %s\n' "$required" >&2; exit 1;
  }
done
[[ -f "$validator" && -f "$common" ]] || {
  echo '[FAIL] Missing production validator or common library.' >&2; exit 1;
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/repo/scripts/validation/lib" "$tmp/repo/environments/dev" "$tmp/bin"
cp -- "$validator" "$tmp/repo/scripts/validation/validate-backup.sh"
ln -s -- "$common" "$tmp/repo/scripts/validation/lib/common.sh"

# All AWS and Terraform calls are forced to these fake binaries. Unexpected
# commands fail closed; none can fall back to an actual cloud API.
cat > "$tmp/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-} ${2:-}" == 'rev-parse --show-toplevel' ]] || exit 91
printf '%s\n' "$MOCK_REPO_ROOT"
MOCK_GIT

cat > "$tmp/bin/terraform" <<'MOCK_TERRAFORM'
#!/usr/bin/env bash
set -euo pipefail
[[ "${2:-} ${3:-}" == 'output -json' && "${1:-}" == -chdir=* ]] || {
  echo "Unexpected Terraform call: $*" >&2; exit 92;
}
jq -c '.outputs' "$MOCK_FIXTURE"
MOCK_TERRAFORM

cat > "$tmp/bin/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'sts get-caller-identity')
    if [[ " $* " == *' --query Account '* ]]; then
      echo '123456789012'
    elif [[ " $* " == *' --query Arn '* ]]; then
      echo 'arn:aws:iam::123456789012:user/offline-fixture'
    else
      echo "Unexpected STS query: $*" >&2; exit 93
    fi
    ;;
  'backup describe-backup-vault') jq -c '.aws.vault' "$MOCK_FIXTURE" ;;
  'backup list-backup-plans') jq -c '.aws.backupPlans' "$MOCK_FIXTURE" ;;
  'ec2 describe-instances') jq -c '.aws.ec2Instances' "$MOCK_FIXTURE" ;;
  'rds describe-db-instances') jq -c '.aws.rdsInstances' "$MOCK_FIXTURE" ;;
  'backup get-restore-testing-plan'|'backup get-restore-testing-selection'|'backup list-restore-jobs')
    [[ "$(jq -r '.outputs.restore_testing.value.enabled' "$MOCK_FIXTURE")" == true ]] || {
      echo 'Restore Testing AWS API called despite disabled Terraform state' >&2; exit 94;
    }
    case "${1:-} ${2:-}" in
      'backup get-restore-testing-plan') jq -c '.aws.restorePlan' "$MOCK_FIXTURE" ;;
      'backup get-restore-testing-selection') jq -c '.aws.restoreSelection' "$MOCK_FIXTURE" ;;
      'backup list-restore-jobs') jq -c '.aws.restoreJobs' "$MOCK_FIXTURE" ;;
    esac
    ;;
  'backup get-backup-plan') jq -c '.aws.backupPlan' "$MOCK_FIXTURE" ;;
  'backup list-backup-selections') jq -c '.aws.backupSelections' "$MOCK_FIXTURE" ;;
  'backup get-backup-selection') jq -c '.aws.backupSelection' "$MOCK_FIXTURE" ;;
  'backup list-recovery-points-by-backup-vault') jq -c '.aws.recoveryPoints' "$MOCK_FIXTURE" ;;
  'backup list-backup-jobs') jq -c '.aws.backupJobs' "$MOCK_FIXTURE" ;;
  'backup describe-recovery-point') jq -c '.aws.recoveryPoint' "$MOCK_FIXTURE" ;;
  *) echo "Unexpected AWS request: $*" >&2; exit 96 ;;
esac
MOCK_AWS
chmod +x "$tmp/bin/git" "$tmp/bin/terraform" "$tmp/bin/aws"

jq -n '
  "tf-secure-baseline-dev" as $p |
  "us-east-1" as $region |
  "123456789012" as $account |
  "sg-11111111111111111" as $source_sg |
  "sg-22222222222222222" as $restore_sg |
  ($p + "-saas-db") as $db |
  ("arn:aws:rds:" + $region + ":" + $account + ":db:" + $db) as $db_arn |
  ($p + "-data-db-subnet-group") as $subnet |
  ($p + "-backup-vault") as $vault |
  ("arn:aws:backup:" + $region + ":" + $account + ":backup-vault:" + $vault) as $vault_arn |
  ("arn:aws:kms:" + $region + ":" + $account + ":key/example-key-id") as $kms |
  ("arn:aws:iam::" + $account + ":role/" + $p + "-backup-role") as $role |
  ("arn:aws:iam::" + $account + ":role/" + $p + "-monitoring") as $monitoring |
  ("arn:aws:backup:" + $region + ":" + $account + ":restore-testing-plan:plan123") as $test_plan_arn |
  (($p | gsub("-"; "_")) + "_rds_restore_test") as $test_plan |
  ("arn:aws:backup:" + $region + ":" + $account + ":recovery-point:rp123") as $rp |
  {outputs: {
    primary_region:{value:$region},
    effective_backup_enabled:{value:true},
    effective_backup_schedule:{value:"cron(0 5 * * ? *)"},
    effective_delete_backups_after_days:{value:30},
    rds_configuration:{value:{
      identifier:$db,arn:$db_arn,monitoring_interval:60,
      monitoring_role_arn:$monitoring,performance_insights_enabled:true,
      performance_insights_kms_key_id:$kms,multi_az:true,
      db_subnet_group_name:$subnet,vpc_security_group_ids:[$source_sg],
      deletion_protection:true,backup_retention_period:14,
      publicly_accessible:false,storage_encrypted:true,
      skip_final_snapshot:false,delete_automated_backups:false,
      final_snapshot_identifier:($p + "-final")
    }},
    backup_vault_configuration:{value:{name:$vault,arn:$vault_arn,kms_key_arn:$kms,force_destroy:false}},
    lifecycle_protection:{value:{rds_deletion_protection:true,backup_vault_force_destroy:false}},
    restore_testing:{value:{
      enabled:true,restore_test_db_sg_id:$restore_sg,
      schedule:"cron(0 8 ? * SUN *)",start_window_hours:2,
      selection_window_days:2,validation_window_hours:1,
      plan:{name:$test_plan,arn:$test_plan_arn,schedule_expression:"cron(0 8 ? * SUN *)",
        start_window_hours:2,
        recovery_point_selection:{algorithm:"LATEST_WITHIN_WINDOW",include_vaults:[$vault_arn],
          recovery_point_types:["SNAPSHOT"],selection_window_days:2}},
      selection:{name:"rds_restore",restore_testing_plan_name:$test_plan,
        protected_resource_type:"RDS",protected_resource_arns:[$db_arn],iam_role_arn:$role,
        restore_metadata_overrides:{
          dbSubnetGroupName:$subnet,vpcSecurityGroupIds:([$restore_sg] | tojson),
          publiclyAccessible:"false",multiAz:"false"},
        validation_window_hours:1}
    }}
  },aws:{
    vault:{BackupVaultName:$vault,BackupVaultArn:$vault_arn,EncryptionKeyArn:$kms,NumberOfRecoveryPoints:1},
    ec2Instances:{Reservations:[{Instances:[{
      InstanceId:"i-0123456789abcdef0",
      Tags:[{Key:"Name",Value:($p+"-EC2-test")},{Key:"Backup",Value:"true"}]
    }]}]},
    rdsInstances:{DBInstances:[{
      DBInstanceIdentifier:$db,DBInstanceArn:$db_arn,MonitoringInterval:60,
      MonitoringRoleArn:$monitoring,PerformanceInsightsEnabled:true,
      PerformanceInsightsKMSKeyId:$kms,MultiAZ:true,
      DBSubnetGroup:{DBSubnetGroupName:$subnet},
      VpcSecurityGroups:[{VpcSecurityGroupId:$source_sg}],
      DeletionProtection:true,BackupRetentionPeriod:14,PubliclyAccessible:false,
      StorageEncrypted:true,TagList:[{Key:"Backup",Value:"true"}]
    }]},
    restorePlan:{RestoreTestingPlan:{
      RestoreTestingPlanName:$test_plan,RestoreTestingPlanArn:$test_plan_arn,
      ScheduleExpression:"cron(0 8 ? * SUN *)",StartWindowHours:2,
      RecoveryPointSelection:{Algorithm:"LATEST_WITHIN_WINDOW",IncludeVaults:[$vault_arn],
        RecoveryPointTypes:["SNAPSHOT"],SelectionWindowDays:2}
    }},
    restoreSelection:{RestoreTestingSelection:{
      RestoreTestingSelectionName:"rds_restore",RestoreTestingPlanName:$test_plan,
      ProtectedResourceType:"RDS",ProtectedResourceArns:[$db_arn],
      IamRoleArn:$role,ValidationWindowHours:1,
      RestoreMetadataOverrides:{dbSubnetGroupName:$subnet,
        vpcSecurityGroupIds:([$restore_sg]|tojson),publiclyAccessible:"false",multiAz:"false"}
    }},
    restoreJobs:{RestoreJobs:[{RestoreJobId:"restore-job-123",CreationDate:"2026-10-22T01:00:00Z",
      Status:"COMPLETED",ValidationStatus:"SUCCESSFUL",DeletionStatus:"SUCCESSFUL",
      RecoveryPointArn:$rp,CreatedResourceArn:($db_arn + "-restored"),CompletionDate:"2026-10-22T01:30:00Z"}]},
    backupPlans:{BackupPlansList:[{BackupPlanName:($p+"-backup-plan"),BackupPlanId:"backup-plan-123"}]},
    backupPlan:{BackupPlan:{BackupPlanName:($p+"-backup-plan"),Rules:[{
      RuleName:"daily-backups",TargetBackupVaultName:$vault,
      ScheduleExpression:"cron(0 5 * * ? *)",Lifecycle:{DeleteAfterDays:30}
    }]}},
    backupSelections:{BackupSelectionsList:[{SelectionName:($p+"-backup-selection"),SelectionId:"selection-123"}]},
    backupSelection:{BackupSelection:{IamRoleArn:$role,Resources:[],NotResources:[],
      Conditions:{StringEquals:[{ConditionKey:"Backup",ConditionValue:"true"}]}}},
    recoveryPoints:{RecoveryPoints:[{ResourceType:"RDS",Status:"COMPLETED",
      CreationDate:"2026-10-22T00:00:00Z",RecoveryPointArn:$rp}]},
    recoveryPoint:{RecoveryPointArn:$rp},
    backupJobs:{BackupJobs:[{ResourceArn:$db_arn,State:"COMPLETED",
      CreationDate:"2026-10-22T00:00:00Z",BackupJobId:"job-123",RecoveryPointArn:$rp}]}
  }}
' > "$tmp/valid.json"

# Restore Testing off, AWS Backup still on. This exercises the null contract
# without conflating disabled Restore Testing with a disabled backup plan.
jq '.outputs.restore_testing.value |= {
  enabled:false,restore_test_db_sg_id:null,schedule:null,start_window_hours:null,
  selection_window_days:null,validation_window_hours:null,plan:null,selection:null
}' "$tmp/valid.json" > "$tmp/disabled.json"

# Development/minimal default: both scheduled AWS Backup and Restore Testing are
# disabled, but the backup vault and source RDS remain subject to validation.
# Terraform omits null outputs, so omit the disabled schedule and retention keys.
jq '
  .outputs.effective_backup_enabled.value = false
  | del(.outputs.effective_backup_schedule, .outputs.effective_delete_backups_after_days)
  | .outputs.restore_testing.value = {
      enabled:false,restore_test_db_sg_id:null,schedule:null,start_window_hours:null,
      selection_window_days:null,validation_window_hours:null,plan:null,selection:null
    }
  | .aws.backupPlans.BackupPlansList = []
  | .aws.ec2Instances.Reservations[].Instances[].Tags |= map(
      if .Key == "Backup" then .Value = "false" else . end
    )
  | .aws.rdsInstances.DBInstances[].TagList |= map(
      if .Key == "Backup" then .Value = "false" else . end
    )
' "$tmp/valid.json" > "$tmp/backup-disabled.json"

cases=0
run_case() {
  local expectation="$1" label="$2" base="$3" mutation="$4" expected_message="${5:-}"
  local casefile="$tmp/case.json" output="$tmp/output.txt" code=0
  cp -- "$tmp/$base.json" "$casefile"
  if [[ "$mutation" != '.' ]]; then
    jq -c "$mutation" "$casefile" > "$tmp/mutated.json"
    mv -- "$tmp/mutated.json" "$casefile"
  fi

  MOCK_FIXTURE="$casefile" MOCK_REPO_ROOT="$tmp/repo" \
    AWS_PROFILE=dev AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID=123456789012 \
    AWS_EC2_METADATA_DISABLED=true PATH="$tmp/bin:$PATH" \
    bash "$tmp/repo/scripts/validation/validate-backup.sh" dev > "$output" 2>&1 || code=$?

  if [[ "$expectation" == pass ]]; then
    local expected_summary='[PASS] Backup validation completed successfully for: dev'
    if [[ "$base" == backup-disabled ]]; then
      expected_summary='[PASS] Backup disabled-state validation completed successfully for: dev'
    fi
    if ((code != 0)) || ! grep -Fq "$expected_summary" "$output"; then
      printf '[FAIL] %s: expected PASS (exit=%d)\n' "$label" "$code" >&2
      tail -90 "$output" >&2; exit 1
    fi
  else
    if ((code == 0)) || ! grep -Fq "$expected_message" "$output"; then
      printf '[FAIL] %s: expected rejection containing %q (exit=%d)\n' "$label" "$expected_message" "$code" >&2
      tail -90 "$output" >&2; exit 1
    fi
  fi
  printf '[PASS] %s\n' "$label"
  cases=$((cases + 1))
}

pass() { run_case pass "$1" "$2" "${3:-.}"; }
deny() { run_case fail "$1" "$2" "$3" "$4"; }

pass 'Isolated restore SG and private metadata' valid
pass 'Restore Testing disabled with backups enabled' disabled
pass 'Development/minimal defaults: Backup and Restore Testing both disabled' backup-disabled

deny 'Restore Testing cannot enable without AWS Backup' valid \
  '.outputs.effective_backup_enabled.value = false | del(.outputs.effective_backup_schedule, .outputs.effective_delete_backups_after_days)' \
  'Restore Testing cannot be enabled when effective_backup_enabled=false'

deny 'Missing SG in enabled contract' valid \
  'del(.outputs.restore_testing.value.restore_test_db_sg_id)' \
  'Enabled restore_testing output does not contain a complete resource-backed contract'
deny 'Null SG in enabled contract' valid \
  '.outputs.restore_testing.value.restore_test_db_sg_id=null' \
  'Enabled restore_testing output does not contain a complete resource-backed contract'
deny 'Malformed SG in enabled contract' valid \
  '.outputs.restore_testing.value.restore_test_db_sg_id="invalid"' \
  'Enabled restore_testing output does not contain a complete resource-backed contract'
deny 'Original RDS SG reused for restore' valid \
  '.outputs.restore_testing.value.restore_test_db_sg_id = .outputs.rds_configuration.value.vpc_security_group_ids[0] | .outputs.restore_testing.value.selection.restore_metadata_overrides.vpcSecurityGroupIds = (.outputs.rds_configuration.value.vpc_security_group_ids|tojson) | .aws.restoreSelection.RestoreTestingSelection.RestoreMetadataOverrides.vpcSecurityGroupIds = .outputs.restore_testing.value.selection.restore_metadata_overrides.vpcSecurityGroupIds' \
  'Restore Testing security group must differ from the source RDS security group'
deny 'Restore metadata incorrectly uses source SG' valid \
  '.outputs.restore_testing.value.selection.restore_metadata_overrides.vpcSecurityGroupIds = (.outputs.rds_configuration.value.vpc_security_group_ids | tojson)' \
  'Restore Testing metadata does not match the isolated restore networking contract'
deny 'Restore metadata has extra SG' valid \
  '.outputs.restore_testing.value.selection.restore_metadata_overrides.vpcSecurityGroupIds = ([.outputs.restore_testing.value.restore_test_db_sg_id,"sg-33333333333333333"] | tojson)' \
  'Restore Testing metadata does not match the isolated restore networking contract'
deny 'Restore metadata has wrong subnet group' valid \
  '.outputs.restore_testing.value.selection.restore_metadata_overrides.dbSubnetGroupName = "wrong-subnet-group"' \
  'Restore Testing metadata does not match the isolated restore networking contract'
deny 'Restore metadata allows public accessibility' valid \
  '.outputs.restore_testing.value.selection.restore_metadata_overrides.publiclyAccessible = "true"' \
  'Restore Testing metadata does not match the isolated restore networking contract'
deny 'Restore metadata requests Multi-AZ' valid \
  '.outputs.restore_testing.value.selection.restore_metadata_overrides.multiAz = "true"' \
  'Restore Testing metadata does not match the isolated restore networking contract'
deny 'Disabled contract advertises SG' disabled \
  '.outputs.restore_testing.value.restore_test_db_sg_id = "sg-22222222222222222"' \
  'Disabled restore_testing contract must contain null policy/resource values'
deny 'Live AWS Restore Testing selection SG drifts' valid \
  '.aws.restoreSelection.RestoreTestingSelection.RestoreMetadataOverrides.vpcSecurityGroupIds = "[\"sg-44444444444444444\"]"' \
  'Live Restore Testing selection does not exactly match Terraform'
deny 'Live AWS Restore Testing selection subnet drifts' valid \
  '.aws.restoreSelection.RestoreTestingSelection.RestoreMetadataOverrides.dbSubnetGroupName = "other-db-subnet"' \
  'Live Restore Testing selection does not exactly match Terraform'
deny 'Source RDS SG drifts independently' valid \
  '.aws.rdsInstances.DBInstances[0].VpcSecurityGroups = [{VpcSecurityGroupId:"sg-55555555555555555"}]' \
  'Live RDS resilience and monitoring configuration does not exactly match Terraform'

printf '[PASS] %d offline RDS Restore Testing isolation scenarios.\n' "$cases"
