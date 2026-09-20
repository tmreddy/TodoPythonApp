# DevOps, end to end

Assumes you know Python and Git, and nothing about containers, Kubernetes, CI/CD
or Terraform. It walks the whole cycle for *this* repository — every file it
names is real and you can open it.

Read it in order. Sections 1-4 are concepts, 5 onwards is doing.

---

## 1. What problem any of this solves

Running the app on your laptop is one command:

```bash
uvicorn app.main:app --port 8000
```

Getting that same app to run reliably somewhere other people can reach it raises
questions your laptop never asked:

| Question | The practice that answers it | Here |
|---|---|---|
| Does the change break anything? | Continuous Integration | [pipeline.yml](.github/workflows/pipeline.yml) |
| Does it run the same everywhere? | Containers | [Dockerfile](Dockerfile) |
| Where do the servers come from? | Infrastructure as Code | [terraform/](terraform/) |
| Who restarts it when it dies? | Orchestration | [k8s/](k8s/) |
| How does new code get out there? | Continuous Deployment | [pipeline.yml](.github/workflows/pipeline.yml) |
| What is it doing right now? | Observability | [cloudwatch.md](cloudwatch.md) |

DevOps is not a tool. It is those six answers written down as code so a machine
performs them identically every time, instead of a person performing them
differently at 2am.

---

## 2. The cycle in one picture

```
  you                     GitHub                        AWS
   |                        |                            |
   |  git push              |                            |
   +----------------------->|                            |
                            |  1. run the tests          |
                            |  2. build a container      |
                            |     and smoke test it      |
                            |                            |
                            |  main only:                |
                            |  3. push image ----------->|  ECR (registry)
                            |  4. tell Kubernetes -----> |  EKS (cluster)
                            |                            |    |
                            |                            |    +-> pods running your image
                            |                            |         |
                            |  5. smoke test the         |         +-> RDS (database)
                            |     public URL <-----------|         +-> CloudWatch (logs)
                            |                            |
```

Steps 1-5 are one file: [pipeline.yml](.github/workflows/pipeline.yml). It takes
6-8 minutes.

**The boxes on the right — ECR, EKS, RDS — are created separately**, by Terraform,
and only when you deliberately ask. Section 5 explains why.

---

## 3. Vocabulary

Enough to read the rest. Skip anything you already know.

**Image** — a frozen filesystem plus a start command. Built once, byte-identical
everywhere. `docker build` produces one; [Dockerfile](Dockerfile) is the recipe.

**Container** — a running image. Your laptop, CI and production all run the *same
image*, which is what "works on my machine" stops being an excuse.

**Registry** — where images live, like a package registry for containers. AWS's is
**ECR**. Images are addressed `registry/repo:tag`.

**Tag** — the version label. This repo tags by **git commit SHA**, never `latest`.
With `latest` you cannot answer "what code is in production?" and you cannot roll
back, because there is no earlier tag to go back to.

**Orchestrator** — the thing that runs containers across many machines, restarts
them when they die, and replaces them during a deploy. **Kubernetes**; AWS's
managed flavour is **EKS**.

**Pod** — Kubernetes' smallest unit: one or more containers scheduled together.
Here, one pod = one copy of the API. Pods are disposable and get deleted
constantly; that is normal, not a fault.

**Deployment** — "keep N healthy pods of this image running." You never create
pods directly; you declare a Deployment and it creates them.

**Service** — a stable network address in front of a set of pods. Individual pod
IPs change every restart, so nothing addresses pods directly.

**Namespace** — a folder inside the cluster. Everything here is in `todo`.

**Declarative** — you describe the desired end state; the system works out the
steps. `kubectl apply` does not mean "do this"; it means "make reality look like
this." Terraform is the same idea for cloud resources. This is why both are safe
to re-run.

**Idempotent** — running it twice has the same effect as once. Everything in this
repo is meant to be.

**IaC (Infrastructure as Code)** — your VPC, cluster and database defined in files
in git, reviewed in pull requests, created by a tool. Nobody clicks in a console,
so nothing is undocumented.

**CI vs CD** — CI is "prove the change is good" (tests, build). CD is "put it
live." Same pipeline, different jobs, and CD only runs if CI passed.

---

## 4. What happens when you push

Every branch is tested. Only `main` deploys.

```
push to any branch
  |
  +-- job: test              ~1 min
  |     pytest, 12 tests, SQLite in memory
  |     FAILS -> stop. nothing else runs.
  |
  +-- job: container         ~3 min   (needs: test)
  |     build the image
  |     start real PostgreSQL 18
  |     run the image against it
  |     poll /.well-known/ready until 200
  |     full CRUD + assert a 404
  |     assert the container is not running as root
  |     FAILS -> stop.
  |
  +-- job: deploy            ~4 min   (needs: test, container)
        if: branch == main AND event == push
          |
          +-- preflight: does the infrastructure exist?
          +-- push image tagged with the commit SHA
          +-- read the DB password from Secrets Manager -> k8s Secret
          +-- kubectl apply -k k8s/
          +-- wait for the rollout
          |     FAILED -> kubectl rollout undo, then fail the build
          +-- curl the public load balancer URL
```

That is the summary. [pipeline-flow.md](pipeline-flow.md) traces all 35 steps
individually — what each one proves, and what a failure at each one means.

Three things about that shape are the actual lessons:

**The gate is ordered and cheap-first.** Unit tests take a minute and catch most
mistakes, so they run before the three-minute container build. Never spend
expensive minutes to learn something a cheap check knew.

**The container job exists because passing unit tests does not mean the container
works.** The tests run in-process on SQLite and never touch the Dockerfile. A
missing `COPY`, a wrong `CMD`, a bad base image — the unit suite sees none of it.
This job caught exactly that class of bug when it was written.

**A failed rollout rolls itself back.** `kubectl rollout undo` runs automatically,
so a bad deploy self-heals in seconds instead of leaving crash-looping pods while
someone gets paged. This works because
[k8s/deployment.yaml](k8s/deployment.yaml) sets `maxUnavailable: 0` — Kubernetes
refuses to remove a working pod until a new one is genuinely healthy, so a broken
image *fails* the rollout rather than replacing a working deployment.

---

## 5. Pushing does NOT create infrastructure

The question everyone asks first, so: **no.** Push to `main` and the pipeline
builds, tests and deploys the *application*. It never runs `terraform apply`.

That is deliberate, not an omission.

| | Application deploy | Infrastructure change |
|---|---|---|
| Frequency | many times a day | rarely |
| Worst case | pods crash-loop | the database is deleted |
| Recovery | automatic, seconds | restore from backup, if you have one |
| So | automate it | require a human |

An accidental `terraform apply` from a bad merge can destroy a database. There is
no undo. The industry compromise, and what this repo does: **plans are automatic,
applies are manual.**

[terraform.yml](.github/workflows/terraform.yml) posts a plan on every pull
request touching `terraform/**` so you can read what *would* change, and never
applies by itself — you go to **Actions → terraform → Run workflow** and pick
`apply` deliberately.

`destroy` goes one step further and makes you type the word `destroy` in the
confirm box. That asymmetry is on purpose: `apply` is convergent, so running it
twice does nothing the first run did not, and a mistake is fixable by correcting
the config and applying again. `destroy` deletes the database permanently.

If you push to `main` before provisioning, the deploy job's preflight step fails
in seconds with the remedy printed in the log, instead of failing four minutes
later inside `aws eks update-kubeconfig`.

---

## 6. Concept → file

| Concept | File | Read the comments in it for why |
|---|---|---|
| Reproducible build | [Dockerfile](Dockerfile) | multi-stage, non-root, layer caching |
| Local dev stack | [docker-compose.yml](docker-compose.yml) | app + PostgreSQL in one command |
| Build exclusions | [.dockerignore](.dockerignore) | keeps `.env` and state files out of images |
| Test + build + deploy | [.github/workflows/pipeline.yml](.github/workflows/pipeline.yml) | the whole CI/CD flow |
| Infra plan/apply/destroy | [.github/workflows/terraform.yml](.github/workflows/terraform.yml) | manual gate, PR plan comments |
| Network | [terraform/vpc.tf](terraform/vpc.tf) | why nodes are in public subnets |
| Cluster | [terraform/eks.tf](terraform/eks.tf) | node group, addons, access entries |
| Pod AWS identity | [terraform/irsa.tf](terraform/irsa.tf) | IRSA instead of static keys |
| Database + secret | [terraform/rds.tf](terraform/rds.tf) | generated password, Secrets Manager |
| Registry | [terraform/ecr.tf](terraform/ecr.tf) | immutable tags |
| Workloads | [k8s/](k8s/) | see [k8s/README.md](k8s/README.md) |
| Health signals | [app/main.py](app/main.py) | `/health` (liveness) vs `/ready` (readiness) |
| Logs | [cloudwatch.md](cloudwatch.md) | from scratch |

Two reference docs go deeper: [terraform/README.md](terraform/README.md) for
infrastructure, [k8s/README.md](k8s/README.md) for the manifests.

---

## 7. First-time setup, in order

Order matters: you cannot deploy into a cluster that does not exist.

### Step 0 — locally first, no AWS

Prove the container works before paying for anything.

```bash
docker compose up --build
curl http://localhost:8000/.well-known/ready
# {"status":"ready","database":"connected"}
docker compose down -v
```

If this fails, nothing downstream will work. Fix it here, where the feedback loop
is 30 seconds and free.

One likely snag: if you followed [README.md](README.md) step 1 and still have that
standalone `todo` PostgreSQL container running, it holds port 5432 and Compose
fails with `Bind for 0.0.0.0:5432 failed: port is already allocated`. Stop it
first (`docker stop todo`), or drop the `5432:5432` mapping from
[docker-compose.yml](docker-compose.yml) — the app reaches PostgreSQL over the
Compose network either way, and that port is published only so you can attach
`psql` from the host.

### Step 1 — AWS credentials in GitHub

**Settings → Secrets and variables → Actions → New repository secret:**

| Name | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | your access key |
| `AWS_SECRET_ACCESS_KEY` | your secret key |

Two things worth knowing:

- Repository secrets are write-only in the UI and masked in logs, but any
  workflow on any branch can use them. On a public repo, review who can open PRs.
- Long-lived access keys are the *simple* option, not the good one. The better
  one is **OIDC**: GitHub proves its identity to AWS per-run and gets temporary
  credentials, so there is no key to leak or rotate. Section 12.

### Step 2 — provision the infrastructure (once, ~15-20 min)

**Actions → terraform → Run workflow**, `action = apply`. Leave the confirm box
empty — it is only required for `destroy`.

Or locally:

```bash
cd terraform
terraform init
terraform plan          # read this
terraform apply
```

Creates 40 resources: VPC, EKS cluster, 2 worker nodes, RDS PostgreSQL, ECR
repository, IAM roles, log groups. The EKS control plane alone takes 10-15
minutes; that is normal.

### Step 3 — deploy the application

```bash
git push origin main
```

Watch it in the **Actions** tab. The deploy job prints the public URL, and it also
appears in the run summary.

### Step 4 — see it working

```bash
aws eks update-kubeconfig --region us-east-1 --name todo-cluster
kubectl get pods -n todo
URL=http://$(kubectl get svc todo-api -n todo \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl "$URL/.well-known/health"
curl -X POST "$URL/todos" -H 'Content-Type: application/json' \
  -d '{"title":"deployed","description":"from my laptop"}'
curl "$URL/todos"
```

---

## 8. The daily loop

Once set up, this is the whole job:

```bash
git checkout -b my-change
# edit code, add a test
pytest                                  # locally first
git commit -am "add thing" && git push  # CI runs on the branch

# open a PR, get it reviewed, merge to main
# -> pipeline deploys automatically, no further action
```

**You never run `terraform apply` or `kubectl apply` in the daily loop.** Those are
setup and infrastructure-change operations. Doing them by hand routinely means
the cluster no longer matches git, and the next automated deploy silently
overwrites whatever you did — the failure mode called *configuration drift*.

---

## 9. Watching it run

The single most useful habit is watching a deploy happen:

```bash
kubectl get pods -n todo -w
```

Push a change and watch the columns. You will see a new pod appear as
`ContainerCreating`, become `Running` but `0/1` ready, flip to `1/1`, and only
then an old pod start `Terminating`. That ordering *is* zero-downtime deployment,
and seeing it once explains readiness probes better than any diagram.

```bash
kubectl logs -n todo -l app.kubernetes.io/name=todo-api -f --all-containers
kubectl top pods -n todo                # CPU/memory (needs metrics-server)
kubectl get hpa -n todo                 # is autoscaling working?
kubectl describe pod -n todo <pod>       # why isn't it starting?
kubectl get events -n todo --sort-by=.lastTimestamp
```

Application logs also go to CloudWatch — searchable, and they survive the pod:

```bash
aws logs tail todo-api-logs --follow
```

`kubectl logs` shows what a *living* pod printed. CloudWatch shows what a pod
printed before it died, which is usually the interesting case.
[cloudwatch.md](cloudwatch.md) covers querying it properly.

---

## 10. When it breaks

Diagnose in pipeline order — the failure is almost always at the first stage that
went red.

**Tests fail in CI, pass locally.** Usually environment. The known case in this
repo is the reverse — `test_config.py::test_missing_database_url` passes in CI and
fails locally if you have a `.env`, because `load_dotenv()` reads the value back
off disk (documented in [README.md](README.md#running-the-tests)). To tell an
environment problem from an ordering problem, run the failing file on its own:

```bash
pytest test/test_config.py -v
```

Passes alone but fails in the full run → shared state between tests.

**Build fails in CI, works locally.** Check [.dockerignore](.dockerignore) — a
file you rely on may be excluded from the build context. Also confirm the file is
actually committed; CI only has what git has.

**Deploy fails at preflight.** The infrastructure does not exist. Section 7 step 2.

**Deploy fails at "Wait for rollout".** The new pods are not becoming ready. The
rollback already happened, so the site is fine; now find out why:

```bash
kubectl get pods -n todo
kubectl logs -n todo <pod> --previous    # logs from the crashed container
kubectl describe pod -n todo <pod>       # events, probe failures
```

[k8s/README.md](k8s/README.md#troubleshooting) explains what each of the common
pod statuses — `ImagePullBackOff`, `CreateContainerConfigError`,
`CrashLoopBackOff`, running-but-never-Ready — actually means here.

**Deploy is green but the URL does not answer.** The pods are healthy inside the
cluster, so it is the network path. Bypass the load balancer to prove it:

```bash
kubectl port-forward -n todo svc/todo-api 8080:80
curl http://localhost:8080/.well-known/health
```

Works via port-forward but not via the URL → load balancer or subnet tags. Fails
both ways → the app.

**`kubectl` says `Unauthorized`.** Your IAM identity has no EKS access entry. Add
its ARN to `cluster_admin_role_arns` in
[terraform/variables.tf](terraform/variables.tf) and re-apply. Note the *creator*
of the cluster always has access, so this bites the second person, not the first.

---

## 11. Tearing it down

This stack costs roughly **$135/month** if left running. Destroy it when you are
not using it — nothing here holds data you cannot recreate.

```bash
./terraform/destroy.sh
```

Or **Actions → terraform → Run workflow**, `action = destroy`,
`confirm = destroy`.

**Do not just run `terraform destroy`.** It hangs ~20 minutes and fails with
`DependencyViolation`, and the reason is a genuinely useful lesson:

> The Kubernetes Service created a load balancer by asking AWS directly, through
> the cluster's cloud-controller-manager. **Terraform has no record of it.** That
> load balancer owns network interfaces inside your subnets, and AWS refuses to
> delete a subnet — so also the VPC — while an ENI is attached.

Generalised: **anything that creates cloud resources outside your IaC tool
becomes something your IaC tool cannot clean up.** Kubernetes Services, Helm
charts, console clicks. It is the single most common way a destroy gets stuck.

So the correct order is Kubernetes first, then Terraform, which is exactly what
[terraform/destroy.sh](terraform/destroy.sh) does. Full detail and the manual
sequence: [terraform/README.md](terraform/README.md#teardown).

**Always verify afterwards.** A forgotten load balancer bills silently:

```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws eks list-clusters
```

`destroy.sh` runs these for you as its last step.

---

## 12. What is deliberately missing

Every real pipeline has gaps. Knowing yours is the difference between a learning
setup and a cargo cult. These are the ones here, roughly in the order you would
fix them.

**One environment.** `main` deploys straight to production. A real setup has
staging: `develop` → staging, `main` → production, with the same manifests
parameterised per environment. That is what Kustomize *overlays* are for, and the
flat [k8s/](k8s/) layout here becomes `base/` + `overlays/staging/` +
`overlays/production/`.

**No database migrations.** [migrations/](migrations/) contains only `env.py` — no
versions. The app calls `create_all()` at startup, which creates missing tables
and **silently ignores changed columns**. Add a column to a model and production
will not get it. This is the most likely thing to bite you first. Fix: generate
Alembic revisions, run `alembic upgrade head` as a Kubernetes **Job** in the
pipeline before the rollout.

**Long-lived AWS keys.** Rotate them on a schedule, and prefer replacing them
with OIDC: create an IAM role trusting `token.actions.githubusercontent.com`,
scoped to this repository, then swap the `aws-access-key-id` inputs in both
workflows for `role-to-assume` plus `permissions: id-token: write`. No secret to
leak.

**Local Terraform state.** `terraform.tfstate` on one laptop. Two people running
`apply` at once corrupts it. Fix: the S3 backend block in
[terraform/versions.tf](terraform/versions.tf), with state locking.

**No HTTPS.** Plain HTTP over an NLB. Real TLS needs a domain, an ACM
certificate, and an ALB Ingress — path in
[k8s/README.md](k8s/README.md#upgrading-to-an-alb-ingress).

**No alerting.** Logs and metrics exist; nothing tells you when they go wrong. The
smallest useful addition is a CloudWatch alarm on the app log group's ERROR count
wired to an SNS topic.

**No image scanning gate.** ECR scans on push, but the pipeline never reads the
result. A step that fails on HIGH/CRITICAL findings is a few lines.

**No load testing.** You cannot know whether the HPA thresholds are right without
generating load. `hey` or `k6` against the public URL, watching
`kubectl get hpa -n todo`, is a genuinely interesting experiment.

---

## 13. Honest status

Verified: `pytest` passes (12 tests), `docker compose up --build` brings up the
app against real PostgreSQL 18 and serves `/ready`, `/health` and full CRUD with
the container running as `appuser` rather than root, `terraform validate` and
`terraform plan` succeed against a real AWS account (40 resources to add), and
`kubectl kustomize k8s/` renders all 7 manifests.

**Not verified:** `terraform apply` has never been run, no EKS cluster has ever
existed for this project, the manifests have never been applied to a live
cluster, and the pipeline has never executed in GitHub Actions.

So expect the first real run to hit something — an IAM permission, an
unsupported engine version, a pod that will not schedule. That is not a defect in
these files; it is what a first deploy is. The troubleshooting sections exist
because those are the failures worth predicting.
