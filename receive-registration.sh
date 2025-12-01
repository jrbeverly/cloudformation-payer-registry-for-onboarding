#!/bin/sh
# Usage: ./receive-registration.sh <central-account-id>
# Sweeps the registration bucket for delivered events, verifies each against
# the generator's local request records, and writes accepted registrations to
# registrations/ for the discovery step. A replayed event never creates a
# second record; rejected events leave existing records untouched.
set -eu

CENTRAL_ACCOUNT_ID=$1
BUCKET="onboarding-registration-$CENTRAL_ACCOUNT_ID"
DIR=$(dirname "$0")
REQUESTS_DIR="$DIR/requests"
REGISTRATIONS_DIR="$DIR/registrations"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

KEYS=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix registrations/ \
  | jq -r '.Contents[]?.Key // empty' | grep '\.json$' || true)

if [ -z "$KEYS" ]; then
  echo "no events in s3://$BUCKET/registrations/"
  exit 0
fi

FAILED=0
for KEY in $KEYS; do
  REQUEST_ID=$(basename "$KEY" .json)
  aws s3api get-object --bucket "$BUCKET" --key "$KEY" "$TMP" >/dev/null

  if ! jq -e '[.requestId, .accountId, .organizationId, .bootstrapRoleArn, .region]
      | all(type == "string" and length > 0)' "$TMP" >/dev/null; then
    echo "REJECTED $KEY: invalid or incomplete event" >&2
    FAILED=1
    continue
  fi
  if [ "$(jq -r .requestId "$TMP")" != "$REQUEST_ID" ]; then
    echo "REJECTED $KEY: requestId does not match object key" >&2
    FAILED=1
    continue
  fi
  if [ ! -f "$REQUESTS_DIR/$REQUEST_ID.json" ]; then
    echo "REJECTED $KEY: unknown onboarding request $REQUEST_ID" >&2
    FAILED=1
    continue
  fi

  RECORD="$REGISTRATIONS_DIR/$REQUEST_ID.json"
  if [ -f "$RECORD" ]; then
    echo "ALREADY-RECORDED $REQUEST_ID"
  else
    mkdir -p "$REGISTRATIONS_DIR"
    cp "$TMP" "$RECORD"
    echo "RECORDED $REQUEST_ID"
  fi
done

[ "$FAILED" -eq 0 ]
