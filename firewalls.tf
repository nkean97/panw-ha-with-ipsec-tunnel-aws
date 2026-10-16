###############################################################################
# VM-Series firewalls: ENIs, EIPs, instances
###############################################################################

locals {
  # ENI role -> EC2 device_index. This ordering is what maps the AWS interfaces
  # onto PAN-OS names: eth0 = management, eth1 = ethernet1/1, and so on.
  eni_device_index = {
    mgmt    = 0
    ha2     = 1
    untrust = 2
    trust   = 3
  }

  eni_security_groups = {
    mgmt    = "mgmt"
    ha2     = "ha2"
    untrust = "untrust"
    trust   = "trust"
  }

  # source/dest check MUST be disabled on the dataplane legs: they forward
  # traffic for addresses that are not their own.
  eni_source_dest_check = {
    mgmt    = true
    ha2     = true
    untrust = false
    trust   = false
  }

  fw_eni_defs = merge([
    for fw_key, fw in local.firewalls : {
      for role, device_index in local.eni_device_index :
      "${fw_key}-${role}" => {
        fw_key            = fw_key
        fw                = fw
        role              = role
        device_index      = device_index
        subnet_key        = "${role}-${fw.index}"
        private_ip        = local.fw_ips[role][fw.index]
        source_dest_check = local.eni_source_dest_check[role]
      }
    }
  ]...)

  sg_ids = {
    mgmt    = aws_security_group.mgmt.id
    ha2     = aws_security_group.ha2.id
    untrust = aws_security_group.untrust.id
    trust   = aws_security_group.trust.id
  }
}

resource "aws_network_interface" "fw" {
  for_each = local.fw_eni_defs

  subnet_id       = aws_subnet.this[each.value.subnet_key].id
  private_ips     = [each.value.private_ip]
  security_groups = [local.sg_ids[local.eni_security_groups[each.value.role]]]

  # `false` disables the check; the attribute is "enable source/dest check".
  source_dest_check = each.value.source_dest_check

  description = "${each.value.fw.name} ${each.value.role} (eth${each.value.device_index})"

  tags = {
    Name     = "${each.value.fw.name}-${each.value.role}"
    Firewall = each.value.fw.name
    Role     = each.value.role
  }

  lifecycle {
    # The AWS plugin may add/remove secondary IPs during failover.
    # security_groups: the account's Xpanse/XSOAR auto-remediation swaps an
    # over-permissive SG for a restricted copy, and admins add rules to that
    # copy. Re-applying must not swap it back.
    ignore_changes = [private_ips, security_groups]
  }
}

###############################################################################
# Elastic IPs
#
#  - mgmt EIP per node: persistent admin access, licensing and content updates.
#  - untrust EIP per node: stable egress source for outbound SNAT.
#  - floating "service" EIP: bound to the ACTIVE node's untrust SECONDARY
#    private IP. This is the address the AWS plugin re-associates on failover
#    (inbound DNAT target, and a fixed IPSec tunnel endpoint if you add one).
###############################################################################

resource "aws_eip" "mgmt" {
  for_each = local.firewalls

  domain            = "vpc"
  network_interface = aws_network_interface.fw["${each.key}-mgmt"].id

  tags = { Name = "${each.value.name}-mgmt-eip" }

  depends_on = [aws_internet_gateway.this]
}

# The one public address on the untrust side, for inbound and (via SNAT to
# the interface address) egress. It sits on the active node's PRIMARY untrust
# IP: in secondary-ip mode the AWS plugin moves whatever EIP is on the peer's
# primary untrust IP. The passive node needs no untrust EIP; its dataplane
# links are down while passive.
#
# Initially on FW-A. The placement lives on the EIP itself, not in a separate
# aws_eip_association: every failover makes a NEW association, so a tracked
# association would vanish and the next apply would recreate it on FW-A,
# pulling the address off whichever node is active.
resource "aws_eip" "floating" {
  domain                    = "vpc"
  network_interface         = aws_network_interface.fw["a-untrust"].id
  associate_with_private_ip = local.fw_ips["untrust"][0]

  tags = {
    Name = "${var.name_prefix}-floating-eip"
    # Lets the failover automation discover this EIP by tag.
    PanwHaFloating = "true"
  }

  lifecycle {
    ignore_changes = [network_interface, associate_with_private_ip, instance]
  }

  depends_on = [aws_internet_gateway.this]
}

# Earlier versions tracked the placement as a separate association. Forget it
# without touching the live association.
removed {
  from = aws_eip_association.floating

  lifecycle {
    destroy = false
  }
}

###############################################################################
# Instances
###############################################################################

resource "aws_instance" "fw" {
  for_each = local.firewalls

  ami                  = local.ami_id
  instance_type        = var.instance_type
  key_name             = aws_key_pair.fw.key_name
  iam_instance_profile = aws_iam_instance_profile.fw.name
  ebs_optimized        = true

  # Points the firewall at its own prefix inside the shared bootstrap bucket.
  user_data = "vmseries-bootstrap-aws-s3bucket=${aws_s3_bucket.bootstrap.id}/${each.value.name}"

  dynamic "network_interface" {
    for_each = {
      for role, device_index in local.eni_device_index :
      role => device_index
    }

    content {
      network_interface_id = aws_network_interface.fw["${each.key}-${network_interface.key}"].id
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
    http_endpoint = "enabled"
    # VM-Series bootstrap and the AWS plugin use IMDSv1-style calls on some
    # PAN-OS releases, so tokens stay optional here.
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name    = each.value.name
    HaRole  = each.value.device_priority == 50 ? "primary" : "secondary"
    HaGroup = tostring(var.ha_group_id)
  }

  # The bootstrap package must be fully uploaded before the instance boots and
  # tries to read it.
  depends_on = [
    aws_s3_object.init_cfg,
    aws_s3_object.bootstrap_xml,
    aws_s3_object.authcodes,
    aws_s3_object.empty_dirs,
    aws_s3_object.license_dir,
    aws_iam_role_policy.fw_bootstrap,
  ]

  lifecycle {
    ignore_changes = [user_data]
  }
}
