#!/usr/bin/env bash
# Shared helpers for the deployment scripts. Sourced, not executed.

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
STATE_FILE="$DEPLOY_DIR/.deploy-state"
SECRETS_FILE="$DEPLOY_DIR/.deploy-secrets"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m  --\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

# Load deploy.env and export everything in it.
load_config() {
  local cfg="$DEPLOY_DIR/deploy.env"
  [ -f "$cfg" ] || die "missing $cfg -- copy deploy.env.example to deploy.env and edit it"
  set -a
  # shellcheck disable=SC1090
  . "$cfg"
  set +a

  : "${STACK:?STACK must be set in deploy.env}"
  : "${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION must be set in deploy.env}"
  export AWS_REGION="$AWS_DEFAULT_REGION"

  # Derived resource names -- keep in sync with teardown.sh
  EC2_SG_NAME="${STACK}-ec2-sg"
  RDS_SG_NAME="${STACK}-rds-sg"
  DB_ID="${STACK}-db"
  DB_SUBNET_GROUP="${STACK}-db-subnet-group"
  KEY_NAME="${STACK}-key"
  KEY_FILE="$DEPLOY_DIR/${KEY_NAME}.pem"
  ROLE_NAME="${STACK}-ec2-cloudwatch-role"
  INSTANCE_PROFILE="${STACK}-ec2-profile"
  INSTANCE_TAG="${STACK}-api"
  APP_PORT="${APP_PORT:-8000}"
  APP_DIR_NAME="${APP_DIR_NAME:-TodoPythonApp}"
  REPO_BRANCH="${REPO_BRANCH:-main}"
}

require_tools() {
  local t
  for t in aws ssh scp curl; do
    command -v "$t" >/dev/null || die "$t is not installed"
  done
}

check_identity() {
  local who
  who=$(aws sts get-caller-identity --query 'Arn' --output text 2>&1) \
    || die "AWS credentials are not working: $who"
  ok "authenticated as $who"
}

# --- state: simple KEY=VALUE file so teardown knows what to delete -----------

state_set() {
  local key="$1" val="$2"
  touch "$STATE_FILE"
  # Portable in-place delete of the old key (works on BSD and GNU sed).
  grep -v "^${key}=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  printf '%s=%s\n' "$key" "$val" >> "$STATE_FILE"
}

state_get() {
  local key="$1"
  [ -f "$STATE_FILE" ] || return 1
  local line
  line=$(grep -m1 "^${key}=" "$STATE_FILE") || return 1
  printf '%s' "${line#*=}"
}

state_require() {
  local key="$1" val
  val=$(state_get "$key") \
    || die "$key not found in $STATE_FILE -- run 01-provision-aws.sh first"
  [ -n "$val" ] || die "$key is empty in $STATE_FILE"
  printf '%s' "$val"
}

# --- secrets: the generated DB password -------------------------------------

db_password() {
  if [ -f "$SECRETS_FILE" ]; then
    # shellcheck disable=SC1090
    . "$SECRETS_FILE"
    [ -n "${DB_PASSWORD:-}" ] && { printf '%s' "$DB_PASSWORD"; return 0; }
  fi
  # Alphanumeric only: RDS rejects / @ " and space, and punctuation would need
  # percent-encoding inside DATABASE_URL.
  local pw
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  printf 'DB_PASSWORD=%s\n' "$pw" > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
  printf '%s' "$pw"
}

# --- ssh helpers ------------------------------------------------------------

ssh_opts() {
  printf '%s' "-i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=$DEPLOY_DIR/.known_hosts -o ConnectTimeout=10"
}

# Run a script (on stdin) on the instance.
remote_bash() {
  local ip="$1"
  # shellcheck disable=SC2046
  ssh $(ssh_opts) "ubuntu@${ip}" 'bash -s'
}

wait_for_ssh() {
  local ip="$1" i
  log "waiting for SSH on $ip"
  for i in $(seq 1 40); do
    # shellcheck disable=SC2046
    if ssh $(ssh_opts) -o BatchMode=yes "ubuntu@${ip}" true 2>/dev/null; then
      ok "SSH is up"
      return 0
    fi
    sleep 10
  done
  die "SSH did not come up on $ip"
}
