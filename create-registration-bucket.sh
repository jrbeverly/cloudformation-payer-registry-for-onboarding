#!/bin/sh
# Usage: ./create-registration-bucket.sh <central-account-id>
set -eu
aws s3 mb "s3://onboarding-registration-$1"
