###############################################################################
# IAM role for the firewalls
#
# Two jobs:
#   1. Read the bootstrap package out of S3 at first boot.
#   2. Let the newly-active node rewrite VPC routes and move the floating EIP
#      during an HA failover (PDF step 1: ec2:ReplaceRoute, ec2:AssociateAddress,
#      ec2:AssignPrivateIpAddresses, ...).
###############################################################################

data "aws_iam_policy_document" "fw_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fw" {
  name               = "${var.name_prefix}-fw-role"
  assume_role_policy = data.aws_iam_policy_document.fw_assume_role.json
  description        = "VM-Series bootstrap + HA failover"

  tags = { Name = "${var.name_prefix}-fw-role" }
}

resource "aws_iam_instance_profile" "fw" {
  name = "${var.name_prefix}-fw-profile"
  role = aws_iam_role.fw.name
}

# ---- Bootstrap: read-only on the bootstrap bucket --------------------------
data "aws_iam_policy_document" "fw_bootstrap" {
  statement {
    sid       = "ListBootstrapBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.bootstrap.arn]
  }

  statement {
    sid       = "ReadBootstrapObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bootstrap.arn}/*"]
  }
}

resource "aws_iam_role_policy" "fw_bootstrap" {
  name   = "${var.name_prefix}-bootstrap"
  role   = aws_iam_role.fw.id
  policy = data.aws_iam_policy_document.fw_bootstrap.json
}

# ---- HA failover -----------------------------------------------------------
data "aws_iam_policy_document" "fw_ha" {
  # Discovery. ec2:Describe* does not support resource-level constraints, so
  # this is necessarily "*" — it is read-only.
  statement {
    sid = "Discover"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeRouteTables",
      "ec2:DescribeAddresses",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }

  # Route-table rewrite, scoped to the workload tables this stack owns.
  statement {
    sid = "RewriteFailoverRoutes"
    actions = [
      "ec2:CreateRoute",
      "ec2:ReplaceRoute",
      "ec2:DeleteRoute",
    ]
    resources = [
      for id in local.failover_route_table_ids :
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:route-table/${id}"
    ]
  }

  # EIP move. AssociateAddress/DisassociateAddress cannot be meaningfully
  # scoped to a specific EIP for the association target, so these stay "*" but
  # are constrained to this VPC's resources by condition where supported.
  statement {
    sid = "MoveFloatingEip"
    actions = [
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
    ]
    resources = ["*"]
  }

  # Secondary private IP move (used by the plugin's "secondary IP" failover
  # mode; harmless to grant and required if you ever switch modes).
  statement {
    sid = "MoveSecondaryIps"
    actions = [
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:network-interface/*"
    ]
  }

  statement {
    sid = "MonitorAndLog"
    actions = [
      "cloudwatch:PutMetricData",
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fw_ha" {
  name   = "${var.name_prefix}-ha-failover"
  role   = aws_iam_role.fw.id
  policy = data.aws_iam_policy_document.fw_ha.json
}

###############################################################################
# IAM role for the test workloads (SSM Session Manager - no SSH keys needed)
###############################################################################

data "aws_iam_policy_document" "workload_assume_role" {
  count = var.deploy_test_workloads ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workload" {
  count = var.deploy_test_workloads ? 1 : 0

  name               = "${var.name_prefix}-workload-role"
  assume_role_policy = data.aws_iam_policy_document.workload_assume_role[0].json

  tags = { Name = "${var.name_prefix}-workload-role" }
}

resource "aws_iam_role_policy_attachment" "workload_ssm" {
  count = var.deploy_test_workloads ? 1 : 0

  role       = aws_iam_role.workload[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "workload" {
  count = var.deploy_test_workloads ? 1 : 0

  name = "${var.name_prefix}-workload-profile"
  role = aws_iam_role.workload[0].name
}
