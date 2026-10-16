# Palo Alto Networks VM-Series in AWS: HA Pair plus an IPsec-Connected Branch Site

> [!WARNING]
> **Not for production use.** This project is a demonstration. It was built
> to show two things: an active/passive firewall pair spread across two
> Amazon Web Services (AWS) Availability Zones can fail over while keeping a
> floating public IP address, and a branch site's IPsec tunnel to that address
> follows the failover.
>
> **Use it at your own risk.** It is not officially supported by Palo Alto
> Networks, AWS, or any other entity. No warranty is given, and nobody is
> responsible for any cost, outage, security exposure, or other consequence
> of using it.

Terraform and Python that build **three Palo Alto Networks VM-Series
firewalls in two VPCs** in AWS (`us-east-2`):

1. **A security VPC with an active/passive high-availability (HA) pair**, one
   firewall in each of two Availability Zones (AZs). Test servers sit behind
   the pair, and a test web site is published on a **floating public IP** that
   moves to whichever firewall is active.
2. **A branch VPC with a standalone firewall**, licensed at first boot from
   its own bootstrap package, with a test server behind it.
3. **An IPsec tunnel** from the branch firewall to the pair's floating IP,
   joining the two VPCs. Because the pair's end of the tunnel is the floating
   IP, the tunnel follows the active firewall through a failover.

All three firewalls run PAN-OS 11.2.15, and each is updated to the latest
Applications and Threats, Antivirus and WildFire content, with recurring
updates scheduled.

One command (`./deploy.sh`) builds, configures and verifies all three. The
branch site and tunnel are on by default. Set `deploy_branch = false` to
build only the HA pair.

**If you have never used this project, start with
[`DEPLOYMENT-GUIDE.md`](DEPLOYMENT-GUIDE.md).** It assumes no Terraform,
AWS, or Palo Alto experience and shows the expected output at every step.
This README is the reference: what gets built, how failover and the tunnel
work, and why it is designed the way it is.

---

## Architecture at a glance

```
                                       Internet
               ┌──────────────────────────┴──────────────────────────┐
       branch tunnel EIP                                       floating EIP
               │                                      (always on the ACTIVE firewall)
               │◄════════════ IPsec tunnel (IKEv2, NAT-T) ══════════►│
               │                                                     │
 ┌─────────────┴─────────────┐   ┌───────────────────────────────────┴───────────────┐
 │ BRANCH VPC 10.200.0.0/16  │   │ SECURITY VPC 10.100.0.0/16                        │
 │ us-east-2a                │   │                                                   │
 │                           │   │   us-east-2a                      us-east-2b      │
 │  Branch FW (standalone)   │   │   FW-A  ACTIVE  ◄── HA1 + HA2 ──► FW-B  PASSIVE   │
 │             │             │   │        │                                          │
 │             │             │   │        │  route tables point at the active FW     │
 │  test server + web page   │   │   test servers + web page, one per AZ             │
 │  10.200.10.0/24           │   │   10.100.20.0/24              10.100.21.0/24      │
 └───────────────────────────┘   └───────────────────────────────────────────────────┘
```

| Part | What it is | What it demonstrates |
|---|---|---|
| **Security VPC (HA pair)** | FW-A and FW-B, active/passive across two AZs, with a floating Elastic IP (EIP) and a test server in each AZ | Failover with a public IP that does not change: routes and the floating EIP move to the new active firewall in about 10 seconds |
| **Branch VPC** | One standalone VM-Series and one test server | A third firewall, licensed at first boot from its own bootstrap package |
| **IPsec tunnel** | Route-based IKEv2 tunnel from the branch firewall to the floating EIP | Site-to-site traffic between the two VPCs. The tunnel stays pointed at the floating EIP when the pair fails over |

### What happens on failover

Only one firewall of the pair handles traffic at a time. The test servers'
AWS route tables point at the **active** firewall, and the **floating** public
IP is attached to it. If the active firewall fails, the passive one takes over
and its VM-Series AWS plugin calls the AWS API to **repoint the route tables
at itself and move the floating IP to itself**. On the deployed stack, routes
moved in about **10 seconds** and the published web site answered again
within about **12 seconds** of the active firewall being suspended.

The branch firewall's tunnel peer is the floating IP, not either firewall's
own address, so nothing changes at the branch. The new active firewall's
tunnel monitor finds that the security associations (SAs) it inherited from
its peer cannot carry traffic, and negotiates fresh ones with the branch
(design note 10). On the deployed stack the tunnel carried traffic again
about **35 seconds** after the failover. `configure.py --failover-test`
checks the tunnel again after each failover.

---

## Quick start

```bash
aws sts get-caller-identity          # confirm the AWS CLI is logged in
./deploy.sh                          # check, plan, confirm, build, configure, verify
```

Before the first run, put your BYOL auth code(s) in `terraform.tfvars`.
`panos_auth_codes` must cover three firewalls, or set `branch_auth_codes`
separately for the branch (see [Licensing](#licensing)).

Allow about **35 minutes**: roughly 5 for Terraform, then 10 to 20 while the
firewalls boot, then several minutes of configuration and content
downloads. When it finishes:

```bash
terraform output floating_service_ip           # open http://<this IP>/ in a browser
python3 scripts/configure.py --failover-test   # suspend the active firewall, measure recovery, re-check the tunnel
```

The web page shows the private IP of the server that answered. It should
show the same server before and after a failover.

| Command | What it does |
|---|---|
| `./deploy.sh` | Pre-flight checks, plan, prompt, apply, then `configure.py` |
| `./deploy.sh --plan-only` | Pre-flight checks and plan; builds nothing |
| `./deploy.sh --yes` | Same as `./deploy.sh` without the prompt |
| `./deploy.sh --verify` | Same as `configure.py --verify-only` |
| `python3 scripts/configure.py` | Post-deploy configuration of all three firewalls, then verification (safe to re-run) |
| `python3 scripts/configure.py --verify-only` | Health check of the pair, the published web site and the tunnel; changes no configuration |
| `python3 scripts/configure.py --failover-test` | Suspend the active firewall, time the route move and the web site's recovery, restore it as standby, then re-check the tunnel |
| `python3 scripts/configure.py --sync-config` | Copy policy changes from the active firewall to the passive one |
| `./scripts/watch-failover.sh` | Read-only live view of the route tables (run in a second terminal) |
| `./destroy.sh` | Delete everything |

---

## What gets built

### Security VPC: the HA pair

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
   │ tunnel.1 169.254.100.1   │         │ tunnel.1 169.254.100.1   │
   └────────────┬─────────────┘         └──────────────────────────┘
                │ route tables: 0.0.0.0/0 and cross-AZ traffic -> active trust ENI
   ┌────────────┴─────────────┐         ┌──────────────────────────┐
   │ workload 10.100.20.0/24  │         │ workload 10.100.21.0/24  │
   │ test server + web page   │         │ test server + web page   │
   └──────────────────────────┘         └──────────────────────────┘
```

On failover the arrows that point at FW-A (the routes and the floating EIP)
move to FW-B. Nothing else changes. Both firewalls carry the same tunnel
interface address; only the active one has its data interfaces up.

| Layer | What |
|---|---|
| Network | VPC `10.100.0.0/16`, internet gateway, 10 subnets (mgmt, ha2, untrust, trust, workload, one of each per AZ), route tables |
| Firewalls | 2 × VM-Series on `m5.4xlarge` (16 vCPU / 64 GiB, needed for the licensed model), 4 network interfaces (ENIs) each, source/destination check off on the data interfaces |
| Public IPs | 1 Elastic IP (EIP) per firewall for management, plus **1 floating EIP** that serves inbound traffic, outbound traffic and the tunnel, and follows the active firewall |
| IAM | Firewall instance role: read the bootstrap bucket, and `ReplaceRoute` / `AssociateAddress` (scoped to this stack's route tables) for failover |
| Test workloads | 1 × Amazon Linux 2023 `t3.micro` per AZ, managed through AWS Systems Manager (SSM). No SSH, no public IP. Each runs a small web server showing its own IP |

| AWS ENI | PAN-OS interface | Role | Address |
|---|---|---|---|
| eth0 | `management` | Web UI, XML API, and the HA1 control link | DHCP (fixed ENI IP) |
| eth1 | `ethernet1/1` | HA2 session-state sync (UDP 29281) | static |
| eth2 | `ethernet1/2` | untrust (internet side, tunnel endpoint) | DHCP (fixed ENI IP) |
| eth3 | `ethernet1/3` | trust (inside) | DHCP (fixed ENI IP) |
| — | `tunnel.1` | IPsec to the branch, zone `vpn` | `169.254.100.1/30` |

HA2 uses UDP transport because the two HA2 interfaces are in different AZ
subnets, so the link is routed, and UDP passes VPC security groups cleanly.

### Branch VPC: the standalone firewall

```
                         Internet
                            │
             branch tunnel EIP  ◄═══ IPsec ═══►  floating EIP (security VPC)
                            │
                            │  us-east-2a
   ┌────────────────────────┴─────┐
   │ Branch FW (standalone)       │
   │ mgmt     10.200.0.10  (EIP)  │
   │ untrust  10.200.1.10  (EIP)  │
   │ trust    10.200.2.10         │
   │ tunnel.1 169.254.100.2       │
   └──────────────┬───────────────┘
                  │ route table: 0.0.0.0/0 -> branch FW trust ENI
   ┌──────────────┴───────────────┐
   │ workload 10.200.10.0/24      │
   │ test server + web page       │
   └──────────────────────────────┘
```

| Layer | What |
|---|---|
| Network | VPC `10.200.0.0/16` (`branch_vpc_cidr`), internet gateway, 4 subnets (mgmt, untrust, trust, workload) in one AZ, route tables |
| Firewall | 1 × VM-Series, same image as the pair, `m5.4xlarge` by default (`branch_instance_type`, empty = `instance_type`), 3 ENIs, no HA |
| Public IPs | 1 EIP for management, 1 EIP on untrust as the tunnel endpoint |
| IAM | Its own role: read **only** its own prefix of the bootstrap bucket. It has none of the pair's failover permissions |
| Untrust security group | Admits only the floating EIP. Nothing is published at the branch |
| Test workload | 1 × `t3.micro`, same web server as the pair's test servers, SSM-managed |

| AWS ENI | PAN-OS interface | Role | Address |
|---|---|---|---|
| eth0 | `management` | Web UI, XML API, licensing, content updates | DHCP (fixed ENI IP) |
| eth1 | `ethernet1/1` | untrust (internet side, tunnel endpoint) | DHCP (fixed ENI IP) |
| eth2 | `ethernet1/2` | trust (inside) | DHCP (fixed ENI IP) |
| — | `tunnel.1` | IPsec to the HA pair, zone `vpn` | `169.254.100.2/30` |

### Shared by both sites

| Layer | What |
|---|---|
| Bootstrap | One encrypted, versioned, TLS-only S3 bucket. Each firewall has its own prefix holding its `init-cfg.txt`, `bootstrap.xml` and license auth code |
| Credentials | One PAN-OS admin password and one SSH key for all three firewalls |
| Local files | `.secrets/admin_password` (PAN-OS password), `.secrets/panw-ha-key.pem` (SSH key) and `.secrets/ipsec_psk` (IKE pre-shared key), mode 0600, git-ignored |

### The IPsec tunnel

| Item | Setting |
|---|---|
| Endpoints | Branch untrust EIP ↔ the pair's floating EIP |
| IKE | IKEv2, AES-256-CBC / SHA-256 / DH group 14, 8 h; pre-shared key (generated into `.secrets/ipsec_psk`, or set `ipsec_psk`) |
| IPsec | ESP AES-256-CBC / SHA-256, PFS group 14, 1 h |
| NAT traversal | On at both ends. Both firewalls sit behind AWS 1:1 NAT, so each identifies itself by its **public** IP (IKE ID type `ipaddr`) |
| Tunnel interfaces | `tunnel.1` on all three firewalls, `169.254.100.0/30` (`tunnel_cidr`): `.1` on the pair, `.2` at the branch |
| Routing | Static route on each end: the other VPC's CIDR via `tunnel.1`. The pair's workload route tables need no change (their default route already points at the active firewall) |
| Tunnel monitoring | Both ends ping the other's tunnel address every 3 s (profile `panw-tunnel-monitor`, 5 misses = down, action wait-recover). Keeps an SA up at all times; on the pair it is what renegotiates after a failover (design note 10) |
| Names | Pair: IKE gateway `branch-gw`, tunnel `to-branch`. Branch: IKE gateway `hub-gw`, tunnel `to-hub` |

### Firewall policy

| Rule | On | Source of truth | What it does |
|---|---|---|---|
| `outbound-snat` (NAT) | all three | bootstrap | Workload egress is source-NATed to the untrust interface. On the pair that carries the floating EIP; at the branch, the branch EIP |
| `allow-outbound` | all three | bootstrap | trust → untrust |
| `allow-east-west` | pair | bootstrap | Workload-to-workload traffic across AZs, inspected on trust |
| `inbound-dnat-1`, `inbound-dnat-2` (NAT) | pair | `configure.py` | Floating IP, TCP 80 → the test web server. One rule per firewall's untrust IP. Also source-NATs to that firewall's trust IP (see design notes) |
| `allow-inbound` | pair | `configure.py` | untrust → trust for the published service |
| `allow-site-to-site` | all three | `configure.py` | trust ↔ vpn, between the two VPC CIDRs |
| `allow-tunnel-monitor` | all three | `configure.py` | Ping between the tunnel interface addresses (vpn → vpn) |
| `allow-ike` | all three | `configure.py` | IKE and ESP between the tunnel peer's public IP and this site's private range, both directions (untrust → untrust; see design note 9) |
| `deny-all` | all three | bootstrap | Logged clean-up rule. Every rule above sits before it |

The inbound rules are added by `configure.py` rather than the bootstrap
because their target is a workload IP, and the workloads are built after the
firewalls boot. Set `enable_inbound_dnat = false` to skip them, or
`inbound_target_ip` / `inbound_service` to publish something else. Why the
tunnel rules also come from `configure.py` is design note 7.

---

## How it is configured

**Terraform** builds both VPCs and all three firewalls. Each firewall boots
from its own bootstrap package, which sets interfaces, zones, routes, the
egress policy, the admin accounts and (for BYOL) the license. The pair's
package also carries the HA settings.

**`scripts/configure.py`** then does what a bootstrap package cannot. Run
with no arguments, it is idempotent: re-running changes nothing that is
already right.

1. Waits for all three firewalls' management APIs and logs in.
2. Reports licenses and fetches them if missing.
3. Sets the pair's AWS plugin failover mode to `secondary-ip`.
4. **Content updates, on all three firewalls:** downloads and installs the
   newest Applications and Threats package (it carries the Advanced Threat
   Prevention signatures), then the newest Antivirus and WildFire packages if
   those licenses are present. Then it schedules recurring updates: threats
   every 30 minutes, antivirus hourly, WildFire every minute, all
   download-and-install. Each node of the pair is updated on its own, because
   HA config sync is off.
5. **IPsec tunnel:** configures both ends (crypto profiles, `tunnel.1`, IKE
   gateway, IPsec tunnel, static route, zone `vpn`, the tunnel rules) on all
   three firewalls, and commits each.
6. Creates or updates the inbound web rules on the active firewall, commits,
   and syncs policy to the passive firewall.
7. Verifies: IAM, HA state, each firewall's next hops, the AWS route tables,
   that `http://<floating-ip>/` answers, and the tunnel. For the tunnel it
   checks for an SA at the branch (and starts negotiation if there is none),
   reports the SA on the active firewall of the pair, then has the branch
   test server fetch `http://<pair test server>/ip` through SSM, across the
   tunnel.

`--verify-only` runs steps 1, 2 and 7 only.

---

## Design decisions

Every note was verified on a live deployment of PAN-OS 11.2.15, the version
this project deploys (`panos_version_filter`), including failover tests in
both directions. Several replace earlier assumptions that turned out to be
wrong, so they are worth knowing before you change anything.

### HA pair

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
The workloads' security group accepts only the VPC CIDRs. The inbound rules
therefore translate the client's source address to the active firewall's
trust IP, which also guarantees the reply returns through the same firewall.
The trade-off: the web server sees the firewall, not the real client, as the
source.

**6. Existing connections do not survive a failover.**
Each firewall source-NATs to its own untrust or trust address, so open TCP
sessions reset and clients reconnect. New connections work as soon as the
routes move. Long-lived agents (the SSM agent, for example) can take a
couple of minutes to notice and reconnect.

### Branch site and tunnel

**7. The tunnel is configured over the XML API, not in the bootstrap.**
When the pre-shared key is sent through the API, PAN-OS stores it encrypted.
Using the API also means a pair that is already running gets the tunnel
without being rebuilt. Each node of the pair gets its own copy of the
tunnel's network configuration, because HA config sync is off (note 4). The
tunnel policy comes out identical on both nodes, so `--sync-config` has
nothing extra to copy.

**8. The pair's end of the tunnel is the floating EIP.**
The IKE gateway on each node of the pair names only the untrust interface as
its local address. That interface uses DHCP and has a different IP on each
node. The IKE ID is the floating EIP, which belongs to whichever node is
active. The branch therefore always peers with the same public address,
and a failover needs no change at the branch.

**9. NAT traversal, public IKE IDs, and a two-way IKE rule.**
Both ends sit behind AWS 1:1 NAT: each firewall only knows its private
address. NAT-T is on at both ends, and each end identifies itself by its
public IP. The default ID would be the private address, which the peer
would not accept. The same NAT shapes `allow-ike`: a firewall's own IKE
packets are checked against its security policy too, and they leave from its
**private** untrust address, while the peer's arrive from its **public** one.
A rule that allows only the peer's address blocks the firewall's own
initiation, so `allow-ike` lists both addresses as source and destination
(found on the first live deploy: the branch's IKE hit `deny-all`).

**10. Both ends monitor the tunnel; the pair's monitor is what recovers a
failover.** HA2 copies the active firewall's IPsec SAs to the passive one,
including the active firewall's **private** local address. Within one AZ the
two would share that address; across AZs they cannot, so after a failover
the new active firewall holds SAs that send from its peer's address, and AWS
drops every packet. Inbound tunnel traffic still decrypts, so the SAs look
up. IKE SAs are not copied, though. When the new active firewall's tunnel
monitor fails (about 15 s: 5 pings 3 s apart), it has no IKE SA to rekey
inside, so it negotiates a fresh one from its **own** address, and the
branch accepts it in place of its stale one.

This was found by testing. With only the branch monitoring, the branch kept
retrying inside its stale IKE SA, and the tunnel stayed down until dead-peer
detection expired it: about 10 minutes, in two runs. Switching the branch's
monitor action from wait-recover to fail-over made no difference. With the
pair monitoring too, the tunnel was back about 35 s after the failover
(FW-A active at 13:55:53, fresh IKE SA from its own address at 13:56:25).
A passive firewall's monitor sits idle, because its data interfaces are down.

---

## Operating notes

**Changing policy on the pair.** Make the change on the **active** firewall
(web UI or CLI) and commit it, then run:

```bash
python3 scripts/configure.py --sync-config
```

It refuses to run if the passive firewall has uncommitted changes, warns if
the active one does (only committed config is copied), and skips the commit
when the two already match. Network settings (interfaces, virtual router,
IPsec) are per-firewall: change those on each firewall individually and keep
each firewall's next hops on its own subnets.

**Changing policy at the branch.** The branch firewall is standalone: change
it directly and commit. Nothing is synced to or from it.

**Changing the bootstrap.** `bootstrap.xml` is read only at a firewall's
first boot. Editing the template and applying updates the files in S3 but not
a running firewall. To rebuild firewalls with a new bootstrap:
`terraform apply -replace='aws_instance.fw["a"]' -replace='aws_instance.fw["b"]'`
for the pair, `-replace='aws_instance.branch_fw[0]'` for the branch. Then run
`configure.py` again to restore the tunnel and content updates.

**Changing the pre-shared key.** `configure.py` sets the key when it creates
an IKE gateway, but cannot compare it later because PAN-OS stores it
encrypted. To change it, set `ipsec_psk`, delete the IKE gateways (`branch-gw`
on both nodes of the pair, `hub-gw` at the branch), and re-run
`configure.py`.

**Terraform after a failover is safe.** The workload routes, the floating
EIP's placement, and the ENIs' security groups all carry `ignore_changes`, so
`terraform apply` never undoes a failover. That is intentional, not drift.

**Leaving out the branch.** Set `deploy_branch = false`. On an existing
deploy that removes the branch infrastructure; the tunnel configuration stays
on the pair until you delete it.

**Management access.** Two variables control who can reach the management
interfaces of all three firewalls, and both feed the security groups and the
firewalls' own PAN-OS `permitted-ip` list:

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

**Credentials.** The PAN-OS superuser on all three firewalls is `pandmin`;
its password is in `.secrets/admin_password`. The AMI's built-in `admin`
account is kept as a **key-only** superuser (`.secrets/panw-ha-key.pem`), so
a bad password can never lock you out.

### Licensing

For BYOL, set your auth code in `terraform.tfvars`. Each firewall redeems a
code from its bootstrap package at first boot.

| Setting | Used by | Must cover |
|---|---|---|
| `panos_auth_codes` | FW-A, FW-B, and the branch if `branch_auth_codes` is empty | 3 instances (2 if you set `branch_auth_codes` or `deploy_branch = false`) |
| `branch_auth_codes` | the branch firewall | 1 instance |

`terraform.tfvars` is git-ignored, so the codes stay out of version control.
`deploy.sh` refuses to run a BYOL deploy without `panos_auth_codes`, warns
when the branch is reusing it, and checks the Marketplace subscription with
a `RunInstances --dry-run` before planning. Replacing a firewall does not
release its license: deactivate old serial numbers in the Palo Alto support
portal or the code may run out of seats. Antivirus and WildFire content
updates need the matching subscriptions on the branch's license; without
them `configure.py` installs Applications and Threats only and says so.

### Cost

| Part | Resources | Roughly |
|---|---|---|
| Security VPC | 2 × `m5.4xlarge`, 2 × `t3.micro`, 3 EIPs | $1.60 per hour |
| Branch VPC | 1 × `m5.4xlarge`, 1 × `t3.micro`, 2 EIPs | $0.80 per hour |
| **Total** | | **$2.40 per hour (about $58 per day)** |

Licensing is extra. The account needs 54 vCPUs of standard on-demand quota
(`deploy.sh` checks). `./destroy.sh` removes everything.

---

## Known trade-offs

- **About 10 to 30 seconds of failover** (10 to 12 seconds measured), compared
  with a few seconds behind a Gateway Load Balancer, because recovery waits
  on AWS API calls. The tunnel takes longer, about 35 seconds measured,
  because the new active firewall first has to detect that its inherited SAs
  are unusable (design note 10).
- **Half the pair's capacity idles**: the passive firewall passes no traffic.
- **Two firewalls in the pair, no horizontal scaling.**
- **Policy sync is a command, not automatic** (see design note 4). Panorama,
  with a per-firewall template variable for the gateways, is the
  fully managed alternative, and would also manage the branch.
- **One branch, one tunnel.** Adding branches means another VPC, firewall,
  IKE gateway and tunnel interface per site.

The reasons to choose this model are a single, predictable public IP (as a
fixed IPsec tunnel endpoint, which the branch site demonstrates) and HA2
session-state replication. If neither matters, Gateway Load Balancer with
active/active firewalls is usually the better fit, and most of this VPC
layout would carry over.

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
vpc.tf                         security VPC, subnets, route tables
security_groups.tf             security VPC per-interface security groups
iam.tf                         HA pair and workload IAM roles
bootstrap.tf                   S3 bootstrap bucket and the pair's rendered configs
firewalls.tf                   HA pair ENIs, EIPs, firewall instances
workloads.tf                   security VPC test servers
branch.tf                      branch VPC, firewall, test server, IAM and bootstrap (deploy_branch)
outputs.tf                     outputs, including configure_inputs for configure.py
templates/init-cfg.txt.tftpl          PAN-OS bootstrap parameters (all three firewalls)
templates/bootstrap.xml.tftpl         HA pair configuration applied at first boot
templates/branch-bootstrap.xml.tftpl  branch firewall configuration applied at first boot
scripts/configure.py           post-deploy config, content updates, IPsec tunnel, verification, failover test, policy sync
scripts/watch-failover.sh      read-only live route-table watcher
scripts/workload-web.sh        test web server (workload user_data)
scripts/sha512_crypt.py        SHA-crypt for the PAN-OS password hash ($5$ SHA-256 is what PAN-OS accepts)
scripts/phash_helper.py        Terraform external data source wrapping the above
```
