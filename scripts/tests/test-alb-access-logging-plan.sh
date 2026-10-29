#!/usr/bin/env bash
set -euo pipefail

# Offline positive/negative fixtures for validate-alb-access-logging-plan.sh.
# Terraform is mocked; no state, AWS credentials, or deployment is required.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/scripts/deployment/validate-alb-access-logging-plan.sh"
# Also allow the two downloaded files to be exercised together before copying.
[[ -f "$guard" ]] || guard="$(dirname "${BASH_SOURCE[0]}")/validate-alb-access-logging-plan.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/root"
touch "$tmp/root/apply.tfplan"

cat >"$tmp/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -chdir=* && "$2" == show && "$3" == -json && "$4" == *.tfplan ]] || exit 2
cat -- "$MOCK_PLAN_JSON"
MOCK
chmod +x "$tmp/bin/terraform"

jq -n '
  def res($type; $after):
    {address: ("module.baseline.module.application_load_balancer[0]." + $type + ".access_logs[0]"),
     mode:"managed", type:$type, name:"access_logs",
     change:{actions:["no-op"], before:$after, after:$after, after_unknown:{}}};
  def bucket: {bucket:"example-prod-alb-access-logs-abcd1234",force_destroy:false};
  def policy: {Statement:[
    {Sid:"AllowALBLogDelivery",Effect:"Allow",
     Principal:{Service:"logdelivery.elasticloadbalancing.amazonaws.com"},
     Action:["s3:PutObject"],
     Resource:"arn:aws:s3:::example-prod-alb-access-logs-abcd1234/alb/AWSLogs/123456789012/*",
     Condition:{ArnLike:{"aws:SourceArn":"arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/*"}}},
    {Sid:"DenyDeleteLogs",Effect:"Deny",Principal:"*",
     Action:["s3:DeleteObject","s3:DeleteObjectVersion"],
     Resource:"arn:aws:s3:::example-prod-alb-access-logs-abcd1234/*"},
    {Sid:"DenyBucketPolicyChanges",Effect:"Deny",Principal:"*",
     Action:["s3:PutBucketPolicy","s3:DeleteBucketPolicy"],
     Resource:"arn:aws:s3:::example-prod-alb-access-logs-abcd1234",
     Condition:{ArnNotEquals:{"aws:PrincipalArn":["arn:aws:iam::123456789012:role/TerraformApplyRole"]}}},
    {Sid:"DenyProtectedBucketConfigurationChanges",Effect:"Deny",Principal:"*",
     Action:["s3:PutLifecycleConfiguration","s3:PutBucketPublicAccessBlock",
             "s3:PutEncryptionConfiguration","s3:PutBucketOwnershipControls"],
     Resource:"arn:aws:s3:::example-prod-alb-access-logs-abcd1234",
     Condition:{ArnNotEquals:{"aws:PrincipalArn":["arn:aws:iam::123456789012:role/TerraformApplyRole"]}}},
    {Sid:"DenyVersioningChanges",Effect:"Deny",Principal:"*",
     Action:["s3:PutBucketVersioning"],
     Resource:"arn:aws:s3:::example-prod-alb-access-logs-abcd1234",
     Condition:{ArnNotEquals:{"aws:PrincipalArn":["arn:aws:iam::123456789012:role/TerraformApplyRole"]}}},
    {Sid:"DenyInsecureTransport",Effect:"Deny",Principal:"*",Action:["s3:*"],
     Resource:["arn:aws:s3:::example-prod-alb-access-logs-abcd1234", "arn:aws:s3:::example-prod-alb-access-logs-abcd1234/*"],
     Condition:{Bool:{"aws:SecureTransport":"false"}}}
  ]} | tojson;
  def alb:
    {address:"module.baseline.module.application_load_balancer[0].aws_lb.load_balancer",
     mode:"managed", type:"aws_lb", name:"load_balancer",
     change:{actions:["no-op"], before:{name:"tf-secure-baseline-prod-alb",access_logs:[{enabled:true,prefix:"alb",bucket:bucket.bucket}]},
             after:{name:"tf-secure-baseline-prod-alb",access_logs:[{enabled:true,prefix:"alb",bucket:bucket.bucket}]}}};
  def r: [
    res("aws_s3_bucket";bucket),
    res("aws_s3_bucket_public_access_block";{
      block_public_acls:true,block_public_policy:true,ignore_public_acls:true,restrict_public_buckets:true}),
    res("aws_s3_bucket_server_side_encryption_configuration";{
      rule:[{apply_server_side_encryption_by_default:[{sse_algorithm:"AES256"}]}]}),
    res("aws_s3_bucket_versioning";{versioning_configuration:[{status:"Enabled"}]}),
    res("aws_s3_bucket_ownership_controls";{rule:[{object_ownership:"BucketOwnerEnforced"}]}),
    res("aws_s3_bucket_lifecycle_configuration";{rule:[{
      id:"alb-access-logs-retention",status:"Enabled",filter:[{prefix:"alb/"}],
      expiration:[{days:90}],noncurrent_version_expiration:[{noncurrent_days:1}]}]}),
    res("aws_s3_bucket_policy";{policy:policy}),
    alb
  ];
  {format_version:"1.0",errored:false,complete:true,
   prior_state:{values:{outputs:{deployment_profile:{value:"production"}},
     root_module:{child_modules:[{address:"module.baseline.module.application_load_balancer[0]",
       resources:[{address:"module.baseline.module.application_load_balancer[0].aws_s3_bucket.access_logs[0]",
                   mode:"managed",name:"access_logs",type:"aws_s3_bucket",values:bucket}]}]}}},
   planned_values:{outputs:{deployment_profile:{value:"production"},
     lifecycle_protection:{value:{production_retirement_mode:false}}}},
   resource_changes:r}
' >"$tmp/base.json"

passed=0
check() {
  local expected="$1" description="$2" fixture="$3" mode="${4:-false}"
  local rc=0
  MOCK_PLAN_JSON="$fixture" PATH="$tmp/bin:$PATH" bash "$guard" \
    --working-directory "$tmp/root" --plan-file "$tmp/root/apply.tfplan" \
    --retirement-mode "$mode" >"$tmp/out" 2>&1 || rc=$?
  if [[ "$expected" == pass && "$rc" -ne 0 ]] || [[ "$expected" == fail && "$rc" -eq 0 ]]; then
    printf '[FAIL] %s (expected %s; got exit %s)\n' "$description" "$expected" "$rc" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
  passed=$((passed + 1))
}

# jq fixture mutations use the same resource identity as the real baseline.
make() {
  jq "$2" "$tmp/base.json" >"$tmp/$1.json"
}
check pass 'Existing production logging unchanged' "$tmp/base.json"

# A normal Apply must be able to repair a previously deployed policy and
# update the configured administrators without changing the protected bucket.
make repaired_policy '(.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change) |=
  (.actions = ["update"] |
   .before.policy |= (fromjson |
     del(.Statement[] | select(.Sid == "DenyProtectedBucketConfigurationChanges")) |
     (.Statement[] | select(.Sid == "AllowALBLogDelivery") | .Condition.ArnLike["aws:SourceArn"]) =
       "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/tf-secure-baseline-prod-alb/*" |
     tojson))'
check pass 'Ordinary Apply can repair the previous bucket policy' "$tmp/repaired_policy.json"

make admins_updated '(.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change) |=
  (.actions = ["update"] |
   .after.policy |= (fromjson |
     (.Statement[] | select(.Sid == "DenyBucketPolicyChanges" or
                              .Sid == "DenyProtectedBucketConfigurationChanges" or
                              .Sid == "DenyVersioningChanges") |
      .Condition.ArnNotEquals["aws:PrincipalArn"]) +=
       ["arn:aws:iam::123456789012:role/BreakGlass-Admin"] |
     tojson))'
check pass 'Ordinary Apply can update bucket administrators' "$tmp/admins_updated.json"
make increase '(.resource_changes[] | select(.type == "aws_s3_bucket_lifecycle_configuration") | .change.after.rule[0].expiration[0].days) = 120'
check pass 'Production retention increase' "$tmp/increase.json"
make stage1 '.planned_values.outputs.lifecycle_protection.value.production_retirement_mode = true |
  (.resource_changes[] | select(.type == "aws_s3_bucket") | .change.after.force_destroy) = true'
check pass 'Approved Stage-1 in-place force_destroy' "$tmp/stage1.json" true

make created '.prior_state = null |
  .resource_changes |= map(
    if .type == "aws_lb" then .change.actions = ["create"] | .change.before = null
    else .change.actions = ["create"] | .change.before = null end) |
  (.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change) |=
    (.after.policy = null | .after_unknown.policy = true)'
check pass 'New production bucket with protected resources' "$tmp/created.json"
make dev_empty '.prior_state = null | .planned_values.outputs.deployment_profile.value = "development" |
  .resource_changes = []'
check pass 'Development without ALB remains unaffected' "$tmp/dev_empty.json"
make prod_empty '.prior_state = null | .resource_changes = []'
check pass 'Production without ingress ALB has no log bucket' "$tmp/prod_empty.json"
make dev_create '.prior_state = null | .planned_values.outputs.deployment_profile.value = "development" |
  .resource_changes |= map(.change.before = null | .change.actions = ["create"]) |
  (.resource_changes[] | select(.type == "aws_s3_bucket") | .change.after.force_destroy) = true |
  (.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change) |=
    (.after.policy = null | .after_unknown.policy = true)'
check pass 'Nonproduction creation uses disposable force_destroy' "$tmp/dev_create.json"
make dev_delete '.prior_state.values.outputs.deployment_profile.value = "development" |
  .planned_values.outputs.deployment_profile.value = "development" |
  .resource_changes |= map(
    if .type == "aws_lb" then .change.after.access_logs[0].enabled = false
    else .change.actions = ["delete"] | .change.after = null end)'
check pass 'Development can disable and delete logging' "$tmp/dev_delete.json"
make promote '.prior_state.values.outputs.deployment_profile.value = "development"'
check pass 'Promoting an existing nonproduction bucket into protected production' "$tmp/promote.json"

make bypass '.planned_values.outputs.deployment_profile.value = "development"'
check fail 'Changing production to development bypass' "$tmp/bypass.json"
make unknown_prior 'del(.prior_state.values.outputs.deployment_profile)'
check fail 'Prior bucket with missing deployment profile' "$tmp/unknown_prior.json"
make invalid_prior '.prior_state.values.outputs.deployment_profile.value = "not-a-profile"'
check fail 'Invalid prior profile fails closed' "$tmp/invalid_prior.json"
make missing_state '.prior_state.values.root_module = null'
check fail 'Missing prior resource inventory does not bypass production protection' "$tmp/missing_state.json"
make removed '(.resource_changes[] | select(.type == "aws_s3_bucket") | .change) |=
  (.actions = ["delete"] | .after = null)'
check fail 'Existing production bucket deletion' "$tmp/removed.json"
make replaced '(.resource_changes[] | select(.type == "aws_s3_bucket") | .change.actions) = ["delete", "create"]'
check fail 'Existing production bucket replacement' "$tmp/replaced.json"
make force_destroy '(.resource_changes[] | select(.type == "aws_s3_bucket") | .change.after.force_destroy) = true'
check fail 'Ordinary Apply cannot set force_destroy=true' "$tmp/force_destroy.json"
check fail 'Cannot fake retirement using outputs alone' "$tmp/stage1.json" false
check fail 'Caller cannot request unplanned retirement' "$tmp/base.json" true
check fail 'Stage-1 cannot create new bucket' "$tmp/created.json" true
make stage1_create '.planned_values.outputs.lifecycle_protection.value.production_retirement_mode = true |
  .prior_state = null |
  .resource_changes |= map(.change.actions = ["create"] | .change.before = null) |
  (.resource_changes[] | select(.type == "aws_s3_bucket") | .change.after.force_destroy) = true'
check fail 'Stage-1 creation not allowed even with retirement flag' "$tmp/stage1_create.json" true
make shorten '(.resource_changes[] | select(.type == "aws_s3_bucket_lifecycle_configuration") | .change.after.rule[0].expiration[0].days) = 30'
check fail 'Production retention cannot be shortened' "$tmp/shorten.json"
make noncurrent '(.resource_changes[] | select(.type == "aws_s3_bucket_lifecycle_configuration") | .change.after.rule[0].noncurrent_version_expiration[0].noncurrent_days) = 0'
check fail 'Noncurrent expiration must remain one day' "$tmp/noncurrent.json"
make missing_rule '(.resource_changes[] | select(.type == "aws_s3_bucket_lifecycle_configuration") | .change.after.rule) = []'
check fail 'Retention rule cannot be removed' "$tmp/missing_rule.json"
make versioning '(.resource_changes[] | select(.type == "aws_s3_bucket_versioning") | .change.after.versioning_configuration[0].status) = "Suspended"'
check fail 'Versioning cannot be suspended' "$tmp/versioning.json"
make encryption '(.resource_changes[] | select(.type == "aws_s3_bucket_server_side_encryption_configuration") | .change.after.rule[0].apply_server_side_encryption_by_default[0].sse_algorithm) = "aws:kms"'
check fail 'SSE-S3 cannot be replaced with SSE-KMS' "$tmp/encryption.json"
make public '(.resource_changes[] | select(.type == "aws_s3_bucket_public_access_block") | .change.after.block_public_policy) = false'
check fail 'Public access protections cannot be weakened' "$tmp/public.json"
make stage1_public '.planned_values.outputs.lifecycle_protection.value.production_retirement_mode = true |
  (.resource_changes[] | select(.type == "aws_s3_bucket") | .change.after.force_destroy) = true |
  (.resource_changes[] | select(.type == "aws_s3_bucket_public_access_block") | .change.after.block_public_policy) = false'
check fail 'Stage-1 cannot weaken public-access safeguards' "$tmp/stage1_public.json" true
make ownership '(.resource_changes[] | select(.type == "aws_s3_bucket_ownership_controls") | .change.after.rule[0].object_ownership) = "ObjectWriter"'
check fail 'BucketOwnerEnforced cannot be removed' "$tmp/ownership.json"
make no_policy '(.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change) |=
  (.actions = ["delete"] | .after = null)'
check fail 'Bucket policy cannot be removed' "$tmp/no_policy.json"
make bad_delivery_policy '(.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change.after.policy) |=
  (fromjson | (.Statement[] | select(.Sid == "AllowALBLogDelivery") | .Condition.ArnLike["aws:SourceArn"]) =
    "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/other-alb/*" | tojson)'
check fail 'Delivery SourceArn cannot be redirected' "$tmp/bad_delivery_policy.json"
make weak_policy '(.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change.after.policy) |=
  (fromjson | (.Statement[] | select(.Sid == "DenyDeleteLogs") | .Action) = ["s3:DeleteObject"] | tojson)'
check fail 'Delete-object-version deny cannot be removed' "$tmp/weak_policy.json"
make weak_admin '(.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change.after.policy) |=
  (fromjson | (.Statement[] | select(.Sid == "DenyBucketPolicyChanges") | .Condition.ArnNotEquals["aws:PrincipalArn"]) = ["*"] | tojson)'
check fail 'Bucket admin deny cannot be opened to wildcard' "$tmp/weak_admin.json"
make missing_config '(.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change.after.policy) |=
  (fromjson | del(.Statement[] | select(.Sid == "DenyProtectedBucketConfigurationChanges")) | tojson)'
check fail 'Protected bucket configuration deny must exist' "$tmp/missing_config.json"
make weak_config '(.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change.after.policy) |=
  (fromjson | (.Statement[] | select(.Sid == "DenyProtectedBucketConfigurationChanges") | .Action) |=
    map(select(. != "s3:PutLifecycleConfiguration")) | tojson)'
check fail 'Lifecycle configuration deny cannot be removed' "$tmp/weak_config.json"
make edited_policy '(.resource_changes[] | select(.type == "aws_s3_bucket_policy") | .change) |=
  (.actions = ["update"] | .after.policy = "{\"Statement\":[]}")'
check fail 'Policy update missing mandatory protections is rejected' "$tmp/edited_policy.json"
make lb_disabled '(.resource_changes[] | select(.type == "aws_lb") | .change.after.access_logs[0].enabled) = false'
check fail 'Protected ALB logging cannot be disabled' "$tmp/lb_disabled.json"
make wrong_prefix '(.resource_changes[] | select(.type == "aws_lb") | .change.after.access_logs[0].prefix) = "other"'
check fail 'Unexpected access-log prefix' "$tmp/wrong_prefix.json"
make bad_bucket '(.resource_changes[] | select(.type == "aws_lb") | .change.after.access_logs[0].bucket) = "wrong-bucket"'
check fail 'Incorrect ALB bucket reference' "$tmp/bad_bucket.json"
make incomplete '.complete = false'
check fail 'Incomplete Terraform plans fail closed' "$tmp/incomplete.json"
printf '{bad json\n' >"$tmp/malformed.json"
check fail 'Malformed plan JSON fails closed' "$tmp/malformed.json"

printf '[PASS] %d offline ALB saved-plan guard cases. No AWS operations performed.\n' "$passed"
