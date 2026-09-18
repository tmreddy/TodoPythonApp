# Kubernetes manifests

What runs in the cluster, and why each setting is the way it is.

New to Kubernetes? Read [../devops.md](../devops.md) first. This file is the
reference for these specific files.

## The files

Applied together by `kubectl apply -k k8s/`.

| File | Kind | Job |
|---|---|---|
| [namespace.yaml](namespace.yaml) | Namespace | A folder for everything below |
| [serviceaccount.yaml](serviceaccount.yaml) | ServiceAccount | The pod's AWS identity (IRSA) |
| [configmap.yaml](configmap.yaml) | ConfigMap | Non-secret config: region, log group |
| [deployment.yaml](deployment.yaml) | Deployment | Runs 2 replicas, handles rolling updates |
| [service.yaml](service.yaml) | Service | Public load balancer, one stable address |
| [hpa.yaml](hpa.yaml) | HorizontalPodAutoscaler | Adds replicas under CPU load |
| [pdb.yaml](pdb.yaml) | PodDisruptionBudget | Keeps 1 pod up during node maintenance |
| [kustomization.yaml](kustomization.yaml) | Kustomization | Ties them together, rewrites the image tag |

**The database password is deliberately not here.** A Secret named
`todo-api-secrets` is created at deploy time from AWS Secrets Manager, so the
credential never exists in this repository. See "The secret" below.

## Two probes, two different jobs

This is the part most worth understanding, because getting it wrong causes
outages that look like random flapping.

| | Path | On database failure | Effect |
|---|---|---|---|
| **liveness** | `/.well-known/health` | still **200** | pod is left alone |
| **readiness** | `/.well-known/ready` | **503** | pod removed from the Service |

The reasoning: **restarting a pod does not fix a broken database.** If liveness
pointed at an endpoint that failed during a database outage, Kubernetes would
restart every pod repeatedly, turning a recoverable outage into a crash loop.
Readiness is the one that should fail — it stops traffic reaching a pod that
cannot serve, without killing it, and the pod rejoins automatically when the
database recovers.

There is also a **startupProbe** with `failureThreshold: 30` at 2s intervals,
giving up to 60s to boot. Without it, a slow start looks like a liveness failure
and the pod is killed before it ever finishes starting.

This is why [../app/main.py](../app/main.py) has two endpoints. `/health` returns
200 with the failure in the JSON body — probes only read status codes and never
parse bodies, so `/health` alone cannot gate traffic.

## The secret

```
Terraform generates password
  -> stores connection string in AWS Secrets Manager
    -> CD reads it, creates a Kubernetes Secret
      -> pod reads DATABASE_URL from that Secret
```

The pipeline step is idempotent:

```bash
kubectl create secret generic todo-api-secrets -n todo \
  --from-literal=DATABASE_URL="$url" \
  --dry-run=client -o yaml | kubectl apply -f -
```

`kubectl create secret` on its own fails once the secret exists; rendering it and
piping to `apply` upserts instead.

Be aware: **Kubernetes Secrets are only base64-encoded, not encrypted**, and
anyone who can read them in the namespace can read the password:

```bash
kubectl get secret todo-api-secrets -n todo -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

Base64 is encoding, not encryption. What Secrets buy you over a ConfigMap is that
they are not printed by `kubectl describe`, are excluded from most logging, and
can be gated by RBAC separately. For real isolation you want EKS envelope
encryption with KMS, or the Secrets Store CSI driver so the value never lands in
etcd at all.

## Resource requests and limits

```yaml
requests: { cpu: 100m, memory: 192Mi }
limits:   { memory: 384Mi }
```

`requests` is what the scheduler reserves; `limits` is the hard ceiling.

**Memory has a limit** because a leak should fail fast (OOMKilled, restarted)
rather than starve every other pod on the node.

**CPU deliberately has no limit.** A CPU limit throttles the container even when
the node is idle, which shows up as latency spikes that are genuinely hard to
diagnose. The request alone already guarantees a fair share under contention.

The `cpu: 100m` request is also load-bearing for the HPA: target utilisation is a
percentage *of the request*, so with no request there is nothing to take 70% of.

## Autoscaling

The HPA needs **metrics-server**, which EKS does not install by default.
Terraform adds it as a managed addon ([../terraform/eks.tf](../terraform/eks.tf)).
Without it the HPA shows `<unknown>/70%` and never scales, and `kubectl top`
fails.

```bash
kubectl get hpa -n todo                 # want a real percentage, not <unknown>
kubectl top pods -n todo
```

Note this scales *pods*, not *nodes*. Once pods exceed node capacity they sit
`Pending` until you add Cluster Autoscaler or Karpenter — neither is installed
here.

## Zero-downtime deploys

```yaml
strategy:
  rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
```

`maxUnavailable: 0` is what makes a deploy safe: Kubernetes starts a new pod,
waits for its readiness probe to pass, shifts traffic, and only then removes an
old one. Capacity never dips. It also means a broken image **fails the rollout**
instead of replacing a working deployment — which is what lets
[pipeline.yml](../.github/workflows/pipeline.yml) detect the failure and run
`kubectl rollout undo`.

## Everyday commands

```bash
kubectl get pods -n todo -w                  # watch a rollout happen
kubectl logs -n todo -l app.kubernetes.io/name=todo-api -f --all-containers
kubectl describe pod -n todo <pod>           # scheduling failures and probe results
kubectl get svc todo-api -n todo             # EXTERNAL-IP = load balancer hostname
kubectl rollout status deployment/todo-api -n todo
kubectl rollout history deployment/todo-api -n todo
kubectl rollout undo deployment/todo-api -n todo     # roll back one revision

# Reach the app without going through the load balancer -- useful for telling
# "the app is broken" apart from "the load balancer is broken".
kubectl port-forward -n todo svc/todo-api 8080:80
curl http://localhost:8080/.well-known/ready
```

## Applying by hand

The manifests carry two placeholders the pipeline substitutes, because both are
account-specific and must not be committed:

- `ACCOUNT_ID` in [serviceaccount.yaml](serviceaccount.yaml) — the IRSA role ARN
- the image tag in [kustomization.yaml](kustomization.yaml)

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR=$(cd terraform && terraform output -raw ecr_repository_url)

sed -i '' "s|ACCOUNT_ID|$ACCOUNT|g" k8s/serviceaccount.yaml
cd k8s && kustomize edit set image todo-api="$ECR:manual"
cd .. && kubectl apply -k k8s/
```

Check the result before applying, always:

```bash
kubectl kustomize k8s/          # render locally, no cluster needed
kubectl diff -k k8s/            # what would change in the cluster
```

## Upgrading to an ALB Ingress

The Service type `LoadBalancer` here creates an NLB — a layer-4 load balancer. It
works on a bare cluster with nothing extra installed, which is why it is the
default. You need an ALB Ingress instead once you want host or path routing, TLS
termination with ACM, WAF, or Cognito auth.

That requires:

1. An IAM policy for the AWS Load Balancer Controller (AWS publishes the JSON)
2. An IRSA role for its service account, same mechanism as
   [../terraform/irsa.tf](../terraform/irsa.tf)
3. Installing the controller via Helm into `kube-system`
4. An `Ingress` with `ingressClassName: alb` and
   `alb.ingress.kubernetes.io/target-type: ip`
5. Changing this Service to `ClusterIP`, since the ALB targets pods directly

Its most common failure mode is an Ingress that stays `<pending>` with the real
reason only in the controller's logs:

```bash
kubectl logs -n kube-system deployment/aws-load-balancer-controller
```

## Troubleshooting

**`ImagePullBackOff`** — the node cannot pull the image. Check the tag exists in
ECR and that the node role has `AmazonEC2ContainerRegistryReadOnly` (it does, via
[../terraform/eks.tf](../terraform/eks.tf)).

**`CreateContainerConfigError`** — almost always the missing Secret. The pod
references `todo-api-secrets`, which the pipeline creates:
`kubectl get secret todo-api-secrets -n todo`.

**`CrashLoopBackOff` immediately on start** — [../app/config.py](../app/config.py)
raises at import if `DATABASE_URL` is unset or malformed, so the process exits
instantly. `kubectl logs --previous` shows the exception from the dead container.

**Pod running but never Ready** — readiness is returning 503, so the app cannot
reach the database. Check from inside the pod:

```bash
kubectl exec -n todo deploy/todo-api -- python -c \
  "import os;print(os.environ['DATABASE_URL'].split('@')[-1])"
kubectl exec -n todo deploy/todo-api -- curl -s localhost:8000/.well-known/ready
```

A hang rather than an error usually means the RDS security group does not allow
the node security group — see [../terraform/rds.tf](../terraform/rds.tf).

**Service `EXTERNAL-IP` stuck `<pending>`** — the public subnets need the
`kubernetes.io/role/elb=1` tag ([../terraform/vpc.tf](../terraform/vpc.tf) sets
it). `kubectl describe svc todo-api -n todo` shows the controller's events.

**CloudWatch logs stop working after moving to Kubernetes** — an IRSA mismatch.
The namespace and service account in
[serviceaccount.yaml](serviceaccount.yaml) must exactly match the trust policy
in [../terraform/irsa.tf](../terraform/irsa.tf). On a mismatch the pod gets no
credentials, boto3 falls back silently, and nothing appears in the pod logs.
Verify the token is mounted:

```bash
kubectl exec -n todo deploy/todo-api -- env | grep AWS_
# expect AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE
```

## Verified

`kubectl kustomize k8s/` builds all 7 resources; every file parses as YAML;
selectors render as exactly `app.kubernetes.io/name: todo-api` and match the pod
template labels.

**Not verified against a live cluster** — these manifests have never been applied
to a running EKS cluster, because the cluster has not been created yet. Rendering
correctly is not the same as scheduling correctly.
