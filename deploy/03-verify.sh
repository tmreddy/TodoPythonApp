#!/usr/bin/env bash
# Smoke-test the deployment: service state, health, CRUD, CloudWatch.
# Exits non-zero if any check fails.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config
EC2_IP=$(state_require EC2_IP)
FAILED=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label"
  else
    printf '\033[1;31mFAIL\033[0m %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

# Everything runs on the instance: RDS is private, and the app's own public
# endpoint may be blocked by a corporate proxy on your workstation.
log "running checks on the instance"
OUT=$(remote_bash "$EC2_IP" <<REMOTE
set -uo pipefail
echo "SERVICE=\$(systemctl is-active ${STACK}app)"
echo "ENABLED=\$(systemctl is-enabled ${STACK}app 2>/dev/null)"
echo "NGINX=\$(systemctl is-active nginx)"
echo "HEALTH_APP=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost:${APP_PORT}/.well-known/health)"
echo "HEALTH_NGINX=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost/.well-known/health)"
echo "DB=\$(curl -s http://localhost/.well-known/health | grep -o 'connected' || echo missing)"
echo "SWAGGER=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost/.well-known/swagger)"
ID=\$(curl -s -X POST http://localhost/todos -H 'Content-Type: application/json' \
      -d '{"title":"deploy verify","description":"03-verify.sh"}' \
      | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
echo "CREATE=\${ID:-fail}"
echo "READ=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost/todos/\${ID})"
echo "UPDATE=\$(curl -s -o /dev/null -w '%{http_code}' -X PUT http://localhost/todos/\${ID} \
      -H 'Content-Type: application/json' -d '{"completed":true}')"
echo "MISSING=\$(curl -s -o /dev/null -w '%{http_code}' http://localhost/todos/99999999)"
echo "DELETE=\$(curl -s -o /dev/null -w '%{http_code}' -X DELETE http://localhost/todos/\${ID})"
# Scope to the current run only -- warnings from earlier boots are history,
# not the state of the service we just deployed. ActiveEnterTimestamp looks
# like "Fri 2026-09-18 07:32:42 UTC" and journalctl --since rejects the
# weekday, so drop it and keep the date and time fields.
SINCE_TS=\$(systemctl show -p ActiveEnterTimestamp --value ${STACK}app | cut -d' ' -f2-3)
if [ -n "\$SINCE_TS" ]; then
  echo "CWWARN=\$(sudo journalctl -u ${STACK}app --since "\$SINCE_TS" --no-pager | grep -c 'CloudWatch handler unavailable' || true)"
else
  echo "CWWARN=no-timestamp"
fi
REMOTE
)

[ -n "$OUT" ] || die "could not run checks on $EC2_IP"
eval "$OUT"

check "service active"          "active"    "${SERVICE:-}"
check "service enabled at boot" "enabled"   "${ENABLED:-}"
check "nginx active"            "active"    "${NGINX:-}"
check "health via app port"     "200"       "${HEALTH_APP:-}"
check "health via nginx"        "200"       "${HEALTH_NGINX:-}"
check "database connected"      "connected" "${DB:-}"
check "swagger UI"              "200"       "${SWAGGER:-}"
check "read todo"               "200"       "${READ:-}"
check "update todo"             "200"       "${UPDATE:-}"
check "missing todo is 404"     "404"       "${MISSING:-}"
check "delete todo"             "200"       "${DELETE:-}"
check "no CloudWatch warnings"  "0"         "${CWWARN:-}"

if [ "${CREATE:-fail}" = "fail" ]; then
  printf '\033[1;31mFAIL\033[0m create todo\n'; FAILED=$((FAILED + 1))
else
  ok "create todo (id ${CREATE})"
fi

# --- CloudWatch -------------------------------------------------------------

log "CloudWatch log group"
if aws logs describe-log-groups --log-group-name-prefix "$CLOUDWATCH_LOG_GROUP" \
     --query 'logGroups[0].logGroupName' --output text 2>/dev/null | grep -q "$CLOUDWATCH_LOG_GROUP"; then
  ok "log group $CLOUDWATCH_LOG_GROUP exists"
  STREAMS=$(aws logs describe-log-streams --log-group-name "$CLOUDWATCH_LOG_GROUP" \
              --query 'length(logStreams)' --output text 2>/dev/null || echo 0)
  if [ "$STREAMS" = "0" ]; then
    warn "no log streams yet -- watchtower flushes about once a minute, re-run to confirm"
  else
    ok "$STREAMS log stream(s) present"
  fi
else
  printf '\033[1;31mFAIL\033[0m log group %s missing\n' "$CLOUDWATCH_LOG_GROUP"
  FAILED=$((FAILED + 1))
fi

echo
if [ "$FAILED" -eq 0 ]; then
  log "all checks passed -- http://${EC2_IP}/"
else
  die "$FAILED check(s) failed"
fi
