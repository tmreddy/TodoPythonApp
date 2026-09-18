# Network layout, and the cost decision baked into it.
#
# Worker nodes sit in PUBLIC subnets with public IPs. The textbook production
# layout puts nodes in private subnets behind a NAT Gateway, but a NAT Gateway
# costs about $32/month per AZ -- more than the nodes themselves here. Nodes
# still need outbound internet to pull images from ECR and reach the EKS API, so
# the choice is public IPs or pay for NAT.
#
# What this trades away: nodes are directly addressable from the internet, so
# their security group is the only thing standing between the internet and the
# kubelet. The SG below opens nothing inbound except from inside the VPC and the
# load balancer, which is why this is acceptable for learning and not for
# production. To harden it, add a NAT Gateway and move the node group to the
# private subnets.
#
# RDS stays in private subnets with no route to the internet, so the database is
# unreachable from outside the VPC no matter what its security group says.

locals {
  name = var.project
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both required for EKS: pods and nodes resolve internal DNS names, and RDS
  # is reached by its private DNS name rather than an IP that can change.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

# ------------------------------------------------------------ public subnets --

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]

  # /20 blocks: 10.0.0.0/20, 10.0.16.0/20, ... Deliberately large, because every
  # pod consumes a VPC IP address under the AWS VPC CNI. A /24 per subnet runs
  # out of addresses surprisingly fast and pods then fail to start with
  # "failed to assign an IP address to container".
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-${local.azs[count.index]}"

    # Tells the AWS cloud provider inside Kubernetes that it may create
    # internet-facing load balancers here. Without this tag a Service of type
    # LoadBalancer stays stuck in <pending> forever with no obvious reason.
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ----------------------------------------------------------- private subnets --

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]

  # Offset past the public blocks: 10.0.128.0/20, 10.0.144.0/20, ...
  cidr_block = cidrsubnet(var.vpc_cidr, 4, count.index + 8)

  tags = {
    Name                              = "${local.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# No 0.0.0.0/0 route: this table has local VPC routing only, which is exactly
# what makes these subnets private. RDS needs no outbound internet access.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
