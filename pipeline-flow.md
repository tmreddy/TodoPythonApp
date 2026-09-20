# What happens when you promote code

A step-by-step trace of [.github/workflows/pipeline.yml](.github/workflows/pipeline.yml),
from `git push` to a live URL. Every step name below is the real name you will see
in the Actions tab, in order.

For the concepts behind any of this, read [devops.md](devops.md) first.

---

## 1. The trigger

```yaml
on:
  push:
    branches: ["**"]     # every branch, no exceptions
  pull_request:
  workflow_dispatch:     # the "Run workflow" button
```

What runs depends on *where* you pushed:

| You push to | `test` | `container` | `deploy` |
|---|---|---|---|
| `feature/anything` | yes | yes | **no** |
| a pull request | yes | yes | **no** |
| `main` | yes | yes | **yes** |

Only `main` reaches the cluster. The gate is one line on the `deploy` job:

```yaml
if: github.ref == 'refs/heads/main' && github.event_name == 'push'
```

Both halves matter. Without the `event_name` check, a pull request *targeting*
main would deploy — which would put unreviewed code live, the exact thing branch
protection is meant to prevent.

Why no branch deploys at all: every branch would share one cluster, one database
and one URL, so "deploy every branch" means whoever pushed last wins, silently.
Real per-branch environments need their own namespace and database, which is a
much bigger change than a config flag.

**Two runs per push on a PR branch.** `push` and `pull_request` both fire, so you
will see the same commit tested twice. Harmless but wasteful; if it annoys you,
narrow the `push` trigger to `branches: [main]` and let `pull_request` cover the
rest.

**Superseded runs are cancelled.**

```yaml
concurrency:
  group: pipeline-${{ github.ref }}
  cancel-in-progress: true
```

Three quick pushes to `main` would otherwise start three deploys racing each other
to the cluster, and the *oldest* could finish last — leaving old code live. This
keeps only the newest run per branch. You will see cancelled runs in the Actions
tab; that is the feature working.

---

## 2. Job `test` — unit tests

Runs on every push. About a minute.

| # | Step | What it does |
|---|---|---|
| 1 | `actions/checkout@v4` | clones the repo at your commit |
| 2 | `actions/setup-python@v5` | Python 3.12, with pip caching |
| 3 | Install dependencies | `pip install -r requirements.txt` |
| 4 | Run tests | `pytest -v --junitxml=test-results.xml` — 12 tests |
| 5 | Upload test results | `if: always()` — uploads even on failure |

The tests use in-memory SQLite, so no database service is needed. That is also
their limitation: they never touch the Dockerfile, which is why job 2 exists.

Step 5 runs `if: always()` on purpose. A test failure with no artifact means
reading raw logs; with the artifact, the failure is readable in the run summary.

**Nothing else starts until this passes.** `container` declares `needs: test`, and
`deploy` declares `needs: [test, container]`. Cheap checks first — never spend a
three-minute container build to learn something a one-minute test suite knew.

> The `pytest` invocation only works because of the root
> [conftest.py](conftest.py). Without it, pytest puts `test/` on `sys.path` and
> never the repository root, and collection fails with
> `ModuleNotFoundError: No module named 'app'`.

---

## 3. Job `container` — does the image actually work?

Runs on every push, after `test`. About three minutes.

| # | Step | What it proves |
|---|---|---|
| 1 | `actions/checkout@v4` | |
| 2 | `docker/setup-buildx-action@v3` | enables layer caching |
| 3 | Build image | the Dockerfile is valid; caches layers via `type=gha` |
| 4 | Start PostgreSQL | real `postgres:18`, polled with `pg_isready` |
| 5 | Run the application container | starts the image against that database |
| 6 | Wait for readiness | polls `/.well-known/ready` for **200** |
| 7 | Exercise the API | create, read, list, update, a 404, delete |
| 8 | Assert the container does not run as root | `docker exec todo-api id -un` |
| 9 | Container logs | `if: always()` — prints logs whatever happened |

**Why this job is not redundant with job 1.** Unit tests run in-process against
SQLite. They cannot see a missing `COPY`, a wrong `CMD`, a base image without the
right library, or a `.dockerignore` that excluded a file the app needs at runtime.
This job runs the actual artifact that will go to production, against the actual
database engine production uses.

**Step 6 is the meaningful gate**, not step 5. A container that started proves only
that a process launched. `/.well-known/ready` returns **503** until the database is
genuinely reachable, so a 200 here proves the app connected. Polling
`/.well-known/health` instead would prove nothing — it returns 200 even with the
database down, by design.

**Step 8 catches a silent regression.** If someone removes `USER appuser` from the
Dockerfile, everything still works — just as root, and nothing else in the
pipeline would notice.

On a branch or PR, the pipeline ends here. Green means the change is safe to
merge.

---

## 4. Job `deploy` — only on `main`

21 steps. About four minutes on a normal deploy, longer on the very first one.
It runs in the `production` environment, so it appears in the repo's
**Environments** view and is where you would add a required reviewer to make
deploys need a human approval.

### 4a. Prove we can talk to AWS (steps 1-4)

| # | Step | Failure means |
|---|---|---|
| 1 | `actions/checkout@v4` | |
| 2 | Check the AWS secrets are set | the GitHub secrets are missing or empty |
| 3 | Configure AWS credentials | |
| 4 | Verify the credentials work | `aws sts get-caller-identity` — keys invalid or expired |

Steps 2 and 4 exist because GitHub substitutes an **empty string** for a missing
secret instead of failing. The action then reports
`Could not load credentials from any providers`, which sounds like an AWS problem
and is actually an unset secret. Step 2 names the real cause and prints the
settings URL; it reports character counts (20 and 40 expected) so a truncated or
whitespace-padded paste is obvious.

### 4b. Is there anywhere to deploy to? (step 5)

**Step 5 — Preflight: does the infrastructure exist?** Checks three things:

```
aws eks describe-cluster     --name todo-cluster
aws ecr describe-repositories --repository-names todo-api
aws secretsmanager describe-secret --secret-id todo/database-url
```

**This pipeline never creates infrastructure.** That is
[terraform.yml](.github/workflows/terraform.yml), triggered deliberately. So on a
fresh account this job would otherwise fail four minutes later inside
`aws eks update-kubeconfig` with an opaque error. Instead it fails here in
seconds, printing the remedy: run the terraform workflow with `action = apply`.

See [devops.md §5](devops.md) for why infrastructure is separated, and
[terraform/README.md](terraform/README.md) for how to provision.

### 4c. Build and publish the image (steps 6-10)

| # | Step | Detail |
|---|---|---|
| 6 | Log in to Amazon ECR | |
| 7 | `docker/setup-buildx-action@v3` | |
| 8 | Resolve image tag | `<registry>/todo-api:<full git SHA>` |
| 9 | Check whether this commit is already built | `aws ecr describe-images` |
| 10 | Build and push image | `if: steps.exists.outputs.found == 'false'` |

**Tagged by commit SHA, never `latest`.** Two consequences you feel immediately:
you can always answer "what code is running?", and rollback is possible because
the previous tag still exists. With `latest`, both are gone.

**Step 9 exists because the ECR repository uses immutable tags** — pushing a tag
that already exists is rejected. That happens whenever you re-run a deploy for the
same commit, so the pipeline checks and reuses the existing image instead of
failing. Immutability is the point: a given SHA tag always refers to the same
bytes, so nobody can quietly replace what you reviewed.

Layer cache from job 2 (`type=gha`) makes this rebuild fast.

### 4d. Hand the credential over (steps 11-14)

| # | Step | Detail |
|---|---|---|
| 11 | Configure kubectl | `aws eks update-kubeconfig`, then `kubectl get nodes` |
| 12 | Install kustomize | |
| 13 | Ensure namespace exists | the Secret needs a namespace to live in |
| 14 | Sync database credentials from Secrets Manager | see below |

Step 11 ends with `kubectl get nodes` deliberately — it fails loudly with
`Unauthorized` if this IAM identity has no EKS access entry, rather than letting a
later step fail confusingly. The cluster's *creator* gets admin implicitly, so
this bites the second identity, not the first.

Step 14 is the whole secret-handling story:

```
Terraform generated the password
  -> stored it in AWS Secrets Manager
    -> this step reads it and creates a Kubernetes Secret
      -> the pod reads DATABASE_URL from that Secret
```

The password **never exists in this repository and never passes through GitHub**.
`::add-mask::` also registers it with the runner, so it is redacted even if a
later command echoes it. The `create --dry-run | apply` shape is what makes the
step idempotent — plain `kubectl create secret` fails once the Secret exists.

### 4e. Deploy (steps 15-18)

| # | Step | Detail |
|---|---|---|
| 15 | Render manifests | fills in `ACCOUNT_ID`, region, and the image tag |
| 16 | Apply manifests | `kubectl apply -k k8s/` |
| 17 | Wait for rollout | `kubectl rollout status --timeout=5m` |
| 18 | Roll back on failure | `if: failure() && steps.rollout.conclusion == 'failure'` |

**Step 17 is the real gate.** [k8s/deployment.yaml](k8s/deployment.yaml) sets
`maxUnavailable: 0`, so Kubernetes will not remove a working pod until a new one
passes its readiness probe. A broken image therefore *fails the rollout* instead
of replacing a working deployment. Watch it happen with:

```bash
kubectl get pods -n todo -w
```

New pod `ContainerCreating` → `Running` but `0/1` → `1/1` → only *then* an old pod
`Terminating`. That ordering is zero-downtime deployment.

**Step 18 is automatic rollback.** It prints diagnostics (pod list, deployment
description, last 100 log lines), runs `kubectl rollout undo`, waits for the old
version to be healthy again, then **still fails the build**. So a bad deploy
self-heals in about a minute while the build stays red — the site is fine, and you
still know something went wrong.

### 4f. Prove it from outside (steps 19-21)

| # | Step | Detail |
|---|---|---|
| 19 | Resolve public endpoint | polls for the load balancer hostname, 40 × 15s |
| 20 | Smoke test through the load balancer | polls for HTTP 200, 40 × 15s |
| 21 | Summary | `if: always()` — commit, image, cluster, URL table |

A green rollout only proves the pods are healthy *inside* the cluster. Step 20
proves the path a user actually takes — DNS → load balancer → target group → pod
— works end to end.

Both windows are generous (up to 10 minutes each) because the AWS
cloud-controller-manager provisions the NLB **asynchronously**. On a first deploy
the hostname is empty for a minute or two and then DNS takes a few more minutes to
propagate. On later deploys both steps pass almost immediately, since the load
balancer already exists.

---

## 5. Timeline

Approximate — these are estimates, not measurements.

```
push to main
0:00  test           ####                                  ~1 min
1:00  container      ############                           ~3 min
4:00  deploy         ################                       ~4 min
8:00  live
```

First-ever deploy: add 5-10 minutes for load balancer creation and DNS. Branch
push: ends at 4:00, no deploy.

---

## 6. Where it fails, and what it means

Diagnose in pipeline order. The failure is almost always the first red step.

| Failing step | Cause |
|---|---|
| Run tests | genuine test failure, or a local `.env` masking one — see [README.md](README.md#running-the-tests) |
| Build image | Dockerfile error, or a needed file excluded by [.dockerignore](.dockerignore) / not committed |
| Wait for readiness | the app cannot reach PostgreSQL; step 9's logs show why |
| Assert ... not run as root | `USER` was removed from the Dockerfile |
| Check the AWS secrets are set | GitHub secrets missing, misnamed, or added under Variables / Dependabot / Codespaces |
| Verify the credentials work | keys are present but invalid, expired, or revoked |
| Preflight | infrastructure not provisioned — run the terraform workflow |
| Configure kubectl (`Unauthorized`) | this IAM identity has no EKS access entry; add it to `cluster_admin_role_arns` |
| Wait for rollout | new pods never became ready — rollback already ran; see [k8s/README.md](k8s/README.md#troubleshooting) |
| Resolve public endpoint | public subnets missing the `kubernetes.io/role/elb=1` tag |
| Smoke test through the LB | pods healthy but the network path is broken — test with `kubectl port-forward` to isolate |

---

## 7. What this pipeline does not do

Deliberate omissions, so you are not surprised by them:

- **It never runs `terraform apply`.** Infrastructure is manual. [devops.md §5](devops.md).
- **It never runs database migrations.** [migrations/](migrations/) has no versions;
  the app calls `create_all()` at startup, which creates missing tables and
  **silently ignores changed columns**. Add a column to a model and production will
  not get it. This is the most likely thing to bite you.
- **It does not deploy to a staging environment.** There is only production.
- **It does not read ECR's vulnerability scan results.** Images are scanned on
  push; nothing gates on the findings.
- **It does not alert anyone.** A red build is something you have to go and look at.

---

## 8. After it is green

```bash
aws eks update-kubeconfig --region us-east-1 --name todo-cluster
URL=http://$(kubectl get svc todo-api -n todo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl "$URL/.well-known/health"
kubectl get pods -n todo
kubectl logs -n todo -l app.kubernetes.io/name=todo-api --tail=50
aws logs tail todo-api-logs --follow        # see cloudwatch.md
```

The image tag in the run summary is the full commit SHA, so you can always map
what is running back to a line of code.

**Remember to tear it down when you are done** — roughly $135/month if left
running. `./terraform/destroy.sh`, and read
[terraform/README.md](terraform/README.md#teardown) first for why order matters.

---

## Status

This describes the workflow as written. **The pipeline has never executed in
GitHub Actions**, and no EKS cluster has ever existed for this project, so the
timings are estimates and the deploy job's steps 5-21 are unproven against real
infrastructure. What has been verified locally: the 12 unit tests pass, the image
builds, and the job-2 sequence (Postgres 18 + container + readiness + CRUD +
non-root assertion) works.
