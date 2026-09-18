## **AWS Deployment Guide: FastAPI on EC2 + RDS PostgreSQL**

> **Verified end to end on 2026-09-18** in `us-east-1`: Ubuntu 22.04.5 LTS on
> `t3.micro`, PostgreSQL 18.6 on `db.t3.micro`, Python 3.10.12, watchtower 3.4.0.
> Every command below was executed against a live account. Anything not
> verified is marked as such.

**Want to skip the manual steps?** Everything below is scripted in
[deploy/](deploy/) — see [deploy/README.md](deploy/README.md):

```bash
cp deploy/deploy.env.example deploy/deploy.env   # then add credentials
./deploy/deploy.sh                               # provision, configure, verify
./deploy/teardown.sh                             # delete it all
```

The rest of this document explains what those scripts do, step by step, and is
the reference for doing it by hand or in the console.

This guide uses the AWS CLI, because the exact commands are reproducible. You
can do all of it in the console instead; where the console behaves differently,
there's a note.

**What you get:** uvicorn running under systemd, behind nginx on port 80, talking
to a private RDS PostgreSQL instance, shipping request logs to CloudWatch.

---

### **0. Prerequisites**

```bash
aws --version          # 2.x
aws sts get-caller-identity   # confirm the right account
export AWS_DEFAULT_REGION=us-east-1
```

You need permission to create EC2, RDS, and IAM resources.

Pick a database password now. **Use only letters and digits.** RDS forbids `/`,
`@`, `"`, and space in master passwords, and any of `@ : / ? # [ ] %` would have
to be percent-encoded inside `DATABASE_URL` — an easy way to create a connection
bug that looks like an auth failure.

```bash
export PGPASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
echo "$PGPASS"   # save this somewhere safe
```

> Do not use the `YourSecurePassword123!` placeholder that earlier versions of
> this guide suggested.

---

### **1. Create Security Groups**

Create these **before** RDS — the database needs a security group at creation
time.

```bash
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text)
MYIP=$(curl -s https://checkip.amazonaws.com)

# EC2 security group: SSH from your IP, HTTP and uvicorn from anywhere
EC2SG=$(aws ec2 create-security-group --group-name todo-ec2-sg \
  --description "Todo API EC2" --vpc-id $VPC --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id $EC2SG --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MYIP}/32}]" \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" \
  "IpProtocol=tcp,FromPort=8000,ToPort=8000,IpRanges=[{CidrIp=0.0.0.0/0}]"

# RDS security group: PostgreSQL from the EC2 security group only
RDSSG=$(aws ec2 create-security-group --group-name todo-rds-sg \
  --description "Todo API RDS" --vpc-id $VPC --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id $RDSSG --ip-permissions \
  "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$EC2SG}]"

echo "EC2 SG: $EC2SG   RDS SG: $RDSSG"
```

> **Do not open 5432 to `0.0.0.0/0`.** An earlier version of this guide suggested
> that, which both contradicts keeping the database private and exposes it to the
> internet. Sourcing the rule from the EC2 security group is the correct form and
> is what was verified here.

---

### **2. Create RDS PostgreSQL Database**

A **DB subnet group** is required. The console creates one implicitly; the CLI
does not, and a default VPC has no `default` DB subnet group — `create-db-instance`
fails without it.

```bash
# three subnets in different AZs from the default VPC
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC \
  --query 'Subnets[0:3].SubnetId' --output text)

aws rds create-db-subnet-group \
  --db-subnet-group-name todo-db-subnet-group \
  --db-subnet-group-description "Todo API RDS subnets" \
  --subnet-ids $SUBNETS
```

Confirm the instance class is orderable for the engine version you want —
`db.t3.micro` is not available for every PostgreSQL version:

```bash
aws rds describe-orderable-db-instance-options --engine postgres \
  --engine-version 18.6 --db-instance-class db.t3.micro \
  --query 'length(OrderableDBInstanceOptions)'
```

```bash
aws rds create-db-instance \
  --db-instance-identifier todo-db \
  --db-instance-class db.t3.micro \
  --engine postgres --engine-version 18.6 \
  --master-username todouser --master-user-password "$PGPASS" \
  --allocated-storage 20 --storage-type gp3 \
  --db-subnet-group-name todo-db-subnet-group \
  --vpc-security-group-ids $RDSSG \
  --no-publicly-accessible \
  --backup-retention-period 0 --no-multi-az

# takes several minutes
aws rds wait db-instance-available --db-instance-identifier todo-db

RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier todo-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "$RDS_ENDPOINT"
```

Start this and move on to the next steps while it provisions.

> `--backup-retention-period 0` disables automated backups. Fine for a test
> deployment; raise it for anything real.

---

### **3. Create the IAM Role for CloudWatch Logs**

Needed for the app's CloudWatch logging (step 9). Skip if you don't want it.

```bash
cat > /tmp/trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role --role-name todo-ec2-cloudwatch-role \
  --assume-role-policy-document file:///tmp/trust.json

cat > /tmp/logs-policy.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":[
 "logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents",
 "logs:DescribeLogStreams","logs:DescribeLogGroups"],"Resource":"*"}]}
EOF

aws iam put-role-policy --role-name todo-ec2-cloudwatch-role \
  --policy-name todo-cloudwatch-logs --policy-document file:///tmp/logs-policy.json

aws iam create-instance-profile --instance-profile-name todo-ec2-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name todo-ec2-profile --role-name todo-ec2-cloudwatch-role
```

---

### **4. Launch EC2 Instance**

```bash
aws ec2 create-key-pair --key-name todo-key --key-type rsa \
  --query KeyMaterial --output text > todo-key.pem
chmod 400 todo-key.pem

AMI=$(aws ec2 describe-images --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*' \
            'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)

SUBNET=$(echo $SUBNETS | awk '{print $1}')

IID=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro \
  --key-name todo-key --security-group-ids $EC2SG --subnet-id $SUBNET \
  --associate-public-ip-address \
  --iam-instance-profile Name=todo-ec2-profile \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=todo-api}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $IID
EC2_IP=$(aws ec2 describe-instances --instance-ids $IID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "$EC2_IP"
```

> `t3.micro` is the current-generation equivalent of `t2.micro` and is available
> in more AZs; either works. Check which one your account's free tier covers.
>
> Wait ~30–60s after `instance-running` before SSH — the instance is running
> before sshd is ready.

---

### **5. Connect to EC2 and Install Dependencies**

```bash
ssh -i todo-key.pem ubuntu@$EC2_IP

# --- on the instance ---
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get upgrade -y -o Dpkg::Options::=--force-confold
sudo apt-get install -y python3 python3-pip python3-venv git postgresql-client
```

> `DEBIAN_FRONTEND=noninteractive` and `--force-confold` keep `upgrade` from
> stopping on interactive config prompts.
>
> Ubuntu 22.04 ships the PostgreSQL **14** client. It connects to a PostgreSQL 18
> server fine (verified) — everything in step 7 works. Install
> `postgresql-client-18` from the PGDG repo only if you need version-matched
> client tooling.

---

### **6. Get the Code onto the Instance**

```bash
cd /home/ubuntu
git clone https://github.com/tmreddy/TodoPythonApp.git
cd TodoPythonApp

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

> The repository is `TodoPythonApp`, and every path below assumes
> `/home/ubuntu/TodoPythonApp`. Earlier versions of this guide said
> `PythonWebApp`, which made the systemd unit paths in step 10 point at a
> directory that does not exist.
>
> `git clone` only gets **committed and pushed** code. If you're deploying local
> changes, push them first, or copy the files up directly:
>
> ```bash
> # from your workstation
> rsync -av --exclude .venv --exclude .git \
>   -e "ssh -i todo-key.pem" ./ ubuntu@$EC2_IP:/home/ubuntu/TodoPythonApp/
> ```

---

### **7. Create the Database in RDS**

The instance created in step 2 has no `todo_db` database yet. From the EC2 box
(the RDS instance is private and only reachable from the EC2 security group):

```bash
export PGPASSWORD='<the password from step 0>'
psql -h <RDS_ENDPOINT> -U todouser -d postgres -c 'CREATE DATABASE todo_db;'

# confirm
psql -h <RDS_ENDPOINT> -U todouser -d postgres -c '\l' | grep todo_db
```

> Alternatively pass `--db-name todo_db` to `create-db-instance` in step 2 and
> skip this step entirely.
>
> You do **not** need to run migrations. The app calls
> `Base.metadata.create_all()` at startup and creates the `todos` table itself.
> `alembic.ini` and `migrations/` are present but unused by this deployment path.

---

### **8. Set Environment Variables**

```bash
cd /home/ubuntu/TodoPythonApp
cat > .env <<EOF
DATABASE_URL=postgresql://todouser:${PGPASS}@${RDS_ENDPOINT}:5432/todo_db
AWS_DEFAULT_REGION=us-east-1
CLOUDWATCH_LOG_GROUP=todo-api-logs
EOF
chmod 600 .env
```

`DATABASE_URL` is required — the app raises at startup without it and does not
fall back to SQLite. `AWS_DEFAULT_REGION` is what enables CloudWatch logging.

To load it into your current shell for a manual run:

```bash
set -a; . ./.env; set +a
echo "$DATABASE_URL"
```

> Use `set -a; . ./.env; set +a`, not `export $(cat .env | xargs)`. The `xargs`
> form word-splits on spaces and mangles quotes and `#`, so it silently corrupts
> any value that isn't simple. It happens to work for an alphanumeric password,
> which is why the bug hides until someone uses a password with punctuation.

**Verifying `DATABASE_URL`:** it must be a full SQLAlchemy URL starting with
`postgresql://`. Pasting only the hostname produces a startup `RuntimeError`
about a missing scheme, and an empty value produces
`sqlalchemy.exc.ArgumentError: Could not parse SQLAlchemy URL`. The app validates
the value at startup and reports which of the two is wrong.

---

### **9. Run the Application (Development)**

```bash
cd /home/ubuntu/TodoPythonApp
source venv/bin/activate
set -a; . ./.env; set +a
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Check it:

```bash
curl http://localhost:8000/.well-known/health
# {"status":"ok","database":"connected"}
```

If `database` reports `disconnected`, the app is up but RDS is unreachable — see
Troubleshooting. Note the endpoint returns **200 either way**, so check the body,
not the status code.

Then stop it with Ctrl-C and set up systemd.

---

### **10. Production Setup**

#### **A. systemd for auto-restart**

```bash
sudo tee /etc/systemd/system/todoapp.service > /dev/null <<'EOF'
[Unit]
Description=Todo FastAPI Application
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/TodoPythonApp
Environment="PATH=/home/ubuntu/TodoPythonApp/venv/bin:/usr/local/bin:/usr/bin:/bin"
EnvironmentFile=/home/ubuntu/TodoPythonApp/.env
ExecStart=/home/ubuntu/TodoPythonApp/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable todoapp
sudo systemctl start todoapp
systemctl is-active todoapp     # -> active
```

> **Use `sudo tee`, not `sudo cat >`.** Earlier versions of this guide used
> `sudo cat > /etc/systemd/system/todoapp.service <<'EOF'`, which **fails with
> `Permission denied`** — your shell opens the output file as `ubuntu` before
> `sudo` ever runs, so `sudo` applies to `cat`, not to the redirect. This was
> confirmed to fail on a clean instance.
>
> The `PATH` also has to include the system directories. Setting it to only
> `venv/bin` leaves the service without `/usr/bin`.

#### **B. nginx as a reverse proxy**

```bash
sudo apt-get install -y nginx

sudo tee /etc/nginx/sites-available/todo > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/todo /etc/nginx/sites-enabled/todo
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
```

> `server_name _;` accepts any Host header, so you don't have to hardcode the
> public IP. Removing the packaged `default` site stops it from shadowing yours.
>
> A separate `location /.well-known` block isn't needed — `location /` already
> proxies those paths.

Now reachable on port 80:

```bash
curl http://$EC2_IP/.well-known/health
```

---

### **11. Verify CloudWatch Logging**

With `AWS_DEFAULT_REGION` set (step 8) and the instance profile attached
(step 3), request logs go to the `todo-api-logs` group.

> If CloudWatch Logs is new to you, [cloudwatch.md](cloudwatch.md) covers the
> concepts and the search commands from scratch.

```bash
# on the instance -- should show no CloudWatch warning
sudo journalctl -u todoapp -n 20 --no-pager | grep -i cloudwatch

# generate traffic, then wait ~60s for watchtower to flush its buffer
curl -s http://localhost:8000/.well-known/health

# from your workstation
aws logs describe-log-streams --log-group-name todo-api-logs \
  --query 'logStreams[].logStreamName'
aws logs tail todo-api-logs --follow
```

> watchtower batches events and flushes about once a minute, so an empty log
> group right after startup is expected. The group is created as soon as the
> handler initialises; events follow on the first flush.
>
> The log group is `todo-api-logs`. An earlier version of this guide said
> `aws logs tail /aws/lambda/todo-api-logs`, which is a Lambda path and will
> never match this application's group.

**Requires watchtower 3.x** (`requirements.txt` pins `>=3.0.0`). watchtower 3.x
removed the `region_name` argument in favour of a preconfigured boto3 client;
`app/main.py` builds the handler accordingly. If you pin an older watchtower,
CloudWatch logging silently degrades to stdout-only.

---

### **12. Test Everything**

```bash
ssh -i todo-key.pem ubuntu@$EC2_IP

sudo systemctl status todoapp
sudo journalctl -u todoapp -f

curl http://localhost:8000/.well-known/health
curl http://localhost/.well-known/health          # through nginx

curl -X POST http://localhost/todos \
  -H 'Content-Type: application/json' \
  -d '{"title":"deployment check","description":"it works"}'
curl http://localhost/todos
```

From outside, replace `localhost` with the public IP. Swagger UI is at
`http://$EC2_IP/.well-known/swagger`.

> If external requests fail while `localhost` works on the instance, check the
> security group first, then whether your own network filters outbound traffic —
> a corporate proxy intercepting requests to a bare public IP looks exactly like
> a broken deployment.

---

### **13. Configure a Load Balancer Health Check (Optional)**

*Not verified in this run — no load balancer was created.*

If you put an ALB in front, point the target group health check at
`GET /.well-known/health` expecting `200`. Because that endpoint returns 200 even
when the database is down, an ALB check will not detect database failure; match
on the response body if you need that.

---

### **14. Troubleshooting**

* **`CloudWatch handler unavailable: ... unexpected keyword argument 'region_name'`**
  — watchtower 3.x dropped `region_name`. Upgrade to the pinned requirements
  (`watchtower>=3.0.0`) and use the current `app/main.py`, which passes a
  `boto3_client` instead. **Setting `AWS_REGION` does not fix this**; the region
  is not the problem, despite what the warning text suggests.

* **`CloudWatch handler unavailable: You must specify a region`** — this one *is*
  a region problem. Set `AWS_DEFAULT_REGION` in `.env` and restart. The app logs
  a warning and keeps running with stdout logging either way; CloudWatch failures
  are never fatal.

* **Empty CloudWatch log group** — wait ~60s. watchtower buffers.

* **`Permission denied` writing to `/etc/...`** — you used `sudo cat > file`.
  Use `sudo tee file` (see step 10A).

* **RDS auth/connection failures** — `password authentication failed for user` or
  `no pg_hba.conf entry for host` means wrong credentials in `DATABASE_URL`, or
  the RDS security group isn't allowing the EC2 instance. Confirm the RDS group
  has a 5432 rule sourced from the EC2 security group. RDS manages `pg_hba.conf`
  internally, so these are always fixed via credentials or security groups.
  Also check for unencoded punctuation in the password inside `DATABASE_URL`.

* **`health` reports `"database":"disconnected"`** — the app is fine, the DB link
  isn't. Test directly: `psql -h $RDS_ENDPOINT -U todouser -d todo_db -c 'select 1'`.

* **Service won't start** — `sudo journalctl -u todoapp -n 50`. Most often a bad
  `EnvironmentFile` path or a `DATABASE_URL` typo.

---

### **15. Quick Reference**

```bash
# Logs
sudo journalctl -u todoapp -n 50
sudo journalctl -u todoapp -f

# Service control
sudo systemctl restart todoapp
sudo systemctl stop todoapp
systemctl is-active todoapp

# Is port 8000 listening?
sudo ss -tulnp | grep 8000

# nginx
sudo tail -f /var/log/nginx/error.log
sudo nginx -t
sudo systemctl reload nginx
```

> Use `ss`, not `netstat` — `net-tools` is **not installed** on Ubuntu 22.04, so
> the `netstat` command in earlier versions of this guide fails with
> `command not found`. Similarly prefer `systemctl reload nginx` over
> `nginx -s reload` so systemd keeps tracking the process state.

---

### **16. Teardown**

Delete everything when you're done — RDS and EC2 bill by the hour.

Scripted: `./deploy/teardown.sh` (asks for confirmation; `--yes` to skip it).

> The commands below are the standard delete calls and the ordering is correct,
> but unlike the rest of this guide they were **not** executed end to end during
> verification — the stack was left running. Watch for dependency-order errors on
> the security groups if an ENI is slow to detach.

```bash
aws ec2 terminate-instances --instance-ids $IID
aws ec2 wait instance-terminated --instance-ids $IID

aws rds delete-db-instance --db-instance-identifier todo-db \
  --skip-final-snapshot --delete-automated-backups
aws rds wait db-instance-deleted --db-instance-identifier todo-db
aws rds delete-db-subnet-group --db-subnet-group-name todo-db-subnet-group

# security groups: RDS group first, it references the EC2 group
aws ec2 delete-security-group --group-id $RDSSG
aws ec2 delete-security-group --group-id $EC2SG

aws ec2 delete-key-pair --key-name todo-key && rm -f todo-key.pem

aws iam remove-role-from-instance-profile \
  --instance-profile-name todo-ec2-profile --role-name todo-ec2-cloudwatch-role
aws iam delete-instance-profile --instance-profile-name todo-ec2-profile
aws iam delete-role-policy --role-name todo-ec2-cloudwatch-role \
  --policy-name todo-cloudwatch-logs
aws iam delete-role --role-name todo-ec2-cloudwatch-role

aws logs delete-log-group --log-group-name todo-api-logs
```

> Order matters: terminate the instance before deleting its security group, and
> delete the RDS group before the EC2 group it references.

---

### **17. Cost**

- **EC2** `t3.micro` — free tier covers 750 h/month for 12 months
- **RDS** `db.t3.micro` — free tier covers 750 h/month for 12 months
- **Storage** — 20 GB EBS + 20 GB RDS, both within free-tier allowances
- **CloudWatch Logs** — first 5 GB ingest/month free

Roughly $0 inside the free tier. Outside it, expect a few dollars a day for the
two instances, so run the teardown in step 16.
