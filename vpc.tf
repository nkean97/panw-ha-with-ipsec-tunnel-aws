###############################################################################
# VPC, subnets, gateways, route tables
###############################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# ---------------------------------------------------------------------------
# Subnets: one per (role, AZ) pair.
# ---------------------------------------------------------------------------
locals {
  subnet_defs = merge([
    for role, cidrs in local.subnet_cidrs : {
      for idx, cidr in cidrs :
      "${role}-${idx}" => {
        role = role
        idx  = idx
        cidr = cidr
        az   = local.azs[idx]
      }
    }
  ]...)
}

resource "aws_subnet" "this" {
  for_each = local.subnet_defs

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name = "${var.name_prefix}-${each.value.role}-${each.value.az}"
    Role = each.value.role
  }
}

###############################################################################
# Route tables
#
#  mgmt    -> IGW   (licensing, content updates, admin access)
#  untrust -> IGW   (firewall's internet-facing side)
#  ha2     -> local only (HA2 is routed VPC-internal traffic)
#  trust   -> local only (firewall's inside leg talks to the VPC)
#  workload-> firewall trust ENI  <-- THESE are what the AWS plugin rewrites
###############################################################################

# ---- mgmt ------------------------------------------------------------------
resource "aws_route_table" "mgmt" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-rt-mgmt" }
}

resource "aws_route" "mgmt_default" {
  route_table_id         = aws_route_table.mgmt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "mgmt" {
  for_each = { for k, v in local.subnet_defs : k => v if v.role == "mgmt" }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.mgmt.id
}

# ---- untrust ---------------------------------------------------------------
resource "aws_route_table" "untrust" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-rt-untrust" }
}

resource "aws_route" "untrust_default" {
  route_table_id         = aws_route_table.untrust.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "untrust" {
  for_each = { for k, v in local.subnet_defs : k => v if v.role == "untrust" }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.untrust.id
}

# ---- ha2 + trust (VPC-local only) -----------------------------------------
resource "aws_route_table" "internal" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-rt-internal" }
}

resource "aws_route_table_association" "internal" {
  for_each = {
    for k, v in local.subnet_defs : k => v if contains(["ha2", "trust"], v.role)
  }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.internal.id
}

# ---- workload --------------------------------------------------------------
# One route table per AZ. Both initially point at FW-A's trust ENI; the PAN-OS
# AWS plugin repoints them at FW-B on failover.
#
# `lifecycle.ignore_changes` on network_interface_id is deliberate: after a
# failover the live target is FW-B's ENI, and Terraform must not revert it on
# the next apply.
resource "aws_route_table" "workload" {
  count = length(local.azs)

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-workload-${local.azs[count.index]}"
    # Consumed by the AWS plugin / failover automation to find these tables.
    PanwHaFailover = "true"
  }
}

resource "aws_route" "workload_default" {
  count = length(local.azs)

  route_table_id         = aws_route_table.workload[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.fw["a-trust"].id

  lifecycle {
    ignore_changes = [network_interface_id]
  }
}

# East-west: force cross-AZ workload traffic through the firewall. These are
# more specific than the VPC local route, which AWS permits.
resource "aws_route" "workload_east_west" {
  count = length(local.azs)

  route_table_id = aws_route_table.workload[count.index].id
  # AZ-A's table gets a route to AZ-B's workload CIDR, and vice versa.
  destination_cidr_block = local.subnet_cidrs["workload"][1 - count.index]
  network_interface_id   = aws_network_interface.fw["a-trust"].id

  lifecycle {
    ignore_changes = [network_interface_id]
  }
}

resource "aws_route_table_association" "workload" {
  for_each = { for k, v in local.subnet_defs : k => v if v.role == "workload" }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.workload[each.value.idx].id
}

locals {
  # Route tables the firewall must be able to rewrite on failover.
  failover_route_table_ids = aws_route_table.workload[*].id
}
