###############################################################################
# Branch site: a standalone VM-Series in its own VPC, IPsec to the HA pair
#
#   branch VPC 10.200.0.0/16 (one AZ)                 security VPC 10.100.0.0/16
#     eth0 mgmt     10.200.0.10  (mgmt EIP)
#     eth1 e1/1 untrust 10.200.1.10  (branch EIP) ==IPsec==> floating EIP (active node)
#     eth2 e1/2 trust   10.200.2.10  <- branch workload route-table next hop
#     workload 10.200.10.0/24
#
# The tunnel is route-based IKEv2 with NAT-T: both ends sit behind AWS 1:1 NAT,
# so each side identifies itself by its public IP. The HA pair's end is the
# floating EIP, which follows the active node, so a failover only re-keys the
# tunnel; the branch's tunnel monitor notices and renegotiates.
#
# Terraform builds the network, the firewall and its bootstrap (interfaces,
# zones, routes, egress policy, license). The tunnel itself is configured by
# scripts/configure.py over the XML API, on all three firewalls, so that
# PAN-OS encrypts the pre-shared key and the pair needs no rebuild to get it.
###############################################################################

locals {
  branch_enabled = var.deploy_branch ? 1 : 0

  branch_az            = var.branch_availability_zone != "" ? var.branch_availability_zone : local.azs[0]
  branch_instance_type = var.branch_instance_type != "" ? var.branch_instance_type : var.instance_type
  branch_name          = "${var.name_prefix}-branch-fw"

  branch_subnet_cidrs = {
    mgmt     = cidrsubnet(var.branch_vpc_cidr, 8, 0)
    untrust  = cidrsubnet(var.branch_vpc_cidr, 8, 1)
    trust    = cidrsubnet(var.branch_vpc_cidr, 8, 2)
    workload = cidrsubnet(var.branch_vpc_cidr, 8, 10)
  }
  branch_fw_ips = {
    for role in ["mgmt", "untrust", "trust"] :
    role => cidrhost(local.branch_subnet_cidrs[role], var.host_index)
  }

  # eth0 = management, eth1 = ethernet1/1, eth2 = ethernet1/2. No HA link.
  branch_eni_device_index = {
    mgmt    = 0
    untrust = 1
    trust   = 2
  }

  hub_tunnel_ip    = cidrhost(var.tunnel_cidr, 1)
  branch_tunnel_ip = cidrhost(var.tunnel_cidr, 2)

  branch_auth_codes       = trimspace(var.branch_auth_codes) != "" ? var.branch_auth_codes : var.panos_auth_codes
  branch_write_authcodes  = var.deploy_branch && var.license_type == "byol" && nonsensitive(trimspace(local.branch_auth_codes) != "")
  effective_ipsec_psk     = var.ipsec_psk != "" ? var.ipsec_psk : random_password.ipsec_psk.result
  branch_workload_enabled = var.deploy_branch && var.deploy_test_workloads ? 1 : 0
}

# Two CIDRs overlap when they share a network at the shorter of their prefixes.
# (Terraform has no cidrcontains(); OpenTofu does.)
locals {
  overlap_prefix = min(split("/", var.vpc_cidr)[1], split("/", var.branch_vpc_cidr)[1])
  cidrs_overlap = (
    cidrhost("${cidrhost(var.vpc_cidr, 0)}/${local.overlap_prefix}", 0) ==
    cidrhost("${cidrhost(var.branch_vpc_cidr, 0)}/${local.overlap_prefix}", 0)
  )
}

check "branch_cidr_does_not_overlap" {
  assert {
    condition     = !var.deploy_branch || !local.cidrs_overlap
    error_message = "branch_vpc_cidr overlaps vpc_cidr; the two are routed to each other over the tunnel."
  }
}

###############################################################################
# IKE pre-shared key
###############################################################################

resource "random_password" "ipsec_psk" {
  length  = 32
  special = false
}

resource "local_sensitive_file" "ipsec_psk" {
  count = local.branch_enabled

  filename        = "${path.module}/.secrets/ipsec_psk"
  content         = local.effective_ipsec_psk
  file_permission = "0600"
}

###############################################################################
# VPC, subnets, route tables
#
#  mgmt, untrust -> IGW
#  trust         -> local only
#  workload      -> branch firewall trust ENI (internet and the tunnel)
###############################################################################

resource "aws_vpc" "branch" {
  count = local.branch_enabled

  cidr_block           = var.branch_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-branch-vpc" }
}

resource "aws_internet_gateway" "branch" {
  count = local.branch_enabled

  vpc_id = aws_vpc.branch[0].id
  tags   = { Name = "${var.name_prefix}-branch-igw" }
}

resource "aws_subnet" "branch" {
  for_each = var.deploy_branch ? local.branch_subnet_cidrs : {}

  vpc_id            = aws_vpc.branch[0].id
  cidr_block        = each.value
  availability_zone = local.branch_az

  tags = {
    Name = "${var.name_prefix}-branch-${each.key}-${local.branch_az}"
    Role = each.key
  }
}

resource "aws_route_table" "branch_public" {
  count = local.branch_enabled

  vpc_id = aws_vpc.branch[0].id
  tags   = { Name = "${var.name_prefix}-branch-rt-public" }
}

resource "aws_route" "branch_public_default" {
  count = local.branch_enabled

  route_table_id         = aws_route_table.branch_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.branch[0].id
}

resource "aws_route_table" "branch_internal" {
  count = local.branch_enabled

  vpc_id = aws_vpc.branch[0].id
  tags   = { Name = "${var.name_prefix}-branch-rt-internal" }
}

resource "aws_route_table" "branch_workload" {
  count = local.branch_enabled

  vpc_id = aws_vpc.branch[0].id
  tags   = { Name = "${var.name_prefix}-branch-rt-workload" }
}

resource "aws_route" "branch_workload_default" {
  count = local.branch_enabled

  route_table_id         = aws_route_table.branch_workload[0].id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.branch["trust"].id
}

resource "aws_route_table_association" "branch" {
  for_each = var.deploy_branch ? local.branch_subnet_cidrs : {}

  subnet_id = aws_subnet.branch[each.key].id
  route_table_id = {
    mgmt     = aws_route_table.branch_public[0].id
    untrust  = aws_route_table.branch_public[0].id
    trust    = aws_route_table.branch_internal[0].id
    workload = aws_route_table.branch_workload[0].id
  }[each.key]
}

###############################################################################
# Security groups
###############################################################################

resource "aws_security_group" "branch_mgmt" {
  count = local.branch_enabled

  name        = "${var.name_prefix}-branch-sg-mgmt"
  description = "Branch VM-Series management plane"
  vpc_id      = aws_vpc.branch[0].id

  tags = { Name = "${var.name_prefix}-branch-sg-mgmt" }
}

resource "aws_vpc_security_group_ingress_rule" "branch_mgmt_https" {
  for_each = var.deploy_branch ? toset(var.mgmt_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.branch_mgmt[0].id
  description       = "PAN-OS web UI / XML API"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "branch_mgmt_ssh" {
  for_each = var.deploy_branch ? toset(var.mgmt_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.branch_mgmt[0].id
  description       = "PAN-OS CLI"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "branch_mgmt_admin_workstation" {
  for_each = var.deploy_branch ? toset(var.admin_workstation_cidrs) : toset([])

  security_group_id = aws_security_group.branch_mgmt[0].id
  description       = "Admin Workstation"
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "branch_mgmt_all" {
  count = local.branch_enabled

  security_group_id = aws_security_group.branch_mgmt[0].id
  description       = "Licensing, content updates"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Nothing is published at the branch, so unlike the pair's untrust SG this one
# admits only the tunnel peer: IKE (UDP 500), NAT-T (UDP 4500), ESP, ICMP.
resource "aws_security_group" "branch_untrust" {
  count = local.branch_enabled

  name        = "${var.name_prefix}-branch-sg-untrust"
  description = "Branch VM-Series internet side - IPsec from the HA pair only"
  vpc_id      = aws_vpc.branch[0].id

  tags = { Name = "${var.name_prefix}-branch-sg-untrust" }
}

resource "aws_vpc_security_group_ingress_rule" "branch_untrust_peer" {
  count = local.branch_enabled

  security_group_id = aws_security_group.branch_untrust[0].id
  description       = "IPsec from the HA pair floating EIP"
  cidr_ipv4         = "${aws_eip.floating.public_ip}/32"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "branch_untrust_all" {
  count = local.branch_enabled

  security_group_id = aws_security_group.branch_untrust[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "branch_trust" {
  count = local.branch_enabled

  name        = "${var.name_prefix}-branch-sg-trust"
  description = "Branch VM-Series inside - accepts workload traffic from the branch VPC"
  vpc_id      = aws_vpc.branch[0].id

  tags = { Name = "${var.name_prefix}-branch-sg-trust" }
}

resource "aws_vpc_security_group_ingress_rule" "branch_trust_vpc" {
  count = local.branch_enabled

  security_group_id = aws_security_group.branch_trust[0].id
  description       = "Workload traffic routed to the trust ENI"
  cidr_ipv4         = var.branch_vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "branch_trust_all" {
  count = local.branch_enabled

  security_group_id = aws_security_group.branch_trust[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "branch_workload" {
  count = local.branch_enabled

  name        = "${var.name_prefix}-branch-sg-workload"
  description = "Test workload behind the branch firewall"
  vpc_id      = aws_vpc.branch[0].id

  tags = { Name = "${var.name_prefix}-branch-sg-workload" }
}

resource "aws_vpc_security_group_ingress_rule" "branch_workload" {
  for_each = var.deploy_branch ? {
    branch = var.branch_vpc_cidr
    hub    = var.vpc_cidr
  } : {}

  security_group_id = aws_security_group.branch_workload[0].id
  description       = each.key == "hub" ? "Security VPC, over the tunnel" : "Branch VPC"
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "branch_workload_all" {
  count = local.branch_enabled

  security_group_id = aws_security_group.branch_workload[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# The pair's workloads only admit the security VPC; let the branch in too.
resource "aws_vpc_security_group_ingress_rule" "workload_branch" {
  count = local.branch_enabled

  security_group_id = aws_security_group.workload.id
  description       = "Branch VPC, over the tunnel"
  cidr_ipv4         = var.branch_vpc_cidr
  ip_protocol       = "-1"
}

###############################################################################
# IAM: bootstrap read only, and only its own prefix. The pair's role also
# carries the failover permissions, which the branch must not have.
###############################################################################

resource "aws_iam_role" "branch_fw" {
  count = local.branch_enabled

  name               = "${var.name_prefix}-branch-fw-role"
  assume_role_policy = data.aws_iam_policy_document.fw_assume_role.json
  description        = "Branch VM-Series bootstrap"

  tags = { Name = "${var.name_prefix}-branch-fw-role" }
}

resource "aws_iam_instance_profile" "branch_fw" {
  count = local.branch_enabled

  name = "${var.name_prefix}-branch-fw-profile"
  role = aws_iam_role.branch_fw[0].name
}

data "aws_iam_policy_document" "branch_fw_bootstrap" {
  statement {
    sid       = "ListBootstrapBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.bootstrap.arn]
  }

  statement {
    sid       = "ReadBranchBootstrapObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bootstrap.arn}/${local.branch_name}/*"]
  }
}

resource "aws_iam_role_policy" "branch_fw_bootstrap" {
  count = local.branch_enabled

  name   = "${var.name_prefix}-branch-bootstrap"
  role   = aws_iam_role.branch_fw[0].id
  policy = data.aws_iam_policy_document.branch_fw_bootstrap.json
}

###############################################################################
# Bootstrap package, under its own prefix in the shared bucket
###############################################################################

locals {
  branch_bootstrap_xml = templatefile("${path.module}/templates/branch-bootstrap.xml.tftpl", {
    hostname         = local.branch_name
    config_version   = var.panos_config_version
    timezone         = var.timezone
    admin_username   = var.admin_username
    admin_phash      = data.external.admin_phash.result.phash
    admin_public_key = base64encode(trimspace(tls_private_key.fw.public_key_openssh))
    permitted_ips    = local.panos_permitted_ips
    branch_cidr      = var.branch_vpc_cidr
    untrust_gateway  = cidrhost(local.branch_subnet_cidrs["untrust"], 1)
    trust_gateway    = cidrhost(local.branch_subnet_cidrs["trust"], 1)
  })

  branch_init_cfg = templatefile("${path.module}/templates/init-cfg.txt.tftpl", {
    hostname = local.branch_name
  })

  # Same layout as the pair's packages (see bootstrap.tf). An empty license/
  # directory stands in for the authcodes file when there is no code.
  branch_bootstrap_objects = merge(
    {
      "config/init-cfg.txt"  = local.branch_init_cfg
      "config/bootstrap.xml" = local.branch_bootstrap_xml
      "software/"            = ""
      "content/"             = ""
      "plugins/"             = ""
    },
    local.branch_write_authcodes ? {} : { "license/" = "" },
  )
}

# Same depends_on as bootstrap.tf, for the same versioning race.
resource "aws_s3_object" "branch_bootstrap" {
  for_each = var.deploy_branch ? local.branch_bootstrap_objects : {}

  bucket                 = aws_s3_bucket.bootstrap.id
  key                    = "${local.branch_name}/${each.key}"
  content                = each.value
  server_side_encryption = "AES256"
  etag                   = md5(each.value)

  depends_on = [
    aws_s3_bucket_versioning.bootstrap,
    aws_s3_bucket_server_side_encryption_configuration.bootstrap,
    aws_s3_bucket_policy.bootstrap,
  ]
}

# Separate from the map above so the auth code never lands in a for_each key
# or a non-sensitive value.
resource "aws_s3_object" "branch_authcodes" {
  count = local.branch_write_authcodes ? 1 : 0

  bucket                 = aws_s3_bucket.bootstrap.id
  key                    = "${local.branch_name}/license/authcodes"
  content                = "${trimspace(local.branch_auth_codes)}\n"
  content_type           = "text/plain"
  server_side_encryption = "AES256"

  depends_on = [
    aws_s3_bucket_versioning.bootstrap,
    aws_s3_bucket_server_side_encryption_configuration.bootstrap,
    aws_s3_bucket_policy.bootstrap,
  ]
}

resource "local_file" "rendered_branch_bootstrap" {
  count = local.branch_enabled

  filename        = "${path.module}/.rendered/${local.branch_name}-bootstrap.xml"
  content         = local.branch_bootstrap_xml
  file_permission = "0600"
}

###############################################################################
# ENIs, EIPs, instance
###############################################################################

resource "aws_network_interface" "branch" {
  for_each = var.deploy_branch ? local.branch_eni_device_index : {}

  subnet_id   = aws_subnet.branch[each.key].id
  private_ips = [local.branch_fw_ips[each.key]]
  security_groups = [{
    mgmt    = aws_security_group.branch_mgmt[0].id
    untrust = aws_security_group.branch_untrust[0].id
    trust   = aws_security_group.branch_trust[0].id
  }[each.key]]

  source_dest_check = each.key == "mgmt"

  description = "${local.branch_name} ${each.key} (eth${each.value})"

  tags = {
    Name     = "${local.branch_name}-${each.key}"
    Firewall = local.branch_name
    Role     = each.key
  }

  lifecycle {
    # See firewalls.tf: account auto-remediation may swap the SG.
    ignore_changes = [security_groups]
  }
}

resource "aws_eip" "branch" {
  for_each = var.deploy_branch ? toset(["mgmt", "untrust"]) : toset([])

  domain                    = "vpc"
  network_interface         = aws_network_interface.branch[each.key].id
  associate_with_private_ip = local.branch_fw_ips[each.key]

  tags = { Name = "${local.branch_name}-${each.key}-eip" }

  depends_on = [aws_internet_gateway.branch]
}

resource "aws_instance" "branch_fw" {
  count = local.branch_enabled

  ami                  = local.ami_id
  instance_type        = local.branch_instance_type
  key_name             = aws_key_pair.fw.key_name
  iam_instance_profile = aws_iam_instance_profile.branch_fw[0].name
  ebs_optimized        = true

  user_data = "vmseries-bootstrap-aws-s3bucket=${aws_s3_bucket.bootstrap.id}/${local.branch_name}"

  dynamic "network_interface" {
    for_each = local.branch_eni_device_index

    content {
      network_interface_id = aws_network_interface.branch[network_interface.key].id
      device_index         = network_interface.value
    }
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  tags = { Name = local.branch_name }

  depends_on = [
    aws_s3_object.branch_bootstrap,
    aws_s3_object.branch_authcodes,
    aws_iam_role_policy.branch_fw_bootstrap,
  ]

  lifecycle {
    ignore_changes = [user_data]
  }
}

###############################################################################
# Branch test workload (same web server as the pair's workloads)
###############################################################################

resource "aws_instance" "branch_workload" {
  count = local.branch_workload_enabled

  ami                    = data.aws_ssm_parameter.al2023[0].value
  instance_type          = var.workload_instance_type
  subnet_id              = aws_subnet.branch["workload"].id
  vpc_security_group_ids = [aws_security_group.branch_workload[0].id]
  iam_instance_profile   = aws_iam_instance_profile.workload[0].name
  key_name               = aws_key_pair.fw.key_name
  user_data              = file("${path.module}/scripts/workload-web.sh")

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = { Name = "${var.name_prefix}-branch-workload-${local.branch_az}" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_instance.branch_fw]
}
