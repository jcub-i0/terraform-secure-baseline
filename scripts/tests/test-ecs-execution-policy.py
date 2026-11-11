#!/usr/bin/env python3
"""Offline regressions for the actual per-service ECS IAM validation path.

Execute its source block and helpers with AWS responses supplied by a shell
function. No AWS CLI, credentials, Terraform backend, or third-party packages.
The policies below independently represent modules/iam/ecs.tf, not the checker.
"""

import copy
import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "scripts/validation/validate-iam.sh").read_text()
HELPERS = SOURCE.split("get_role_json() {", 1)[1].split(
    'section "Validating expected IAM roles"', 1
)[0]
BLOCK = SOURCE.split('section "Validating per-service ECS IAM roles and policies"', 1)[1].split(
    'section "IAM Summary"', 1
)[0]

ACCOUNT = "123456789012"
REPO = f"arn:aws:ecr:us-east-1:{ACCOUNT}:repository/test"
SIDECAR_REPO = f"arn:aws:ecr:us-east-1:{ACCOUNT}:repository/scanner"
SIDECAR_URL = f"{ACCOUNT}.dkr.ecr.us-east-1.amazonaws.com/scanner"
GUARDDUTY = "arn:aws:ecr:us-east-1:593207742271:repository/aws-guardduty-agent-fargate"
URL = f"{ACCOUNT}.dkr.ecr.us-east-1.amazonaws.com/test"
LOG = f"arn:aws:logs:us-east-1:{ACCOUNT}:log-group:test"
SECRET = f"arn:aws:secretsmanager:us-east-1:{ACCOUNT}:secret:app-AbCdEf"
PARAMETER = f"arn:aws:ssm:us-east-1:{ACCOUNT}:parameter/app/host"
SCANNER_SECRET = (f"arn:aws:secretsmanager:us-east-1:{ACCOUNT}:secret:scanner-GhIjKl")
SCANNER_PARAMETER = (f"arn:aws:ssm:us-east-1:{ACCOUNT}:parameter/scanner/token")
KEY = f"arn:aws:kms:us-east-1:{ACCOUNT}:key/00000000-0000-0000-0000-000000000000"
PULL = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]

MOCKS = r'''
set -euo pipefail
source scripts/validation/lib/common.sh
source scripts/validation/lib/ecs-task-role-managed-policies.sh
ACCOUNT_ID=123456789012
AWS_REGION=us-east-1
aws_args=()
aws() {
  local operation="$1:$2" role='' previous='' arg
  for arg in "$@"; do
    if [[ "$previous" == --role-name ]]; then role="$arg"; fi
    previous="$arg"
  done
  case "$operation" in
    iam:get-role)
      jq -nc --arg name "$role" '{Role:{
        Arn:("arn:aws:iam::123456789012:role/"+$name),
        AssumeRolePolicyDocument:{Statement:[{
          Effect:"Allow",Action:"sts:AssumeRole",
          Principal:{Service:"ecs-tasks.amazonaws.com"},
          Condition:{StringEquals:{"aws:SourceAccount":"123456789012"},
            ArnLike:{"aws:SourceArn":"arn:aws:ecs:us-east-1:123456789012:*"}}
        }]}}}' ;;
    iam:list-attached-role-policies) echo '{"AttachedPolicies":[]}' ;;
    iam:list-role-policies)
      if [[ "$role" == test-execution ]]; then
        echo '{"PolicyNames":["test-execution"]}'
      else echo '{"PolicyNames":[]}'; fi ;;
    iam:get-role-policy) jq -nc --argjson p "$MOCK_POLICY" '{PolicyDocument:$p}' ;;
    ecs:describe-task-definition) printf '%s\n' "$MOCK_TASK" ;;
    *) echo "Unexpected mock operation: $operation" >&2; return 99 ;;
  esac
}
'''
SCRIPT = MOCKS + "get_role_json() {" + HELPERS + BLOCK


def grant(actions, resources):
    return {"Effect": "Allow", "Action": actions, "Resource": resources}


def fixture(optional=False, guardduty=True):
    config = {
        "task_execution_kms_key_arns": [KEY, KEY + "1"] if optional else [],
        "guardduty_agent_ecr_repository_arns": [GUARDDUTY] if guardduty else [],
    }
    outputs = {k: {"value": v} for k, v in {
        "deployment_profile": "production" if guardduty else "minimal",
        "ecs_services": {"test": {}},
        "ecs_service_configuration": {"test": config},
        "ecs_task_definition_arns": {"test": f"arn:aws:ecs:us-east-1:{ACCOUNT}:task-definition/test:2"},
        "ecs_log_groups": {"test": {"arn": LOG}},
        "ecs_task_execution_roles": {"test": {
            "name": "test-execution", "arn": f"arn:aws:iam::{ACCOUNT}:role/test-execution"}},
        "ecs_task_roles": {"test": {
            "name": "test-task", "arn": f"arn:aws:iam::{ACCOUNT}:role/test-task"}},
        "ecr_repositories": {"test": {"arn": REPO, "repository_url": URL}},
    }.items()}
    task = {"taskDefinition": {"containerDefinitions": [{
        "name": "test", "image": URL + "@sha256:" + "a" * 64,
        "secrets": ([{"name": "password", "valueFrom": SECRET},
                     {"name": "token", "valueFrom": SECRET + "2"},
                     {"name": "host", "valueFrom": PARAMETER}] if optional else []),
    }]}}
    statements = [
        grant(["ecr:GetAuthorizationToken"], ["*"]),
        grant(PULL, [REPO]),
        grant(["logs:CreateLogStream", "logs:PutLogEvents"], [LOG + ":*"]),
    ]
    if guardduty:
        statements.append(grant(PULL, [GUARDDUTY]))
    if optional:
        statements.extend([
            grant(["secretsmanager:GetSecretValue"], [SECRET, SECRET + "2"]),
            grant(["ssm:GetParameters"], [PARAMETER]),
            grant(["kms:Decrypt"], [KEY, KEY + "1"]),
        ])
    return outputs, task, {"Version": "2012-10-17", "Statement": statements}


class ExecutionPolicyTests(unittest.TestCase):
    def check(self, data, accepted, diagnostic="[FAIL]"):
        outputs, task, policy = data
        result = subprocess.run(
            ["bash"], input=SCRIPT, text=True, capture_output=True, cwd=ROOT,
            env={**os.environ, "OUTPUTS_JSON": json.dumps(outputs),
                 "MOCK_POLICY": json.dumps(policy), "MOCK_TASK": json.dumps(task)},
            timeout=30,
        )
        evidence = result.stdout + result.stderr
        self.assertEqual(result.returncode == 0, accepted, evidence)
        if accepted:
            self.assertIn("execution inline policy matches the generated contract", evidence)
            self.assertIn("not effective IAM permissions", evidence)
        else:
            self.assertIn(diagnostic, evidence)
            self.assertNotIn("execution inline policy matches the generated contract", evidence)

    def test_legitimate_profile_and_optional_grants(self):
        for guardduty in (False, True):
            for optional in (False, True):
                with self.subTest(guardduty=guardduty, optional=optional):
                    self.check(fixture(optional, guardduty), True)

    def test_iam_serialization_order_and_scalar_forms(self):
        data = fixture(optional=True)
        for statement in data[2]["Statement"]:
            statement["Sid"] = "IgnoredStatementIdentifier"
            for key in ("Action", "Resource"):
                values = list(reversed(statement[key]))
                statement[key] = values[0] if len(values) == 1 else values
        data[2]["Statement"].reverse()
        self.check(data, True)

    def test_confirmed_bypasses_and_undeclared_permissions(self):
        for action in ("iam:*", "iam:PassRole", "*", "secretsmanager:GetSecretValue",
                       "ssm:GetParameters", "kms:Decrypt", "logs:*", "s3:GetObject"):
            with self.subTest(action=action):
                data = fixture()
                data[2]["Statement"].append(grant([action], ["*"]))
                self.check(data, False)

    def test_added_grants_beside_legitimate_optional_permissions(self):
        for action in ("secretsmanager:GetSecretValue", "ssm:GetParameters", "kms:Decrypt",
                       "logs:PutLogEvents"):
            with self.subTest(action=action):
                data = fixture(optional=True)
                data[2]["Statement"].append(grant([action], ["*"]))
                self.check(data, False)

    def test_broader_or_wrong_resource_for_every_generated_statement(self):
        original = fixture(optional=True)
        for index in range(len(original[2]["Statement"])):
            with self.subTest(statement=index):
                data = copy.deepcopy(original)
                # Authorization must retain *, all other grants must be scoped.
                data[2]["Statement"][index]["Resource"] = [REPO if index == 0 else "*"]
                self.check(data, False)

    def test_missing_required_statement(self):
        data = fixture(optional=True)
        del data[2]["Statement"][-1]
        self.check(data, False)

    def test_extra_action_on_existing_statement(self):
        data = fixture()
        data[2]["Statement"][2]["Action"].append("logs:DeleteLogGroup")
        self.check(data, False)

    def test_unexpected_statement_semantics(self):
        for extra in ({"NotAction": ["iam:PassRole"]}, {"NotResource": [SECRET]},
                      {"Condition": {"StringEquals": {"aws:RequestedRegion": "us-east-1"}}},
                      {"Principal": "*"}, {"Effect": "Deny"}):
            with self.subTest(extra=extra):
                data = fixture()
                data[2]["Statement"][2].update(extra)
                self.check(data, False)

    def test_malformed_statement_fails_closed(self):
        for statement in (None, {}, {"Effect": "Allow", "Action": 1, "Resource": "*"}):
            with self.subTest(statement=statement):
                data = fixture()
                data[2]["Statement"].append(statement)
                # Non-string actions already fail closed in the existing ECR
                # normalizer, before the new full-contract diagnostic is reached.
                diagnostic = "jq: error" if statement and statement.get("Action") == 1 else "[FAIL]"
                self.check(data, False, diagnostic)

    def test_ambiguous_secret_reference_fails_closed(self):
        data = fixture()
        data[1]["taskDefinition"]["containerDefinitions"][0]["secrets"] = [
            {"name": "unknown", "valueFrom": "unclassified-parameter"}]
        self.check(data, False)

    def test_wildcard_secret_in_both_contract_and_live_policy_is_rejected(self):
        data = fixture(optional=True)
        data[1]["taskDefinition"]["containerDefinitions"][0]["secrets"][0]["valueFrom"] = SECRET + "*"
        data[2]["Statement"][4]["Resource"][0] = SECRET + "*"
        self.check(data, False)

    def test_multi_container_ecr_permissions(self):
        data = fixture(guardduty=False)
        outputs, task, policy = data

        outputs["ecr_repositories"]["value"]["scanner"] = {
            "arn": SIDECAR_REPO,
            "repository_url": SIDECAR_URL,
        }

        task["taskDefinition"]["containerDefinitions"].append({
            "name": "scanner",
            "image": SIDECAR_URL + "@sha256:" + "b" * 64,
            "secrets": [],
        })

        policy["Statement"][1]["Resource"] = [REPO, SIDECAR_REPO]

        # Both declared repositories are authorized.
        self.check(data, True)

        # Missing sidecar repository permission is rejected.
        missing = copy.deepcopy(data)
        missing[2]["Statement"][1]["Resource"] = [REPO]
        self.check(missing, False)

        # An additional undeclared repository is rejected.
        excessive = copy.deepcopy(data)
        excessive[2]["Statement"][1]["Resource"].append(
            f"arn:aws:ecr:us-east-1:{ACCOUNT}:repository/other"
        )
        self.check(excessive, False)

        # Multiple containers may share the primary repository.
        shared = copy.deepcopy(data)
        shared[1]["taskDefinition"]["containerDefinitions"][1]["image"] = (
            URL + "@sha256:" + "b" * 64
        )
        shared[2]["Statement"][1]["Resource"] = [REPO]
        self.check(shared, True)

        # A mutable sidecar image must be rejected.
        unpinned = copy.deepcopy(shared)
        unpinned[1]["taskDefinition"]["containerDefinitions"][1]["image"] = (
            URL + ":latest"
        )
        self.check(unpinned, False)

        # An image outside the managed repository inventory is rejected.
        unknown = copy.deepcopy(shared)
        unknown[1]["taskDefinition"]["containerDefinitions"][1]["image"] = (
            "999999999999.dkr.ecr.us-east-1.amazonaws.com/other@sha256:"
            + "b" * 64
        )
        self.check(unknown, False)

    def test_multi_container_secret_permissions(self):
        data = fixture(guardduty=False)
        outputs, task, policy = data

        task["taskDefinition"]["containerDefinitions"].append({
            "name": "scanner",
            "image": URL + "@sha256:" + "b" * 64,
            "secrets": [
                {
                    "name": "SCANNER_TOKEN",
                    "valueFrom": SCANNER_SECRET + ":token::",
                },
                {
                    "name": "SCANNER_PARAMETER",
                    "valueFrom": SCANNER_PARAMETER,
                },
            ],
        })

        policy["Statement"].extend([
            grant(["secretsmanager:GetSecretValue"], [SCANNER_SECRET]),
            grant(["ssm:GetParameters"], [SCANNER_PARAMETER]),
        ])

        # Exact, declared permissions must succeed.
        self.check(data, True)

        # Missing Secrets Manager permission must fail.
        missing_secret = copy.deepcopy(data)
        missing_secret[2]["Statement"] = [
            statement
            for statement in missing_secret[2]["Statement"]
            if "secretsmanager:GetSecretValue" not in statement["Action"]
        ]
        self.check(missing_secret, False)

        # Missing SSM permission must fail.
        missing_ssm = copy.deepcopy(data)
        missing_ssm[2]["Statement"] = [
            statement
            for statement in missing_ssm[2]["Statement"]
            if "ssm:GetParameters" not in statement["Action"]
        ]
        self.check(missing_ssm, False)

        # Additional undeclared secret permissions must fail.
        excessive = copy.deepcopy(data)
        excessive[2]["Statement"][3]["Resource"].append(
            f"arn:aws:secretsmanager:us-east-1:{ACCOUNT}:secret:other-XyZaBc"
        )
        self.check(excessive, False)

        # Malformed sidecar references must fail closed.
        malformed = copy.deepcopy(data)
        malformed[1]["taskDefinition"]["containerDefinitions"][1]["secrets"][0]["valueFrom"] = (
            "not-a-valid-secret-arn"
        )
        self.check(malformed, False)

    def test_primary_and_sidecar_shared_secrets(self):
        data = fixture(optional=True, guardduty=False)

        data[1]["taskDefinition"]["containerDefinitions"].append({
            "name": "scanner",
            "image": URL + "@sha256:" + "b" * 64,
            "secrets": [
                {
                    "name": "SHARED_TOKEN",
                    "valueFrom": SECRET + ":token::",
                },
                {
                    "name": "SHARED_PARAMETER",
                    "valueFrom": PARAMETER,
                },
            ],
        })

        # Existing primary-container permissions also cover the sidecar.
        # No duplicate IAM resource entries should be required.
        self.check(data, True)

if __name__ == "__main__":
    unittest.main(verbosity=2)
