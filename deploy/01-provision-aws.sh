#!/usr/bin/env bash
# Create the AWS resources: security groups, RDS, IAM role, key pair, EC2.
# Safe to re-run -- anything that already exists is adopted, not recreated.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config
require_tools
check_identity

# --- VPC and subnets --------------------------------------------------------

VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
        --query 'Vpcs[0].VpcId' --output text)
[ "$VPC" != "None" ] || die "no default VPC in $AWS_DEFAULT_REGION -- set one up or adapt this script"
ok "default VPC $VPC"
state_set VPC "$VPC"

# Three subnets in distinct AZs, needed for the DB subnet group.
SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
            --query 'Subnets[0:3].SubnetId' --output text)
[ -n "$SUBNETS" ] || die "no subnets found in $VPC"
FIRST_SUBNET=$(printf '%s' "$SUBNETS" | awk '{print $1}')

# --- security groups --------------------------------------------------------

find_sg() {
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$VPC" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null
}

# Ignore the "rule already exists" error so re-runs are quiet.
authorize() {
  local out
  if out=$(aws ec2 authorize-security-group-ingress "$@" 2>&1); then
    return 0
  fi
  case "$out" in
    *InvalidPermission.Duplicate*) return 0 ;;
    *) die "authorize-security-group-ingress failed: $out" ;;
  esac
}

log "security groups"
EC2SG=$(find_sg "$EC2_SG_NAME")
if [ "$EC2SG" = "None" ] || [ -z "$EC2SG" ]; then
  EC2SG=$(aws ec2 create-security-group --group-name "$EC2_SG_NAME" \
            --description "$STACK API EC2" --vpc-id "$VPC" \
            --query GroupId --output text)
  ok "created $EC2_SG_NAME ($EC2SG)"
else
  skip "$EC2_SG_NAME exists ($EC2SG)"
fi

CIDR="${SSH_CIDR:-}"
if [ -z "$CIDR" ]; then
  MYIP=$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
  [ -n "$MYIP" ] || die "could not detect your public IP -- set SSH_CIDR in deploy.env"
  CIDR="${MYIP}/32"
fi
ok "SSH allowed from $CIDR"

authorize --group-id "$EC2SG" --ip-permissions \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$CIDR,Description=SSH}]"
authorize --group-id "$EC2SG" --ip-permissions \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP}]"
authorize --group-id "$EC2SG" --ip-permissions \
  "IpProtocol=tcp,FromPort=${APP_PORT},ToPort=${APP_PORT},IpRanges=[{CidrIp=0.0.0.0/0,Description=uvicorn}]"

RDSSG=$(find_sg "$RDS_SG_NAME")
if [ "$RDSSG" = "None" ] || [ -z "$RDSSG" ]; then
  RDSSG=$(aws ec2 create-security-group --group-name "$RDS_SG_NAME" \
            --description "$STACK API RDS" --vpc-id "$VPC" \
            --query GroupId --output text)
  ok "created $RDS_SG_NAME ($RDSSG)"
else
  skip "$RDS_SG_NAME exists ($RDSSG)"
fi

# Postgres reachable only from the EC2 security group, never from 0.0.0.0/0.
authorize --group-id "$RDSSG" --ip-permissions \
  "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$EC2SG,Description=From EC2 SG}]"

state_set EC2SG "$EC2SG"
state_set RDSSG "$RDSSG"

# --- IAM role for CloudWatch logs -------------------------------------------

log "IAM role for CloudWatch logs"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  skip "role $ROLE_NAME exists"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    >/dev/null
  ok "created role $ROLE_NAME"
fi

aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "${STACK}-cloudwatch-logs" \
  --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams","logs:DescribeLogGroups"],"Resource":"*"}]}'
ok "policy attached"

if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null 2>&1; then
  skip "instance profile $INSTANCE_PROFILE exists"
else
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE" \
    --role-name "$ROLE_NAME"
  ok "created instance profile $INSTANCE_PROFILE"
  sleep 10  # let it propagate before run-instances references it
fi
state_set ROLE_NAME "$ROLE_NAME"
state_set INSTANCE_PROFILE "$INSTANCE_PROFILE"

# --- RDS --------------------------------------------------------------------

log "RDS PostgreSQL"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  skip "subnet group $DB_SUBNET_GROUP exists"
else
  # Required by the CLI: a default VPC has no default DB subnet group.
  aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "$STACK RDS subnets" \
    --subnet-ids $SUBNETS >/dev/null
  ok "created subnet group $DB_SUBNET_GROUP"
fi

if aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  skip "db instance $DB_ID exists"
else
  # Not every engine version offers every instance class.
  ORDERABLE=$(aws rds describe-orderable-db-instance-options --engine postgres \
    --engine-version "$DB_ENGINE_VERSION" --db-instance-class "$DB_INSTANCE_CLASS" \
    --query 'length(OrderableDBInstanceOptions)' --output text 2>/dev/null || echo 0)
  [ "$ORDERABLE" != "0" ] \
    || die "$DB_INSTANCE_CLASS is not orderable for PostgreSQL $DB_ENGINE_VERSION in $AWS_DEFAULT_REGION"

  PGPASS=$(db_password)
  aws rds create-db-instance \
    --db-instance-identifier "$DB_ID" \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --engine postgres --engine-version "$DB_ENGINE_VERSION" \
    --master-username "$DB_MASTER_USER" --master-user-password "$PGPASS" \
    --allocated-storage "$DB_ALLOCATED_GB" --storage-type gp3 \
    --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --vpc-security-group-ids "$RDSSG" \
    --db-name "$DB_NAME" \
    --no-publicly-accessible \
    --backup-retention-period 0 --no-multi-az >/dev/null
  ok "creating $DB_ID (this takes several minutes)"
fi

# --- EC2 --------------------------------------------------------------------

log "EC2 instance"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  skip "key pair $KEY_NAME exists"
  [ -f "$KEY_FILE" ] || warn "key pair $KEY_NAME exists in AWS but $KEY_FILE is missing -- you cannot SSH in. Delete the key pair and re-run to regenerate it."
else
  aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type rsa \
    --query KeyMaterial --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  ok "created key pair -> $KEY_FILE"
fi
state_set KEY_NAME "$KEY_NAME"

IID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$INSTANCE_TAG" \
            "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

if [ "$IID" = "None" ] || [ -z "$IID" ]; then
  AMI=$(aws ec2 describe-images --owners 099720109477 \
    --filters 'Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*' \
              'Name=state,Values=available' \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  ok "Ubuntu 22.04 AMI $AMI"

  IID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$EC2_INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --security-group-ids "$EC2SG" --subnet-id "$FIRST_SUBNET" \
    --associate-public-ip-address \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$EC2_VOLUME_GB,VolumeType=gp3}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_TAG}]" \
    --query 'Instances[0].InstanceId' --output text)
  ok "launched $IID"
else
  skip "instance $IID already running"
fi

aws ec2 wait instance-running --instance-ids "$IID"
EC2_IP=$(aws ec2 describe-instances --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
state_set IID "$IID"
state_set EC2_IP "$EC2_IP"
ok "instance $IID at $EC2_IP"

# --- wait for the database, then record its endpoint ------------------------

log "waiting for $DB_ID to become available"
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
state_set RDS_ENDPOINT "$RDS_ENDPOINT"
ok "database at $RDS_ENDPOINT"

echo
log "provisioning complete -- state written to $STATE_FILE"
echo "  next: ./deploy/02-configure-instance.sh"
