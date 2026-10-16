###############################################################################
# Outputs
###############################################################################

output "firewall_management_urls" {
  description = "PAN-OS web UI / XML API endpoints."
  value       = { for k, fw in local.firewalls : fw.name => "https://${aws_eip.mgmt[k].public_ip}" }
}

output "firewall_management_ips" {
  description = "Public management IPs, keyed by firewall name."
  value       = { for k, fw in local.firewalls : fw.name => aws_eip.mgmt[k].public_ip }
}

output "firewall_private_mgmt_ips" {
  description = "Private management IPs (these are the HA1 peer addresses)."
  value       = { for k, fw in local.firewalls : fw.name => local.fw_ips["mgmt"][fw.index] }
}

output "admin_username" {
  description = "PAN-OS superuser."
  value       = var.admin_username
}

output "admin_password_file" {
  description = "Local file containing the PAN-OS admin password (mode 0600)."
  value       = local_sensitive_file.admin_password.filename
}

output "ssh_private_key_file" {
  description = "Local SSH private key for the firewalls and workloads (mode 0600)."
  value       = local_sensitive_file.ssh_key.filename
}

output "floating_service_ip" {
  description = <<-EOT
    The public IP that moves between nodes on failover: inbound/published
    address, fixed IPSec tunnel endpoint, and the egress (SNAT) address.
  EOT
  value       = aws_eip.floating.public_ip
}

output "trust_eni_ids" {
  description = "Trust ENIs. These are the route-table next hops that swap on failover."
  value       = { for k, fw in local.firewalls : fw.name => aws_network_interface.fw["${k}-trust"].id }
}

output "untrust_eni_ids" {
  description = "Untrust ENIs (the floating EIP moves between these)."
  value       = { for k, fw in local.firewalls : fw.name => aws_network_interface.fw["${k}-untrust"].id }
}

output "failover_route_table_ids" {
  description = "Route tables the firewall rewrites on failover. Feed these to the AWS plugin."
  value       = local.failover_route_table_ids
}

output "region" {
  description = "Region the stack is deployed in."
  value       = var.region
}

output "vpc_id" {
  value       = aws_vpc.this.id
  description = "Security VPC ID."
}

output "subnet_ids" {
  description = "All subnets, keyed by <role>-<az-index>."
  value       = { for k, s in aws_subnet.this : k => s.id }
}

output "bootstrap_bucket" {
  description = "S3 bucket holding the bootstrap packages."
  value       = aws_s3_bucket.bootstrap.id
}

output "ami_id" {
  description = "VM-Series AMI in use."
  value       = local.ami_id
}

output "workload_instance_ids" {
  description = "Test workload instance IDs (connect with: aws ssm start-session --target <id>)."
  value       = var.deploy_test_workloads ? aws_instance.workload[*].id : []
}

output "workload_private_ips" {
  description = "Test workload private IPs."
  value       = var.deploy_test_workloads ? aws_instance.workload[*].private_ip : []
}

# Consumed by scripts/configure.py so the post-deploy step needs no arguments.
output "configure_inputs" {
  description = "Everything scripts/configure.py needs, as one JSON blob."
  sensitive   = true
  value = {
    region         = var.region
    admin_username = var.admin_username
    admin_password = local.effective_admin_password
    ha_group_id    = var.ha_group_id
    floating_eip = {
      allocation_id = aws_eip.floating.id
      public_ip     = aws_eip.floating.public_ip
    }
    route_table_ids = local.failover_route_table_ids
    inbound = {
      enabled   = local.inbound_dnat_enabled
      target_ip = local.inbound_target_ip
      service   = var.inbound_service
      # Either node's primary untrust IP: the floating EIP lands on whichever
      # node is active, and the rules are synced to both.
      match_ips = local.fw_ips["untrust"]
      # Matching trust IPs, used to source-NAT inbound requests so they reach
      # the workload from inside the VPC (its SG only admits the VPC CIDR).
      snat_ips = local.fw_ips["trust"]
    }
    firewalls = {
      for k, fw in local.firewalls : fw.name => {
        mgmt_public_ip       = aws_eip.mgmt[k].public_ip
        mgmt_private_ip      = local.fw_ips["mgmt"][fw.index]
        peer_mgmt_private_ip = local.fw_ips["mgmt"][1 - fw.index]
        instance_id          = aws_instance.fw[k].id
        trust_eni_id         = aws_network_interface.fw["${k}-trust"].id
        untrust_eni_id       = aws_network_interface.fw["${k}-untrust"].id
        untrust_cidr         = local.subnet_cidrs["untrust"][fw.index]
        trust_cidr           = local.subnet_cidrs["trust"][fw.index]
        device_priority      = fw.device_priority
        availability_zone    = fw.az
      }
    }
    workload_ips = var.deploy_test_workloads ? aws_instance.workload[*].private_ip : []
    # Branch firewall and the IPsec tunnel to it; null when deploy_branch = false.
    branch = var.deploy_branch ? {
      name                 = local.branch_name
      mgmt_public_ip       = aws_eip.branch["mgmt"].public_ip
      instance_id          = aws_instance.branch_fw[0].id
      availability_zone    = local.branch_az
      workload_instance_id = local.branch_workload_enabled == 1 ? aws_instance.branch_workload[0].id : ""
      workload_ip          = local.branch_workload_enabled == 1 ? aws_instance.branch_workload[0].private_ip : ""
    } : null
    vpn = var.deploy_branch ? {
      psk              = local.effective_ipsec_psk
      hub_public_ip    = aws_eip.floating.public_ip
      branch_public_ip = aws_eip.branch["untrust"].public_ip
      hub_cidr         = var.vpc_cidr
      branch_cidr      = var.branch_vpc_cidr
      tunnel_cidr      = var.tunnel_cidr
      hub_tunnel_ip    = local.hub_tunnel_ip
      branch_tunnel_ip = local.branch_tunnel_ip
    } : null
  }
}

###############################################################################
# Branch site
###############################################################################

output "branch_firewall_management_url" {
  description = "Branch firewall web UI / XML API."
  value       = var.deploy_branch ? "https://${aws_eip.branch["mgmt"].public_ip}" : null
}

output "branch_tunnel_public_ip" {
  description = "Branch firewall's IPsec endpoint (its untrust EIP). The pair's end is floating_service_ip."
  value       = var.deploy_branch ? aws_eip.branch["untrust"].public_ip : null
}

output "branch_workload_instance_id" {
  description = "Branch test workload (aws ssm start-session --target <id>)."
  value       = local.branch_workload_enabled == 1 ? aws_instance.branch_workload[0].id : null
}

output "branch_workload_private_ip" {
  description = "Branch test workload private IP. From a pair workload: curl http://<this>/ip"
  value       = local.branch_workload_enabled == 1 ? aws_instance.branch_workload[0].private_ip : null
}

output "ipsec_psk_file" {
  description = "Local file containing the IKE pre-shared key (mode 0600)."
  value       = var.deploy_branch ? local_sensitive_file.ipsec_psk[0].filename : null
}
