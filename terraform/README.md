# Infrastructure as code

Terraform definitions for the containerized stack: VPC, EKS, ECR, RDS and IAM.

New to any of this? Read [../devops.md](../devops.md) first — it explains the
whole cycle. This file is the operational reference.

## Important: this is not run by the app pipeline

Pushing code does **not** create infrastructure. `terraform apply` is always
deliberate, because application code and infrastructure have very different blast
radii — a bad app deploy rolls back in seconds, a bad `apply` can delete a
database. So:

| Change | Who runs it | When |
|---|---|---|
| Application code | [pipeline.yml](../.github/workflows/pipeline.yml) | automatically, on push to `main` |
| Infrastructure | [terraform.yml](../.github/workflows/terraform.yml) | manually, or locally |

The app pipeline has a preflight check that fails with instructions if the
cluster, registry or secret is missing, so a first push to `main` tells you what
to do rather than failing obscurely.

## First run, in order

Order matters. The application deploy needs a cluster to deploy *into*, a
registry to push *to*, and a secret to read the database password *from*.

```bash
# 1. Credentials. Any standard AWS mechanism works.
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=us-east-1
aws sts get-caller-identity          # confirm who you are before creating anything

# 2. Optional configuration
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars             # every value has a working default

# 3. Provision. 15-20 minutes: the EKS control plane alone is 10-15.
terraform init
terraform plan                       # read this before applying
terraform apply

# 4. Point kubectl at the new cluster
$(terraform output -raw kubeconfig_command)
kubectl get nodes                    # expect 2 nodes, status Ready
```

Then deploy the application, either by pushing to `main` or by hand:

```bash
cd ..
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR=$(cd terraform && terraform output -raw ecr_repository_url)

aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR%%/*}"
docker build -t "$ECR:manual" .
docker push "$ECR:manual"

kubectl apply -f k8s/namespace.yaml
DATABASE_URL=$(aws secretsmanager get-secret-value \
  --secret-id "$(cd terraform && terraform output -raw db_secret_name)" \
  --query SecretString --output text | python3 -c 'import sys,json;print(json.load(sys.stdin)["DATABASE_URL"])')
kubectl create secret generic todo-api-secrets -n todo \
  --from-literal=DATABASE_URL="$DATABASE_URL" --dry-run=client -o yaml | kubectl apply -f -

sed -i '' "s|ACCOUNT_ID|$ACCOUNT|g" k8s/serviceaccount.yaml
cd k8s && kubectl kustomize --load-restrictor=LoadRestrictionsNone . | \
  sed "s|image: todo-api:local|image: $ECR:manual|" | kubectl apply -f -
```

See [../k8s/README.md](../k8s/README.md) for the manifest details.

## What gets created

40 resources. The plan is the authority; this is the shape of it.

| File | Creates |
|---|---|
| [vpc.tf](vpc.tf) | VPC, 2 public + 2 private subnets, internet gateway, route tables |
| [eks.tf](eks.tf) | EKS cluster, managed node group, cluster/node IAM roles, addons |
| [irsa.tf](irsa.tf) | OIDC provider, the app's IAM role, its CloudWatch log group |
| [rds.tf](rds.tf) | PostgreSQL instance, subnet group, security group, Secrets Manager secret |
| [ecr.tf](ecr.tf) | Image repository with immutable tags and a lifecycle policy |
| [outputs.tf](outputs.tf) | The values the deploy pipeline and you need |

## Deliberate trade-offs

These are choices, not oversights. Each one is commented in the file it affects.

**Worker nodes are in public subnets.** The production layout is private subnets
behind a NAT Gateway, but NAT costs ~$32/month per AZ — more than the nodes. Nodes
need outbound internet for ECR and the EKS API, so it's public IPs or pay. Their
security group allows nothing inbound from the internet. RDS stays private
regardless. To harden: add a NAT Gateway and move the node group to
`aws_subnet.private`.

**A Service of type LoadBalancer, not an ALB Ingress.** This uses the
cloud-controller-manager EKS already runs, so it works on a bare cluster. An ALB
Ingress needs the AWS Load Balancer Controller — its own IAM policy, IRSA role and
Helm release — and its most common failure is an Ingress stuck `<pending>` with the
reason buried in controller logs. Upgrade path in
[../k8s/README.md](../k8s/README.md).

**Local state by default.** Fine for one person. The moment a second person or CI
runs `apply`, you need remote state with locking or two applies corrupt the
record. Bootstrap in [versions.tf](versions.tf).

**No TLS.** The load balancer serves plain HTTP. Real HTTPS needs a domain name
and an ACM certificate, which needs a hosted zone you own.

**`skip_final_snapshot = true` and `deletion_protection = false`.** So that
teardown actually works while learning. Both are wrong for production.

## Teardown

**Do not just run `terraform destroy`.** It will hang for ~20 minutes and fail
with `DependencyViolation`.

The reason: the Kubernetes Service created a load balancer via the
cloud-controller-manager, so **Terraform has no record of it**. That load balancer
owns network interfaces in your subnets, and AWS refuses to delete a subnet — and
therefore the VPC — while an ENI is attached.

Use the script, which orders it correctly:

```bash
./terraform/destroy.sh
```

It asks you to type `destroy`, then:

1. Deletes the Kubernetes Service, releasing the load balancer
2. Deletes the namespace
3. Polls until the load balancer's network interfaces are gone
4. Runs `terraform destroy`
5. Checks for orphans that would keep billing

Or from CI: **Actions → terraform → Run workflow**, `action = destroy`,
`confirm = destroy`. That job performs the same cleanup first.

To do it by hand:

```bash
kubectl delete svc todo-api -n todo --wait      # releases the load balancer
kubectl delete namespace todo --wait
sleep 45                                        # ENI detachment is asynchronous
terraform destroy
```

**Destroy is safe to re-run.** If it fails partway, run it again — a second pass
usually clears dependencies that were still detaching.

**Verify afterwards.** An orphaned load balancer or RDS instance bills whether or
not you remember it:

```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws eks list-clusters
```

`destroy.sh` runs these checks for you as step 3.

## Cost

Approximate, us-east-1, whole stack running:

| Resource | ~Monthly |
|---|---|
| EKS control plane | $73 — flat, charged even with zero nodes |
| 2 × t3.small nodes | $30 |
| RDS db.t3.micro | $12 |
| Network Load Balancer | $16 |
| Storage, ECR, logs, secret | ~$5 |
| **Total** | **~$135** |

The control plane is the reason this is expensive and it cannot be reduced —
it is a fixed EKS charge. **Destroy the stack when you are not using it.**
Nothing here holds data you cannot recreate.

Cheaper ways to learn the same Kubernetes concepts: `kind` or `minikube` locally
(free), or ECS Fargate on AWS (no control plane charge).

## Troubleshooting

**`UnauthorizedOperation` / `AccessDenied` during apply** — the IAM user needs
broad create permissions across EC2, EKS, RDS, IAM, ECR, Secrets Manager and
CloudWatch. Sandbox and lab accounts frequently block IAM role creation, which
stops this at `aws_iam_role.cluster`.

**`InvalidParameterException: unsupported Kubernetes version`** — AWS retired
that version. Check and bump `kubernetes_version`:
`aws eks describe-addon-versions --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion' --output text`

**`Cannot find version 18.6 for postgres`** — not orderable for that class in that
region. List real options:
`aws rds describe-orderable-db-instance-options --engine postgres --db-instance-class db.t3.micro --query 'OrderableDBInstanceOptions[].EngineVersion'`

**`kubectl` says `Unauthorized`** — the cluster creator gets admin implicitly;
every other identity needs an access entry. Add its ARN to
`cluster_admin_role_arns` and re-apply.

**Pods stuck `Pending`** — usually node capacity. `kubectl describe pod` shows the
reason. `Insufficient memory` means move `node_instance_type` to `t3.medium`;
`too many pods` means you hit the per-instance ENI/IP limit, which is set by
instance type rather than CPU.

**`error acquiring the state lock`** — a previous run died holding the lock. With
local state, delete `.terraform.tfstate.lock.info`. Never use `-lock=false` as a
habit; it exists for read-only commands.

## Verified

- `terraform fmt -check -recursive` — clean
- `terraform validate` — passes
- `terraform plan` against a real AWS account — **40 to add, 0 to change,
  0 to destroy**, on 2026-09-18 in `us-east-1` with Terraform 1.5.7 and AWS
  provider 5.100.0
- `destroy.sh` — syntax checked, and its orphan-detection step runs correctly

**Not yet verified:** `terraform apply` has not been run, so the cluster has never
been built from these files and no application has been deployed to EKS. The plan
proves the configuration is accepted by the AWS API; it does not prove the
resources converge. Expect to hit at least one thing on a first real apply.
