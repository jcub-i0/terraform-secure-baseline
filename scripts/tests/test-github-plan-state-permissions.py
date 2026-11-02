#!/usr/bin/env python3
"""Fast, offline guard for the GitHub Plan role's S3 state/lock policy.

Checks the actual module's HCL policy source (not deployed/effective IAM).
Live policy evaluation and S3 behavior are separate M1 qualification gates.
"""

import re
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2] / "modules/github_oidc/main.tf"
START = 'data "aws_iam_policy_document" "github_plan" {'
END = 'resource "aws_iam_policy" "github_plan" {'
EXPECTED = {
    "TerraformStateBucketList": (
        {"s3:ListBucket"}, {"var.tf_state_bucket_arn"}
    ),
    "TerraformStateObjectAccess": (
        {"s3:GetObject"}, {'"${var.tf_state_bucket_arn}/*"'}
    ),
    "TerraformStateLockfileAccess": (
        {"s3:GetObject", "s3:PutObject", "s3:DeleteObject"},
        {'"${var.tf_state_bucket_arn}/*.tflock"'},
    ),
}
BLOCK = re.compile(r"(?ms)^  statement \{\n(.*?)^  \}")
TOKEN = re.compile(r'"[^"\n]+"|var\.tf_state_bucket_arn')


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def field(body, name):
    match = re.search(rf"(?m)^    {name}\s*=\s*\[([^]]*)\]", body)
    require(match is not None, f"missing or non-literal {name} field")
    raw = match.group(1)
    values = TOKEN.findall(raw)
    residue = TOKEN.sub("", raw)
    require(not residue.strip(" \t\r\n,"), f"non-literal {name} field")
    require(len(values) == len(set(values)), f"duplicate {name} entries")
    return {value.strip('"') if name == "actions" else value for value in values}


def verify(source):
    require(source.count(START) == 1 and source.count(END) == 1,
            "GitHub Plan policy source not uniquely identifiable")
    policy = source.split(START, 1)[1].split(END, 1)[0]
    matches = list(BLOCK.finditer(policy))
    require(matches, "no direct Plan policy statements")
    checked = set()

    for match in matches:
        body = match.group(1)
        sid = re.search(r'(?m)^    sid\s*=\s*"([^"]+)"\s*$', body)
        require(sid is not None, "Plan statement is missing a literal Sid")
        name = sid.group(1)
        require(name not in checked, f"duplicate Plan policy statement: {name}")
        checked.add(name)
        actions = field(body, "actions")
        resources = field(body, "resources")

        if name in EXPECTED:
            expected_actions, expected_resources = EXPECTED[name]
            require(re.search(r'(?m)^    effect\s*=\s*"Allow"\s*$', body),
                    f"{name}: expected Allow")
            require(actions == expected_actions and resources == expected_resources,
                    f"{name}: unexpected S3 permissions or resource scope")
        else:
            require(not any(a == "*" or a.lower().startswith("s3:") for a in actions),
                    f"unexpected S3 grant in Plan statement: {name}")

    require(EXPECTED.keys() <= checked, "missing a required state/lock statement")
    # Also reject S3 authority hidden inside dynamically generated statements.
    remaining = BLOCK.sub("", policy)
    require(not re.search(r'(?im)s3:|^\s*(?:not_actions|not_resources)\s*=|^\s*actions\s*=\s*\[\s*\"\*\"', remaining),
            "unexpected S3/dynamic or NotAction/NotResource authority")
    require('policy = data.aws_iam_policy_document.github_plan.json' in source,
            "Plan IAM policy no longer consumes the checked document")


if __name__ == "__main__":
    try:
        verify(MODULE.read_text())
    except (OSError, ValueError) as error:
        print(f"[FAIL] GitHub Plan state permissions: {error}", file=sys.stderr)
        sys.exit(1)
    print("[PASS] GitHub Plan state read / lockfile-only write contract (offline)")
