#!/bin/sh
# Usage: ./create-next-stage-role.sh
# Assumes the bootstrap role recorded in each accepted registration and creates
# the next-stage placeholder role through the assumed-role session, writing one
# record per registration to next-stage/. A registration whose creation fails
# is reported and skipped; the remaining registrations still run, and the
# script exits non-zero if any failed.
set -eu

DIR=$(dirname "$0")
REGISTRATIONS_DIR="$DIR/registrations"
REQUESTS_DIR="$DIR/requests"
NEXT_STAGE_DIR="$DIR/next-stage"

# Hard-coded identity of the placeholder, per PLAN.md; not configurable.
ROLE_NAME="next-stage"
ROLE_PATH="/onboarding/"
POLICY_NAME="OrganizationDiscovery"

if ! ls "$REGISTRATIONS_DIR"/*.json >/dev/null 2>&1; then
  echo "no registrations in $REGISTRATIONS_DIR"
  exit 0
fi
mkdir -p "$NEXT_STAGE_DIR"

# Create the placeholder role for one registration through the assumed
# bootstrap session. Called in a context where set -e is off, so every aws
# call's failure is caught and fails the record.
create_record() {
  RECORD=$1
  REQUEST_ID=$(basename "$RECORD" .json)
  ROLE_ARN=$(jq -r .bootstrapRoleArn "$RECORD")
  CENTRAL_ACCOUNT_ID=$(jq -r .centralAccountId \
    "$REQUESTS_DIR/$REQUEST_ID.json") || return 1

  # The placeholder stands in for the permanent management roles: trustable
  # from the central account, carrying the set a future discovery role would
  # hold (see PLAN.md).
  TRUST_POLICY=$(jq -n -c \
    --arg principal "arn:aws:iam::$CENTRAL_ACCOUNT_ID:root" \
    '{Version: "2012-10-17",
      Statement: [{Effect: "Allow",
                   Principal: {AWS: $principal},
                   Action: "sts:AssumeRole"}]}') || return 1
  INLINE_POLICY=$(jq -n -c \
    '{Version: "2012-10-17",
      Statement: [{Effect: "Allow",
                   Action: ["organizations:DescribeOrganization",
                            "organizations:ListRoots",
                            "organizations:ListChildren",
                            "organizations:ListOrganizationalUnitsForParent",
                            "organizations:ListAccounts"],
                   Resource: "*"}]}') || return 1

  CREDS=$(aws sts assume-role --role-arn "$ROLE_ARN" \
    --role-session-name onboarding-next-stage --output json) || return 1
  export AWS_ACCESS_KEY_ID=$(printf '%s\n' "$CREDS" | jq -r .Credentials.AccessKeyId)
  export AWS_SECRET_ACCESS_KEY=$(printf '%s\n' "$CREDS" | jq -r .Credentials.SecretAccessKey)
  export AWS_SESSION_TOKEN=$(printf '%s\n' "$CREDS" | jq -r .Credentials.SessionToken)

  CREATED=$(aws iam create-role --role-name "$ROLE_NAME" --path "$ROLE_PATH" \
    --assume-role-policy-document "$TRUST_POLICY" --output json) || return 1
  aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" \
    --policy-document "$INLINE_POLICY" || return 1
  CREATED_ARN=$(printf '%s\n' "$CREATED" | jq -r .Role.Arn) || return 1

  jq -n \
    --arg roleArn "$CREATED_ARN" \
    --arg policyName "$POLICY_NAME" \
    '{roleArn: $roleArn, policyName: $policyName}' \
    > "$NEXT_STAGE_DIR/$REQUEST_ID.json"
  echo "CREATED $REQUEST_ID -> next-stage/$REQUEST_ID.json"
}

FAILED=0
for RECORD in "$REGISTRATIONS_DIR"/*.json; do
  [ -e "$RECORD" ] || continue
  if ! create_record "$RECORD"; then
    echo "FAILED $(basename "$RECORD" .json)" >&2
    FAILED=1
  fi
  # Drop the assumed credentials so the next record assumes with central ones.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done

[ "$FAILED" -eq 0 ]
