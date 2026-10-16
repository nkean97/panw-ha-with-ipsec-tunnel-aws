###############################################################################
# Test workloads
#
# One Amazon Linux 2023 instance per AZ in the workload subnets, managed via
# SSM Session Manager (no inbound SSH, no key handling). Their only path to
# the internet - including to the SSM endpoints - is through the firewall pair,
# so "can I open a session?" is itself an end-to-end data-path test.
###############################################################################

data "aws_ssm_parameter" "al2023" {
  count = var.deploy_test_workloads ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "workload" {
  count = var.deploy_test_workloads ? length(local.azs) : 0

  ami                    = data.aws_ssm_parameter.al2023[0].value
  instance_type          = var.workload_instance_type
  subnet_id              = aws_subnet.this["workload-${count.index}"].id
  vpc_security_group_ids = [aws_security_group.workload.id]
  iam_instance_profile   = aws_iam_instance_profile.workload[0].name
  key_name               = aws_key_pair.fw.key_name

  # Test web server on :80 showing this instance's private IP, ID and AZ from
  # IMDSv2. Python ships with AL2023, so nothing is downloaded: at first boot
  # the firewalls are usually not passing traffic yet, which is what broke the
  # earlier `dnf install nginx`.
  user_data = file("${path.module}/scripts/workload-web.sh")

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted = true
  }

  tags = { Name = "${var.name_prefix}-workload-${local.azs[count.index]}" }

  # The SSM parameter tracks the newest AL2023 image; without this every AMI
  # release would rebuild the test workloads on the next apply. user_data only
  # runs at first boot, so a change would just stop/start running instances;
  # push it to existing ones with SSM instead (see scripts/workload-web.sh).
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_instance.fw]
}
