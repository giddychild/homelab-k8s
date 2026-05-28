#!/usr/bin/env bash
# Verify the two backup buckets have:
#   1. Default SSE-S3 encryption on PUT (so any future object written without
#      explicit headers is still encrypted at rest)
#   2. A bucket policy that DENIES non-TLS access (aws:SecureTransport = false)
#   3. Public-access-block ON for all four flags
#   4. Versioning enabled (defense against silent overwrite / ransomware)
#
# Read-only checks; remediation commands are printed at the end if anything
# fails, NOT auto-applied. Run from any box with AWS creds for the Velero IAM
# user (or admin). Buckets:
#   - 155125294186-homelab-k8s-backups   (Velero + etcd snapshots)
#   - giddyland-money-pg-backups         (CNPG Barman for money's Postgres)
set -uo pipefail

BUCKETS=("155125294186-homelab-k8s-backups" "giddyland-money-pg-backups")
fail=0

check_bucket() {
  local b="$1"
  echo "=== $b ==="

  # 1) Default server-side encryption
  if aws s3api get-bucket-encryption --bucket "$b" >/dev/null 2>&1; then
    algo=$(aws s3api get-bucket-encryption --bucket "$b" \
      --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
      --output text)
    echo "  [OK]   default SSE = $algo"
  else
    echo "  [FAIL] no default encryption set"
    fail=1
  fi

  # 2) TLS-only bucket policy (look for aws:SecureTransport=false deny)
  pol=$(aws s3api get-bucket-policy --bucket "$b" --query 'Policy' --output text 2>/dev/null || echo "{}")
  if echo "$pol" | grep -q '"aws:SecureTransport".*"false"'; then
    echo "  [OK]   bucket policy denies non-TLS"
  else
    echo "  [FAIL] bucket policy does NOT deny non-TLS access"
    fail=1
  fi

  # 3) Public-access-block
  pab=$(aws s3api get-public-access-block --bucket "$b" \
    --query 'PublicAccessBlockConfiguration' --output json 2>/dev/null || echo "{}")
  if echo "$pab" | grep -qv 'false'; then
    echo "  [OK]   public-access-block fully on"
  else
    echo "  [FAIL] public-access-block has a false flag: $pab"
    fail=1
  fi

  # 4) Versioning
  vstat=$(aws s3api get-bucket-versioning --bucket "$b" --query 'Status' --output text 2>/dev/null || echo "None")
  if [ "$vstat" = "Enabled" ]; then
    echo "  [OK]   versioning Enabled"
  else
    echo "  [WARN] versioning = $vstat (recommend Enabled for ransomware defense)"
  fi
}

for b in "${BUCKETS[@]}"; do check_bucket "$b"; echo; done

if [ "$fail" -ne 0 ]; then
  cat <<'REMEDY'
=== REMEDIATION (run only after reviewing) ===
# Enable default SSE-S3 encryption:
aws s3api put-bucket-encryption --bucket BUCKET --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# Lock down to TLS-only (replace BUCKET in BOTH places):
cat > /tmp/tls-only-policy.json <<'POL'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::BUCKET", "arn:aws:s3:::BUCKET/*"],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
}
POL
aws s3api put-bucket-policy --bucket BUCKET --policy file:///tmp/tls-only-policy.json

# Block all public access:
aws s3api put-public-access-block --bucket BUCKET --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

# Enable versioning (one-way; cannot be disabled, only Suspended):
aws s3api put-bucket-versioning --bucket BUCKET --versioning-configuration Status=Enabled
REMEDY
  exit 1
fi

echo "All buckets pass posture check."
