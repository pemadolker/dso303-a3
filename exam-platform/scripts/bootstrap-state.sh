#!/usr/bin/env bash
# Creates the S3 bucket that holds Terraform state. Safe to run again. Prints the bucket name.
set -euo pipefail
REGION="${AWS_REGION:-ap-south-1}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="exam-platform-tfstate-${ACCOUNT}"

if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi
echo "$BUCKET"
