#!/usr/bin/env bash
# Writes frontend/config.json from Terraform outputs, uploads the site to S3, clears the CloudFront cache.
set -euo pipefail
cd "$(dirname "$0")/.."
out() { terraform -chdir=infra output -raw "$1"; }

cat > frontend/config.json <<JSON
{ "region": "$(out region)", "clientId": "$(out user_pool_client_id)" }
JSON

BUCKET=$(out frontend_bucket)
aws s3 sync frontend "s3://${BUCKET}" --delete --exclude "config.json" --exclude "index.html" --cache-control "public,max-age=300"
aws s3 cp frontend/index.html "s3://${BUCKET}/index.html" --cache-control "no-cache"
aws s3 cp frontend/config.json "s3://${BUCKET}/config.json" --cache-control "no-cache"
aws cloudfront create-invalidation --distribution-id "$(out cloudfront_distribution_id)" --paths "/*" >/dev/null
echo "Frontend published to $(out site_url)"
