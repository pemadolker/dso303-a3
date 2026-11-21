#!/usr/bin/env bash
# Tear everything down. NAT gateways and the Multi-AZ database bill by the hour.
# Step 1 switches off the data protection (RDS deletion protection, keep-non-empty-bucket),
# step 2 deletes the stack. Uploaded files and the database are gone afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_REGION="${AWS_REGION:-ap-south-1}"
BUCKET=$(scripts/bootstrap-state.sh)
terraform -chdir=infra init -input=false \
  -backend-config="bucket=${BUCKET}" -backend-config="key=exam-platform/terraform.tfstate" -backend-config="region=${AWS_REGION}"

echo "==> 1/2 Turning off data protection"
scripts/tf-apply.sh -var protect_data=false

echo "==> 2/2 Destroying the stack"
scripts/tf-apply.sh -destroy -var protect_data=false
echo "Stack destroyed. The state bucket ${BUCKET} is kept; delete it by hand if you want."
