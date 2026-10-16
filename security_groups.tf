###############################################################################
# Security groups
#
# Note on `untrust`: it is intentionally permissive inbound. The firewall itself
# is the enforcement point for that interface — putting a second, stricter
# filter in front of it would silently drop traffic you expect PAN-OS to see.
# Every other SG is tight.
###############################################################################

# ---- Management ------------------------------------------------------------
resource "aws_security_group" "mgmt" {
  name        = "${var.name_prefix}-sg-mgmt"
  description = "VM-Series management plane: admin access + HA1 control link"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-sg-mgmt" }
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_https" {
  for_each = toset(var.mgmt_allowed_cidrs)

  security_group_id = aws_security_group.mgmt.id
  description       = "PAN-OS web UI / XML API"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_ssh" {
  for_each = toset(var.mgmt_allowed_cidrs)

  security_group_id = aws_security_group.mgmt.id
  description       = "PAN-OS CLI"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_admin_workstation" {
  for_each = toset(var.admin_workstation_cidrs)

  security_group_id = aws_security_group.mgmt.id
  description       = "Admin Workstation"
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
}

# HA1 control link runs over the management interface (PDF step 2: "Set the
# Peer HA1 IP to the opposite firewall's Management IP address").
# HA1: TCP 28769 (clear) and 28260 (encrypted), plus ICMP for the heartbeat.
resource "aws_vpc_security_group_ingress_rule" "mgmt_ha1" {
  security_group_id = aws_security_group.mgmt.id
  description       = "HA1 control link (encrypted)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 28260
  to_port           = 28260
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_ha1_clear" {
  security_group_id = aws_security_group.mgmt.id
  description       = "HA1 control link (clear text)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 28769
  to_port           = 28769
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_ha_heartbeat" {
  security_group_id = aws_security_group.mgmt.id
  description       = "HA1 heartbeat (ICMP)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
}

resource "aws_vpc_security_group_egress_rule" "mgmt_all" {
  security_group_id = aws_security_group.mgmt.id
  description       = "Licensing, content updates, AWS API, HA1 to peer"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---- HA2 data link ---------------------------------------------------------
resource "aws_security_group" "ha2" {
  name        = "${var.name_prefix}-sg-ha2"
  description = "VM-Series HA2 session-state synchronisation link"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-sg-ha2" }
}

# HA2 transport is set to `udp` in the bootstrap config (port 29281) rather than
# the default IP proto 99, because UDP survives VPC security-group filtering
# cleanly and HA2 is routed across AZs here.
resource "aws_vpc_security_group_ingress_rule" "ha2_udp" {
  security_group_id = aws_security_group.ha2.id
  description       = "HA2 state sync (UDP transport)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "udp"
  from_port         = 29281
  to_port           = 29281
}

resource "aws_vpc_security_group_ingress_rule" "ha2_keepalive" {
  security_group_id = aws_security_group.ha2.id
  description       = "HA2 keep-alive (ICMP)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
}

resource "aws_vpc_security_group_egress_rule" "ha2_all" {
  security_group_id = aws_security_group.ha2.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

# ---- Untrust ---------------------------------------------------------------
resource "aws_security_group" "untrust" {
  name        = "${var.name_prefix}-sg-untrust"
  description = "VM-Series internet-facing dataplane - PAN-OS policy is the filter"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-sg-untrust" }
}

resource "aws_vpc_security_group_ingress_rule" "untrust_all" {
  security_group_id = aws_security_group.untrust.id
  description       = "Inspected by PAN-OS security policy, not by the SG"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "untrust_all" {
  security_group_id = aws_security_group.untrust.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---- Trust -----------------------------------------------------------------
resource "aws_security_group" "trust" {
  name        = "${var.name_prefix}-sg-trust"
  description = "VM-Series inside dataplane - accepts workload traffic from the VPC"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-sg-trust" }
}

resource "aws_vpc_security_group_ingress_rule" "trust_vpc" {
  security_group_id = aws_security_group.trust.id
  description       = "Workload traffic routed to the trust ENI"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "trust_all" {
  security_group_id = aws_security_group.trust.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---- Test workloads --------------------------------------------------------
resource "aws_security_group" "workload" {
  name        = "${var.name_prefix}-sg-workload"
  description = "Test workloads behind the firewall pair"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name_prefix}-sg-workload" }
}

resource "aws_vpc_security_group_ingress_rule" "workload_vpc" {
  security_group_id = aws_security_group.workload.id
  description       = "Intra-VPC (incl. east-west via the firewall)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "workload_all" {
  security_group_id = aws_security_group.workload.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
