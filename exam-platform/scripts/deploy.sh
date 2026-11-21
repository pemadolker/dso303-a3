#!/usr/bin/env bash
# Same steps as the GitHub Actions workflow, for running from your own machine.
# Needs: aws cli (logged in), terraform >= 1.10, docker, node 22.
# Required: infra/terraform.tfvars (copy terraform.tfvars.example) or TF_VAR_ses_sender_email.
set -euo pipefail
cd "$(dirname "$0")/.."
export AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || date +%s)}"

echo "==> 1/7 Terraform state bucket"
BUCKET=$(scripts/bootstrap-state.sh)

echo "==> 2/7 Worker dependencies + RDS CA bundle"
(cd workers && npm ci --omit=dev)
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o workers/rds-ca.pem

echo "==> 3/7 terraform init, then create the container registry first"
terraform -chdir=infra init -input=false \
  -backend-config="bucket=${BUCKET}" -backend-config="key=exam-platform/terraform.tfstate" -backend-config="region=${AWS_REGION}"
scripts/tf-apply.sh -target=aws_ecr_repository.api

echo "==> 4/7 Build and push the API image (${TAG})"
REPO=$(terraform -chdir=infra output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build -t "${REPO}:${TAG}" api
docker push "${REPO}:${TAG}"

echo "==> 5/7 Apply the full stack"
scripts/tf-apply.sh -var "image_tag=${TAG}"

echo "==> 6/7 Wait for the API to become stable"
aws ecs wait services-stable --cluster "$(terraform -chdir=infra output -raw ecs_cluster)" --services "$(terraform -chdir=infra output -raw ecs_service)"

echo "==> 7/7 Publish the frontend"
scripts/publish-frontend.sh

echo
echo "Done. Site: $(terraform -chdir=infra output -raw site_url)"
echo "Next: click the SES verification link in your inbox, then scripts/seed-users.sh"
