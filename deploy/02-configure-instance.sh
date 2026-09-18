#!/usr/bin/env bash
# Install and configure the app on the instance: packages, code, venv, .env,
# systemd unit, nginx. Safe to re-run -- it converges to the same state.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config
require_tools

EC2_IP=$(state_require EC2_IP)
RDS_ENDPOINT=$(state_require RDS_ENDPOINT)
PGPASS=$(db_password)
APP_DIR="/home/ubuntu/${APP_DIR_NAME}"

[ -f "$KEY_FILE" ] || die "missing $KEY_FILE -- cannot SSH to the instance"
wait_for_ssh "$EC2_IP"

# --- system packages --------------------------------------------------------

log "installing system packages"
remote_bash "$EC2_IP" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq python3 python3-pip python3-venv git postgresql-client nginx
REMOTE
ok "packages installed"

# --- application code -------------------------------------------------------

if [ "${DEPLOY_LOCAL_TREE:-0}" = "1" ]; then
  log "copying local working tree to $APP_DIR"
  # shellcheck disable=SC2046
  ssh $(ssh_opts) "ubuntu@${EC2_IP}" "mkdir -p '$APP_DIR'"
  rsync -az --delete \
    --exclude '.git' --exclude '.venv' --exclude 'venv' \
    --exclude '__pycache__' --exclude '.pytest_cache' \
    --exclude 'deploy/.deploy-state' --exclude 'deploy/.deploy-secrets' \
    --exclude 'deploy/deploy.env' --exclude 'deploy/*.pem' \
    -e "ssh $(ssh_opts)" "$REPO_ROOT/" "ubuntu@${EC2_IP}:${APP_DIR}/"
  ok "working tree copied"
else
  log "cloning $REPO_URL ($REPO_BRANCH)"
  remote_bash "$EC2_IP" <<REMOTE
set -euo pipefail
if [ -d '$APP_DIR/.git' ]; then
  cd '$APP_DIR'
  git remote set-url origin '$REPO_URL'
  git fetch -q origin '$REPO_BRANCH'
  git checkout -q '$REPO_BRANCH'
  git reset -q --hard 'origin/$REPO_BRANCH'
else
  rm -rf '$APP_DIR'
  git clone -q --branch '$REPO_BRANCH' '$REPO_URL' '$APP_DIR'
fi
git -C '$APP_DIR' log --oneline -1
REMOTE
  ok "code in place"
fi

# --- python environment -----------------------------------------------------

log "creating virtualenv and installing requirements"
remote_bash "$EC2_IP" <<REMOTE
set -euo pipefail
cd '$APP_DIR'
[ -d venv ] || python3 -m venv venv
./venv/bin/pip install -q --upgrade pip
./venv/bin/pip install -q -r requirements.txt
./venv/bin/python -c 'import fastapi, uvicorn, sqlalchemy, psycopg2, boto3, watchtower; print("deps ok")'
REMOTE
ok "virtualenv ready"

# --- database ---------------------------------------------------------------

# The instance is created with --db-name, so the database normally exists
# already; this covers instances created without it.
log "ensuring database $DB_NAME exists"
remote_bash "$EC2_IP" <<REMOTE
set -euo pipefail
export PGPASSWORD='$PGPASS'
if psql -h '$RDS_ENDPOINT' -U '$DB_MASTER_USER' -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  echo "database $DB_NAME already present"
else
  psql -h '$RDS_ENDPOINT' -U '$DB_MASTER_USER' -d postgres -c 'CREATE DATABASE $DB_NAME;'
fi
REMOTE
ok "database ready"

# --- .env -------------------------------------------------------------------

log "writing $APP_DIR/.env"
remote_bash "$EC2_IP" <<REMOTE
set -euo pipefail
cd '$APP_DIR'
cat > .env <<EOF
DATABASE_URL=postgresql://${DB_MASTER_USER}:${PGPASS}@${RDS_ENDPOINT}:5432/${DB_NAME}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}
CLOUDWATCH_LOG_GROUP=${CLOUDWATCH_LOG_GROUP}
EOF
chmod 600 .env
REMOTE
ok ".env written"

# --- systemd ----------------------------------------------------------------

log "installing systemd unit"
remote_bash "$EC2_IP" <<REMOTE
set -euo pipefail
# sudo tee, not sudo cat >: the redirect would be performed as ubuntu and fail.
sudo tee /etc/systemd/system/${STACK}app.service > /dev/null <<EOF
[Unit]
Description=${STACK} FastAPI Application
After=network.target

[Service]
User=ubuntu
WorkingDirectory=${APP_DIR}
Environment="PATH=${APP_DIR}/venv/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port ${APP_PORT}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable -q ${STACK}app
sudo systemctl restart ${STACK}app
REMOTE
ok "service ${STACK}app installed"

# --- nginx ------------------------------------------------------------------

log "configuring nginx reverse proxy"
remote_bash "$EC2_IP" <<REMOTE
set -euo pipefail
sudo tee /etc/nginx/sites-available/${STACK} > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:__APP_PORT__;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
sudo sed -i "s/__APP_PORT__/${APP_PORT}/" /etc/nginx/sites-available/${STACK}
sudo ln -sf /etc/nginx/sites-available/${STACK} /etc/nginx/sites-enabled/${STACK}
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
REMOTE
ok "nginx configured"

echo
log "configuration complete"
echo "  app:     http://${EC2_IP}/"
echo "  swagger: http://${EC2_IP}/.well-known/swagger"
echo "  next:    ./deploy/03-verify.sh"
