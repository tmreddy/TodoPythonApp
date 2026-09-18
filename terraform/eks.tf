# The Kubernetes cluster.
#
# Two IAM roles are involved and they are easy to confuse:
#   - the CLUSTER role is assumed by the EKS control plane (AWS-managed) so it
#     can create load balancers and network interfaces on your behalf.
#   - the NODE role is assumed by the EC2 worker instances so the kubelet can
#     register with the cluster and pull images from ECR.
# Neither has anything to do with what your application code is allowed to do --
# that is IRSA, in irsa.tf.

# ------------------------------------------------------------- cluster role --

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ---------------------------------------------------------- control plane logs --

# Created explicitly so retention is set from the start. If EKS creates this
# group itself it defaults to never expiring. The name is fixed by EKS.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.name}-cluster/cluster"
  retention_in_days = var.log_retention_days
}

# ------------------------------------------------------------------- cluster --

resource "aws_eks_cluster" "main" {
  name     = "${local.name}-cluster"
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = aws_subnet.public[*].id

    # Public endpoint so GitHub Actions (and your laptop) can run kubectl.
    # Private access keeps in-VPC traffic off the internet.
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.public_access_cidrs
  }

  # "API_AND_CONFIG_MAP" enables the modern access-entry mechanism while leaving
  # the legacy aws-auth ConfigMap working. Access entries are plain AWS API
  # calls, so a mistake is fixable with the CLI -- whereas corrupting aws-auth
  # can lock every identity out of the cluster with no way back in.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Audit and authenticator logs are what let you answer "who deleted that
  # deployment?". They cost ingestion, hence the retention above.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = { Name = "${local.name}-cluster" }
}

# ---------------------------------------------------------------- node role --

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    # Lets the kubelet register the node with the control plane.
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    # The VPC CNI assigns pod IPs from the subnet; without this, pods never
    # get an address and stay stuck in ContainerCreating.
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    # Pull images from ECR.
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Lets SSM Session Manager reach the node, so you can debug a node without
    # opening SSH or managing a key pair.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# -------------------------------------------------------------- node group --

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id

  instance_types = [var.node_instance_type]
  disk_size      = var.node_disk_size

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # Replace at most one node at a time, so the cluster keeps serving during a
  # Kubernetes version upgrade.
  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node]

  lifecycle {
    # The cluster autoscaler (if you add one later) changes desired_size at
    # runtime. Ignoring it here stops Terraform from fighting the autoscaler and
    # scaling the cluster back down on every apply.
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = { Name = "${local.name}-nodes" }
}

# ---------------------------------------------------------------- addons --

# Managed addons keep the cluster's own networking and DNS components patched.
# They are installed after the node group because CoreDNS has no node to be
# scheduled onto before then, and would sit Pending.
resource "aws_eks_addon" "core" {
  for_each = toset([
    "vpc-cni",
    "kube-proxy",
    "coredns",
    # EKS does NOT ship metrics-server, and without it a HorizontalPodAutoscaler
    # reports "<unknown>/70%" and never scales. `kubectl top` fails too.
    "metrics-server",
  ])

  cluster_name = aws_eks_cluster.main.name
  addon_name   = each.value

  # Take AWS's default version for the cluster version, and let AWS's value win
  # if it conflicts with something already installed.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# ------------------------------------------------------- extra cluster admins --

# Grants kubectl access to principals other than whoever ran apply. Needed when
# GitHub Actions authenticates as a different IAM user than you do locally.
resource "aws_eks_access_entry" "admins" {
  for_each = toset(var.cluster_admin_role_arns)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admins" {
  for_each = toset(var.cluster_admin_role_arns)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admins]
}
