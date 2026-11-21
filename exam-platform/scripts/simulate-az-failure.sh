#!/usr/bin/env bash
# Simulates losing one Availability Zone while the site is being used, and records what happens.
#
# What it does (all reversible):
#   1. Starts a background loop that calls the site through CloudFront every 2 seconds.
#   2. Cuts off the app subnet in AZ "a" with a deny-all network ACL (its tasks become unreachable, like a dead AZ).
#   3. Forces the Multi-AZ database to fail over to the standby in the other AZ.
#   4. Watches the load balancer move all traffic to the healthy AZ, then restores everything.
# Output is saved to evidence/az-failure-<time>.log
set -uo pipefail
cd "$(dirname "$0")/.."
export AWS_REGION="${AWS_REGION:-ap-south-1}"
tf() { terraform -chdir=infra output -raw "$1"; }

SITE=$(tf site_url); VPC=$(tf vpc_id); TG=$(tf target_group_arn); DB=$(tf db_identifier)
CLUSTER=$(tf ecs_cluster); SERVICE=$(tf ecs_service)
LOG="evidence/az-failure-$(date +%Y%m%d-%H%M%S).log"; mkdir -p evidence
exec > >(tee -a "$LOG") 2>&1
ts() { date '+%H:%M:%S'; }
say() { echo; echo "[$(ts)] $*"; }

targets() { aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescription[].[Target.AvailabilityZone,TargetHealth.State]' --output text | sort | uniq -c; }

AZ=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=tag:Tier,Values=private-app \
  --query 'sort_by(Subnets,&AvailabilityZone)[0].AvailabilityZone' --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=tag:Tier,Values=private-app Name=availabilityZone,Values="$AZ" \
  --query 'Subnets[0].SubnetId' --output text)
ORIG_ACL=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values="$SUBNET" --query 'NetworkAcls[0].NetworkAclId' --output text)
ASSOC=$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values="$SUBNET" \
  --query "NetworkAcls[0].Associations[?SubnetId=='$SUBNET'].NetworkAclAssociationId | [0]" --output text)
DENY_ACL=""; NEW_ASSOC=""

restore() {
  if [ -n "$NEW_ASSOC" ]; then
    say "RESTORE: putting the original network ACL back on $SUBNET"
    aws ec2 replace-network-acl-association --association-id "$NEW_ASSOC" --network-acl-id "$ORIG_ACL" >/dev/null
  fi
  [ -n "$DENY_ACL" ] && aws ec2 delete-network-acl --network-acl-id "$DENY_ACL" 2>/dev/null
  [ -n "${PROBE_PID:-}" ] && kill "$PROBE_PID" 2>/dev/null
}
trap restore EXIT

say "BASELINE. Failing AZ will be $AZ (subnet $SUBNET). Targets per AZ/state:"; targets
aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].[desiredCount,runningCount]' --output text

# 401 from /api/me means the whole path works (CloudFront -> ALB -> ECS) and only the login is missing.
( while true; do echo "$(ts) $(curl -s -o /dev/null -w '%{http_code}' -m 8 "$SITE/api/me")"; sleep 2; done > /tmp/az-probe.log ) &
PROBE_PID=$!
sleep 10

say "FAILURE: isolating AZ $AZ (deny-all network ACL on its app subnet)"
DENY_ACL=$(aws ec2 create-network-acl --vpc-id "$VPC" --query 'NetworkAcl.NetworkAclId' --output text) # a new ACL denies everything
NEW_ASSOC=$(aws ec2 replace-network-acl-association --association-id "$ASSOC" --network-acl-id "$DENY_ACL" --query NewAssociationId --output text)

say "FAILURE: forcing database failover to the standby in the other AZ"
aws rds reboot-db-instance --db-instance-identifier "$DB" --force-failover >/dev/null

for i in 1 2 3 4 5 6; do
  sleep 15; say "WATCH ($((i*15))s after failure) targets per AZ/state:"; targets
done
say "Database status:"; aws rds describe-db-instances --db-instance-identifier "$DB" \
  --query 'DBInstances[0].[DBInstanceStatus,AvailabilityZone,SecondaryAvailabilityZone]' --output text

restore; NEW_ASSOC=""; DENY_ACL=""
sleep 45
say "AFTER RESTORE targets per AZ/state:"; targets
kill "$PROBE_PID" 2>/dev/null; PROBE_PID=""

echo; echo "===== Site probe summary (HTTP code: count). 401 = healthy, 5xx/000 = failed ====="
awk '{print $2}' /tmp/az-probe.log | sort | uniq -c
echo "----- first non-401 and last non-401 responses -----"
grep -v ' 401$' /tmp/az-probe.log | sed -n '1p;$p'
echo "Log saved to $LOG"
