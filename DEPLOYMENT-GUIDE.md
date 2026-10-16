# Deployment Guide: Palo Alto VM-Series HA Pair in AWS

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

**Who this is for:** anyone with an AWS account and a Mac terminal. You do not
need to have used Terraform, Palo Alto firewalls, or high availability (HA)
before. Every command is copy-paste, and after each one this guide tells you
what you should see.

**What you will end up with:** two Palo Alto firewalls in AWS (`us-east-2`),
one **active** and one **passive**, in different Availability Zones (separate
data centres). Behind them sit two test servers, and a test web page is
published on a public IP address. You will then deliberately take down the
active firewall and watch the passive one take over, with the web page coming
back in about 10 to 30 seconds.

**Time required:** about an hour, most of it waiting.
**Cost while running:** roughly **$1.60 per hour (about $38 per day)**.
[Part 11](#part-11--delete-everything) deletes everything; do it when you
are finished.

---

## Table of contents

| Part | What you do | Time |
|---|---|---|
| [Part 1](#part-1--install-the-tools) | Install the tools | 10 min |
| [Part 2](#part-2--connect-the-aws-cli-to-your-account) | Connect the AWS CLI to your account | 5 min |
| [Part 3](#part-3--preview-the-build-changes-nothing) | Preview the build (changes nothing) | 5 min |
| [Part 4](#part-4--deploy) | Deploy | 30 min |
| [Part 5](#part-5--log-in-to-the-firewalls) | Log in to the firewalls | 5 min |
| [Part 6](#part-6--confirm-the-pair-is-healthy) | Confirm the pair is healthy (**do not skip**) | 5 min |
| [Part 7](#part-7--prove-traffic-flows-through-the-firewall) | Prove traffic flows through the firewall | 5 min |
| [Part 8](#part-8--the-failover-test) | **The failover test** | 15 min |
| [Part 9](#part-9--making-configuration-changes) | Making configuration changes | as needed |
| [Part 10](#part-10--troubleshooting) | Troubleshooting | as needed |
| [Part 11](#part-11--delete-everything) | Delete everything | 10 min |

---

## A two-minute explanation of what you're building

Two firewalls. Only one does any work at a time.

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
   it, and the test servers' outbound traffic leaves from it.

When the active firewall fails, the passive one promotes itself, and a piece
of firewall software called the **VM-Series AWS plugin** calls the AWS API to
**turn both signposts around**: the route tables now point at FW-B, and the
floating IP moves to FW-B. You will watch that happen in Part 8.

```
                              Internet
                                 │
                       floating IP (public)
                                 │
   us-east-2a                    │                  us-east-2b
   ┌──────────────┐              │              ┌──────────────┐
   │    FW-A      │◄─────────────┘              │     FW-B     │
   │   ACTIVE     │◄── heartbeat + state sync ─►│   PASSIVE    │
   └──────┬───────┘                             └──────────────┘
          │ ▲
          │ └── route tables point here ... until failover, then at FW-B
   ┌──────┴───────┐                             ┌──────────────┐
   │ test server  │                             │ test server  │
   │ + web page   │                             │ + web page   │
   └──────────────┘                             └──────────────┘
```

The web page shows the private IP address of the server that answered. The
same server answers before and after a failover; only the firewall in the
path changes.

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

This lets you reach things **inside** the AWS network (a shell on a test
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

**You need at least `36.0`** (two 16-vCPU firewalls plus two small test
servers). If it's lower (new accounts often show `5.0`), request an increase
now so it can be approved while you continue:

```bash
aws service-quotas request-service-quota-increase \
  --region us-east-2 --service-code ec2 \
  --quota-code L-1216C47A --desired-value 64
```

`deploy.sh` checks this too and refuses to start if it's too low. Details in
[Part 10](#problem-vcpulimitexceeded--quota-too-low).

---

# Part 3 — Preview the build (changes nothing)

Go to the project folder:

```bash
cd ~/Downloads/panw-ha-aws
ls
```

You should see `deploy.sh`, `destroy.sh`, `main.tf`, `templates`, `scripts`,
`README.md` and others.

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
| Preparing terraform.tfvars | First run only: writes your settings file with your current public IP | `mgmt_allowed_cidrs = ["x.x.x.x/32"]` |
| terraform init / validate | Downloads providers, checks the code | `Success! The configuration is valid.` |
| terraform plan | Lists what would be created | `Plan: NN to add, 0 to change, 0 to destroy.` |

It then stops. Nothing has been built. The exact number to add varies by
version (roughly 100); what matters is **`0 to destroy`** and no red
`Error:`.

## 3.1 — Who can reach the firewalls' management pages

Your settings live in `terraform.tfvars` (created by the step above; open it
with `open -e terraform.tfvars`). Two settings decide who can reach the
firewalls' web pages and command line:

| Setting | Default | Allows |
|---|---|---|
| `mgmt_allowed_cidrs` | the public IP `deploy.sh` detected | HTTPS (web page) and SSH |
| `admin_workstation_cidrs` | `["0.0.0.0/1", "128.0.0.0/1"]` | **everything, from anywhere** ("Admin Workstation" rule) |

Both go into the AWS security group **and** the firewall's own allowlist.

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

---

# Part 4 — Deploy

### Before you start

- Allow about **30 minutes**: about 5 for Terraform, 10 to 20 for the
  firewalls to boot, then a few minutes of configuration.
- **Don't let your Mac sleep or close Terminal** during it.
- If it dies partway, that's recoverable: see
  [Part 10](#problem-terraform-apply-failed-partway-through).

### Run it

```bash
./deploy.sh
```

It repeats the Part 3 checks, shows the plan and stops:

```
Build this? Type 'yes' to continue:
```

Type `yes` and press Enter.

### Stage 1 — Terraform builds the AWS resources (about 5 minutes)

A long stream of lines like:

```
aws_vpc.this: Creating...
aws_vpc.this: Creation complete after 2s [id=vpc-0abc123...]
aws_instance.fw["a"]: Still creating... [30s elapsed]
```

`Still creating...` is normal. Stage 1 ends with
`Apply complete! Resources: NN added, 0 changed, 0 destroyed.`

### Stage 2 — The firewalls boot (10 to 20 minutes)

`deploy.sh` now runs `scripts/configure.py`, which waits for the firewalls:

```
==> Connecting to the firewall pair
  ... waiting for panw-ha-fw-a @ 3.14.x.x - unreachable (URLError) (38m40s left)
```

**This sits there for a long time, and that is correct.** On first boot a
VM-Series firewall starts PAN-OS, downloads its configuration from S3,
applies it, redeems its license with Palo Alto, and reboots. The status
moves from `unreachable` to `API not ready` to logged in. The script gives up
after 40 minutes.

### Stage 3 — Configuration and verification (a few minutes)

Once both firewalls answer, you see (addresses will differ):

```
  [ ok ] panw-ha-fw-a @ 3.14.x.x authenticated
  [ ok ] panw-ha-fw-b @ 18.22.x.x authenticated

==> Licensing
  panw-ha-fw-a: license PA-VM                              expires ...
  ...

==> VM-Series AWS plugin failover mode
  [ ok ] panw-ha-fw-a: HA failover mode set to secondary-ip

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

==> Summary
  panw-ha-fw-a     active    https://3.14.x.x   (AZ us-east-2a)
  panw-ha-fw-b     passive   https://18.22.x.x  (AZ us-east-2b)
  floating service IP : 52.x.x.x
```

**That's success:** every line `[ ok ]`, one firewall `active` and one
`passive`.

> **`running-sync=not synchronized` is expected.** The firewalls' built-in
> config sync is deliberately off in this design (Part 9 explains why). It
> is not an error.

---

# Part 5 — Log in to the firewalls

## 5.1 — Addresses, username and password

```bash
terraform output firewall_management_urls
terraform output admin_username
cat .secrets/admin_password
```

The username is **`pandmin`** (not `admin`). The password exists only in
that file; keep it. To copy it to the clipboard without showing it:
`pbcopy < .secrets/admin_password`.

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

## 5.3 — The High Availability widget

On the Dashboard, find the **High Availability** widget (if it's missing:
**Widgets** dropdown → **System** → **High Availability**). On FW-A it shows:

- **Local:** `Active`, **Peer:** `Passive`
- **HA1** and **HA2:** `Up`
- **Running Config:** `Synchronized` or not; either is fine here

Log in to **FW-B** in another tab. Its widget is the mirror image:
**Local: Passive**, **Peer: Active**.

## 5.4 — Command line access (optional)

Two accounts exist on each firewall:

| Account | Logs in with | Use for |
|---|---|---|
| `pandmin` | password | Web UI, API, SSH |
| `admin` | SSH key `.secrets/panw-ha-key.pem` only | Emergency CLI access; it cannot be locked out by a password problem |

```bash
ssh -i .secrets/panw-ha-key.pem admin@<firewall management IP>
```

If SSH times out or hangs (many corporate networks block outbound SSH), use
the SSM tunnel in
[Part 10](#problem-cant-reach-the-firewall-web-pages) and connect to
`localhost` instead.

---

# Part 6 — Confirm the pair is healthy

Failing over an unhealthy pair just takes your traffic down. Spend five
minutes here.

```bash
python3 scripts/configure.py --verify-only
```

This is **read-only**; run it as often as you like. Check:

| # | Check | Section of the output | Required |
|---|---|---|---|
| 1 | One active, one passive | HA state | Exactly one of each, never two active |
| 2 | Firewalls licensed | Licensing | Entries with future expiry dates |
| 3 | Each firewall uses its own gateways | Firewall next hops | All `[ ok ]` (FW-A `10.100.2.1`/`10.100.3.1`, FW-B `10.100.12.1`/`10.100.13.1`) |
| 4 | Routes point at the active firewall | VPC route tables | All `[ ok ]` |
| 5 | The web page answers | Published web server | `answered from 10.100.20.x` |

**All five must pass before Part 8.** If one doesn't, find it in
[Part 10](#part-10--troubleshooting).

---

# Part 7 — Prove traffic flows through the firewall

## 7.1 — Inbound: open the web page

```bash
terraform output floating_service_ip
```

Open `http://<that IP>/` in a browser (plain `http`, not `https`). You see a
page whose heading is a private IP such as `10.100.20.125`, with the
instance ID and AZ underneath. That request went internet → floating IP →
active firewall → test server, and back.

For scripts, `http://<floating IP>/ip` returns just the IP.

## 7.2 — Outbound: ask a test server for its public IP

The test servers have no public IP of their own, so the only way they can
reach the internet is through the firewall. This uses the AWS API to run a
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

## 7.3 — See it on the firewall

In FW-A's web interface: **Monitor → Traffic**. You'll see your web request
(rule `allow-inbound`) and the server's outbound traffic (rule
`allow-outbound`). Logs can take 30 seconds to appear.

---

# Part 8 — The failover test

### What you are testing

That when the active firewall stops, the passive one becomes active, moves
the route tables and the floating IP to itself through the AWS API, and
traffic resumes, with nobody touching anything.

### What success looks like

1. The passive firewall becomes `active` (1 to 3 seconds).
2. The route tables' next hop moves to it (**about 10 seconds** measured).
3. The web page answers again, from the **same** server (**about 12 seconds**
   measured).

10 to 30 seconds of interruption is the expected result for this design.
**Connections that were open during the failover are reset** (each firewall
translates traffic to its own addresses), so clients reconnect; new
connections work as soon as the routes move.

### What happens afterwards

The restored firewall comes back as the **standby**; the other one stays
active. That's deliberate ("preemption" is off) because an automatic switch
back raced the AWS updates. To fail back, run the test again.

### Is this safe?

Yes. Suspending a firewall is a reversible software state; nothing is
deleted or stopped. The script always restores the suspended firewall, even
if it is interrupted.

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

==> Summary
  panw-ha-fw-a     initial   https://3.14.x.x   (AZ us-east-2a)
  panw-ha-fw-b     active    https://18.22.x.x  (AZ us-east-2b)
```

The two lines that matter:

- `Routes moved off … -> now …`: AWS routing now points at the other
  firewall.
- `After: … -> 10.100.20.125, ~12s after the suspend`: the web page came back
  through the other firewall, from the same server.

`initial` in the summary is the restored firewall rejoining; a few seconds
later it reads `passive`.

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
and leaves FW-B as standby:

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
   `http://<floating IP>/` in a browser.
2. On the **active** firewall's web UI: **Device → High Availability →
   Operational Commands → Suspend local device** → **OK**.
3. Watch the watcher: within about 10 to 30 seconds it prints
   `*** ROUTES MOVED ***` pointing at the other firewall. Refresh the web
   page: same server IP.
4. On the other firewall, the Dashboard HA widget now reads **Local: Active**
   (refresh if stale).
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

### Policy changes (rules, NAT, objects, zones, profiles)

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

### Network changes (interfaces, virtual router)

These are per-firewall. Make them on **each** firewall separately, keep each
firewall's next hops on its own subnets, then run
`python3 scripts/configure.py --verify-only` and check **Firewall next
hops**.

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
This build needs 36 vCPUs:

| What | Count | vCPUs each | Total |
|---|---|---|---|
| Firewalls (`m5.4xlarge`) | 2 | 16 | 32 |
| Test servers (`t3.micro`) | 2 | 2 | 4 |

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

> **Smaller firewalls?** Only with a matching license. The instance must be at
> least as large as the VM-Series model the auth code licenses; if it is
> smaller, PAN-OS refuses the license and never finishes starting.

## Problem: `Marketplace subscription required`

The account isn't subscribed to the Palo Alto listing. `deploy.sh` prints the
URL: open it, **Continue to Subscribe**, accept the terms, wait about five
minutes, re-run.

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
  --filters "Name=tag:Project,Values=panw-ha" "Name=tag:HaGroup,Values=*" \
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
2. **Automatic remediation in your AWS account replaced the management
   security group** with a restricted copy. Check what's attached:
   ```bash
   aws ec2 describe-network-interfaces --region us-east-2 \
     --filters "Name=tag:Role,Values=mgmt" \
     --query 'NetworkInterfaces[].[TagSet[?Key==`Name`]|[0].Value, join(`, `, Groups[].GroupName)]' --output text
   ```
   Terraform's own group is `panw-ha-sg-mgmt`. Names like
   `panw-ha-sg-mgmt-ar-NNN` or `…_xpanse_ar_NNN` are copies made by
   remediation; Terraform deliberately leaves them alone. Each copy's
   description says which rule was removed:
   ```bash
   aws ec2 describe-security-groups --region us-east-2 \
     --filters "Name=group-name,Values=*-ar-*" \
     --query 'SecurityGroups[].[GroupName,Description]' --output text
   ```

**The way in that always works: an SSM tunnel.** It goes through a test
server inside the VPC over HTTPS to AWS, so it needs no inbound rules and
passes most corporate proxies:

```bash
W=$(terraform output -json workload_instance_ids | python3 -c 'import json,sys;print(json.load(sys.stdin)[0])')
aws ssm start-session --region us-east-2 --target "$W" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters 'host=10.100.0.10,portNumber=443,localPortNumber=8443'
```

Leave it running and browse to **https://localhost:8443** for FW-A. For
FW-B use `host=10.100.10.10` and `localPortNumber=8444`. For SSH, use
`portNumber=22,localPortNumber=2222` and then
`ssh -i .secrets/panw-ha-key.pem -p 2222 admin@localhost`.

`configure.py` talks to the firewalls' public management IPs, so to run it
again you need direct access back. Either add your current IP to an
attached security group, or attach Terraform's `panw-ha-sg-mgmt` group
**alongside** the existing ones:

```bash
TF=$(terraform state show aws_security_group.mgmt | awk '$1=="id"{gsub(/"/,"",$3);print $3;exit}')
for eni in $(aws ec2 describe-network-interfaces --region us-east-2 --filters "Name=tag:Role,Values=mgmt" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
  CUR=$(aws ec2 describe-network-interfaces --region us-east-2 --network-interface-ids $eni --query 'NetworkInterfaces[0].Groups[].GroupId' --output text)
  aws ec2 modify-network-interface-attribute --region us-east-2 --network-interface-id $eni --groups $CUR $TF
done
```

Check with your security team first if remediation removed it. If
`panw-ha-sg-mgmt` still contains a `0.0.0.0/0` rule on SSH or HTTPS (from
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
   log from AWS, which needs no login:
   ```bash
   ID=$(aws ec2 describe-instances --region us-east-2 \
     --filters "Name=tag:Name,Values=panw-ha-fw-a" "Name=instance-state-name,Values=running" \
     --query 'Reservations[].Instances[].InstanceId' --output text)
   aws ec2 get-console-output --region us-east-2 --latest --instance-id "$ID" --output text | grep -iE "licen|CRITICAL"
   ```
   `… is not supported for this platform` means the auth code is for the
   wrong product (you need a VM-Series capacity code). A size mismatch means
   the instance is smaller than the licensed model. Put the right code in
   `terraform.tfvars` as `panos_auth_codes = "YOURCODE"` and rebuild the
   firewalls (below).
3. **The password hash format.** PAN-OS accepts `$5$` (SHA-256) hashes; this
   project generates those. A `$6$` hash loads without error but rejects
   every login. Only relevant if you've changed `scripts/phash_helper.py`.

Licensing and the admin password are applied only at a firewall's **first**
boot. To rebuild just the firewalls (keeping the VPC, IPs and test servers):

```bash
terraform apply -replace='aws_instance.fw["a"]' -replace='aws_instance.fw["b"]'
python3 scripts/configure.py
```

That takes about 20 minutes. Rebuilt firewalls don't release their old
licenses: deactivate the old serial numbers in the Palo Alto support portal,
or the auth code may run out of seats.

## Problem: a commit fails with "Validation Error … unexpected here" or "no UUID found for rule"

The firewall loaded a configuration at boot that it then refuses to commit,
so **every** later commit fails. Known causes, all fixed in the current
template: `passive-link-state` under active-passive, `action` under
`ha2-keep-alive`, and rules without a `uuid`. If you've edited
`templates/bootstrap.xml.tftpl`, run the firewall's own check on the
**Commit** menu (**Validate Commit**) to see the offending lines.

## Problem: the GUI asks to change packet IO mode to mmap and reboot

You switched the AWS failover mode to **interface-move**. Don't reboot.
Go to **Device → VM-Series**, click **Change to secondary-ip mode**, and
check both firewalls show **secondary-ip**. `configure.py` also sets it on
every run.

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
2. **Monitor → Traffic** on the active firewall, filtered on the server's IP.
3. Right after a failover, give the SSM agent a couple of minutes to
   reconnect before concluding anything is broken.

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

**Do this when you're finished;** the stack costs about $38 per day.

```bash
cd ~/Downloads/panw-ha-aws
./destroy.sh
```

It lists what will be deleted and asks you to type `destroy` (not `yes`).
It takes about 10 minutes and ends with `Destroy complete!`.

### If it fails with `DependencyViolation` on a security group or the VPC

Something outside Terraform added resources to the VPC. The usual culprit
is security groups created by automatic remediation (names containing
`-ar-`). Terraform's own groups are exactly `panw-ha-sg-mgmt`, `-ha2`,
`-untrust`, `-trust` and `-workload`; this lists everything else:

```bash
VPC=$(terraform output -raw vpc_id 2>/dev/null)
aws ec2 describe-security-groups --region us-east-2 --filters "Name=vpc-id,Values=$VPC" \
  --query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName]' --output text \
  | grep -vE '\spanw-ha-sg-(mgmt|ha2|untrust|trust|workload)$'
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
the serial numbers in the Palo Alto support portal so the auth code can be
used again.

### What stays on your Mac

`.secrets/` (password and SSH key). Delete it when you're sure you're done:
`rm -rf .secrets`

---

# Quick reference

```bash
cd ~/Downloads/panw-ha-aws
aws sso login                                  # if credentials expired

./deploy.sh --plan-only                        # preview, change nothing
./deploy.sh                                    # deploy (asks first)

python3 scripts/configure.py                   # configure + verify (safe to re-run)
python3 scripts/configure.py --verify-only     # health check, read-only
python3 scripts/configure.py --failover-test   # fail over (run again to fail back)
python3 scripts/configure.py --sync-config     # copy policy active -> passive
./scripts/watch-failover.sh                    # live route watcher (2nd window)

terraform output floating_service_ip           # http://<this>/ = test web page
terraform output firewall_management_urls      # firewall web UIs
terraform output workload_instance_ids         # test servers (for SSM)
cat .secrets/admin_password                    # pandmin password

./destroy.sh                                   # delete everything
```

**In the PAN-OS web interface:**

| Task | Where |
|---|---|
| HA status | Dashboard → High Availability widget |
| Suspend / restore a firewall | Device → High Availability → Operational Commands |
| AWS failover mode (must be secondary-ip) | Device → VM-Series → AWS HA |
| Licenses | Device → Licenses |
| Static routes / next hops | Network → Virtual Routers → default → Static Routes |
| Traffic logs | Monitor → Traffic |
| System logs | Monitor → System |

---

# A successful failover test, in short

All of these are true:

1. ✅ `--verify-only` is all `[ ok ]`: one active, one passive, own next hops,
   routes on the active firewall, web page answering.
2. ✅ `http://<floating IP>/` shows a test server's IP.
3. ✅ `--failover-test` reports `Routes moved …` within about 10 to 30
   seconds.
4. ✅ It reports `After: … -> <same IP>`: the web page came back through the
   other firewall.
5. ✅ Running it again fails back the other way.

Points 3 and 4 are what distinguish a working HA pair in AWS from two
firewalls that merely agree about who is in charge.
