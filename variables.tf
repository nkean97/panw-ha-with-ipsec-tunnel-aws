###############################################################################
# General
###############################################################################

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-2"
}

variable "availability_zones" {
  description = "Exactly two AZs. FW-A lands in [0], FW-B in [1]."
  type        = list(string)
  default     = ["us-east-2a", "us-east-2b"]

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Active/Passive HA requires exactly two availability zones."
  }
}

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "panw-ha"
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}

###############################################################################
# Networking
###############################################################################

variable "vpc_cidr" {
  description = "CIDR for the security VPC."
  type        = string
  default     = "10.100.0.0/16"
}

# Subnet layout is derived from vpc_cidr via cidrsubnet() in vpc.tf, so these
# are offsets (the 3rd octet) rather than hardcoded CIDRs.
variable "subnet_offsets" {
  description = <<-EOT
    /24 offsets within vpc_cidr for each subnet role, per AZ.
    Index 0 = AZ-A (FW-A), index 1 = AZ-B (FW-B).
  EOT
  type        = map(list(number))
  default = {
    mgmt     = [0, 10]
    ha2      = [1, 11]
    untrust  = [2, 12]
    trust    = [3, 13]
    workload = [20, 21]
  }
}

variable "host_index" {
  description = "Host octet used for firewall ENI primary IPs (e.g. 10.100.2.10)."
  type        = number
  default     = 10
}

variable "mgmt_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the firewall MANAGEMENT interfaces (HTTPS/SSH) and
    the PAN-OS permitted-ip list. Leave empty to auto-detect your current
    public IP (deploy.sh writes it into terraform.tfvars).

    Setting this to ["0.0.0.0/0"] opens the management plane to the whole
    internet. That is a deliberate, supported choice for a short-lived lab --
    it also makes PAN-OS drop its permitted-ip list entirely, which removes a
    whole class of "the GUI loads but the API is silently blackholed" problems
    when your egress IP is dynamic or a rotating NAT pool. Do not do it for
    anything long-lived: narrow it once the pair is up and configured.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.mgmt_allowed_cidrs : can(cidrnetmask(c))
    ])
    error_message = "Every entry in mgmt_allowed_cidrs must be a valid IPv4 CIDR (e.g. 203.0.113.10/32)."
  }
}

variable "admin_workstation_cidrs" {
  description = <<-EOT
    Sources allowed ALL traffic to the firewall management interfaces (one
    rule per CIDR, each described "Admin Workstation"), not just HTTPS/SSH.
    The default halves together cover all of IPv4: on a rotating corporate
    egress (Prisma Access) the address the firewalls see cannot be predicted
    from the deploying machine. Narrow it to /32s for anything long-lived.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/1", "128.0.0.0/1"]

  validation {
    condition = alltrue([
      for c in var.admin_workstation_cidrs : can(cidrnetmask(c))
    ])
    error_message = "Every entry in admin_workstation_cidrs must be a valid IPv4 CIDR (e.g. 203.0.113.10/32)."
  }
}

###############################################################################
# VM-Series
###############################################################################

variable "license_type" {
  description = "byol | bundle1 | bundle2. Selects the AWS Marketplace product code."
  type        = string
  default     = "byol"

  validation {
    condition     = contains(["byol", "bundle1", "bundle2"], var.license_type)
    error_message = "license_type must be one of: byol, bundle1, bundle2."
  }
}

variable "panos_auth_codes" {
  description = <<-EOT
    BYOL authorisation code(s) from the Palo Alto CSP, one per line. Written to
    /license/authcodes in the bootstrap bucket so each firewall self-licenses on
    first boot. Used when license_type = "byol"; ignored otherwise.

    Set this in terraform.tfvars (git-ignored), never here. Both firewalls
    bootstrap from the same code, which is how a VM-Series HA pair is normally
    entitled -- the auth code must cover two instances.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "panos_version_filter" {
  description = "AMI name filter. 'PA-VM-AWS-11.2.15-*' pins a release (and its hotfixes); 'PA-VM-AWS-11.2*' a major.minor; 'PA-VM-AWS-*' the newest."
  type        = string
  default     = "PA-VM-AWS-11.2.15-*"
}

variable "panos_config_version" {
  description = <<-EOT
    Schema version stamped into bootstrap.xml (<config version="...">). Must
    match the PAN-OS major.minor of the AMI, or the device rejects the config
    on load. Keep in sync with panos_version_filter.
  EOT
  type        = string
  default     = "11.2.0"
}

variable "ami_id" {
  description = "Explicit VM-Series AMI ID. Overrides the Marketplace lookup when set."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = <<-EOT
    EC2 type for the firewalls. Must support >= 4 ENIs and ENA.

    Sized for the VM-700 model, which PAN-OS requires to have 16 vCPUs and
    56 GiB of memory. m5.4xlarge (16 vCPU / 64 GiB / 8 ENIs) is the smallest
    AWS type that clears both. The VM-Series model itself comes from the
    capacity auth code, not from anything set here -- but if the instance is
    smaller than the licensed model, PAN-OS refuses the license and the
    management plane never finishes coming up.

    Dropping to a smaller model later means changing BOTH this and the auth
    code: m5.xlarge (4 vCPU / 16 GiB) suits VM-300, m5.2xlarge VM-500.
  EOT
  type        = string
  default     = "m5.4xlarge"
}

variable "root_volume_size" {
  description = "Root EBS size in GiB. PAN-OS 10.1+ images require at least 60."
  type        = number
  default     = 60

  validation {
    condition     = var.root_volume_size >= 60
    error_message = "PAN-OS 10.1+ requires a root volume of at least 60 GiB."
  }
}

variable "admin_username" {
  description = "PAN-OS superuser created by the bootstrap config."
  type        = string
  default     = "pandmin"

  validation {
    condition     = var.admin_username != "admin"
    error_message = "PAN-OS reserves/limits the literal 'admin' account on VM-Series; pick another name."
  }
}

variable "admin_password" {
  description = <<-EOT
    Password for admin_username. Leave empty and deploy.sh will generate a
    strong one and store it in ./.secrets/admin_password (chmod 600).
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "ha_group_id" {
  description = "PAN-OS HA group ID. Must match on both peers."
  type        = number
  default     = 10
}

variable "timezone" {
  description = "PAN-OS system timezone."
  type        = string
  default     = "US/Eastern"
}

###############################################################################
# Traffic inspection
###############################################################################

variable "enable_inbound_dnat" {
  description = <<-EOT
    Publish a workload through the floating IP: scripts/configure.py adds a
    destination-NAT rule (floating IP -> inbound_target_ip) and a matching
    security rule on the active node and syncs them to the passive one. With
    the defaults this is the test web server on the first workload:
    http://<floating_service_ip>/ shows the private IP of the server answering.
  EOT
  type        = bool
  default     = true
}

variable "inbound_target_ip" {
  description = "Private IP the inbound DNAT rule forwards to. Empty = the first test workload."
  type        = string
  default     = ""
}

variable "inbound_service" {
  description = "PAN-OS service object matched by the inbound DNAT rule (service-http = TCP 80, which the test web server listens on)."
  type        = string
  default     = "service-http"
}

variable "deploy_test_workloads" {
  description = "Deploy one SSM-managed test instance per AZ behind the firewall to validate the data path."
  type        = bool
  default     = true
}

variable "workload_instance_type" {
  description = "Instance type for the test workloads."
  type        = string
  default     = "t3.micro"
}

###############################################################################
# Branch site: a third VM-Series in its own VPC, IPsec to the HA pair
###############################################################################

variable "deploy_branch" {
  description = <<-EOT
    Build a branch VPC with a standalone VM-Series and an IPsec tunnel from it
    to the HA pair's floating EIP. scripts/configure.py configures the tunnel
    and installs the latest content updates on the branch firewall.
  EOT
  type        = bool
  default     = true
}

variable "branch_vpc_cidr" {
  description = "CIDR for the branch VPC. Must not overlap vpc_cidr: it is routed over the tunnel."
  type        = string
  default     = "10.200.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.branch_vpc_cidr))
    error_message = "branch_vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "branch_availability_zone" {
  description = "AZ for the branch firewall and its subnets. Empty = availability_zones[0]."
  type        = string
  default     = ""
}

variable "branch_instance_type" {
  description = <<-EOT
    EC2 type for the branch firewall. Empty = instance_type. Must be at least
    as large as the VM-Series model its auth code licenses (see instance_type).
  EOT
  type        = string
  default     = ""
}

variable "branch_auth_codes" {
  description = <<-EOT
    BYOL auth code for the branch firewall. Empty = reuse panos_auth_codes,
    which then has to cover three instances. Set in terraform.tfvars only.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "ipsec_psk" {
  description = <<-EOT
    IKE pre-shared key for the branch tunnel. Leave empty to generate one into
    ./.secrets/ipsec_psk. Letters and digits only: it is sent inside XML.
  EOT
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9]*$", var.ipsec_psk))
    error_message = "ipsec_psk may contain only letters and digits."
  }
}

variable "tunnel_cidr" {
  description = "/30 for the tunnel interfaces: .1 on the HA pair, .2 on the branch (tunnel monitoring pings .1)."
  type        = string
  default     = "169.254.100.0/30"
}
