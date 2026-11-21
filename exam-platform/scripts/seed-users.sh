#!/usr/bin/env bash
# Creates one admin, one tutor and two students for the demo, with permanent passwords (no email step).
# Usage: PASSWORD='Choose-A-Strong-Pass-1' scripts/seed-users.sh your.address@example.com
# Emails are derived from your address with +tags (you+admin@..., you+tutor@...), so one inbox receives everything.
set -euo pipefail
cd "$(dirname "$0")/.."
BASE="${1:?give your email address}"; : "${PASSWORD:?set PASSWORD (12+ chars, upper, lower, number)}"
POOL=$(terraform -chdir=infra output -raw user_pool_id)
LOCAL="${BASE%@*}"; DOMAIN="${BASE#*@}"

make_user() { # tag group
  local email="${LOCAL}+$1@${DOMAIN}"
  aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$email" \
    --user-attributes Name=email,Value="$email" Name=email_verified,Value=true --message-action SUPPRESS >/dev/null 2>&1 || true
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$email" --password "$PASSWORD" --permanent
  aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --username "$email" --group-name "$2"
  echo "  $2: $email"
}
make_user admin admin
make_user tutor tutor
make_user student1 student
make_user student2 student
