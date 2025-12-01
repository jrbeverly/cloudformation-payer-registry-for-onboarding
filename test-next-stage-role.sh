#!/bin/sh
# Offline check for the next-stage role step's acceptance criteria, without
# real AWS: a fake aws CLI in PATH serves sts and iam, serving iam only to the
# session created by the fake sts assume-role, which accepts exactly the
# registration record's role ARN.
#
#   1. The script creates the role with the documented identity — name
#      next-stage, path /onboarding/ — through the assumed-role session, and
#      the record lists the created role's ARN and the attached policy.
#   2. The trust policy's principal is the request record's central account
#      identifier, and the inline policy carries the documented action set.
#   3. A create that fails writes no record and makes the script exit
#      non-zero; re-running with the failure cleared creates the role.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
FAILED=0

check() {
  if "$@"; then
    echo "ok: $*"
  else
    echo "FAIL: $*"
    FAILED=1
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

EXP="$TMP/exp"
mkdir -p "$EXP" "$TMP/bin" "$TMP/iam"
cp "$DIR/create-next-stage-role.sh" "$EXP/"

# The registration record and its request record are the inputs the script
# reads; the trust policy's principal must come from the request record's
# central account identifier.
mkdir -p "$EXP/registrations" "$EXP/requests"
cat > "$EXP/registrations/req-1.json" <<'EOF'
{"requestId":"req-1","accountId":"222222222222","organizationId":"o-fake","bootstrapRoleArn":"arn:aws:iam::222222222222:role/onboarding-bootstrap","region":"us-east-1"}
EOF
cat > "$EXP/requests/req-1.json" <<'EOF'
{"requestId":"req-1","centralAccountId":"111111111111"}
EOF

cat > "$TMP/bin/aws" <<'EOF'
#!/bin/sh
# Fake aws CLI: sts and iam only. IAM is served only to the session created
# by the fake sts assume-role; the policy documents handed to iam are stored
# under FAKE_IAM_DIR for the checks. FAKE_FAIL_CREATE_ROLE fails create-role.
set -eu
cmd=$1; shift
case "$cmd" in
  sts)
    sub=$1; shift
    case "$sub" in
      assume-role)
        role_arn=; session=
        while [ $# -gt 0 ]; do
          case "$1" in
            --role-arn) role_arn=$2; shift 2 ;;
            --role-session-name) session=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ "$role_arn" != "$FAKE_ROLE_ARN" ]; then
          echo "fake aws: assume-role with unexpected role arn $role_arn" >&2
          exit 1
        fi
        echo "assume-role $role_arn $session" >> "$FAKE_LOG"
        cat <<'JSON'
{
  "Credentials": {
    "AccessKeyId": "ASIA-fake-access",
    "SecretAccessKey": "fake-secret",
    "SessionToken": "fake-session-token",
    "Expiration": "2030-01-01T00:00:00Z"
  }
}
JSON
        ;;
      *) echo "fake aws: unknown sts subcommand $sub" >&2; exit 1 ;;
    esac
    ;;
  iam)
    if [ "${AWS_ACCESS_KEY_ID:-}" != "ASIA-fake-access" ]; then
      echo "fake aws: iam called without the assumed-role session" >&2
      exit 1
    fi
    sub=$1; shift
    case "$sub" in
      create-role)
        if [ "${FAKE_FAIL_CREATE_ROLE:-}" = 1 ]; then
          echo "AccessDenied: iam:CreateRole is not authorized" >&2
          exit 254
        fi
        role_name=; path=; doc=
        while [ $# -gt 0 ]; do
          case "$1" in
            --role-name) role_name=$2; shift 2 ;;
            --path) path=$2; shift 2 ;;
            --assume-role-policy-document) doc=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        echo "create-role $role_name $path" >> "$FAKE_LOG"
        printf '%s' "$doc" > "$FAKE_IAM_DIR/create-role-trust.json"
        cat <<JSON
{"Role":{"RoleName":"$role_name","Arn":"arn:aws:iam::222222222222:role${path}${role_name}"}}
JSON
        ;;
      put-role-policy)
        role_name=; policy_name=; doc=
        while [ $# -gt 0 ]; do
          case "$1" in
            --role-name) role_name=$2; shift 2 ;;
            --policy-name) policy_name=$2; shift 2 ;;
            --policy-document) doc=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        echo "put-role-policy $role_name $policy_name" >> "$FAKE_LOG"
        printf '%s' "$doc" > "$FAKE_IAM_DIR/put-role-policy.json"
        ;;
      *) echo "fake aws: unknown iam subcommand $sub" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "fake aws: unknown command $cmd" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TMP/bin/aws"

export PATH="$TMP/bin:$PATH"
export FAKE_ROLE_ARN=$(jq -r .bootstrapRoleArn "$EXP/registrations/req-1.json")
export FAKE_LOG="$TMP/aws.log"
export FAKE_IAM_DIR="$TMP/iam"

# A create that fails: the record is failed, nothing is written, and the
# script exits non-zero.
export FAKE_FAIL_CREATE_ROLE=1
set +e
"$EXP/create-next-stage-role.sh" > "$TMP/out1" 2> "$TMP/err1"
RC1=$?
set -e
check test "$RC1" -eq 1
check grep -q "FAILED req-1" "$TMP/err1"
check test ! -e "$EXP/next-stage/req-1.json"

# Replay with the failure cleared: the role is created with the documented
# identity through the assumed-role session.
unset FAKE_FAIL_CREATE_ROLE
"$EXP/create-next-stage-role.sh" > "$TMP/out2"

RECORD="$EXP/next-stage/req-1.json"
check test -f "$RECORD"
check sh -c 'jq -e ".roleArn == \"arn:aws:iam::222222222222:role/onboarding/next-stage\"" "$0" > /dev/null' "$RECORD"
check sh -c 'jq -e ".policyName == \"OrganizationDiscovery\"" "$0" > /dev/null' "$RECORD"
check grep -q "CREATED req-1" "$TMP/out2"

check grep -Fq "assume-role $FAKE_ROLE_ARN onboarding-next-stage" "$TMP/aws.log"
check grep -Fq "create-role next-stage /onboarding/" "$TMP/aws.log"
check grep -Fq "put-role-policy next-stage OrganizationDiscovery" "$TMP/aws.log"
check sh -c 'jq -e ".Statement[0].Principal.AWS == \"arn:aws:iam::111111111111:root\"" "$0" > /dev/null' "$TMP/iam/create-role-trust.json"
check sh -c 'jq -e ".Statement[0].Action == [\"organizations:DescribeOrganization\",\"organizations:ListRoots\",\"organizations:ListChildren\",\"organizations:ListOrganizationalUnitsForParent\",\"organizations:ListAccounts\"] and .Statement[0].Resource == \"*\"" "$0" > /dev/null' "$TMP/iam/put-role-policy.json"
check sh -c '! AWS_ACCESS_KEY_ID=central-access AWS_SECRET_ACCESS_KEY=central-secret AWS_SESSION_TOKEN= aws iam create-role --role-name x --path /onboarding/ --assume-role-policy-document "{}" > /dev/null 2>&1'

if [ "$FAILED" -eq 0 ]; then
  echo "PASS: next-stage role acceptance criteria"
else
  echo "FAIL: see checks above"
fi
[ "$FAILED" -eq 0 ]
