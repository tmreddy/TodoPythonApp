#!/usr/bin/env bash
#
# Ordered teardown of the container stack.
#
# Why a script instead of just `terraform destroy`: the Kubernetes Service of
# type LoadBalancer is created by the AWS cloud-controller-manager, not by
# Terraform. Terraform has no record of it, so it tries to delete the subnets
# while that load balancer's network interfaces are still attached -- and AWS
# refuses, with "DependencyViolation: has some mapped public address(es)". The
# destroy then hangs for ~20 minutes before failing, leaving a half-deleted VPC.
#
# Correct order: Kubernetes workloads -> wait for the ENIs to clear -> Terraform.
#
# Usage:
#   ./terraform/destroy.sh          # asks for confirmation
#   ./terraform/destroy.sh --yes    # no prompt (for automation)

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

RED=$'\033[1;31m'; GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; BLUE=$'\033[1;34m'; OFF=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$BLUE" "$OFF" "$*"; }
ok()   { printf '%sok%s   %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '%swarn%s %s\n' "$YELLOW" "$OFF" "$*"; }
die()  { printf '%serror%s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

command -v terraform >/dev/null || die "terraform not found"
command -v aws >/dev/null || die "aws CLI not found"

[ -f terraform.tfstate ] || [ -d .terraform ] || \
  die "no Terraform state here -- nothing to destroy (run from the repo root as ./terraform/destroy.sh)"

# ---------------------------------------------------------------- confirm --

REGION=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")
CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || echo "")

if [ "$ASSUME_YES" -ne 1 ]; then
  cat <<EOF

${RED}This deletes the whole stack, permanently.${OFF}

  region   ${REGION}
  cluster  ${CLUSTER:-<none in state>}

Gone for good, including:
  - the EKS cluster and its worker nodes
  - the RDS database AND ALL ITS DATA (skip_final_snapshot = true)
  - the ECR repository and every image in it
  - the VPC, subnets and load balancer
  - the CloudWatch log groups and all log history

EOF
  printf 'Type %sdestroy%s to proceed: ' "$RED" "$OFF"
  read -r reply
  [ "$reply" = "destroy" ] || die "aborted (you typed '${reply}')"
fi

# --------------------------------------------- step 1: Kubernetes workloads --

if [ -n "$CLUSTER" ] && aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  log "step 1/3: removing Kubernetes resources from $CLUSTER"

  if aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
    # The Service first and on its own: deleting it is what releases the load
    # balancer. kubectl blocks until the finalizer finishes.
    log "deleting the Service (releases the load balancer)"
    kubectl delete svc todo-api -n todo --ignore-not-found --wait --timeout=5m || \
      warn "could not delete the Service; check for a leftover load balancer afterwards"

    log "deleting the namespace"
    kubectl delete namespace todo --ignore-not-found --wait --timeout=5m || \
      warn "namespace deletion did not complete"

    # ENI detachment is asynchronous and lags the API call.
    log "waiting for load balancer network interfaces to clear"
    for i in $(seq 1 20); do
      remaining=$(aws ec2 describe-network-interfaces --region "$REGION" \
        --filters "Name=description,Values=*${CLUSTER}*" \
        --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
      [ "$remaining" = "0" ] && { ok "network interfaces cleared"; break; }
      printf '  %s remaining (attempt %s/20)\n' "$remaining" "$i"
      sleep 15
    done
  else
    warn "could not reach the cluster; continuing to Terraform destroy"
  fi
else
  ok "step 1/3: no reachable cluster, skipping Kubernetes cleanup"
fi

# ------------------------------------------------- step 2: terraform destroy --

log "step 2/3: terraform destroy (RDS and EKS deletion take several minutes)"
if terraform destroy -input=false -auto-approve -lock-timeout=5m; then
  ok "terraform destroy completed"
else
  die "terraform destroy failed -- re-run this script; destroy is safe to repeat, \
and a second pass usually clears dependencies that were still detaching"
fi

# --------------------------------------------------- step 3: leftovers check --

log "step 3/3: checking for orphaned resources"
LEFTOVERS=0

check() {
  local label="$1" count="$2"
  if [ "${count:-0}" != "0" ] && [ -n "${count:-}" ]; then
    warn "$label: $count still present"
    LEFTOVERS=1
  else
    ok "$label: clean"
  fi
}

check "load balancers" "$(aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0)"

check "EKS clusters" "$(aws eks list-clusters --region "$REGION" \
  --query 'length(clusters)' --output text 2>/dev/null || echo 0)"

check "RDS instances" "$(aws rds describe-db-instances --region "$REGION" \
  --query 'length(DBInstances)' --output text 2>/dev/null || echo 0)"

# Secrets Manager keeps names reserved after deletion unless the recovery window
# is 0, which terraform/rds.tf sets. Worth confirming, because a lingering
# secret blocks re-applying with the same name.
check "scheduled-for-deletion secrets" "$(aws secretsmanager list-secrets --region "$REGION" \
  --include-planned-deletion --query 'length(SecretList[?DeletedDate!=null])' \
  --output text 2>/dev/null || echo 0)"

echo
if [ "$LEFTOVERS" -eq 0 ]; then
  ok "teardown complete -- nothing left billing"
else
  warn "some resources remain. They may still be deleting; re-check in a few minutes."
  warn "Anything genuinely orphaned has to be removed by hand, or it keeps billing."
fi
