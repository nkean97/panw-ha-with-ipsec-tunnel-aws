# Palo Alto Networks VM-Series: Active/Passive HA across two AWS Availability Zones

> [!WARNING]
> **Not for production use.** This project is a demonstration. It was built
> to show that an active/passive firewall pair spread across two Amazon Web
> Services (AWS) Availability Zones can fail over while keeping a floating
> public IP address that does not change after failover.
>
> **Use it at your own risk.** It is not officially supported by Palo Alto
> Networks, AWS, or any other entity. No warranty is given, and nobody is
> responsible for any cost, outage, security exposure, or other consequence
> of using it.

Terraform and Python that build a pair of Palo Alto Networks VM-Series
firewalls in AWS (`us-east-2`), one in each of two Availability Zones (AZs),
running as an **active/passive high-availability (HA) pair**. Test servers sit
behind the pair, and a test web site is published on a public IP that moves
to whichever firewall is active.

**If you have never used this project, start with
[`DEPLOYMENT-GUIDE.md`](DEPLOYMENT-GUIDE.md).** It assumes no Terraform,
AWS, or Palo Alto experience and shows the expected output at every step.
This README is the reference: what gets built, how failover works, and why it
is designed the way it is.

---

## What it does, in one paragraph

Only one firewall handles traffic at a time. The test servers' AWS route
tables point at the **active** firewall, and one **floating** public IP is
attached to it. If the active firewall fails, the passive one takes over and
its VM-Series AWS plugin calls the AWS API to **repoint the route tables at
itself and move the floating IP to itself**. On the deployed stack, routes
moved in about **10 seconds** and the published web site answered again
within about **12 seconds** of the active firewall being suspended.

```
                                Internet
                                   │
                         floating EIP (public)
                     on the ACTIVE firewall's untrust IP
                                   │
            us-east-2a             │             us-east-2b
   ┌──────────────────────────┐    │    ┌──────────────────────────┐
   │ FW-A   (active)          │    │    │ FW-B   (passive)         │
   │ mgmt     10.100.0.10  ◄──┼─ HA1 ──►│ mgmt     10.100.10.10    │
   │ ha2      10.100.1.10  ◄──┼─ HA2 ──►│ ha2      10.100.11.10    │
   │ untrust  10.100.2.10  ◄──┼─ EIP    │ untrust  10.100.12.10    │
   │ trust    10.100.3.10     │         │ trust    10.100.13.10    │
   └────────────┬─────────────┘         └──────────────────────────┘
                │ route tables: 0.0.0.0/0 and cross-AZ traffic -> active trust ENI
   ┌────────────┴─────────────┐         ┌──────────────────────────┐
   │ workload 10.100.20.0/24  │         │ workload 10.100.21.0/24  │
   │ test server + web page   │         │ test server + web page   │
   └──────────────────────────┘         └──────────────────────────┘
```

On failover the arrows that point at FW-A (the routes and the floating EIP)
move to FW-B. Nothing else changes.

---

## Quick start

```bash
cd panw-ha-aws
aws sts get-caller-identity          # confirm the AWS CLI is logged in
./deploy.sh                          # check, plan, confirm, build, configure, verify
```

Allow about **30 minutes**: roughly 5 for Terraform, then 10 to 20 while the
firewalls boot, then a few minutes of configuration. When it finishes:

```bash
terraform output floating_service_ip           # open http://<this IP>/ in a browser
python3 scripts/configure.py --failover-test   # suspend the active firewall, measure recovery
```

The web page shows the private IP of the server that answered. It should
show the same server before and after a failover.

| Command | What it does |
|---|---|
| `./deploy.sh` | Pre-flight checks, plan, prompt, apply, then `configure.py` |
| `./deploy.sh --plan-only` | Pre-flight checks and plan; builds nothing |
| `./deploy.sh --yes` | Same as `./deploy.sh` without the prompt |
| `./deploy.sh --verify` | Same as `configure.py --verify-only` |
| `python3 scripts/configure.py` | Post-deploy configuration, then verification (safe to re-run) |
| `python3 scripts/configure.py --verify-only` | Read-only health check |
| `python3 scripts/configure.py --failover-test` | Suspend the active firewall, time the route move and the web site's recovery, then restore it as standby |
| `python3 scripts/configure.py --sync-config` | Copy policy changes from the active firewall to the passive one |
| `./scripts/watch-failover.sh` | Read-only live view of the route tables (run in a second terminal) |
| `./destroy.sh` | Delete everything |

---

## What gets built

| Layer | What |
|---|---|
| Network | VPC `10.100.0.0/16`, internet gateway, 10 subnets (mgmt, ha2, untrust, trust, workload, one of each per AZ), route tables |
| Firewalls | 2 × VM-Series on `m5.4xlarge` (16 vCPU / 64 GiB, needed for the licensed model), 4 network interfaces (ENIs) each, source/destination check off on the data interfaces |
| Public IPs | 1 Elastic IP (EIP) per firewall for management, plus **1 floating EIP** that serves inbound and outbound traffic and follows the active firewall |
| IAM | Firewall instance role: read the bootstrap bucket, and `ReplaceRoute` / `AssociateAddress` (scoped to this stack's route tables) for failover |
| Bootstrap | Encrypted, versioned, TLS-only S3 bucket holding each firewall's `init-cfg.txt`, `bootstrap.xml` and license auth code |
| Test workloads | 1 × Amazon Linux 2023 `t3.micro` per AZ, managed through AWS Systems Manager (SSM). No SSH, no public IP. Each runs a small web server showing its own IP |
| Local files | `.secrets/admin_password` (PAN-OS password) and `.secrets/panw-ha-key.pem` (SSH key), mode 0600, git-ignored |

### Interface map

| AWS ENI | PAN-OS interface | Role | Address |
|---|---|---|---|
| eth0 | `management` | Web UI, XML API, and the HA1 control link | DHCP (fixed ENI IP) |
| eth1 | `ethernet1/1` | HA2 session-state sync (UDP 29281) | static |
| eth2 | `ethernet1/2` | untrust (internet side) | DHCP (fixed ENI IP) |
| eth3 | `ethernet1/3` | trust (inside) | DHCP (fixed ENI IP) |

HA2 uses UDP transport because the two HA2 interfaces are in different AZ
subnets, so the link is routed, and UDP passes VPC security groups cleanly.

### Firewall policy

| Rule | Source of truth | What it does |
|---|---|---|
| `outbound-snat` (NAT) | bootstrap | Workload egress is source-NATed to the untrust interface, which carries the floating EIP on the active firewall |
| `allow-outbound` | bootstrap | trust → untrust |
| `allow-east-west` | bootstrap | Workload-to-workload traffic across AZs, inspected on trust |
| `inbound-dnat-1`, `inbound-dnat-2` (NAT) | `configure.py` | Floating IP, TCP 80 → the test web server. One rule per firewall's untrust IP. Also source-NATs to that firewall's trust IP (see design notes) |
| `allow-inbound` | `configure.py` | untrust → trust for the published service, placed above `deny-all` |
| `deny-all` | bootstrap | Logged clean-up rule |

The inbound rules are added by `configure.py` rather than the bootstrap
because their target is a workload IP, and the workloads are built after the
firewalls boot. Set `enable_inbound_dnat = false` to skip them, or
`inbound_target_ip` / `inbound_service` to publish something else.

---

## How failover works, and the design decisions behind it

Each of these was tested on a live pair (PAN-OS 11.1.13-h12, VM-Series
plugin 5.1.11). Several replace earlier assumptions that turned out to be
wrong, so they are worth knowing before you change anything.

**1. The plugin does the AWS work, in `secondary-ip` failover mode.**
When a firewall becomes active, the VM-Series plugin repoints every route
that targets the peer's trust ENI at its own trust ENI, and moves the EIP
that sits on the peer's **primary** untrust IP to its own primary untrust IP.
It discovers both itself, so there are no route-table IDs to enter anywhere.
The AMI defaults to `interface-move` mode, which cannot work across AZs (an
ENI cannot attach to an instance in another AZ) and on these builds asks for
a reboot to change packet IO mode. `configure.py` sets `secondary-ip` with an
operational command on every run; it applies to both firewalls with no
commit. **Never accept the "packet mmap / reboot" prompt in the GUI.**

**2. One floating EIP on the primary untrust IP.**
Because the plugin moves whatever EIP is on the peer's primary untrust IP,
the floating EIP lives there. A secondary private IP cannot move to a subnet
in another AZ, so there are none. The passive firewall has no untrust EIP; it
does not need one, because its data interfaces are down while passive.
Terraform sets the EIP's initial placement on FW-A and then ignores where it
is (`ignore_changes`), so an apply after a failover never pulls it back.

**3. Preemption is off.**
With preemption on, the original firewall reclaimed the active role about 60
seconds after returning, while the other firewall's plugin was still moving
routes, and the two traded routes and the EIP back and forth. Now a restored
firewall comes back as **standby**, and failback is deliberate: run
`--failover-test` again, or suspend the active firewall.

**4. HA configuration sync is off; use `configure.py --sync-config` instead.**
Each firewall's static routes must use its **own** subnet's gateway (FW-A:
`10.100.2.1`, `10.100.3.1`; FW-B: `10.100.12.1`, `10.100.13.1`). Native HA
config sync copies the whole network config, so it overwrote the passive
firewall's routes with the active one's, and that firewall dropped all
traffic the moment it went active. AWS does not answer ARP for addresses
outside a subnet (tested), so routes without a next-hop IP cannot make the
two configs identical. Instead, `--sync-config` copies `shared` and `vsys1`
(rules, NAT, objects, zones, profiles) from the active firewall to the
passive one and commits there. It never copies network, HA, management or
admin settings. `configure.py` also checks that each firewall's next hops are
on its own subnets ("Firewall next hops").

**5. Inbound traffic is source-NATed at the firewall.**
The workloads' security group accepts only the VPC CIDR. The inbound rules
therefore translate the client's source address to the active firewall's
trust IP, which also guarantees the reply returns through the same firewall.
The trade-off: the web server sees the firewall, not the real client, as the
source.

**6. Existing connections do not survive a failover.**
Each firewall source-NATs to its own untrust or trust address, so open TCP
sessions reset and clients reconnect. New connections work as soon as the
routes move. Long-lived agents (the SSM agent, for example) can take a
couple of minutes to notice and reconnect.

### What `configure.py` does

Run with no arguments (it is idempotent, so re-running changes nothing that is
already right):

1. Waits for both firewalls' management APIs and logs in.
2. Reports licenses and fetches them if missing.
3. Sets the plugin failover mode to `secondary-ip`.
4. Creates or updates the inbound web rules on the active firewall, commits,
   and syncs policy to the passive firewall.
5. Verifies: IAM, HA state, each firewall's next hops, the AWS route tables,
   and that `http://<floating-ip>/` answers.

---

## Operating notes

**Changing firewall policy.** Make the change on the **active** firewall (web
UI or CLI) and commit it, then run:

```bash
python3 scripts/configure.py --sync-config
```

It refuses to run if the passive firewall has uncommitted changes, warns if
the active one does (only committed config is copied), and skips the commit
when the two already match. Network settings (interfaces, virtual router) are
per-firewall: change those on each firewall individually and keep each
firewall's next hops on its own subnets.

**Changing the bootstrap.** `bootstrap.xml` is read only at a firewall's
first boot. Editing the template and applying updates the files in S3 but not
a running firewall. To rebuild the firewalls with a new bootstrap:
`terraform apply -replace='aws_instance.fw["a"]' -replace='aws_instance.fw["b"]'`.

**Terraform after a failover is safe.** The workload routes, the floating
EIP's placement, and the ENIs' security groups all carry `ignore_changes`, so
`terraform apply` never undoes a failover. That is intentional, not drift.

**Management access.** Two variables control who can reach the management
interfaces, and both feed the security group and the firewall's own PAN-OS
`permitted-ip` list:

| Variable | Default | Allows |
|---|---|---|
| `mgmt_allowed_cidrs` | your public IP (`deploy.sh` writes it on first run) | HTTPS and SSH |
| `admin_workstation_cidrs` | `["0.0.0.0/1", "128.0.0.0/1"]` (all of IPv4) | All traffic, rule description "Admin Workstation" |

The wide default exists because corporate egress through Prisma Access uses a
different public IP per destination, so the address a firewall sees cannot be
predicted. Narrow it to `/32`s for anything long-lived. If your AWS account
runs security auto-remediation (for example Xpanse/XSOAR), expect it to
replace any management security group allowing `0.0.0.0/0` on SSH or HTTPS
with a copy minus that rule (`<group>-ar-NNN`), within a couple of hours. The ENIs
ignore security-group changes, so Terraform will not fight it, and **SSM port
forwarding** (see the deployment guide) always works as a fallback because it
needs no inbound rules.

**Credentials.** The PAN-OS superuser is `pandmin`; its password is in
`.secrets/admin_password`. The AMI's built-in `admin` account is kept as a
**key-only** superuser (`.secrets/panw-ha-key.pem`), so a bad password can
never lock you out of both firewalls.

**Licensing and Marketplace.** For BYOL, set your auth code in
`terraform.tfvars` as `panos_auth_codes = "YOUR-AUTH-CODE"`; each firewall
redeems it from its bootstrap at first boot, so it must cover two instances.
`terraform.tfvars` is git-ignored, so the code stays out of version control,
and `deploy.sh` refuses to run a BYOL deploy without it. `deploy.sh` checks the Marketplace subscription with a
`RunInstances --dry-run` before planning. Replacing a firewall does not
release its license: deactivate old serial numbers in the Palo Alto support
portal or the code may run out of seats.

**Cost.** Two `m5.4xlarge`, two `t3.micro` and three EIPs come to roughly
**$1.60 per hour (about $38 per day)** before any licensing. `./destroy.sh`
removes all of it.

---

## Known trade-offs

- **About 10 to 30 seconds of failover** (10 to 12 seconds measured), compared
  with a few seconds behind a Gateway Load Balancer, because recovery waits
  on AWS API calls.
- **Half the capacity idles**: the passive firewall passes no traffic.
- **Two firewalls, no horizontal scaling.**
- **Policy sync is a command, not automatic** (see design note 4). Panorama,
  with a per-firewall template variable for the gateways, is the
  fully managed alternative.

The reasons to choose this model are a single, predictable public IP (for
example as a fixed IPsec tunnel endpoint) and HA2 session-state replication.
If neither matters, Gateway Load Balancer with active/active firewalls is
usually the better fit, and most of this VPC layout would carry over.

---

## Layout

```
README.md                      this file: reference and design notes
DEPLOYMENT-GUIDE.md            step-by-step guide, no prior experience assumed
deploy.sh                      pre-flight checks, plan/apply, then configure.py
destroy.sh                     guarded teardown
versions.tf                    Terraform and provider versions
variables.tf                   all inputs, with validation
main.tf                        locals, AMI lookup, addressing, credentials
vpc.tf                         VPC, subnets, route tables
security_groups.tf             per-interface security groups
iam.tf                         firewall and workload IAM roles
bootstrap.tf                   S3 bootstrap bucket and rendered configs
firewalls.tf                   ENIs, EIPs, firewall instances
workloads.tf                   SSM-managed test servers
outputs.tf                     outputs, including configure_inputs for configure.py
templates/init-cfg.txt.tftpl   PAN-OS bootstrap parameters
templates/bootstrap.xml.tftpl  PAN-OS configuration applied at first boot
scripts/configure.py           post-deploy config, verification, failover test, policy sync
scripts/watch-failover.sh      read-only live route-table watcher
scripts/workload-web.sh        test web server (workload user_data)
scripts/sha512_crypt.py        SHA-crypt for the PAN-OS password hash ($5$ SHA-256 is what PAN-OS accepts)
scripts/phash_helper.py        Terraform external data source wrapping the above
```
