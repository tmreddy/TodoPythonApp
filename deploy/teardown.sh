#!/usr/bin/env bash
# Delete every resource created by 01-provision-aws.sh.
# Requires confirmation unless --yes is passed.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

cat <<BANNER
This deletes the "$STACK" stack in $AWS_DEFAULT_REGION:

  EC2 instance      $(state_get IID 2>/dev/null || echo "(from tag $INSTANCE_TAG)")
  RDS instance      $DB_ID          <-- all data is destroyed, no final snapshot
  DB subnet group   $DB_SUBNET_GROUP
  Security groups   $RDS_SG_NAME, $EC2_SG_NAME
  Key pair          $KEY_NAME
  IAM role          $ROLE_NAME
  Instance profile  $INSTANCE_PROFILE
  Log group         $CLOUDWATCH_LOG_GROUP

BANNER

if [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Type "delete" to proceed: '
  read -r reply
  [ "$reply" = "delete" ] || die "aborted"
fi

# Best-effort throughout: a partially provisioned stack should still tear down.
soft() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else skip "$label (absent or already gone)"; fi
}

# --- EC2 --------------------------------------------------------------------

IID=$(state_get IID 2>/dev/null || true)
if [ -z "${IID:-}" ] || [ "$IID" = "None" ]; then
  IID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$INSTANCE_TAG" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
fi

if [ -n "${IID:-}" ] && [ "$IID" != "None" ]; then
  log "terminating instance $IID"
  aws ec2 terminate-instances --instance-ids "$IID" >/dev/null 2>&1 || true
  aws ec2 wait instance-terminated --instance-ids "$IID" 2>/dev/null || true
  ok "instance terminated"
else
  skip "no EC2 instance found"
fi

# --- RDS --------------------------------------------------------------------

if aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  log "deleting database $DB_ID (no final snapshot)"
  aws rds delete-db-instance --db-instance-identifier "$DB_ID" \
    --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || true
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_ID" 2>/dev/null || true
  ok "database deleted"
else
  skip "no RDS instance $DB_ID"
fi

soft "subnet group $DB_SUBNET_GROUP deleted" \
  aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP"

# --- security groups (RDS first: it references the EC2 group) ---------------

delete_sg_by_name() {
  local name="$1" sgid
  sgid=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$name" \
          --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
  if [ -z "$sgid" ] || [ "$sgid" = "None" ]; then
    skip "security group $name (absent)"
    return
  fi
  # ENIs can linger briefly after instance termination.
  local i
  for i in 1 2 3 4 5 6; do
    if aws ec2 delete-security-group --group-id "$sgid" >/dev/null 2>&1; then
      ok "security group $name deleted"
      return
    fi
    sleep 10
  done
  warn "could not delete security group $name ($sgid) -- a dependency may still exist"
}

log "deleting security groups"
delete_sg_by_name "$RDS_SG_NAME"
delete_sg_by_name "$EC2_SG_NAME"

# --- key pair, IAM, logs ----------------------------------------------------

soft "key pair $KEY_NAME deleted" aws ec2 delete-key-pair --key-name "$KEY_NAME"
[ -f "$KEY_FILE" ] && { rm -f "$KEY_FILE"; ok "removed $KEY_FILE"; }

log "deleting IAM resources"
soft "role removed from instance profile" \
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE" --role-name "$ROLE_NAME"
soft "instance profile deleted" \
  aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE"
soft "role policy deleted" \
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "${STACK}-cloudwatch-logs"
soft "role deleted" aws iam delete-role --role-name "$ROLE_NAME"

soft "log group $CLOUDWATCH_LOG_GROUP deleted" \
  aws logs delete-log-group --log-group-name "$CLOUDWATCH_LOG_GROUP"

# --- local state ------------------------------------------------------------

rm -f "$STATE_FILE" "$DEPLOY_DIR/.known_hosts"
ok "removed local state"
warn "kept $SECRETS_FILE -- delete it yourself if you no longer need the DB password"

echo
log "teardown complete"
