# Deployment scripts

Scripted version of [../deployment.md](../deployment.md): provisions EC2 + RDS,
configures the app under systemd behind nginx, and verifies it. Reusable across
accounts — everything account-specific lives in `deploy.env`.

## Quick start

```bash
cp deploy/deploy.env.example deploy/deploy.env
$EDITOR deploy/deploy.env          # credentials + region

./deploy/deploy.sh                 # provision, configure, verify
```

Tear it down when you're done — EC2 and RDS bill by the hour:

```bash
./deploy/teardown.sh
```

## Scripts

| Script | What it does |
|---|---|
| `deploy.sh` | Runs 01 → 02 → 03 in order |
| `01-provision-aws.sh` | Security groups, IAM role, RDS, key pair, EC2 |
| `02-configure-instance.sh` | Packages, code, venv, database, `.env`, systemd, nginx |
| `03-verify.sh` | Smoke-tests the deployment; non-zero exit on failure |
| `teardown.sh` | Deletes everything (asks for confirmation) |
| `lib.sh` | Shared helpers; sourced, not run |

All of them are **idempotent**. Re-running `01` adopts resources that already
exist rather than failing, and `02` converges the instance to the desired state,
so it doubles as the redeploy path:

```bash
./deploy/02-configure-instance.sh && ./deploy/03-verify.sh
```

## Credentials

`deploy.env` is gitignored. Two options, in order of preference:

```bash
AWS_PROFILE=my-sandbox          # 1. a named CLI profile, keys stay in ~/.aws
```

```bash
AWS_ACCESS_KEY_ID=...           # 2. keys inline -- convenient, less safe
AWS_SECRET_ACCESS_KEY=...
```

To deploy to a different account, change those values. Nothing else in the repo
holds credentials.

## Deploying a different stack, region, or app version

`STACK` prefixes every resource name (`${STACK}-db`, `${STACK}-ec2-sg`,
`${STACK}-api`, …), so two stacks can coexist in one account:

```bash
STACK=todo-staging
AWS_DEFAULT_REGION=eu-west-1
```

By default the instance clones `REPO_URL` at `REPO_BRANCH`, so **only committed
and pushed code is deployed**. To deploy your local working tree instead:

```bash
DEPLOY_LOCAL_TREE=1
```

That rsyncs the repo up, excluding `.git`, virtualenvs, and everything secret in
`deploy/`.

## Generated files (all gitignored)

| File | Contents |
|---|---|
| `deploy.env` | Your credentials and configuration |
| `.deploy-state` | Resource IDs, so `teardown.sh` knows what to delete |
| `.deploy-secrets` | The generated database password |
| `${STACK}-key.pem` | SSH private key for the instance |
| `.known_hosts` | Host keys, kept out of your `~/.ssh/known_hosts` |

The database password is generated on first run — 24 alphanumeric characters,
deliberately without punctuation, since RDS rejects some symbols and others would
need percent-encoding inside `DATABASE_URL`.

**Keep `.deploy-secrets` and the `.pem` for as long as the stack is up.** If you
lose the password you'll have to reset it with
`aws rds modify-db-instance --master-user-password`; if you lose the `.pem` you
cannot SSH in, and the key pair has to be deleted and the instance replaced.

## Verified

Run end to end on 2026-09-18 in `us-east-1`: Ubuntu 22.04.5 LTS on `t3.micro`,
PostgreSQL 18.6 on `db.t3.micro`. `01` was verified both creating resources from
scratch and adopting existing ones; `02` and `03` were verified against a live
instance. `teardown.sh` has **not** been run end to end — see the caveat in
[../deployment.md](../deployment.md#16-teardown).
