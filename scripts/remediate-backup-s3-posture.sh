#!/usr/bin/env bash
# Applies the remediation for the four checks check-backup-s3-posture.sh
# inspects (SSE-S3 default, TLS-only deny policy, public-access-block,
# versioning).  Idempotent — safe to re-run.  Uses the same AWS creds as
# the Velero IAM user (or admin).
#
# Run order: this BEFORE flipping any new traffic on; no data is rewritten.
set -euo pipefail

BUCKETS=("155125294186-homelab-k8s-backups" "giddyland-money-pg-backups")

fix_bucket() {
  local b="$1"
  echo "=== $b ==="

  # 1) Default SSE-S3 — encrypts every future PUT at rest. BucketKey reduces
  #    KMS GetKey cost (irrelevant for SSE-S3 but harmless to set).
  echo "  [1/4] enabling default SSE-S3..."
  aws s3api put-bucket-encryption --bucket "$b" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

  # 2) TLS-only bucket policy. Merges nothing — replaces any prior policy.
  #    Velero + barman already use TLS so this breaks nothing.
  echo "  [2/4] applying TLS-only bucket policy..."
  cat > /tmp/tls-only-${b}.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::${b}", "arn:aws:s3:::${b}/*"],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
}
EOF
  aws s3api put-bucket-policy --bucket "$b" --policy "file:///tmp/tls-only-${b}.json"
  rm -f "/tmp/tls-only-${b}.json"

  # 3) Public-access-block (already on per the check, but assert it).
  echo "  [3/4] asserting public-access-block..."
  aws s3api put-public-access-block --bucket "$b" --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

  # 4) Versioning. One-way enable; you can later Suspend but not delete. With
  #    versioning on, accidental/malicious DELETE creates a delete-marker and
  #    the object stays recoverable.
  echo "  [4/4] enabling versioning..."
  aws s3api put-bucket-versioning --bucket "$b" \
    --versioning-configuration Status=Enabled

  echo "  done."
  echo
}

for b in "${BUCKETS[@]}"; do fix_bucket "$b"; done

echo "All fixes applied. Verifying:"
bash "$(dirname "$0")/check-backup-s3-posture.sh"
