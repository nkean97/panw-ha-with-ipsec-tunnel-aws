# Deployment Guide: VM-Series HA Pair plus an IPsec-Connected Branch Site in AWS

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

**Who this is for:** anyone with an AWS account and a Mac terminal. You do not
need to have used Terraform, Palo Alto firewalls, high availability (HA) or
IPsec before. Every command is copy-paste, and after each one this guide
tells you what you should see.

**What you will end up with:** three Palo Alto firewalls in AWS
(`us-east-2`), in two separate networks, joined by an encrypted tunnel:

1. **The main site: a high-availability pair.** Two firewalls in different
   Availability Zones (separate data centres), one **active** and one
   **passive**. Behind them sit two test servers, and a test web page is
   published on a public IP address.
2. **The branch site: a third firewall** in its own network, with one test
   server behind it.
3. **An IPsec tunnel** between the branch firewall and the main site, so the
   test servers at each site can reach each other privately.

All three run PAN-OS 11.2.15, license themselves, and install the latest
threat protection updates.

You will then deliberately take down the active firewall at the main site
and watch the passive one take over. The web page comes back in about 10 to
30 seconds, and the tunnel from the branch reconnects to the new active
firewall in under a minute, without any change at the branch.

**Time required:** about an hour, most of it waiting.
**Cost while running:** roughly **$2.40 per hour (about $58 per day)**.
[Part 11](#part-11--delete-everything) deletes everything; do it when you
are finished.

> Only want the HA pair? Set `deploy_branch = false` in `terraform.tfvars`
> before deploying. The branch steps in this guide then do not apply, and the
> cost drops to about $1.60 per hour.

---

## Table of contents

| Part | What you do | Time |
|---|---|---|
| [Part 1](#part-1--install-the-tools) | Install the tools | 10 min |
| [Part 2](#part-2--connect-the-aws-cli-to-your-account) | Connect the AWS CLI to your account | 5 min |
| [Part 3](#part-3--preview-the-build-and-add-your-license-codes) | Preview the build and add your license codes | 10 min |
| [Part 4](#part-4--deploy) | Deploy all three firewalls | 35 min |
| [Part 5](#part-5--log-in-to-the-firewalls) | Log in to the firewalls | 5 min |
| [Part 6](#part-6--confirm-everything-is-healthy) | Confirm everything is healthy (**do not skip**) | 5 min |
| [Part 7](#part-7--prove-traffic-flows-through-the-firewalls-and-the-tunnel) | Prove traffic flows through the firewalls and the tunnel | 10 min |
| [Part 8](#part-8--the-failover-test) | **The failover test** | 15 min |
| [Part 9](#part-9--making-configuration-changes) | Making configuration changes | as needed |
| [Part 10](#part-10--troubleshooting) | Troubleshooting | as needed |
| [Part 11](#part-11--delete-everything) | Delete everything | 10 min |

---

## A three-minute explanation of what you're building

```
                                       Internet
               ┌──────────────────────────┴──────────────────────────┐
       branch tunnel IP                                         floating IP
               │                                      (always on the ACTIVE firewall)
               │◄═══════════════ encrypted IPsec tunnel ════════════►│
               │                                                     │
 ┌─────────────┴─────────────┐   ┌───────────────────────────────────┴───────────────┐
 │ BRANCH SITE               │   │ MAIN SITE                                         │
 │ network 10.200.0.0/16     │   │ network 10.100.0.0/16                             │
 │                           │   │   us-east-2a                      us-east-2b      │
 │  Branch firewall          │   │   FW-A  ACTIVE  ◄── heartbeat ──► FW-B  PASSIVE   │
 │             │             │   │        │                                          │
 │             │             │   │        │  route tables point at the active FW     │
 │  test server + web page   │   │   test servers + web page, one per AZ             │
 └───────────────────────────┘   └───────────────────────────────────────────────────┘
```

### The main site: two firewalls, only one working at a time

- **FW-A** is in Availability Zone `us-east-2a` and starts as **active**.
- **FW-B** is in `us-east-2b` and starts as **passive**: powered on,
  configured, receiving a copy of FW-A's connection table, but passing no
  traffic.

Two things point at the active firewall:

1. **The route tables.** The test servers send their traffic wherever their
   AWS route table says. Think of a route table as a signpost: "to reach the
   internet, go to FW-A."
2. **The floating IP.** One public IP address (an AWS *Elastic IP*, or EIP)
   is attached to the active firewall. The test web page is published on
   it, the test servers' outbound traffic leaves from it, and the branch's
   tunnel connects to it.

When the active firewall fails, the passive one promotes itself, and a piece
of firewall software called the **VM-Series AWS plugin** calls the AWS API to
**turn both signposts around**: the route tables now point at FW-B, and the
floating IP moves to FW-B. You will watch that happen in Part 8.

### The branch site: one firewall on its own

A separate network with a single firewall and a test server. It is not part
of the HA pair and does not fail over. It stands in for a remote office that
needs to reach servers at the main site.

### The tunnel: what joins the two

The branch firewall builds an encrypted **IPsec tunnel** across the internet
to the main site's **floating IP**. Traffic between the two networks
(`10.200.x.x` and `10.100.x.x`) goes through it. Because the branch connects
to the floating IP and not to FW-A itself, a failover at the main site just
means the tunnel reconnects, to FW-B now, at the same address. Both ends
check the tunnel every few seconds, so the new active firewall notices it
needs a fresh connection and makes one on its own, in about 35 seconds.

Every test server runs a small web page showing its own private IP address,
so you can always tell which server answered and over which path.

---

# Part 1 — Install the tools

Open the **Terminal** app on your Mac. You type commands at the prompt and
press Enter after each one.

> **Tip:** lines in grey boxes are commands. Don't type the surrounding text,
> or a leading `$` if you see one.

## 1.1 — Check what you already have

Paste this whole block and press Enter:

```bash
for t in terraform aws python3 curl session-manager-plugin; do
  if command -v "$t" >/dev/null 2>&1; then echo "OK      $t"; else echo "MISSING $t"; fi
done
```

You get five lines. Install anything marked `MISSING` using the sections
below, then run the check again.

## 1.2 — Homebrew (installs everything else)

If you have never used Homebrew, install it:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

It asks for your Mac password. Typing it shows nothing on screen; that's
normal. At the end it may print two `echo >> ~/.zprofile` commands and tell
you to run them. **Run them**, then close and reopen Terminal.

## 1.3 — Terraform

Terraform is the tool that creates the AWS resources.

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform version
```

Expect `Terraform v1.x.x`; 1.7 or newer is needed.

## 1.4 — AWS CLI

```bash
brew install awscli
aws --version
```

Expect something like `aws-cli/2.x.x`.

## 1.5 — Python 3

macOS usually has it:

```bash
python3 --version
```

Expect `Python 3.9` or newer. If it's missing: `brew install python3`.

## 1.6 — Session Manager plugin

This lets you reach things **inside** the AWS networks (a shell on a test
server, or a firewall's web page) without opening any firewall rules. It is
also your way back in if you ever get locked out of the firewalls'
management pages, so install it.

```bash
brew install --cask session-manager-plugin
session-manager-plugin --version
```

## 1.7 — Final check

Re-run the block from step 1.1. All five lines should say `OK`.

---

# Part 2 — Connect the AWS CLI to your account

The AWS CLI needs permission to build things in your account. Use **one** of
these two methods.

## Method A — AWS SSO / IAM Identity Center (most companies)

If your company gave you an SSO start URL:

```bash
aws configure sso
```

Follow the browser prompts and choose region `us-east-2`. SSO sessions
expire after some hours. When a command fails with `ExpiredToken`,
`InvalidGrantException` or `No valid credential sources found`, run:

```bash
aws sso login
```

## Method B — Access keys

1. Sign in to the AWS Console: <https://console.aws.amazon.com>
2. Click your account name (top right) → **Security credentials**.
3. **Access keys** → **Create access key** → **Command Line Interface (CLI)**
   → tick the acknowledgement → **Next** → **Create access key**.
4. The **secret access key** is shown once only. Keep the tab open until
   step 6 is done.
5. In Terminal: `aws configure`
6. Answer the prompts:
   ```
   AWS Access Key ID [None]:      <paste the access key ID>
   AWS Secret Access Key [None]:  <paste the secret access key>
   Default region name [None]:    us-east-2
   Default output format [None]:  json
   ```

## 2.1 — Verify it works

```bash
aws sts get-caller-identity
```

**Success looks like:**
```json
{
    "UserId": "AIDXXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/yourname"
}
```

`Unable to locate credentials` means the setup didn't take; run it again.
`ExpiredToken` means run `aws sso login`.

## 2.2 — Permissions you need

You need to be able to create VPCs, EC2 instances, IAM roles and S3 buckets.
The `AdministratorAccess` policy covers it. If you don't have that, get the
rights before Part 4; failing halfway is messier to clean up than not
starting.

## 2.3 — Check your EC2 capacity limit now

AWS caps how much compute an account may run. This trips up most first
deployments, so check before building anything:

```bash
aws service-quotas get-service-quota --region us-east-2 \
  --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text
```

**You need at least `54.0`**: three 16-vCPU firewalls plus three small test
servers. If it's lower (new accounts often show `5.0`), request an increase
now so it can be approved while you continue:

```bash
aws service-quotas request-service-quota-increase \
  --region us-east-2 --service-code ec2 \
  --quota-code L-1216C47A --desired-value 64
```

`deploy.sh` checks this too and refuses to start if it's too low. Details in
[Part 10](#problem-vcpulimitexceeded--quota-too-low).

---

# Part 3 — Preview the build and add your license codes

Go to the project folder:

```bash
cd ~/Downloads/panw-ha-aws
ls
```

You should see `deploy.sh`, `destroy.sh`, `main.tf`, `branch.tf`,
`templates`, `scripts`, `README.md` and others.

Run a **dry run**. It creates nothing, costs nothing, and can be repeated:

```bash
./deploy.sh --plan-only
```

### What happens, in order

| Stage | What it means | Good output |
|---|---|---|
| Checking prerequisites | Your tools are present; the password-hashing code passes its self-test | no errors |
| Checking AWS access | Your credentials work | your account number and ARN |
| Marketplace subscription | Your account may launch the Palo Alto image | `Marketplace subscription active for byol` |
| EC2 vCPU quota | Your account may run enough compute | `vCPU quota is sufficient` |
| Preparing terraform.tfvars | First run only: writes your settings file with your current public IP | `wrote terraform.tfvars` |
| terraform init / validate | Downloads providers, checks the code | `Success! The configuration is valid.` |
| terraform plan | Lists what would be created | `Plan: NN to add, 0 to change, 0 to destroy.` |

On the very first run it stops at **Preparing terraform.tfvars** with
`panos_auth_codes is not set`. That is expected: add your license codes
(3.1) and run it again.

When it gets all the way through, nothing has been built. The exact number
to add varies by version (about 150 with the branch site); what matters is
**`0 to destroy`** and no red `Error:`.

## 3.1 — License codes

Each firewall licenses itself with Palo Alto the first time it starts, using
an **auth code** from the Palo Alto Customer Support Portal. Open your
settings file:

```bash
open -e terraform.tfvars
```

Choose one of these:

- **One code for all three firewalls.** Put it on the `panos_auth_codes`
  line. The code must have **three** seats (FW-A, FW-B and the branch).
  ```hcl
  panos_auth_codes = "YOUR-AUTH-CODE"
  ```
- **A separate code for the branch.** The main code then needs only two
  seats.
  ```hcl
  panos_auth_codes  = "YOUR-AUTH-CODE"
  branch_auth_codes = "YOUR-BRANCH-AUTH-CODE"
  ```

`deploy.sh` prints a `NOTE` when the branch is reusing `panos_auth_codes`, as
a reminder about the seat count. `terraform.tfvars` is never committed to
git, so the codes stay private.

> **Threat updates need subscriptions.** Each firewall installs the latest
> Applications and Threats package, plus Antivirus and WildFire if its
> license includes those subscriptions. Without them it installs what it
> can and tells you what it skipped.

## 3.2 — Who can reach the firewalls' management pages

Two settings in `terraform.tfvars` decide who can reach the web pages and
command line of all three firewalls:

| Setting | Default | Allows |
|---|---|---|
| `mgmt_allowed_cidrs` | the public IP `deploy.sh` detected | HTTPS (web page) and SSH |
| `admin_workstation_cidrs` | `["0.0.0.0/1", "128.0.0.0/1"]` | **everything, from anywhere** ("Admin Workstation" rule) |

Both go into the AWS security groups **and** the firewalls' own allowlists.

**Why the default is so wide:** on corporate networks that route through a
cloud proxy such as Prisma Access, your public IP can differ per website, so
the IP `deploy.sh` detects may not be the IP the firewall sees, and a
narrow rule would lock you out. If you're on a normal home or office
connection with a stable IP, narrow it before deploying:

```hcl
admin_workstation_cidrs = ["203.0.113.45/32"]
```

(`/32` is one address; `/24` is 256.)

> **If your company runs automatic security remediation in AWS** (for example
> Palo Alto Xpanse / Cortex XSOAR), expect it to act on any security group
> that allows `0.0.0.0/0` to SSH (22) or HTTPS (443). In the account this was
> built in, it acted about **two hours** after such a rule appeared: it made a
> copy of the group without that rule, named `<group>-ar-NNN` (or
> `…_xpanse_ar_NNN`), and swapped the copy onto the firewalls in place of the
> original. Everything else in the group, including the "Admin Workstation"
> rules, was kept. Terraform deliberately leaves the swapped groups alone. If
> it ever locks you out,
> [Part 10](#problem-cant-reach-the-firewall-web-pages) has the way back in,
> which needs no rules at all.

Run `./deploy.sh --plan-only` once more and confirm it reaches the plan.

---

# Part 4 — Deploy

### Before you start

- Allow about **35 minutes**: about 5 for Terraform, 10 to 20 for the
  firewalls to boot, then several minutes of configuration and threat
  updates.
- **Don't let your Mac sleep or close Terminal** during it.
- If it dies partway, that's recoverable: see
  [Part 10](#problem-terraform-apply-failed-partway-through).

### Run it

```bash
./deploy.sh
```

It repeats the Part 3 checks, shows the plan and stops:

```
About to create a VM-Series HA pair in us-east-2 of account 123456789012.
Plus a branch VPC with a third firewall (m5.4xlarge) and an IPsec tunnel.
Three firewalls plus EIPs; this costs real money per hour.
Type 'yes' to continue:
```

Type `yes` and press Enter.

### Stage 1 — Terraform builds the AWS resources (about 5 minutes)

A long stream of lines like:

```
aws_vpc.this: Creating...
aws_vpc.branch[0]: Creating...
aws_instance.fw["a"]: Still creating... [30s elapsed]
aws_instance.branch_fw[0]: Still creating... [30s elapsed]
```

`aws_vpc.this` and `aws_instance.fw[...]` are the main site;
anything named `branch` is the branch site. `Still creating...` is normal.
Stage 1 ends with
`Apply complete! Resources: NN added, 0 changed, 0 destroyed.`

### Stage 2 — The firewalls boot (10 to 20 minutes)

`deploy.sh` now runs `scripts/configure.py`, which waits for each firewall in
turn:

```
==> Connecting to the firewall pair
  ... waiting for panw-ha-fw-a @ 3.14.x.x - unreachable (URLError) (38m40s left)
```

**This sits there for a long time, and that is correct.** On first boot a
VM-Series firewall starts PAN-OS, downloads its configuration from S3,
applies it, redeems its license with Palo Alto, and reboots. The status
moves from `unreachable` to `API not ready` to logged in. All three boot at
the same time, so by the time FW-A answers the others are usually ready too.
The script gives up after 40 minutes per firewall.

### Stage 3 — Configuration and verification (several minutes)

Once the firewalls answer, `configure.py` works through them. Addresses and
version numbers will differ:

```
  [ ok ] panw-ha-fw-a @ 3.14.x.x authenticated
  [ ok ] panw-ha-fw-b @ 18.22.x.x authenticated
  [ ok ] panw-ha-branch-fw @ 3.18.x.x authenticated

==> Licensing
  panw-ha-fw-a: license PA-VM                              expires ...
  ...
  panw-ha-branch-fw: license Advanced Threat Prevention    expires ...

==> VM-Series AWS plugin failover mode
  [ ok ] panw-ha-fw-a: HA failover mode set to secondary-ip

==> Content updates on panw-ha-fw-a
  panw-ha-fw-a: downloading Applications and Threats 9160-10295
  panw-ha-fw-a: installing Applications and Threats 9160-10295
  [ ok ] panw-ha-fw-a: Applications and Threats 9160-10295 installed
  ...                                             (then Antivirus and WildFire)
  [ ok ] panw-ha-fw-a: commit complete
  [ ok ] panw-ha-fw-a: recurring updates scheduled for content, anti-virus, wildfire

==> Content updates on panw-ha-fw-b
  ...                                             (the same)
==> Content updates on panw-ha-branch-fw
  ...                                             (the same)

==> IPsec tunnel: 3.19.x.x (branch) <-> 52.x.x.x (HA pair floating IP)
  [ ok ] panw-ha-fw-a: gateway 'branch-gw'
  ...
  [ ok ] panw-ha-fw-a: commit complete
  ...                                             (the same on panw-ha-fw-b)
  [ ok ] panw-ha-branch-fw: gateway 'hub-gw'
  ...
  [ ok ] panw-ha-branch-fw: commit complete

==> Inbound publishing (floating IP -> 10.100.20.x)
  [ ok ] panw-ha-fw-a: nat rule 'inbound-dnat-1' -> 10.100.20.x
  [ ok ] panw-ha-fw-a: nat rule 'inbound-dnat-2' -> 10.100.20.x
  [ ok ] panw-ha-fw-a: security rule 'allow-inbound' -> 10.100.20.x
  [ ok ] panw-ha-fw-a: commit complete

==> Policy sync (active -> passive)
  Source panw-ha-fw-a (active) -> target panw-ha-fw-b (passive)
  [ ok ] shared: already identical
  [ ok ] vsys: copied to panw-ha-fw-b
  [ ok ] panw-ha-fw-b: commit complete

==> Firewall IAM permissions (dry-run)
  [ ok ] Failover route tables reachable: rtb-0aaa..., rtb-0bbb...

==> HA state
  [ ok ] panw-ha-fw-a: local=active peer=passive running-sync=not synchronized
  [ ok ] panw-ha-fw-b: local=passive peer=active running-sync=not synchronized
  [ ok ] Exactly one active (panw-ha-fw-a) and one passive (panw-ha-fw-b)

==> Firewall next hops
  [ ok ] panw-ha-fw-a: 0.0.0.0/0 via 10.100.2.1
  [ ok ] panw-ha-fw-a: 10.100.0.0/16 via 10.100.3.1
  [ ok ] panw-ha-fw-b: 0.0.0.0/0 via 10.100.12.1
  [ ok ] panw-ha-fw-b: 10.100.0.0/16 via 10.100.13.1

==> VPC route tables
  [ ok ] rtb-0aaa... 0.0.0.0/0 -> eni-0xxx (active node panw-ha-fw-a)
  ...

==> Published web server
  [ ok ] http://52.x.x.x/ answered from 10.100.20.x

==> IPsec tunnel
  panw-ha-branch-fw: no IPsec SA yet; initiating
  [ ok ] panw-ha-branch-fw: IPsec SA for to-hub is up
  [ ok ] panw-ha-fw-a (active): IPsec SA for to-branch is up
  [ ok ] Branch workload -> http://10.100.20.x/ over the tunnel answered from 10.100.20.x

==> Summary
  panw-ha-fw-a     active    https://3.14.x.x   (AZ us-east-2a)
  panw-ha-fw-b     passive   https://18.22.x.x  (AZ us-east-2b)
  panw-ha-branch-fw branch    https://3.18.x.x   (AZ us-east-2a)
  floating service IP : 52.x.x.x
  IPsec tunnel        : 3.19.x.x (branch) <-> 52.x.x.x, 10.200.0.0/16 <-> 10.100.0.0/16
```

**That's success:** every line `[ ok ]`, one firewall `active` and one
`passive`, and the tunnel's last line answered from a main-site test server.

> **`running-sync=not synchronized` is expected.** The firewalls' built-in
> config sync is deliberately off in this design (Part 9 explains why). It
> is not an error.

> **`[warn] Could not run the end-to-end check through SSM`?** The branch
> test server had not finished registering with AWS yet. Wait a couple of
> minutes and run `python3 scripts/configure.py --verify-only`.

---

# Part 5 — Log in to the firewalls

## 5.1 — Addresses, username and password

```bash
terraform output firewall_management_urls          # FW-A and FW-B
terraform output branch_firewall_management_url    # branch firewall
terraform output admin_username
cat .secrets/admin_password
```

The username is **`pandmin`** (not `admin`) on all three firewalls, with the
same password. The password exists only in that file; keep it. To copy it
to the clipboard without showing it: `pbcopy < .secrets/admin_password`.

## 5.2 — Open the web interface

Paste the FW-A URL into your browser. **You'll get a security warning**
("Your connection is not private" or similar). That's expected: the firewall
uses a self-signed certificate.

- **Chrome/Edge:** **Advanced** → **Proceed to … (unsafe)**
- **Safari:** **Show Details** → **visit this website** → **Visit Website**
- **Firefox:** **Advanced** → **Accept the Risk and Continue**

Log in with `pandmin` and the password. You land on the **Dashboard**; the
tabs across the top are Dashboard, ACC, Monitor, Policies, Objects, Network,
Device.

> **The page won't load at all** (a timeout rather than a certificate
> warning)? See
> [Part 10](#problem-cant-reach-the-firewall-web-pages).

## 5.3 — Main site: the High Availability widget

On FW-A's Dashboard, find the **High Availability** widget (if it's missing:
**Widgets** dropdown → **System** → **High Availability**). It shows:

- **Local:** `Active`, **Peer:** `Passive`
- **HA1** and **HA2:** `Up`
- **Running Config:** `Synchronized` or not; either is fine here

Log in to **FW-B** in another tab. Its widget is the mirror image:
**Local: Passive**, **Peer: Active**.

## 5.4 — Branch site: tunnel and threat updates

Log in to the branch firewall in a third tab. It has no HA widget; it is a
standalone firewall. Two pages are worth a look:

- **Network → IPSec Tunnels:** `to-hub`, with green status icons. On FW-A
  the same page shows `to-branch`.
- **Device → Dynamic Updates:** the Applications and Threats, Antivirus and
  WildFire versions marked **Currently Installed**, and a **Schedule** on
  each.

## 5.5 — Command line access (optional)

Two accounts exist on each firewall:

| Account | Logs in with | Use for |
|---|---|---|
| `pandmin` | password | Web UI, API, SSH |
| `admin` | SSH key `.secrets/panw-ha-key.pem` only | Emergency CLI access; it cannot be locked out by a password problem |

```bash
ssh -i .secrets/panw-ha-key.pem admin@<firewall management IP>
```

Useful on the branch: `show vpn ipsec-sa` lists the tunnel's security
associations.

If SSH times out or hangs (many corporate networks block outbound SSH), use
the SSM tunnel in
[Part 10](#problem-cant-reach-the-firewall-web-pages) and connect to
`localhost` instead.

---

# Part 6 — Confirm everything is healthy

Failing over an unhealthy pair just takes your traffic down. Spend five
minutes here.

```bash
python3 scripts/configure.py --verify-only
```

This changes no configuration; run it as often as you like. Check:

| # | Check | Section of the output | Required |
|---|---|---|---|
| 1 | One active, one passive | HA state | Exactly one of each, never two active |
| 2 | All three firewalls licensed | Licensing | Entries with future expiry dates for each |
| 3 | Each firewall of the pair uses its own gateways | Firewall next hops | All `[ ok ]` (FW-A `10.100.2.1`/`10.100.3.1`, FW-B `10.100.12.1`/`10.100.13.1`) |
| 4 | Routes point at the active firewall | VPC route tables | All `[ ok ]` |
| 5 | The web page answers | Published web server | `answered from 10.100.20.x` |
| 6 | The tunnel is up and carries traffic | IPsec tunnel | `IPsec SA for to-hub is up`, and `answered from 10.100.20.x` |

**All six must pass before Part 8.** If one doesn't, find it in
[Part 10](#part-10--troubleshooting).

---

# Part 7 — Prove traffic flows through the firewalls and the tunnel

## 7.1 — Inbound: open the web page

```bash
terraform output floating_service_ip
```

Open `http://<that IP>/` in a browser (plain `http`, not `https`). You see a
page whose heading is a private IP such as `10.100.20.125`, with the
instance ID and AZ underneath. That request went internet → floating IP →
active firewall → test server, and back.

For scripts, `http://<floating IP>/ip` returns just the IP.

## 7.2 — Outbound: ask a main-site test server for its public IP

The test servers have no public IP of their own, so the only way they can
reach the internet is through a firewall. This uses the AWS API to run a
command on one, with no extra software:

```bash
ID=$(terraform output -json workload_instance_ids | python3 -c 'import json,sys;print(json.load(sys.stdin)[0])')
CMD=$(aws ssm send-command --region us-east-2 --instance-ids "$ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["curl -s --max-time 10 https://checkip.amazonaws.com"]' \
  --query 'Command.CommandId' --output text)
sleep 8
aws ssm get-command-invocation --region us-east-2 --command-id "$CMD" --instance-id "$ID" \
  --query '[Status,StandardOutputContent]' --output text
```

**Success:** `Success    52.x.x.x`, the **floating IP** from 7.1. The
server's internet traffic leaves through the active firewall on the floating
IP. After a failover it is still the floating IP, now on the other firewall.

> **`Pending` that never finishes?** Shortly after a deployment or a failover
> the server's SSM agent may take a couple of minutes to reconnect. Wait and
> re-run the last command.

Prefer an interactive shell on the server? `aws ssm start-session --target "$ID"`
(type `exit` to leave).

## 7.3 — Across the tunnel: main site to branch

Now ask the same main-site test server to fetch the **branch** test server's
web page. The branch server has only a private address (`10.200.x.x`), which
the internet cannot reach, so the only way the request can get there is
through the tunnel:

```bash
ID=$(terraform output -json workload_instance_ids | python3 -c 'import json,sys;print(json.load(sys.stdin)[0])')
BRANCH_IP=$(terraform output -raw branch_workload_private_ip)
CMD=$(aws ssm send-command --region us-east-2 --instance-ids "$ID" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"curl -s --max-time 10 http://$BRANCH_IP/ip\"]" \
  --query 'Command.CommandId' --output text)
sleep 8
aws ssm get-command-invocation --region us-east-2 --command-id "$CMD" --instance-id "$ID" \
  --query '[Status,StandardOutputContent]' --output text
```

**Success:** `Success    10.200.10.x`, the branch server's own address. The
request went main-site server → active firewall → tunnel → branch firewall
→ branch server, and back.

`configure.py` tests the other direction (branch to main site) every time it
runs: that is the `Branch workload -> … answered from …` line.

## 7.4 — See it on the firewalls

- **FW-A → Monitor → Traffic.** Your web request (rule `allow-inbound`), the
  server's outbound traffic (rule `allow-outbound`), and the request to the
  branch (rule `allow-site-to-site`, zone `trust` to zone `vpn`).
- **Branch firewall → Monitor → Traffic.** The same request arriving from
  the tunnel (rule `allow-site-to-site`, zone `vpn` to zone `trust`), and
  the tunnel-monitor pings (rule `allow-tunnel-monitor`).

Logs can take 30 seconds to appear.

---

# Part 8 — The failover test

### What you are testing

That when the active firewall stops, the passive one becomes active, moves
the route tables and the floating IP to itself through the AWS API, and
traffic resumes, with nobody touching anything. Then that the branch's
tunnel reconnects to the new active firewall, again with nobody touching
anything.

### What success looks like

1. The passive firewall becomes `active` (1 to 3 seconds).
2. The route tables' next hop moves to it (**about 10 seconds** measured).
3. The web page answers again, from the **same** server (**about 12 seconds**
   measured).
4. The tunnel is up again, now ending on the new active firewall, and
   carries traffic between the sites (**about 35 seconds** measured).

10 to 30 seconds of interruption is the expected result for the main site.
**Connections that were open during the failover are reset** (each firewall
translates traffic to its own addresses), so clients reconnect; new
connections work as soon as the routes move. The tunnel takes a little
longer. The new active firewall inherits its peer's tunnel keys, which are
tied to the peer's address and can't carry traffic from the new one. Its
tunnel check fails after about 15 seconds, and it then builds a fresh
tunnel.

### What happens afterwards

The restored firewall comes back as the **standby**; the other one stays
active. That's deliberate ("preemption" is off) because an automatic switch
back raced the AWS updates. To fail back, run the test again.

### Is this safe?

Yes. Suspending a firewall is a reversible software state; nothing is
deleted or stopped. The script always restores the suspended firewall, even
if it is interrupted. The branch firewall is never touched.

---

## Test 1 — Automated (do this first)

Optional but worthwhile: in a **second** Terminal window (⌘N) run the live
route watcher and leave it visible:

```bash
cd ~/Downloads/panw-ha-aws
./scripts/watch-failover.sh
```

Then in the first window:

```bash
python3 scripts/configure.py --failover-test
```

It re-checks health first and refuses to run if the pair isn't healthy.

### What you'll see (end of the output)

```
==> Failover test
  [ ok ] Before: http://52.x.x.x/ -> 10.100.20.125
  Active node is panw-ha-fw-a (trust ENI eni-0xxx). Suspending it...
  [ ok ] Suspend issued on panw-ha-fw-a
  [ ok ] Routes moved off eni-0xxx after ~10s -> now eni-0yyy
  [ ok ] After: http://52.x.x.x/ -> 10.100.20.125, ~12s after the suspend
  Restoring panw-ha-fw-a to functional state...
  [ ok ] panw-ha-fw-a returned to functional
  panw-ha-fw-a is now the standby. Run --failover-test again to fail back.

==> IPsec tunnel
  [ ok ] panw-ha-branch-fw: IPsec SA for to-hub is up
  [ ok ] panw-ha-fw-b (active): IPsec SA for to-branch is up
  [ ok ] Branch workload -> http://10.100.20.125/ over the tunnel answered from 10.100.20.125 (after ~30s)

==> Summary
  panw-ha-fw-a     initial   https://3.14.x.x   (AZ us-east-2a)
  panw-ha-fw-b     active    https://18.22.x.x  (AZ us-east-2b)
  panw-ha-branch-fw branch    https://3.18.x.x   (AZ us-east-2a)
```

The lines that matter:

- `Routes moved off … -> now …`: AWS routing now points at the other
  firewall.
- `After: … -> 10.100.20.125, ~12s after the suspend`: the web page came back
  through the other firewall, from the same server.
- `panw-ha-fw-b (active): IPsec SA for to-branch is up` and the
  `Branch workload …` line: the tunnel now ends on FW-B and carries traffic.

`initial` in the summary is the restored firewall rejoining; a few seconds
later it reads `passive`. The SA lines read `up` straight away, because the
new active firewall holds the copied keys. Only the `Branch workload` line
proves traffic flows, and it shows how long the new tunnel took. While it
waits you'll see `waiting for traffic over the tunnel...`. The script waits
up to three minutes.

Meanwhile the watcher window shows:

```
[15:15:30] *** ROUTES MOVED *** (19s since the last change)
           0.0.0.0/0          -> eni-0yyy  (panw-ha-fw-b)
           10.100.20.0/24     -> eni-0yyy  (panw-ha-fw-b)
           ...
```

(Its "seconds since the last change" counts from when the watcher started,
not from the suspend.)

### Fail back

Run the same command again. It suspends FW-B, moves everything back to FW-A,
leaves FW-B as standby, and checks the tunnel again:

```bash
python3 scripts/configure.py --failover-test
```

Press **Ctrl-C** in the watcher window when you're done.

### If the routes never move

```
Routes still point at eni-0xxx after 180s. The AWS plugin did not move them ...
```

See [Part 10](#problem-ha-fails-over-but-the-routes-never-move).

---

## Test 2 — By hand, watching it happen

1. Start `./scripts/watch-failover.sh` in a second window, and open
   `http://<floating IP>/` in a browser. Open the branch firewall's
   **Network → IPSec Tunnels** page in another tab.
2. On the **active** firewall's web UI: **Device → High Availability →
   Operational Commands → Suspend local device** → **OK**.
3. Watch the watcher: within about 10 to 30 seconds it prints
   `*** ROUTES MOVED ***` pointing at the other firewall. Refresh the web
   page: same server IP.
4. On the other firewall, the Dashboard HA widget now reads **Local: Active**
   (refresh if stale). Its **Network → IPSec Tunnels** page shows
   `to-branch` going green; refresh the branch's page to see `to-hub` green
   again.
5. Bring the suspended firewall back: on it, **Device → High Availability →
   Operational Commands → Make local device functional** → **OK**. It
   returns as **passive**; the routes stay where they are.
6. Run `python3 scripts/configure.py --verify-only` and confirm everything is
   `[ ok ]`.

To fail back by hand, repeat steps 2 to 5 on the firewall that is now active.

---

## Optional — Test 3: a hard failure

Suspending is graceful. To simulate the active firewall dying outright, stop
its instance (this example stops FW-A; check which one is active first):

```bash
INSTANCE=$(terraform output -json configure_inputs | python3 -c 'import json,sys;print(json.load(sys.stdin)["firewalls"]["panw-ha-fw-a"]["instance_id"])')
aws ec2 stop-instances --region us-east-2 --instance-ids "$INSTANCE"
```

The other firewall detects the lost heartbeat and takes over, a few seconds
slower than Test 1. Bring FW-A back:

```bash
aws ec2 start-instances --region us-east-2 --instance-ids "$INSTANCE"
```

It needs several minutes to boot and rejoin as passive. Re-run
`--verify-only` until everything is `[ ok ]`.

---

# Part 9 — Making configuration changes

### Policy changes at the main site (rules, NAT, objects, zones, profiles)

1. Make the change on the **active** firewall, in the web UI or CLI, and
   **Commit** it.
2. Copy it to the passive firewall:
   ```bash
   python3 scripts/configure.py --sync-config
   ```

```
==> Policy sync (active -> passive)
  Source panw-ha-fw-a (active) -> target panw-ha-fw-b (passive)
  [ ok ] shared: already identical
  [ ok ] vsys: copied to panw-ha-fw-b
  [ ok ] panw-ha-fw-b: commit complete
```

It works out which firewall is active, so it works the same after a failover.
It refuses to run if the passive firewall has its own uncommitted changes,
and warns if the active one does (only **committed** config is copied).

### Why not the firewalls' built-in HA config sync?

Each firewall must route through its **own** AZ's gateways (FW-A uses
`10.100.2.1` and `10.100.3.1`; FW-B uses `10.100.12.1` and `10.100.13.1`).
Built-in sync copies the whole network configuration, which overwrote the
passive firewall's gateways with the active one's; that firewall then dropped
all traffic the moment it became active. So built-in sync is off, and
`--sync-config` copies only policy (never network, HA, management or admin
settings).

### Network changes at the main site (interfaces, virtual router, IPsec)

These are per-firewall. Make them on **each** firewall of the pair
separately, keep each firewall's next hops on its own subnets, then run
`python3 scripts/configure.py --verify-only` and check **Firewall next
hops**. This includes the tunnel's settings: `configure.py` set them on both
firewalls, and any change must be made on both too.

### Changes at the branch

The branch firewall is standalone. Change it directly and commit; nothing
is copied to or from it.

### Publishing something else

The test web page is published by `configure.py`. To publish a different
host or service, set these in `terraform.tfvars`, then run
`terraform apply` and `python3 scripts/configure.py`:

```hcl
inbound_target_ip = "10.100.20.50"   # empty = the first test server
inbound_service   = "service-https"  # a PAN-OS service object
# enable_inbound_dnat = false        # to publish nothing
```

---

# Part 10 — Troubleshooting

## Problem: `./deploy.sh: Permission denied`

```bash
chmod +x deploy.sh destroy.sh scripts/*.sh
```

## Problem: AWS commands fail with `ExpiredToken`, `InvalidGrantException` or `No valid credential sources found`

Your SSO session expired:

```bash
aws sso login
```

If this happens during `--failover-test`, the script keeps retrying and
still restores the suspended firewall.

## Problem: `VcpuLimitExceeded` / `QUOTA TOO LOW`

Your account's compute limit is too low; it's not a fault in the deployment.
This build needs 54 vCPUs:

| What | Count | vCPUs each | Total |
|---|---|---|---|
| Main-site firewalls (`m5.4xlarge`) | 2 | 16 | 32 |
| Branch firewall (`m5.4xlarge`) | 1 | 16 | 16 |
| Test servers (`t3.micro`) | 3 | 2 | 6 |

Request an increase (it costs nothing to have headroom):

```bash
aws service-quotas request-service-quota-increase \
  --region us-east-2 --service-code ec2 \
  --quota-code L-1216C47A --desired-value 64
```

Check approval (`CASE_OPENED` = pending, `APPROVED` = done):

```bash
aws service-quotas list-requested-service-quota-change-history-by-quota \
  --region us-east-2 --service-code ec2 --quota-code L-1216C47A \
  --query 'RequestedQuotas[].[Status,DesiredValue]' --output text
```

Then re-run `./deploy.sh`; Terraform reuses what it already built.
`deploy_branch = false` brings the requirement down to 36.

> **Smaller firewalls?** Only with a matching license. The instance must be at
> least as large as the VM-Series model the auth code licenses; if it is
> smaller, PAN-OS refuses the license and never finishes starting. The
> branch's size is `branch_instance_type` (empty = same as the pair).

## Problem: `Marketplace subscription required`

The account isn't subscribed to the Palo Alto listing. `deploy.sh` prints the
URL: open it, **Continue to Subscribe**, accept the terms, wait about five
minutes, re-run.

## Problem: `panos_auth_codes is not set`

`deploy.sh` will not build BYOL firewalls without a license code, because they
would boot but never pass traffic. Add it as described in
[3.1](#31--license-codes).

## Problem: `reading S3 Object (...): couldn't find resource`

A brief consistency race inside S3 while the bucket switches to versioning.
The current code waits for versioning to settle, so a fresh deployment
shouldn't hit it. If you do, simply re-run `./deploy.sh`; Terraform
re-uploads the file.

## Problem: timed out waiting for the management API

The firewalls were still booting. Resume:

```bash
python3 scripts/configure.py
```

If it times out again, check the instances are healthy:

```bash
IDS=$(aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:Project,Values=panw-ha" "Name=tag:Name,Values=panw-ha-fw-a,panw-ha-fw-b,panw-ha-branch-fw" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ec2 describe-instance-status --region us-east-2 --include-all-instances --instance-ids $IDS \
  --query 'InstanceStatuses[].[InstanceId,InstanceState.Name,InstanceStatus.Status]' --output text
```

If they're `running` / `ok` but the API never answers, you probably can't
reach them: see the next problem.

## Problem: can't reach the firewall web pages

The page times out (no certificate warning, nothing). Two common causes:

1. **Your public IP isn't allowed.** Your IP changed, or you're behind a
   proxy that uses a different IP per destination.
2. **Automatic remediation in your AWS account replaced a management
   security group** with a restricted copy. Check what's attached:
   ```bash
   aws ec2 describe-network-interfaces --region us-east-2 \
     --filters "Name=tag:Role,Values=mgmt" \
     --query 'NetworkInterfaces[].[TagSet[?Key==`Name`]|[0].Value, join(`, `, Groups[].GroupName)]' --output text
   ```
   Terraform's own groups are `panw-ha-sg-mgmt` (main site) and
   `panw-ha-branch-sg-mgmt` (branch). Names ending `-ar-NNN` or
   `…_xpanse_ar_NNN` are copies made by remediation; Terraform deliberately
   leaves them alone. Each copy's description says which rule was removed:
   ```bash
   aws ec2 describe-security-groups --region us-east-2 \
     --filters "Name=group-name,Values=*-ar-*" \
     --query 'SecurityGroups[].[GroupName,Description]' --output text
   ```

**The way in that always works: an SSM tunnel.** It goes through a test
server in the same network over HTTPS to AWS, so it needs no inbound rules
from you and passes most corporate proxies. For the main site:

```bash
W=$(terraform output -json workload_instance_ids | python3 -c 'import json,sys;print(json.load(sys.stdin)[0])')
aws ssm start-session --region us-east-2 --target "$W" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters 'host=10.100.0.10,portNumber=443,localPortNumber=8443'
```

Leave it running and browse to **https://localhost:8443** for FW-A. For
FW-B use `host=10.100.10.10` and `localPortNumber=8444`. For the branch
firewall, go through the branch test server instead:

```bash
W=$(terraform output -raw branch_workload_instance_id)
aws ssm start-session --region us-east-2 --target "$W" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters 'host=10.200.0.10,portNumber=443,localPortNumber=8445'
```

and browse to **https://localhost:8445**. For SSH, use
`portNumber=22,localPortNumber=2222` and then
`ssh -i .secrets/panw-ha-key.pem -p 2222 admin@localhost`.

`configure.py` talks to the firewalls' public management IPs, so to run it
again you need direct access back. Either add your current IP to an
attached security group, or attach Terraform's own group **alongside** the
existing ones. For the main site:

```bash
TF=$(terraform state show aws_security_group.mgmt | awk '$1=="id"{gsub(/"/,"",$3);print $3;exit}')
for eni in $(aws ec2 describe-network-interfaces --region us-east-2 --filters "Name=tag:Role,Values=mgmt" "Name=tag:Firewall,Values=panw-ha-fw-a,panw-ha-fw-b" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
  CUR=$(aws ec2 describe-network-interfaces --region us-east-2 --network-interface-ids $eni --query 'NetworkInterfaces[0].Groups[].GroupId' --output text)
  aws ec2 modify-network-interface-attribute --region us-east-2 --network-interface-id $eni --groups $CUR $TF
done
```

For the branch, use `aws_security_group.branch_mgmt[0]` and
`Values=panw-ha-branch-fw` in the same commands.

Check with your security team first if remediation removed it. If a
Terraform group still contains a `0.0.0.0/0` rule on SSH or HTTPS (from
`mgmt_allowed_cidrs = ["0.0.0.0/0"]`), remediation will swap it out again;
set `mgmt_allowed_cidrs` to specific addresses and `terraform apply` first.

## Problem: SSH hangs at `kex_exchange_identification` or `banner exchange`

The TCP connection opens but SSH never starts: your network (often a
corporate proxy) blocks outbound SSH. Use the SSM tunnel above.

## Problem: every login is rejected (`Invalid Credential`)

The login page loads, but `pandmin` and the password from
`.secrets/admin_password` are refused, and `configure.py` reports
`403 Invalid Credential`. Work out which of three causes it is:

1. **Try SSH as `admin` with the key** (directly or through the SSM tunnel).
   If that works, log in and run `show system bootstrap status` and
   `show system info`.
2. **The firewall isn't licensed.** Without a license PAN-OS never finishes
   starting its authentication service, so no password works. Read the boot
   log from AWS, which needs no login (use `panw-ha-branch-fw` for the
   branch):
   ```bash
   ID=$(aws ec2 describe-instances --region us-east-2 \
     --filters "Name=tag:Name,Values=panw-ha-fw-a" "Name=instance-state-name,Values=running" \
     --query 'Reservations[].Instances[].InstanceId' --output text)
   aws ec2 get-console-output --region us-east-2 --latest --instance-id "$ID" --output text | grep -iE "licen|CRITICAL"
   ```
   `… is not supported for this platform` means the auth code is for the
   wrong product (you need a VM-Series capacity code). A size mismatch means
   the instance is smaller than the licensed model. If only the **branch**
   fails while the pair is fine, the shared code has probably run out of
   seats: set `branch_auth_codes`. Fix the code in `terraform.tfvars` and
   rebuild the firewall (below).
3. **The password hash format.** PAN-OS accepts `$5$` (SHA-256) hashes; this
   project generates those. A `$6$` hash loads without error but rejects
   every login. Only relevant if you've changed `scripts/phash_helper.py`.

Licensing and the admin password are applied only at a firewall's **first**
boot. To rebuild just the firewalls (keeping the networks, IPs and test
servers):

```bash
terraform apply -replace='aws_instance.fw["a"]' -replace='aws_instance.fw["b"]'   # main site
terraform apply -replace='aws_instance.branch_fw[0]'                               # branch
python3 scripts/configure.py
```

That takes about 20 minutes. `configure.py` puts the tunnel and the threat
updates back. Rebuilt firewalls don't release their old licenses: deactivate
the old serial numbers in the Palo Alto support portal, or the auth code may
run out of seats.

## Problem: a commit fails with "Validation Error … unexpected here" or "no UUID found for rule"

The firewall loaded a configuration at boot that it then refuses to commit,
so **every** later commit fails. Known causes, all fixed in the current
templates: `passive-link-state` under active-passive, `action` under
`ha2-keep-alive`, and rules without a `uuid`. If you've edited
`templates/bootstrap.xml.tftpl` or `templates/branch-bootstrap.xml.tftpl`,
run the firewall's own check on the **Commit** menu (**Validate Commit**) to
see the offending lines.

## Problem: the GUI asks to change packet IO mode to mmap and reboot

You switched the AWS failover mode to **interface-move**. Don't reboot.
Go to **Device → VM-Series**, click **Change to secondary-ip mode**, and
check both firewalls of the pair show **secondary-ip**. `configure.py` also
sets it on every run.

## Problem: both firewalls say "Active" (split brain)

The HA1 heartbeat isn't getting through.

1. On both: **Device → High Availability → Link and Path Monitoring**: is HA1
   up?
2. The management security group must allow TCP 28769, TCP 28260 and ICMP
   from `10.100.0.0/16`. If remediation replaced the group, check its copy
   still has them.
3. Re-run `python3 scripts/configure.py --verify-only`.

To recover: suspend one firewall, let the other settle as the only active,
then make the suspended one functional again.

## Problem: HA fails over but the routes never move

1. Both firewalls' **Device → VM-Series → AWS HA → Failover Mode** must read
   **secondary-ip**. Re-run `python3 scripts/configure.py` to set it.
2. The firewalls' IAM role needs `ec2:ReplaceRoute` and
   `ec2:AssociateAddress`; `configure.py` shows "Firewall IAM permissions".
3. Check CloudTrail for the firewalls' calls and their errors:
   ```bash
   aws cloudtrail lookup-events --region us-east-2 \
     --lookup-attributes AttributeKey=EventName,AttributeValue=ReplaceRoute \
     --max-results 10 --query 'Events[].[EventTime,Username]' --output text
   ```
   (CloudTrail can lag by several minutes and isn't a complete real-time
   record; the watcher reads the route tables directly.)
4. In the active firewall's **Monitor → System** log, filter for
   `( description contains 'aws' ) or ( description contains 'plugin' )`.

## Problem: routes move, but traffic stops after a failover

Almost always the newly active firewall is using the **other** AZ's
gateways. `--verify-only` shows it under **Firewall next hops** as, for example,
`[FAIL] panw-ha-fw-b: 0.0.0.0/0 via 10.100.2.1 is not on its own ethernet1/2
subnet (10.100.12.0/24)`. The check reads each firewall's configured routes,
so it covers the passive firewall too. It happens if HA config sync was turned
back on, or a network change was copied between firewalls. Fix it on that
firewall: **Network → Virtual Routers → default → Static Routes**, set
`default` to its own untrust gateway and `vpc-inside` to its own trust
gateway (FW-A `10.100.2.1` / `10.100.3.1`, FW-B `10.100.12.1` /
`10.100.13.1`), and commit. Make sure **Device → High Availability → General
→ Setup → Enable Config Sync** is **off** on both.

## Problem: the web page doesn't answer

1. `python3 scripts/configure.py --verify-only`: is a firewall active, and
   do the routes point at it?
2. Re-run `python3 scripts/configure.py`; it re-creates the inbound rules if
   they're missing.
3. Is the web server running? Check through SSM:
   ```bash
   ID=$(terraform output -json workload_instance_ids | python3 -c 'import json,sys;print(json.load(sys.stdin)[0])')
   aws ssm start-session --region us-east-2 --target "$ID"
   systemctl status web-test; curl -s http://127.0.0.1/ip
   ```
   To reinstall it on a running server:
   ```bash
   aws ssm send-command --region us-east-2 --instance-ids "$ID" \
     --document-name AWS-RunShellScript \
     --parameters "$(python3 -c 'import json;print(json.dumps({"commands":[open("scripts/workload-web.sh").read()]}))')"
   ```
4. On the active firewall, **Monitor → Traffic**, filter on port 80. Hits on
   `deny-all` mean policy is blocking it.

## Problem: a test server can't reach the internet

1. `--verify-only`: active firewall, correct next hops, routes pointing at
   it?
2. **Monitor → Traffic** on the firewall in front of it (the active firewall
   at the main site, or the branch firewall), filtered on the server's IP.
3. Right after a deployment or a failover, give the SSM agent a couple of
   minutes to reconnect before concluding anything is broken.

## Problem: the IPsec tunnel does not come up

1. `python3 scripts/configure.py --verify-only` starts negotiation and
   reports the result.
2. On the branch firewall, go to **Monitor → System** and filter with
   `( subtype eq vpn )`. A message about the IKE ID or the pre-shared key
   means the two ends disagree. Re-run `python3 scripts/configure.py` to
   reapply both ends.
3. Check that the main site has an active firewall and that the floating IP
   is on it (`--verify-only`). The branch connects only to the floating IP.
4. On both ends, **Monitor → Traffic** filtered on `( port.dst eq 500 )`.
   Hits on `deny-all` (app `not-applicable`) mean `allow-ike` is missing,
   below `deny-all`, or from an older version that allowed only the peer's
   address: a firewall's own IKE packets leave from its private untrust IP,
   so the rule must list that too. Re-run `python3 scripts/configure.py`.

## Problem: the tunnel is up but test servers can't reach each other

1. **Monitor → Traffic** on both ends, filtered on the other site's network
   (`( addr in 10.200.0.0/16 )` at the main site, `( addr in 10.100.0.0/16 )`
   at the branch). Hits on `deny-all` mean `allow-site-to-site` is missing.
2. Each end needs a static route to the other site's network via `tunnel.1`
   (**Network → Virtual Routers → default → Static Routes**, `to-branch` or
   `to-hub`). Re-run `python3 scripts/configure.py` to restore it.

## Problem: threat updates fail

1. **License error:** the firewall has no license, or lacks the
   subscription for that update type. If it reuses `panos_auth_codes`, the
   code must cover three firewalls; set `branch_auth_codes` to give it its
   own code.
2. **`check not ready` for several minutes, then a failure:** the firewall
   could not reach Palo Alto's update servers yet. Re-run
   `python3 scripts/configure.py`; it skips anything already installed.

## Problem: `terraform apply` failed partway through

Terraform is safe to re-run; it creates only what's missing:

```bash
./deploy.sh
```

## Problem: `terraform plan` wants to replace the test servers or move the floating IP

It shouldn't. The test servers ignore AMI and `user_data` changes, and the
floating IP's placement is ignored after creation. If you see either, you're
probably on an older copy of the code. Don't apply; update the code first.

## Problem: I lost the admin password

```bash
cat .secrets/admin_password
```

If `.secrets/` is gone, the password can't be recovered. SSH in as `admin`
with the key (if you still have `.secrets/panw-ha-key.pem`) and set a new
one, or destroy and redeploy.

## Getting more detail out of any failure

```bash
python3 scripts/configure.py --verify-only   # full health report
terraform output                             # every value the stack produced
```

The firewall's own explanation of what it did is under **Monitor → System**
in the web UI.

---

# Part 11 — Delete everything

**Do this when you're finished;** the whole build costs about $58 per day.

```bash
cd ~/Downloads/panw-ha-aws
./destroy.sh
```

It lists what will be deleted (both sites) and asks you to type `destroy`
(not `yes`). It takes about 10 minutes and ends with `Destroy complete!`.

### If it fails with `DependencyViolation` on a security group or a VPC

Something outside Terraform added resources to a VPC. The usual culprit
is security groups created by automatic remediation (names containing
`-ar-`). Terraform's own groups are exactly `panw-ha-sg-mgmt`, `-ha2`,
`-untrust`, `-trust` and `-workload` at the main site, and
`panw-ha-branch-sg-mgmt`, `-untrust`, `-trust` and `-workload` at the branch.
This lists everything else in both VPCs:

```bash
for VPC in $(aws ec2 describe-vpcs --region us-east-2 --filters "Name=tag:Project,Values=panw-ha" --query 'Vpcs[].VpcId' --output text); do
  aws ec2 describe-security-groups --region us-east-2 --filters "Name=vpc-id,Values=$VPC" \
    --query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName]' --output text \
    | grep -vE '\spanw-ha-(branch-)?sg-(mgmt|ha2|untrust|trust|workload)$'
done
```

Once the instances are gone, delete each one listed
(`aws ec2 delete-security-group --region us-east-2 --group-id sg-…`), then
run `./destroy.sh` again.

### Confirm nothing is left

```bash
aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:Project,Values=panw-ha" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text

aws ec2 describe-addresses --region us-east-2 \
  --query 'Addresses[?Tags[?Key==`Project` && Value==`panw-ha`]].[PublicIp,AllocationId]' --output text
```

**Empty output from both means you're clean.** Elastic IPs bill even when
unattached.

### Licenses

Destroying the firewalls doesn't release their BYOL licenses. Deactivate
all three serial numbers in the Palo Alto support portal so the auth codes
can be used again.

### What stays on your Mac

`.secrets/` (password, SSH key and IPsec pre-shared key). Delete it when
you're sure you're done: `rm -rf .secrets`

---

# Quick reference

```bash
cd ~/Downloads/panw-ha-aws
aws sso login                                    # if credentials expired

./deploy.sh --plan-only                          # preview, change nothing
./deploy.sh                                      # deploy everything (asks first)

python3 scripts/configure.py                     # configure + verify (safe to re-run)
python3 scripts/configure.py --verify-only       # health check, pair + tunnel
python3 scripts/configure.py --failover-test     # fail over (run again to fail back)
python3 scripts/configure.py --sync-config       # copy policy active -> passive
./scripts/watch-failover.sh                      # live route watcher (2nd window)

terraform output floating_service_ip             # http://<this>/ = test web page
terraform output firewall_management_urls        # main-site firewall web UIs
terraform output branch_firewall_management_url  # branch firewall web UI
terraform output workload_instance_ids           # main-site test servers (for SSM)
terraform output branch_workload_private_ip      # branch test server (reach it over the tunnel)
cat .secrets/admin_password                      # pandmin password (all three firewalls)
cat .secrets/ipsec_psk                           # IPsec pre-shared key

./destroy.sh                                     # delete everything
```

**In the PAN-OS web interface:**

| Task | Where |
|---|---|
| HA status (main site) | Dashboard → High Availability widget |
| Suspend / restore a firewall | Device → High Availability → Operational Commands |
| AWS failover mode (must be secondary-ip) | Device → VM-Series → AWS HA |
| IPsec tunnel status | Network → IPSec Tunnels |
| Threat update versions and schedule | Device → Dynamic Updates |
| Licenses | Device → Licenses |
| Static routes / next hops | Network → Virtual Routers → default → Static Routes |
| Traffic logs | Monitor → Traffic |
| System logs (including IKE) | Monitor → System |

---

# A successful run, in short

All of these are true:

1. ✅ `--verify-only` is all `[ ok ]`: one active, one passive, own next hops,
   routes on the active firewall, web page answering, tunnel up.
2. ✅ `http://<floating IP>/` shows a test server's IP.
3. ✅ A main-site test server can fetch the branch test server's page across
   the tunnel (7.3), and every firewall's **Device → Dynamic Updates** shows
   current threat content.
4. ✅ `--failover-test` reports `Routes moved …` within about 10 to 30
   seconds.
5. ✅ It reports `After: … -> <same IP>`: the web page came back through the
   other firewall.
6. ✅ After the failover, the tunnel is up on the new active firewall and
   carries traffic between the sites.
7. ✅ Running it again fails back the other way.

Points 4 to 6 are what distinguish a working HA pair in AWS from two
firewalls that merely agree about who is in charge: the public address, the
routes and the branch tunnel all follow the active firewall.
