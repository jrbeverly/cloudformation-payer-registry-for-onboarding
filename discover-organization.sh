#!/bin/sh
# Usage: ./discover-organization.sh
# Assumes the bootstrap role recorded in each accepted registration and walks
# the organization through the assumed-role session, writing one discovery
# report per registration to discovery/. A registration whose walk fails is
# reported and skipped; the remaining registrations still run, and the script
# exits non-zero if any failed.
set -eu

DIR=$(dirname "$0")
REGISTRATIONS_DIR="$DIR/registrations"
DISCOVERY_DIR="$DIR/discovery"

if ! ls "$REGISTRATIONS_DIR"/*.json >/dev/null 2>&1; then
  echo "no registrations in $REGISTRATIONS_DIR"
  exit 0
fi
mkdir -p "$DISCOVERY_DIR"

# Organizations is a global API served from us-east-1, whatever region the
# stack was deployed into.
ORG_REGION="us-east-1"

# JSON array of the OU subtrees ({name,id,children}) directly under $1.
ou_subtrees() {
  PARENT=$1
  LISTING=$(aws organizations list-organizational-units-for-parent \
    --parent-id "$PARENT" --region "$ORG_REGION" --output json) || return 1
  RESULT='['
  FIRST=1
  while read -r OU; do
    [ -n "$OU" ] || continue
    NAME=$(printf '%s\n' "$OU" | jq -r '.[0]')
    ID=$(printf '%s\n' "$OU" | jq -r '.[1]')
    [ "$FIRST" = 0 ] && RESULT="$RESULT,"
    FIRST=0
    CHILDREN=$(ou_subtrees "$ID") || return 1
    RESULT="$RESULT$(jq -n -c --arg name "$NAME" --arg id "$ID" \
      --argjson children "$CHILDREN" \
      '{name: $name, id: $id, children: $children}')"
  done <<EOF
$(printf '%s\n' "$LISTING" | jq -c '.OrganizationalUnits[] | [.Name, .Id]')
EOF
  echo "$RESULT]"
}

# JSON array of the OU subtrees under the root: the ids come from ListChildren
# (the tree walk's entry point) and the names from
# ListOrganizationalUnitsForParent.
root_ous() {
  ROOT_ID=$1
  CHILDREN_JSON=$(aws organizations list-children --parent-id "$ROOT_ID" \
    --child-type ORGANIZATIONAL_UNIT --region "$ORG_REGION" --output json) \
    || return 1
  PAIRS_JSON=$(aws organizations list-organizational-units-for-parent \
    --parent-id "$ROOT_ID" --region "$ORG_REGION" --output json) || return 1
  IDS=$(printf '%s\n' "$CHILDREN_JSON" | jq -r '.Children[]?.Id')
  RESULT='['
  FIRST=1
  for ID in $IDS; do
    NAME=$(printf '%s\n' "$PAIRS_JSON" | jq -r --arg id "$ID" \
      '.OrganizationalUnits[] | select(.Id == $id) | .Name')
    [ "$FIRST" = 0 ] && RESULT="$RESULT,"
    FIRST=0
    CHILDREN=$(ou_subtrees "$ID") || return 1
    RESULT="$RESULT$(jq -n -c --arg name "$NAME" --arg id "$ID" \
      --argjson children "$CHILDREN" \
      '{name: $name, id: $id, children: $children}')"
  done
  echo "$RESULT]"
}

# Walk one registration through the assumed role. Called in a context where
# set -e is off, so every aws call's failure is caught and fails the record
# instead of silently producing an incomplete report.
discover_record() {
  RECORD=$1
  REQUEST_ID=$(basename "$RECORD" .json)
  ROLE_ARN=$(jq -r .bootstrapRoleArn "$RECORD")

  CREDS=$(aws sts assume-role --role-arn "$ROLE_ARN" \
    --role-session-name onboarding-discovery --output json) || return 1
  export AWS_ACCESS_KEY_ID=$(printf '%s\n' "$CREDS" | jq -r .Credentials.AccessKeyId)
  export AWS_SECRET_ACCESS_KEY=$(printf '%s\n' "$CREDS" | jq -r .Credentials.SecretAccessKey)
  export AWS_SESSION_TOKEN=$(printf '%s\n' "$CREDS" | jq -r .Credentials.SessionToken)

  ORG_JSON=$(aws organizations describe-organization --region "$ORG_REGION" \
    --output json) || return 1
  ORG_ID=$(printf '%s\n' "$ORG_JSON" | jq -r .Organization.Id)
  ROOTS_JSON=$(aws organizations list-roots --region "$ORG_REGION" \
    --output json) || return 1
  ROOT_ID=$(printf '%s\n' "$ROOTS_JSON" | jq -r '.Roots[0].Id')
  OUS=$(root_ous "$ROOT_ID") || return 1
  ACCOUNTS_JSON=$(aws organizations list-accounts --region "$ORG_REGION" \
    --output json) || return 1
  ACCOUNTS=$(printf '%s\n' "$ACCOUNTS_JSON" \
    | jq -c '.Accounts | map({id: .Id, name: .Name})')

  jq -n \
    --arg organizationId "$ORG_ID" \
    --argjson organizationalUnits "$OUS" \
    --argjson accounts "$ACCOUNTS" \
    '{organizationId: $organizationId,
      organizationalUnits: $organizationalUnits,
      accounts: $accounts}' > "$DISCOVERY_DIR/$REQUEST_ID.json"
  echo "DISCOVERED $REQUEST_ID -> discovery/$REQUEST_ID.json"
}

FAILED=0
for RECORD in "$REGISTRATIONS_DIR"/*.json; do
  [ -e "$RECORD" ] || continue
  if ! discover_record "$RECORD"; then
    echo "FAILED $(basename "$RECORD" .json)" >&2
    FAILED=1
  fi
  # Drop the assumed credentials so the next record assumes with central ones.
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done

[ "$FAILED" -eq 0 ]
