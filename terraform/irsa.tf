# IRSA -- IAM Roles for Service Accounts.
#
# The problem it solves: this app ships logs to CloudWatch (see cloudwatch.md).
# On plain EC2 the instance role granted that permission. In Kubernetes, giving
# the *node* role CloudWatch access would give it to every pod on that node,
# including anything else you deploy later. That is the container equivalent of
# running everything as root.
#
# IRSA instead lets a Kubernetes ServiceAccount assume an IAM role directly. The
# cluster signs a token identifying the pod's service account; AWS trusts that
# signature via an OIDC provider and hands back scoped credentials. boto3 picks
# them up with no code changes -- the same automatic discovery that found the
# instance role before.

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Registers the cluster's token issuer with IAM, so IAM will trust tokens the
# cluster signs. One per cluster.
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = { Name = "${local.name}-eks-oidc" }
}

locals {
  # "oidc.eks.us-east-1.amazonaws.com/id/ABC123" -- the issuer without its scheme,
  # which is the form the trust policy conditions use.
  oidc_host = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")

  # Must match the namespace and service account name in k8s/serviceaccount.yaml.
  # A mismatch is the most common IRSA failure: the pod gets no credentials and
  # boto3 falls back to the node role, so CloudWatch silently stops working.
  k8s_namespace       = var.project
  k8s_service_account = "${var.project}-api"
}

data "aws_iam_policy_document" "app_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    # Scope the trust to exactly one service account in one namespace. Without
    # the "sub" condition, ANY pod in the cluster could assume this role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${local.k8s_namespace}:${local.k8s_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-api-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.app_assume_role.json

  tags = { Name = "${local.name}-api-irsa-role" }
}

# The application's own permissions: write its log group, and nothing else.
data "aws_iam_policy_document" "app_permissions" {
  statement {
    sid    = "WriteApplicationLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    # Scoped to this app's group rather than "*", so a compromised pod cannot
    # read or write logs belonging to anything else in the account.
    resources = [
      aws_cloudwatch_log_group.app.arn,
      "${aws_cloudwatch_log_group.app.arn}:*",
    ]
  }

  # DescribeLogGroups cannot be scoped to a single group by IAM -- it is a
  # list operation, so it only accepts "*".
  statement {
    sid       = "ListLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "${local.name}-api-logs"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app_permissions.json
}

# Created here rather than letting watchtower create it, so retention is set
# from the very first log line instead of defaulting to "never expires".
resource "aws_cloudwatch_log_group" "app" {
  name              = var.cloudwatch_log_group
  retention_in_days = var.log_retention_days

  tags = { Name = var.cloudwatch_log_group }
}
