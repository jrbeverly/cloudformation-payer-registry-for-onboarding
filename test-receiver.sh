#!/bin/sh
# Offline check for the receiver's acceptance criteria, without real AWS:
# a fake aws CLI in PATH maps the registration bucket onto a local directory,
# and the scripts run from a copied directory so their local records land in
# a temp dir.
#
#   1. A delivered event for a known request is recorded exactly once.
#   2. Replaying the sweep (and a copy of the event under another key) does
#      not create a second record.
#   3. Unknown request identifiers and missing required fields are rejected
#      observably without disturbing existing records.
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
cp "$DIR/generate-onboarding-stack.sh" "$DIR/receive-registration.sh" \
  "$DIR/registration-function.js" "$EXP/"

cat > "$TMP/bin/aws" <<'EOF'
#!/bin/sh
# Fake aws CLI: s3/s3api bucket operations read and write FAKE_S3_ROOT.
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

# Generator: records known requests locally and still emits a valid template.
"$EXP/generate-onboarding-stack.sh" req-1 111111111111 > "$TMP/template.json"
"$EXP/generate-onboarding-stack.sh" req-2 111111111111 > /dev/null
check test -f "$EXP/requests/req-1.json"
check test -f "$EXP/requests/req-2.json"
check sh -c 'jq -e . "$0" > /dev/null' "$TMP/template.json"

# Delivered events: req-1 complete, req-2 missing a field, unknown-id not
# recorded by the generator.
cat > "$BUCKET/registrations/req-1.json" <<'EOF'
{"requestId":"req-1","accountId":"222222222222","organizationId":"o-abc","bootstrapRoleArn":"arn:aws:iam::222222222222:role/onboarding-bootstrap","region":"us-east-1"}
EOF
cat > "$BUCKET/registrations/req-2.json" <<'EOF'
{"requestId":"req-2","accountId":"333333333333","organizationId":"o-def","bootstrapRoleArn":"arn:aws:iam::333333333333:role/onboarding-bootstrap"}
EOF
cat > "$BUCKET/registrations/unknown-id.json" <<'EOF'
{"requestId":"unknown-id","accountId":"444444444444","organizationId":"o-ghi","bootstrapRoleArn":"arn:aws:iam::444444444444:role/onboarding-bootstrap","region":"us-east-1"}
EOF

set +e
"$EXP/receive-registration.sh" 111111111111 > "$TMP/out1" 2> "$TMP/err1"
RC1=$?
set -e

check test "$RC1" -eq 1
check grep -q "RECORDED req-1" "$TMP/out1"
check test -f "$EXP/registrations/req-1.json"
check diff "$BUCKET/registrations/req-1.json" "$EXP/registrations/req-1.json"
check test ! -e "$EXP/registrations/req-2.json"
check test ! -e "$EXP/registrations/unknown-id.json"
check grep -q "REJECTED registrations/req-2.json: invalid or incomplete event" "$TMP/err1"
check grep -q "REJECTED registrations/unknown-id.json: unknown onboarding request" "$TMP/err1"

# Replay: sweep again, plus a copy of req-1's event under another key.
cp "$BUCKET/registrations/req-1.json" "$BUCKET/registrations/req-1-copy.json"
set +e
"$EXP/receive-registration.sh" 111111111111 > "$TMP/out2" 2> "$TMP/err2"
RC2=$?
set -e

check test "$RC2" -eq 1
check grep -q "ALREADY-RECORDED req-1" "$TMP/out2"
check grep -q "REJECTED registrations/req-1-copy.json: requestId does not match object key" "$TMP/err2"
check test "$(ls "$EXP/registrations" | wc -l | tr -d ' ')" = "1"
check diff "$BUCKET/registrations/req-1.json" "$EXP/registrations/req-1.json"

if [ "$FAILED" -eq 0 ]; then
  echo "PASS: registration receiver acceptance criteria"
else
  echo "FAIL: see checks above"
fi
[ "$FAILED" -eq 0 ]
