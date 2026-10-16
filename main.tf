###############################################################################
# Locals, AMI lookup, and derived addressing
#
# Topology (Multi-AZ Active/Passive, API-driven failover):
#
#   AZ-A (fw-a, priority 50, active)      AZ-B (fw-b, priority 100, passive)
#     eth0 mgmt     10.x.0.10   <----------- HA1 (mgmt, TCP 28769/28260) ----->  10.x.10.10
#     eth1 e1/1 HA2 10.x.1.10   <----------- HA2 (UDP 29281, routed) -------->  10.x.11.10
#     eth2 e1/2 untrust 10.x.2.10  (floating EIP while active)                  10.x.12.10
#     eth3 e1/3 trust   10.x.3.10  <- workload route-table next hop ->          10.x.13.10
#
# On failover the VM-Series AWS plugin (failover mode secondary-ip) on the new
# active node calls ec2:ReplaceRoute to repoint the workload route tables at its
# own trust ENI, and ec2:AssociateAddress to pull the floating EIP from the
# peer's primary untrust IP onto its own. Secondary IPs are subnet-bound and
# cannot cross AZs, so nothing here uses them.
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  azs = var.availability_zones

  # AWS Marketplace product codes for the VM-Series AMIs.
  product_codes = {
    byol    = "6njl1pau431dv1qxipg63mvah"
    bundle1 = "e9yfvyj3uag5uo5j2hjikv74n"
    bundle2 = "hd44w1chf26uv4p52cdynb2o"
  }
  product_code = local.product_codes[var.license_type]

  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.vmseries[0].id

  # ---- Subnet CIDRs -------------------------------------------------------
  # cidrsubnet(10.100.0.0/16, 8, N) => 10.100.N.0/24
  subnet_cidrs = {
    for role, offsets in var.subnet_offsets :
    role => [for o in offsets : cidrsubnet(var.vpc_cidr, 8, o)]
  }

  # AWS reserves .1 of every subnet as the implicit router.
  subnet_gateways = {
    for role, cidrs in local.subnet_cidrs :
    role => [for c in cidrs : cidrhost(c, 1)]
  }

  # ---- Firewall ENI addressing -------------------------------------------
  # Index 0 => fw-a (AZ-A), index 1 => fw-b (AZ-B).
  fw_ips = {
    for role in ["mgmt", "ha2", "untrust", "trust"] :
    role => [for c in local.subnet_cidrs[role] : cidrhost(c, var.host_index)]
  }

  # ---- Per-firewall definition -------------------------------------------
  firewalls = {
    "a" = {
      index           = 0
      name            = "${var.name_prefix}-fw-a"
      hostname        = "${var.name_prefix}-fw-a"
      az              = local.azs[0]
      device_priority = 50 # lower wins the election -> active
    }
    "b" = {
      index           = 1
      name            = "${var.name_prefix}-fw-b"
      hostname        = "${var.name_prefix}-fw-b"
      az              = local.azs[1]
      device_priority = 100
    }
  }

  ha2_netmask = cidrnetmask(local.subnet_cidrs["ha2"][0])

  # Inbound DNAT target: an explicit IP, else the first test workload (whose
  # test web server shows its own IP). configure.py creates the rules.
  inbound_target_ip = (
    var.inbound_target_ip != "" ? var.inbound_target_ip :
    var.deploy_test_workloads ? aws_instance.workload[0].private_ip : ""
  )
  inbound_dnat_enabled = var.enable_inbound_dnat && local.inbound_target_ip != ""

  effective_admin_password = var.admin_password != "" ? var.admin_password : random_password.admin.result
}

###############################################################################
# VM-Series AMI
###############################################################################

data "aws_ami" "vmseries" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "product-code"
    values = [local.product_code]
  }

  filter {
    name   = "name"
    values = [var.panos_version_filter]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

###############################################################################
# Admin credentials
###############################################################################

resource "random_password" "admin" {
  length  = 24
  special = true
  # PAN-OS rejects several punctuation characters in passwords set via config.
  override_special = "!@#%^*_-+="
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

# PAN-OS stores the superuser password as a sha256-crypt ($5$) hash, the format
# `request password-hash` emits. ($6$ loaded but every login was rejected.)
# Python 3.13 removed `crypt` and macOS ships LibreSSL (no `openssl passwd -5`), so we
# use the bundled pure-Python implementation, which is unit-tested against the
# SHA-crypt reference vectors (scripts/sha512_crypt.py --selftest).
data "external" "admin_phash" {
  program = ["python3", "${path.module}/scripts/phash_helper.py"]

  query = {
    password = local.effective_admin_password
  }
}

resource "local_sensitive_file" "admin_password" {
  filename        = "${path.module}/.secrets/admin_password"
  content         = local.effective_admin_password
  file_permission = "0600"
}

###############################################################################
# SSH keypair (PAN-OS admin SSH + workload break-glass)
###############################################################################

resource "tls_private_key" "fw" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "fw" {
  key_name   = "${var.name_prefix}-key"
  public_key = tls_private_key.fw.public_key_openssh
}

resource "local_sensitive_file" "ssh_key" {
  filename        = "${path.module}/.secrets/${var.name_prefix}-key.pem"
  content         = tls_private_key.fw.private_key_pem
  file_permission = "0600"
}
