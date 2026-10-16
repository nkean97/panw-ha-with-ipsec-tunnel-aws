###############################################################################
# Bootstrap package in S3
#
# VM-Series reads this at first boot via user_data =
# "vmseries-bootstrap-aws-s3bucket=<bucket>". Required layout:
#
#   /config/init-cfg.txt      mgmt-plane bootstrap parameters
#   /config/bootstrap.xml     full PAN-OS running config
#   /license/authcodes        BYOL auth code(s)
#   /software/                (must exist, may be empty)
#   /content/                 (must exist, may be empty)
#   /plugins/                 (must exist, may be empty)
#
# Each firewall gets its OWN prefix because init-cfg.txt and bootstrap.xml
# differ per node (hostname, HA2 IP, peer IP, device priority).
###############################################################################

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "bootstrap" {
  bucket        = "${var.name_prefix}-bootstrap-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = { Name = "${var.name_prefix}-bootstrap" }
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "bootstrap" {
  bucket = aws_s3_bucket.bootstrap.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Deny any non-TLS access to the bootstrap material.
data "aws_iam_policy_document" "bootstrap_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.bootstrap.arn, "${aws_s3_bucket.bootstrap.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "bootstrap" {
  bucket     = aws_s3_bucket.bootstrap.id
  policy     = data.aws_iam_policy_document.bootstrap_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.bootstrap]
}

###############################################################################
# Rendered bootstrap content, per firewall
###############################################################################

locals {
  # Directories the bootstrap process expects to exist, even when empty.
  bootstrap_empty_dirs = ["software/", "content/", "plugins/"]

  # Whether auth codes were supplied. nonsensitive() is safe and necessary
  # here: this is a boolean "were any codes given", not the codes themselves,
  # and for_each cannot take a sensitive-derived value.
  write_authcodes = var.license_type == "byol" && nonsensitive(trimspace(var.panos_auth_codes) != "")

  # PAN-OS permitted-ip is a second, independent filter in front of the
  # management plane -- and unlike the security group it is baked into the
  # running config at first boot, so it cannot be widened later without
  # rebuilding the instance. When management is deliberately open, emit no
  # permitted-ip block at all rather than an entry of 0.0.0.0/0: that is the
  # PAN-OS-native way to express "unrestricted", and it keeps the GUI and the
  # XML API reachable from any source address.
  #
  # The list covers admin_workstation_cidrs too: otherwise the "Admin
  # Workstation" security-group rule would admit a host that PAN-OS itself then
  # refuses.
  panos_mgmt_sources  = distinct(concat(var.mgmt_allowed_cidrs, var.admin_workstation_cidrs))
  panos_permitted_ips = contains(local.panos_mgmt_sources, "0.0.0.0/0") ? [] : local.panos_mgmt_sources

  bootstrap_renders = {
    for key, fw in local.firewalls : key => {
      init_cfg = templatefile("${path.module}/templates/init-cfg.txt.tftpl", {
        hostname = fw.hostname
      })

      bootstrap_xml = templatefile("${path.module}/templates/bootstrap.xml.tftpl", {
        hostname         = fw.hostname
        config_version   = var.panos_config_version
        timezone         = var.timezone
        admin_username   = var.admin_username
        admin_phash      = data.external.admin_phash.result.phash
        admin_public_key = base64encode(trimspace(tls_private_key.fw.public_key_openssh))
        permitted_ips    = local.panos_permitted_ips
        vpc_cidr         = var.vpc_cidr
        ha_group_id      = var.ha_group_id
        device_priority  = fw.device_priority

        # HA2 is a dedicated, statically-addressed interface (ethernet1/1).
        # PAN-OS HA interfaces cannot use DHCP.
        ha2_ip      = local.fw_ips["ha2"][fw.index]
        ha2_netmask = local.ha2_netmask
        ha2_gateway = local.subnet_gateways["ha2"][fw.index]

        # HA1 rides the management interface; peer is the other node's mgmt IP.
        peer_mgmt_ip = local.fw_ips["mgmt"][1 - fw.index]

        # Dataplane next hops (the AWS implicit router in each subnet).
        untrust_gateway = local.subnet_gateways["untrust"][fw.index]
        trust_gateway   = local.subnet_gateways["trust"][fw.index]
      })
    }
  }
}

# Every object below carries the same depends_on. Without it Terraform writes
# the objects in parallel with enabling versioning, and enabling versioning is
# eventually consistent: an object written into that window comes back with a
# version_id S3 cannot resolve yet, the provider's post-create read fails with
# "couldn't find resource", and the object is tainted -- aborting the apply
# before the instances are ever created. Only the bucket ID is an implicit
# dependency, so the ordering has to be declared explicitly.
resource "aws_s3_object" "init_cfg" {
  for_each = local.firewalls

  bucket                 = aws_s3_bucket.bootstrap.id
  key                    = "${each.value.name}/config/init-cfg.txt"
  content                = local.bootstrap_renders[each.key].init_cfg
  content_type           = "text/plain"
  server_side_encryption = "AES256"
  etag                   = md5(local.bootstrap_renders[each.key].init_cfg)

  depends_on = [
    aws_s3_bucket_versioning.bootstrap,
    aws_s3_bucket_server_side_encryption_configuration.bootstrap,
    aws_s3_bucket_policy.bootstrap,
  ]
}

resource "aws_s3_object" "bootstrap_xml" {
  for_each = local.firewalls

  bucket                 = aws_s3_bucket.bootstrap.id
  key                    = "${each.value.name}/config/bootstrap.xml"
  content                = local.bootstrap_renders[each.key].bootstrap_xml
  content_type           = "application/xml"
  server_side_encryption = "AES256"
  etag                   = md5(local.bootstrap_renders[each.key].bootstrap_xml)

  depends_on = [
    aws_s3_bucket_versioning.bootstrap,
    aws_s3_bucket_server_side_encryption_configuration.bootstrap,
    aws_s3_bucket_policy.bootstrap,
  ]
}

# BYOL auth codes. Only written when license_type = "byol" and codes were
# supplied — an empty authcodes file makes the bootstrap licensing step fail.
resource "aws_s3_object" "authcodes" {
  for_each = {
    for k, v in local.firewalls : k => v if local.write_authcodes
  }

  bucket                 = aws_s3_bucket.bootstrap.id
  key                    = "${each.value.name}/license/authcodes"
  content                = "${trimspace(var.panos_auth_codes)}\n"
  content_type           = "text/plain"
  server_side_encryption = "AES256"

  depends_on = [
    aws_s3_bucket_versioning.bootstrap,
    aws_s3_bucket_server_side_encryption_configuration.bootstrap,
    aws_s3_bucket_policy.bootstrap,
  ]
}

resource "aws_s3_object" "empty_dirs" {
  for_each = {
    for pair in setproduct(keys(local.firewalls), local.bootstrap_empty_dirs) :
    "${pair[0]}-${pair[1]}" => {
      fw  = local.firewalls[pair[0]]
      dir = pair[1]
    }
  }

  bucket                 = aws_s3_bucket.bootstrap.id
  key                    = "${each.value.fw.name}/${each.value.dir}"
  content                = ""
  server_side_encryption = "AES256"

  depends_on = [
    aws_s3_bucket_versioning.bootstrap,
    aws_s3_bucket_server_side_encryption_configuration.bootstrap,
    aws_s3_bucket_policy.bootstrap,
  ]
}

# When no auth codes are supplied the /license directory must still exist.
resource "aws_s3_object" "license_dir" {
  for_each = {
    for k, v in local.firewalls : k => v if !local.write_authcodes
  }

  bucket                 = aws_s3_bucket.bootstrap.id
  key                    = "${each.value.name}/license/"
  content                = ""
  server_side_encryption = "AES256"

  depends_on = [
    aws_s3_bucket_versioning.bootstrap,
    aws_s3_bucket_server_side_encryption_configuration.bootstrap,
    aws_s3_bucket_policy.bootstrap,
  ]
}

# Keep a local copy of exactly what was uploaded, for troubleshooting.
resource "local_file" "rendered_bootstrap" {
  for_each = local.firewalls

  filename        = "${path.module}/.rendered/${each.value.name}-bootstrap.xml"
  content         = local.bootstrap_renders[each.key].bootstrap_xml
  file_permission = "0600"
}
