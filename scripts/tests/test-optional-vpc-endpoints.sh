#!/usr/bin/env bash
set -euo pipefail

# Offline M3 regression suite: exercises the real VPC endpoint validator against
# synthetic Terraform outputs and mocked AWS responses. No live AWS requests or
# Terraform state mutations occur. Run from any working directory:
#   bash scripts/tests/test-optional-vpc-endpoints.sh

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="${root}/scripts/validation/validate-vpc-endpoints.sh"
common="${root}/scripts/validation/lib/common.sh"
for required in jq bash cp mktemp; do
  command -v "$required" >/dev/null 2>&1 || { echo "Missing command: $required" >&2; exit 1; }
done
[[ -f "$validator" && -f "$common" ]] || {
  echo "Missing validator or shared validation library under $root" >&2; exit 1;
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/repo/scripts/validation/lib" "$tmp/repo/environments/dev" "$tmp/bin"
cp -- "$validator" "$tmp/repo/scripts/validation/validate-vpc-endpoints.sh"
ln -s -- "$common" "$tmp/repo/scripts/validation/lib/common.sh"

# Fake command binaries deliberately have no fallback to real AWS/Terraform.
cat > "$tmp/bin/git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == rev-parse && "${2:-}" == --show-toplevel ]]; then
  printf '%s\n' "$MOCK_REPO_ROOT"
else
  echo "Unexpected git command: $*" >&2
  exit 91
fi
MOCK_GIT

cat > "$tmp/bin/terraform" <<'MOCK_TERRAFORM'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" output -json "* ]]; then
  jq -c '.outputs' "$MOCK_FIXTURE"
else
  echo "Unexpected Terraform command: $*" >&2
  exit 92
fi
MOCK_TERRAFORM

cat > "$tmp/bin/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  'sts get-caller-identity')
    if [[ " $* " == *" --query Account "* ]]; then
      printf '%s\n' '955775177042'
    elif [[ " $* " == *" --query Arn "* ]]; then
      printf '%s\n' 'arn:aws:iam::955775177042:user/offline-test'
    else
      echo 'Unexpected STS query' >&2; exit 93
    fi
    ;;
  'ec2 describe-subnets')
    jq -c '.subnets' "$MOCK_FIXTURE"
    ;;
  'ec2 describe-security-groups')
    jq -c '.securityGroups' "$MOCK_FIXTURE"
    ;;
  'ec2 describe-route-tables')
    case " $* " in
      *'Endpoint-Private-RT-'*) jq -c '.endpointRoutes' "$MOCK_FIXTURE" ;;
      *'Compute-Private-RT-'*) jq -c '.computeRoutes' "$MOCK_FIXTURE" ;;
      *'Serverless-Private-RT-'*) jq -c '.serverlessRoutes' "$MOCK_FIXTURE" ;;
      *) echo "Unexpected route table filter: $*" >&2; exit 94 ;;
    esac
    ;;
  'ec2 describe-vpc-endpoints')
    if [[ " $* " == *'Name=vpc-endpoint-type,Values=Interface'* ]]; then
      jq -c '.interface' "$MOCK_FIXTURE"
    elif [[ " $* " == *'Name=vpc-endpoint-type,Values=Gateway'* ]]; then
      jq -c '.gateway' "$MOCK_FIXTURE"
    else
      echo "Unexpected endpoint filter: $*" >&2; exit 95
    fi
    ;;
  *) echo "Unexpected AWS request: $*" >&2; exit 96 ;;
esac
MOCK_AWS
chmod +x "$tmp/bin/git" "$tmp/bin/terraform" "$tmp/bin/aws"

# Independent required-service fixture: deliberately do not extract this set
# from the script under test, so inventory regressions are observable.
mandatory=(sts sqs logs ssm ssmmessages secretsmanager kms config sns ec2 \
           ecr.api ecr.dkr events securityhub lambda guardduty-data)
services_json="$(printf '%s\n' "${mandatory[@]}" | jq -R . | jq -sc 'sort')"

make_fixture() {
  local destination="$1" with_bedrock="$2"
  local names="$services_json"
  if [[ "$with_bedrock" == true ]]; then
    names="$(jq -nc --argjson names "$names" '$names + ["bedrock-runtime"] | sort')"
  fi

  jq -n --argjson names "$names" '
    "us-east-1" as $region |
    "tf-secure-baseline-dev" as $prefix |
    "vpc-0123456789abcdef0" as $vpc |
    "sg-0123456789abcdef0" as $sg |
    ["subnet-111111111", "subnet-222222222"] as $endpoint_subnets |
    ($names | to_entries | map({
      VpcEndpointId: ("vpce-" + ((1000000 + .key) | tostring)),
      ServiceName: ("com.amazonaws." + $region + "." + .value),
      State: "available",
      VpcId: $vpc,
      PrivateDnsEnabled: true,
      SubnetIds: $endpoint_subnets,
      Groups: [{GroupId:$sg}]
    })) as $interfaces |
    (reduce $interfaces[] as $e ({};
      .[($e.ServiceName | ltrimstr("com.amazonaws." + $region + "."))] = $e.VpcEndpointId
    )) as $ids |
    ["us-east-1a", "us-east-1b"] as $azs |
    {outputs: {
      primary_region: {value:$region},
      vpc_id: {value:$vpc},
      effective_egress_mode: {value:"nat_only"},
      interface_endpoint_ids: {value:$ids},
      network_topology: {value:{
        availability_zones:$azs,
        endpoint_private_subnet_ids_by_az:{"us-east-1a":$endpoint_subnets[0], "us-east-1b":$endpoint_subnets[1]}
      }}
    },
    subnets:{Subnets:[
      {SubnetId:$endpoint_subnets[0],AvailabilityZone:$azs[0],MapPublicIpOnLaunch:false},
      {SubnetId:$endpoint_subnets[1],AvailabilityZone:$azs[1],MapPublicIpOnLaunch:false}
    ]},
    securityGroups:{SecurityGroups:[{GroupId:$sg,GroupName:($prefix + "-vpc-endpoints-sg")}]},
    endpointRoutes:{RouteTables:[
      {RouteTableId:"rtb-111",Routes:[],Associations:[{SubnetId:$endpoint_subnets[0]}],Tags:[{Key:"Name",Value:($prefix + "-Endpoint-Private-RT-" + $azs[0])}]},
      {RouteTableId:"rtb-222",Routes:[],Associations:[{SubnetId:$endpoint_subnets[1]}],Tags:[{Key:"Name",Value:($prefix + "-Endpoint-Private-RT-" + $azs[1])}]}
    ]},
    computeRoutes:{RouteTables:[{RouteTableId:"rtb-333"},{RouteTableId:"rtb-444"}]},
    serverlessRoutes:{RouteTables:[{RouteTableId:"rtb-555"},{RouteTableId:"rtb-666"}]},
    interface:{VpcEndpoints:$interfaces},
    gateway:{VpcEndpoints:[{
      VpcEndpointId:"vpce-99990000",State:"available",
      RouteTableIds:["rtb-111","rtb-222","rtb-333","rtb-444","rtb-555","rtb-666"]
    }]}
    }
  ' > "$destination"
}

make_fixture "$tmp/base16.json" false
make_fixture "$tmp/base17.json" true

cases=0
run_case() {
  local expectation="$1" description="$2" base="$3" mutation="$4" expected_message="$5"
  local fixture="$tmp/case.json" output="$tmp/output.txt"
  cp -- "$tmp/$base.json" "$fixture"
  if [[ "$mutation" != '.' ]]; then
    jq -c "$mutation" "$fixture" > "$tmp/new-case.json"
    mv -- "$tmp/new-case.json" "$fixture"
  fi

  local code=0
  MOCK_FIXTURE="$fixture" \
  MOCK_REPO_ROOT="$tmp/repo" \
  AWS_PROFILE=dev AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID=955775177042 \
  PATH="$tmp/bin:$PATH" \
    bash "$tmp/repo/scripts/validation/validate-vpc-endpoints.sh" dev > "$output" 2>&1 || code=$?

  if [[ "$expectation" == pass ]]; then
    if ((code != 0)) || ! grep -Fq '[PASS] VPC Endpoints validation completed successfully for: dev' "$output"; then
      printf '[FAIL] %s (expected success; status=%d)\n' "$description" "$code" >&2
      tail -70 "$output" >&2; exit 1
    fi
  else
    if ((code == 0)) || ! grep -Fq "$expected_message" "$output"; then
      printf '[FAIL] %s (expected rejection containing %q; status=%d)\n' "$description" "$expected_message" "$code" >&2
      tail -70 "$output" >&2; exit 1
    fi
  fi
  cases=$((cases+1))
}

pass() { run_case pass "$1" "$2" "${3:-.}" ''; }
deny() { run_case fail "$1" "$2" "$3" "$4"; }

pass 'Default required 16 services' base16
pass 'Enabled bedrock-runtime (17 services)' base17
pass 'Optional intent empty agrees with disabled' base16 \
  '.outputs.configured_additional_interface_endpoint_services={value:[]}'
pass 'Optional intent agrees with enabled' base17 \
  '.outputs.configured_additional_interface_endpoint_services={value:["bedrock-runtime"]}'

deny 'Required endpoint absent from Terraform' base17 \
  'del(.outputs.interface_endpoint_ids.value.sts)' \
  'must contain all required endpoints'
deny 'Unapproved Terraform endpoint rejected' base17 \
  '.outputs.interface_endpoint_ids.value."bedrock-agent"="vpce-9999991"' \
  'outside the approved optional allowlist'
deny 'Malformed Terraform endpoint identity' base17 \
  '.outputs.interface_endpoint_ids.value."bedrock-runtime"="malformed"' \
  'must be a non-empty map of service names to VPC Endpoint IDs'
deny 'Duplicate Terraform endpoint identity' base17 \
  '.outputs.interface_endpoint_ids.value."bedrock-runtime"=.outputs.interface_endpoint_ids.value.sts' \
  'assigned to more than one service'
deny 'Configured optional service disagrees with deployed' base17 \
  '.outputs.configured_additional_interface_endpoint_services={value:[]}' \
  'disagree with Terraform-owned endpoint IDs'
deny 'Unapproved optional intent rejected' base16 \
  '.outputs.configured_additional_interface_endpoint_services={value:["bedrock-agent"]}' \
  'must be a unique list of approved optional services'
deny 'Repeated optional intent rejected' base17 \
  '.outputs.configured_additional_interface_endpoint_services={value:["bedrock-runtime","bedrock-runtime"]}' \
  'must be a unique list of approved optional services'
deny 'Missing live optional endpoint rejected' base17 \
  '.interface.VpcEndpoints |= map(select(.ServiceName != "com.amazonaws.us-east-1.bedrock-runtime"))' \
  'Missing expected Interface VPC Endpoints'
deny 'Unexpected live optional endpoint in default mode rejected' base16 \
  '.interface.VpcEndpoints += [(.interface.VpcEndpoints[0] | .ServiceName="com.amazonaws.us-east-1.bedrock-runtime" | .VpcEndpointId="vpce-9999992")]' \
  'Unexpected Interface VPC Endpoint services are present'
deny 'Duplicate live service rejected' base17 \
  '.interface.VpcEndpoints += [.interface.VpcEndpoints[0]]' \
  'Duplicate Interface VPC Endpoints found for services'
deny 'Live endpoint ID drift rejected' base17 \
  '.interface.VpcEndpoints[0].VpcEndpointId="vpce-9999993"' \
  'identities do not exactly match Terraform output'
deny 'Disabled private DNS rejected' base17 \
  '.interface.VpcEndpoints[0].PrivateDnsEnabled=false' \
  'One or more Interface VPC Endpoints do not have private DNS enabled'
deny 'Incorrect endpoint security group rejected' base17 \
  '.interface.VpcEndpoints[0].Groups=[{GroupId:"sg-999999999"}]' \
  'do not use exactly the expected Interface Endpoint security group'
deny 'Incorrect endpoint-private subnet rejected' base17 \
  '.interface.VpcEndpoints[0].SubnetIds=["subnet-999999999"]' \
  'do not use the exact endpoint-private subnet set'
deny 'Non-available endpoint rejected' base17 \
  '.interface.VpcEndpoints[0].State="pending"' \
  'One or more Interface VPC Endpoints are not available'
deny 'Wrong VPC endpoint rejected' base17 \
  '.interface.VpcEndpoints[0].VpcId="vpc-999999999"' \
  'One or more Interface VPC Endpoints belong to an unexpected VPC'
deny 'Endpoint-private default route rejected' base17 \
  '.endpointRoutes.RouteTables[0].Routes=[{DestinationCidrBlock:"0.0.0.0/0"}]' \
  'Expected endpoint private route tables to have no 0.0.0.0/0 default routes'
deny 'S3 Gateway route table drift rejected' base17 \
  '.gateway.VpcEndpoints[0].RouteTableIds += ["rtb-777"]' \
  'S3 Gateway Endpoint route-table associations do not exactly match'

printf '[PASS] %d offline optional Interface VPC Endpoint scenarios.\n' "$cases"
