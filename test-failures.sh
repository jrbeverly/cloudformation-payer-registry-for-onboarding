#!/bin/sh
# Offline exercise of the VISION's failure scenarios, without real AWS: a fake
# aws CLI in PATH maps the registration bucket onto a local directory and
# serves sts/organizations with failure switches, a local HTTPS server stands
# in for the registration endpoint, and the scripts run from a copied
# directory so their local records land in a temp dir.
#
#   1. CloudFormation succeeds but registration fails: the Lambda makes one
#      PUT (no retry) and a failed PUT is signalled FAILED, rolling the stack
#      back; an event that fails central verification is rejected and the
#      recovery (regenerate + receive) records it without touching the stack.
#   2. Registration succeeds but the central system cannot assume the role:
#      the record is failed and the remaining registrations still run.
#   3. The registration event is delivered more than once: re-delivery under
#      the same key records once.
#   4. The central onboarding process fails partway through: a failed walk
#      fails the record observably instead of writing a silently incomplete
#      report, and a fixed environment discovers on re-run.
#   5. The stack is deployed again: the same event re-PUT to the same key is
#      already-recorded; an overridden request identifier is rejected.
#   6. Onboarding is restarted: regenerate, receive, and discover from empty
#      central state is sufficient.
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
trap 'kill "${SRV:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT

EXP="$TMP/exp"
mkdir -p "$EXP" "$TMP/bin" "$TMP/lambda"
cp "$DIR/generate-onboarding-stack.sh" "$DIR/receive-registration.sh" \
  "$DIR/discover-organization.sh" "$DIR/registration-function.js" "$EXP/"

cat > "$TMP/bin/aws" <<'EOF'
#!/bin/sh
# Fake aws CLI: s3/s3api bucket operations read and write FAKE_S3_ROOT; sts
# and organizations serve the discovery step. Failure switches:
# FAKE_BROKEN_ROLE_ARN (sts), FAKE_FAIL_ORG_SUB and FAKE_FAIL_OU_PARENT
# (organizations).
set -eu
ROOT=${FAKE_S3_ROOT:?}
cmd=$1; shift
case "$cmd" in
  s3)
    sub=$1
    case "$sub" in
      presign)
        # args: s3://bucket/key --expires-in N
        echo "https://fake.invalid/$1"
        ;;
      *)
        echo "fake aws: unknown s3 subcommand $sub" >&2
        exit 1
        ;;
    esac
    ;;
  s3api)
    sub=$1; shift
    case "$sub" in
      list-objects-v2)
        bucket=; prefix=
        while [ $# -gt 0 ]; do
          case "$1" in
            --bucket) bucket=$2; shift 2 ;;
            --prefix) prefix=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        dir="$ROOT/$bucket/$prefix"
        echo '{"Contents":['
        first=1
        for f in "$dir"/*.json; do
          [ -e "$f" ] || continue
          if [ "$first" = 0 ]; then echo ','; fi
          first=0
          printf '{"Key":"%s"}' "$prefix$(basename "$f")"
        done
        echo ']}'
        ;;
      get-object)
        bucket=; key=
        while [ $# -gt 1 ]; do
          case "$1" in
            --bucket) bucket=$2; shift 2 ;;
            --key) key=$2; shift 2 ;;
            *) shift ;;
          esac
        done
        cp "$ROOT/$bucket/$key" "$1"
        ;;
      *)
        echo "fake aws: unknown s3api subcommand $sub" >&2
        exit 1
        ;;
    esac
    ;;
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
        if [ "${FAKE_BROKEN_ROLE_ARN:-}" != "" ] \
          && [ "$role_arn" = "$FAKE_BROKEN_ROLE_ARN" ]; then
          echo "AccessDenied: role cannot be assumed" >&2
          exit 255
        fi
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
    if [ "${FAKE_FAIL_ORG_SUB:-}" = "$sub" ]; then
      echo "AccessDeniedException: not authorized for $sub" >&2
      exit 254
    fi
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
          *) echo '{"Children":[]}' ;;
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
        if [ "${FAKE_FAIL_OU_PARENT:-}" != "" ] \
          && [ "$parent" = "$FAKE_FAIL_OU_PARENT" ]; then
          echo "AccessDeniedException: not authorized for parent $parent" >&2
          exit 254
        fi
        case "$parent" in
          r-root) echo '{"OrganizationalUnits":[{"Name":"Production","Id":"ou-prod"},{"Name":"Development","Id":"ou-dev"}]}' ;;
          ou-prod) echo '{"OrganizationalUnits":[{"Name":"Prod-Europe","Id":"ou-eu"}]}' ;;
          ou-eu|ou-dev) echo '{"OrganizationalUnits":[]}' ;;
          *) echo '{"OrganizationalUnits":[]}' ;;
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
export FAKE_S3_ROOT="$TMP/s3"
BUCKET="$FAKE_S3_ROOT/onboarding-registration-111111111111"
mkdir -p "$BUCKET/registrations"

EVENT_BROKEN='{"requestId":"req-broken","accountId":"222222222222","organizationId":"o-abc","bootstrapRoleArn":"arn:aws:iam::222222222222:role/broken-role","region":"us-east-1"}'
EVENT_HEALTHY='{"requestId":"req-healthy","accountId":"333333333333","organizationId":"o-def","bootstrapRoleArn":"arn:aws:iam::333333333333:role/onboarding-bootstrap","region":"us-east-1"}'
EVENT_1='{"requestId":"req-1","accountId":"222222222222","organizationId":"o-abc","bootstrapRoleArn":"arn:aws:iam::222222222222:role/onboarding-bootstrap","region":"us-east-1"}'
EVENT_9='{"requestId":"req-9","accountId":"444444444444","organizationId":"o-ghi","bootstrapRoleArn":"arn:aws:iam::444444444444:role/onboarding-bootstrap","region":"us-east-1"}'
EVENT_OVERRIDE='{"requestId":"req-2","accountId":"222222222222","organizationId":"o-abc","bootstrapRoleArn":"arn:aws:iam::222222222222:role/onboarding-bootstrap","region":"us-east-1"}'

# Scenario 1, deploy boundary: the Lambda PUTs once and signals FAILED on a
# failed PUT; the second run (the redeploy) succeeds. A local HTTPS server
# stands in for the presigned endpoint; the orgs SDK is stubbed.
mkdir -p "$TMP/lambda/node_modules/@aws-sdk/client-organizations"
cat > "$TMP/lambda/node_modules/@aws-sdk/client-organizations/package.json" <<'EOF'
{"name":"@aws-sdk/client-organizations","version":"0.0.0-stub","main":"index.js"}
EOF
cat > "$TMP/lambda/node_modules/@aws-sdk/client-organizations/index.js" <<'EOF'
class OrganizationsClient {
  send() { return Promise.resolve({ Organization: { Id: "o-stub" } }); }
}
class DescribeOrganizationCommand {}
module.exports = { OrganizationsClient, DescribeOrganizationCommand };
EOF
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/lambda/key.pem" -out "$TMP/lambda/cert.pem" \
  -days 1 -subj "/CN=localhost" > /dev/null 2>&1
cat > "$TMP/lambda/server.js" <<'EOF'
// args: key.pem cert.pem request-log port-file
const https = require("https");
const fs = require("fs");
const server = https.createServer({
  key: fs.readFileSync(process.argv[2]),
  cert: fs.readFileSync(process.argv[3]),
}, (req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    fs.appendFileSync(process.argv[4], `${req.method} ${req.url} -> ${body}\n`);
    if (req.url.startsWith("/fail")) { res.writeHead(500); res.end(); }
    else { res.writeHead(200); res.end(); }
  });
});
server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(process.argv[5], String(server.address().port));
});
EOF
cat > "$TMP/lambda/drive.js" <<'EOF'
// args: registration-function.js port endpoint-path request-log
const fs = require("fs");
const handler = require(process.argv[2]).handler;
const port = process.argv[3];
const endpoint = process.argv[4];
const event = {
  RequestType: "Create",
  RequestId: "req-1",
  StackId: "arn:aws:cloudformation:us-east-1:222222222222:stack/onboarding-bootstrap",
  LogicalResourceId: "Registration",
  PhysicalResourceId: "Registration",
  ResponseURL: `https://localhost:${port}/cfn-response`,
  ResourceProperties: {
    Endpoint: `https://localhost:${port}${endpoint}`,
    RequestId: "req-1",
    AccountId: "222222222222",
    BootstrapRoleArn: "arn:aws:iam::222222222222:role/onboarding-bootstrap",
    Region: "us-east-1",
  },
};
handler(event).then(() => {
  const tries = fs.readFileSync(process.argv[5], "utf8")
    .split("\n").filter((l) => l.includes(endpoint)).length;
  console.log(`endpoint PUTs: ${tries}`);
});
EOF

REQLOG="$TMP/lambda/req.log"
run_lambda() {
  ENDPOINT=$1
  rm -f "$REQLOG" "$TMP/lambda/port"
  node "$TMP/lambda/server.js" "$TMP/lambda/key.pem" "$TMP/lambda/cert.pem" \
    "$REQLOG" "$TMP/lambda/port" &
  SRV=$!
  I=0
  while [ ! -f "$TMP/lambda/port" ]; do
    I=$((I + 1))
    [ "$I" -gt 100 ] && { echo "lambda server did not start" >&2; exit 1; }
    sleep 0.1
  done
  PORT=$(cat "$TMP/lambda/port")
  NODE_TLS_REJECT_UNAUTHORIZED=0 NODE_PATH="$TMP/lambda/node_modules" \
    node "$TMP/lambda/drive.js" "$EXP/registration-function.js" "$PORT" \
    "$ENDPOINT" "$REQLOG" > "$TMP/lambda/out"
  kill "$SRV"; wait "$SRV" 2>/dev/null || true
  SRV=
}

run_lambda /fail
check grep -q '^endpoint PUTs: 1$' "$TMP/lambda/out"
check grep -q '"Status":"FAILED"' "$REQLOG"
run_lambda /ok
check grep -q '"Status":"SUCCESS"' "$REQLOG"

# Scenario 1, central side: the event for req-9 lands but the request is
# unknown centrally, so the receiver rejects it and leaves the known record
# untouched. Recovery: regenerate for req-9 and receive again.
"$EXP/generate-onboarding-stack.sh" req-1 111111111111 > /dev/null
printf '%s' "$EVENT_1" > "$BUCKET/registrations/req-1.json"
printf '%s' "$EVENT_9" > "$BUCKET/registrations/req-9.json"
set +e
"$EXP/receive-registration.sh" 111111111111 > "$TMP/rec1.out" 2> "$TMP/rec1.err"
RC1=$?
set -e
check test "$RC1" -eq 1
check grep -q "RECORDED req-1" "$TMP/rec1.out"
check grep -q "REJECTED registrations/req-9.json: unknown onboarding request req-9" "$TMP/rec1.err"
check test -f "$EXP/registrations/req-1.json"
check test ! -e "$EXP/registrations/req-9.json"

"$EXP/generate-onboarding-stack.sh" req-9 111111111111 > /dev/null
set +e
"$EXP/receive-registration.sh" 111111111111 > "$TMP/rec2.out" 2> "$TMP/rec2.err"
RC2=$?
set -e
check test "$RC2" -eq 0
check grep -q "RECORDED req-9" "$TMP/rec2.out"
check test -f "$EXP/registrations/req-9.json"

# Scenario 3: the same event delivered again under its own key records once.
printf '%s' "$EVENT_1" > "$BUCKET/registrations/req-1.json"
set +e
"$EXP/receive-registration.sh" 111111111111 > "$TMP/rec3.out" 2> "$TMP/rec3.err"
RC3=$?
set -e
check test "$RC3" -eq 0
check grep -q "ALREADY-RECORDED req-1" "$TMP/rec3.out"
check test "$(ls "$EXP/registrations" | wc -l | tr -d ' ')" = "2"

# Scenario 5: redeploying re-PUTs the same event (already recorded), and an
# override of the request identifier at deploy time is rejected because the
# presigned URL fixes the object key.
printf '%s' "$EVENT_1" > "$BUCKET/registrations/req-1.json"
printf '%s' "$EVENT_OVERRIDE" > "$BUCKET/registrations/req-1.json"
set +e
"$EXP/receive-registration.sh" 111111111111 > "$TMP/rec5.out" 2> "$TMP/rec5.err"
RC5=$?
set -e
check test "$RC5" -eq 1
check grep -q "REJECTED registrations/req-1.json: requestId does not match object key" "$TMP/rec5.err"
check test "$(ls "$EXP/registrations" | wc -l | tr -d ' ')" = "2"
check test "$(jq -r .requestId "$EXP/registrations/req-1.json")" = "req-1"

# The override is corrected by redeploying with the original request
# identifier, which re-PUTs the right event.
printf '%s' "$EVENT_1" > "$BUCKET/registrations/req-1.json"

# Scenario 2: req-broken's role cannot be assumed. Its record is failed, the
# healthy registrations still run, and the script exits non-zero.
"$EXP/generate-onboarding-stack.sh" req-broken 111111111111 > /dev/null
"$EXP/generate-onboarding-stack.sh" req-healthy 111111111111 > /dev/null
printf '%s' "$EVENT_BROKEN" > "$BUCKET/registrations/req-broken.json"
printf '%s' "$EVENT_HEALTHY" > "$BUCKET/registrations/req-healthy.json"
set +e
"$EXP/receive-registration.sh" 111111111111 > "$TMP/rec6.out" 2> "$TMP/rec6.err"
RC6=$?
set -e
check test "$RC6" -eq 0
check grep -q "RECORDED req-broken" "$TMP/rec6.out"
check grep -q "RECORDED req-healthy" "$TMP/rec6.out"

export FAKE_BROKEN_ROLE_ARN=$(printf '%s' "$EVENT_BROKEN" | jq -r .bootstrapRoleArn)
set +e
"$EXP/discover-organization.sh" > "$TMP/disc2.out" 2> "$TMP/disc2.err"
RCD2=$?
set -e
check test "$RCD2" -eq 1
check grep -q "DISCOVERED req-healthy" "$TMP/disc2.out"
check grep -q "FAILED req-broken" "$TMP/disc2.err"
check test -f "$EXP/discovery/req-healthy.json"
check test ! -e "$EXP/discovery/req-broken.json"

# Scenario 4: ListAccounts fails partway through every walk. Each record is
# failed observably, no report is written, and the script exits non-zero.
rm -rf "$EXP/discovery"
export FAKE_FAIL_ORG_SUB=list-accounts
set +e
"$EXP/discover-organization.sh" > "$TMP/disc4.out" 2> "$TMP/disc4.err"
RCD4=$?
set -e
check test "$RCD4" -eq 1
check grep -q "FAILED req-healthy" "$TMP/disc4.err"
check test ! -e "$EXP/discovery/req-healthy.json"

# Scenario 4, nested walk: a listing denied deep in the OU tree fails the
# record instead of writing a silently incomplete report.
unset FAKE_FAIL_ORG_SUB
export FAKE_FAIL_OU_PARENT=ou-prod
set +e
"$EXP/discover-organization.sh" > "$TMP/disc4b.out" 2> "$TMP/disc4b.err"
RCD4B=$?
set -e
check test "$RCD4B" -eq 1
check grep -q "FAILED req-healthy" "$TMP/disc4b.err"
check test ! -e "$EXP/discovery/req-healthy.json"

# Scenario 4 recovery and scenario 2 recovery: with the environment fixed
# (failures unset), the same run discovers everything; nothing was left
# behind by the failed runs.
unset FAKE_FAIL_OU_PARENT FAKE_BROKEN_ROLE_ARN
set +e
"$EXP/discover-organization.sh" > "$TMP/disc4c.out" 2> "$TMP/disc4c.err"
RCD4C=$?
set -e
check test "$RCD4C" -eq 0
check grep -q "DISCOVERED req-broken" "$TMP/disc4c.out"
check test -f "$EXP/discovery/req-broken.json"
check test -f "$EXP/discovery/req-healthy.json"

# Scenario 6: onboarding restarted from empty central state. The delivered
# events persist in the bucket, so regenerate + receive + discover restores
# the records and reports; only req-1 is regenerated here, so the remaining
# events are rejected as unknown.
rm -rf "$EXP/requests" "$EXP/registrations" "$EXP/discovery"
"$EXP/generate-onboarding-stack.sh" req-1 111111111111 > /dev/null
set +e
"$EXP/receive-registration.sh" 111111111111 > "$TMP/rec7.out" 2> "$TMP/rec7.err"
RC7=$?
set -e
check test "$RC7" -eq 1
check grep -q "RECORDED req-1" "$TMP/rec7.out"
check test -f "$EXP/registrations/req-1.json"

set +e
"$EXP/discover-organization.sh" > "$TMP/disc6.out" 2> "$TMP/disc6.err"
RCD6=$?
set -e
check test "$RCD6" -eq 0
check grep -q "DISCOVERED req-1" "$TMP/disc6.out"
check test -f "$EXP/discovery/req-1.json"

if [ "$FAILED" -eq 0 ]; then
  echo "PASS: failure scenario exercise"
else
  echo "FAIL: see checks above"
fi
[ "$FAILED" -eq 0 ]
