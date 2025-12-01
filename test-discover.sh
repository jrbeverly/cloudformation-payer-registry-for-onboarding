#!/bin/sh
# Offline check for the discovery step's acceptance criteria, without real
# AWS: a fake aws CLI in PATH serves sts and organizations, serving
# organizations data only to the session created by the fake sts
# assume-role, which accepts exactly the registration record's role ARN.
#
#   1. The report lists the organization identifier, the organizational
#      units (with nesting), and the member accounts of the fake
#      environment.
#   2. The organizations data is fetched through the assumed-role session:
#      the fake serves it only to that session, and the report's
#      organization identifier deliberately differs from the one recorded
#      in the registration.
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
mkdir -p "$EXP" "$TMP/bin"
cp "$DIR/discover-organization.sh" "$EXP/"

# The registration record is the only input the script reads. Its
# organizationId deliberately does not match the fake environment's, so a
# matching report proves the value was fetched, not copied.
mkdir -p "$EXP/registrations"
cat > "$EXP/registrations/req-1.json" <<'EOF'
{"requestId":"req-1","accountId":"222222222222","organizationId":"o-fake","bootstrapRoleArn":"arn:aws:iam::222222222222:role/onboarding-bootstrap","region":"us-east-1"}
EOF

cat > "$TMP/bin/aws" <<'EOF'
#!/bin/sh
# Fake aws CLI: sts and organizations only. Organizations data is served
# only to the session created by the fake sts assume-role.
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
  organizations)
    if [ "${AWS_ACCESS_KEY_ID:-}" != "ASIA-fake-access" ]; then
      echo "fake aws: organizations called without the assumed-role session" >&2
      exit 1
    fi
    sub=$1; shift
    case "$sub" in
      describe-organization)
        echo '{"Organization":{"Id":"o-discovered"}}'
        ;;
      list-roots)
        echo '{"Roots":[{"Id":"r-root"}]}'
        ;;
      list-children)
        parent=
        while [ $# -gt 0 ]; do
          case "$1" in
            --parent-id) parent=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        case "$parent" in
          r-root) echo '{"Children":[{"Id":"ou-prod"},{"Id":"ou-dev"}]}' ;;
          *) echo "fake aws: unexpected list-children parent $parent" >&2; exit 1 ;;
        esac
        ;;
      list-organizational-units-for-parent)
        parent=
        while [ $# -gt 0 ]; do
          case "$1" in
            --parent-id) parent=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        case "$parent" in
          r-root) echo '{"OrganizationalUnits":[{"Name":"Production","Id":"ou-prod"},{"Name":"Development","Id":"ou-dev"}]}' ;;
          ou-prod) echo '{"OrganizationalUnits":[{"Name":"Prod-Europe","Id":"ou-eu"}]}' ;;
          ou-eu|ou-dev) echo '{"OrganizationalUnits":[]}' ;;
          *) echo "fake aws: unexpected parent $parent" >&2; exit 1 ;;
        esac
        ;;
      list-accounts)
        echo '{"Accounts":[{"Id":"222222222222","Name":"Management"},{"Id":"333333333333","Name":"Prod-Workloads"}]}'
        ;;
      *) echo "fake aws: unknown organizations subcommand $sub" >&2; exit 1 ;;
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

"$EXP/discover-organization.sh" > "$TMP/out"

REPORT="$EXP/discovery/req-1.json"
check test -f "$REPORT"

cat > "$TMP/expected.json" <<'EOF'
{
  "organizationId": "o-discovered",
  "organizationalUnits": [
    {"name": "Production", "id": "ou-prod", "children": [{"name": "Prod-Europe", "id": "ou-eu", "children": []}]},
    {"name": "Development", "id": "ou-dev", "children": []}
  ],
  "accounts": [
    {"id": "222222222222", "name": "Management"},
    {"id": "333333333333", "name": "Prod-Workloads"}
  ]
}
EOF
check sh -c 'jq -e -n --slurpfile report "$0" --slurpfile expected "$1" "$report[0] == $expected[0]" > /dev/null' "$REPORT" "$TMP/expected.json"

check grep -q "DISCOVERED req-1" "$TMP/out"
check grep -Fq "assume-role $FAKE_ROLE_ARN onboarding-discovery" "$TMP/aws.log"
check sh -c '! AWS_ACCESS_KEY_ID=central-access AWS_SECRET_ACCESS_KEY=central-secret AWS_SESSION_TOKEN= aws organizations describe-organization > /dev/null 2>&1'

if [ "$FAILED" -eq 0 ]; then
  echo "PASS: organization discovery acceptance criteria"
else
  echo "FAIL: see checks above"
fi
[ "$FAILED" -eq 0 ]
