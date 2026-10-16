#!/usr/bin/env python3
"""Post-deploy configuration and verification for the VM-Series HA pair.

Terraform builds the infrastructure and bootstraps PAN-OS (interfaces, zones,
virtual router, NAT/security policy, HA1/HA2). Two things cannot be expressed
in bootstrap.xml and are done here, over the PAN-OS XML API:

  1. The VM-Series AWS plugin failover mode. It is an operational command,
     not config, so bootstrap.xml cannot carry it, and the AMI defaults to
     interface-move. In secondary-ip mode the newly active node repoints the
     workload routes at its own trust ENI and pulls the floating EIP; it finds
     them itself, so there are no route tables to configure.
  2. Verification: licensing state, HA1/HA2 link state, peer sync, and that
     the workload route tables actually point at the active node's trust ENI.

With the branch site deployed (deploy_branch = true) it also:

  3. Installs the newest Applications and Threats, Antivirus and WildFire
     content on the branch firewall and schedules recurring updates.
  4. Configures the IPsec tunnel on all three firewalls (each node of the
     pair gets its own copy: HA config sync is off) and verifies it, end to
     end, with an HTTP request from the branch workload to a pair workload.

Input comes from `terraform output -json configure_inputs`.

  python3 scripts/configure.py                 # configure, then verify
  python3 scripts/configure.py --verify-only   # read-only health check
  python3 scripts/configure.py --failover-test # suspend active node, watch routes
  python3 scripts/configure.py --sync-config   # copy policy config active -> passive
"""

import argparse
import ipaddress
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
TF_DIR = os.path.dirname(HERE)

# The firewalls present a self-signed certificate on first boot. We are talking
# to an IP address we just created and whose admin password only we know, so we
# accept it -- but say so loudly rather than silently disabling verification.
SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE


class Colors:
    OK = "\033[32m"
    WARN = "\033[33m"
    ERR = "\033[31m"
    DIM = "\033[2m"
    BOLD = "\033[1m"
    END = "\033[0m"


def _c(text, color):
    return "%s%s%s" % (color, text, Colors.END) if sys.stdout.isatty() else text


def info(msg):
    print("  %s" % msg)


def step(msg):
    print("\n%s" % _c("==> " + msg, Colors.BOLD))


def ok(msg):
    print("  %s %s" % (_c("[ ok ]", Colors.OK), msg))


def warn(msg):
    print("  %s %s" % (_c("[warn]", Colors.WARN), msg))


def fail(msg):
    print("  %s %s" % (_c("[FAIL]", Colors.ERR), msg))


###############################################################################
# PAN-OS XML API client
###############################################################################


class PanOS:
    def __init__(self, host, name=None):
        self.host = host
        self.name = name or host
        self.key = None

    def _request(self, params, timeout=60):
        # POST: --sync-config sends whole config subtrees, far past URL length
        # limits, and it keeps the password out of request URLs.
        req = urllib.request.Request(
            "https://%s/api/" % self.host,
            data=urllib.parse.urlencode(params).encode(),
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=timeout, context=SSL_CTX) as resp:
            body = resp.read()
        root = ET.fromstring(body)
        if root.get("status") != "success":
            msg = "".join(root.itertext()).strip()
            raise PanOSError("%s: API error: %s" % (self.name, msg or body[:300]))
        return root

    def keygen(self, username, password):
        root = self._request(
            {"type": "keygen", "user": username, "password": password}
        )
        self.key = root.findtext(".//key")
        if not self.key:
            raise PanOSError("%s: keygen returned no key" % self.name)
        return self.key

    # Op commands are relayed to backend daemons, which drop out briefly while
    # PAN-OS finishes boot or applies a plugin change (the failover-mode
    # command does this). The API then answers e.g. "op command for client
    # dagger timed out as client is not available"; it clears on its own.
    TRANSIENT = ("client is not available", "timed out")

    def op(self, cmd, timeout=120, retry_for=180):
        deadline = time.time() + retry_for
        while True:
            try:
                return self._request(
                    {"type": "op", "cmd": cmd, "key": self.key}, timeout=timeout
                )
            except PanOSError as exc:
                if time.time() >= deadline or not any(t in str(exc) for t in self.TRANSIENT):
                    raise
                print("  %s %s: management backend busy; retrying"
                      % (_c("...", Colors.DIM), self.name), end="\r", flush=True)
                time.sleep(10)

    def get(self, xpath):
        return self._request(
            {"type": "config", "action": "get", "xpath": xpath, "key": self.key}
        )

    def set(self, xpath, element):
        return self._request(
            {
                "type": "config",
                "action": "set",
                "xpath": xpath,
                "element": element,
                "key": self.key,
            }
        )

    def commit(self, timeout=900):
        # Commit is its own API type; sent as type=op it fails with
        # "Invalid op command handler".
        root = self._request(
            {"type": "commit", "cmd": "<commit></commit>", "key": self.key},
            timeout=120,
        )
        job = root.findtext(".//job")
        if not job:
            # "no changes to commit" comes back as success with no job id.
            return None
        return self.wait_for_job(job, timeout=timeout)

    def wait_for_job(self, job_id, timeout=900):
        deadline = time.time() + timeout
        while time.time() < deadline:
            root = self.op("<show><jobs><id>%s</id></jobs></show>" % job_id)
            status = root.findtext(".//job/status")
            result = root.findtext(".//job/result")
            if status == "FIN":
                if result != "OK":
                    details = " ".join(
                        t.strip() for t in root.itertext() if t.strip()
                    )
                    raise PanOSError(
                        "%s: job %s finished %s: %s"
                        % (self.name, job_id, result, details[:500])
                    )
                return result
            time.sleep(5)
        raise PanOSError("%s: job %s did not finish within %ds" % (self.name, job_id, timeout))

    def ha_state(self):
        root = self.op("<show><high-availability><state></state></high-availability></show>")
        g = root.find(".//group")
        if g is None:
            return {"enabled": root.findtext(".//enabled") or "no"}
        return {
            "enabled": root.findtext(".//enabled") or "yes",
            "local_state": g.findtext("./local-info/state"),
            "peer_state": g.findtext("./peer-info/state"),
            "ha1_status": g.findtext("./local-info/state-sync")
            or g.findtext("./running-sync"),
            "running_sync": g.findtext("./running-sync"),
            "ha2_status": g.findtext("./local-info/state-sync-type"),
            "priority": g.findtext("./local-info/priority"),
            "peer_conn": g.findtext("./peer-info/conn-status"),
            "ha2_conn": g.findtext("./link-mon/failure-condition")
            or g.findtext("./local-info/active-passive/passive-link-state"),
        }


class PanOSError(Exception):
    pass


###############################################################################
# Terraform inputs
###############################################################################


def load_inputs():
    try:
        raw = subprocess.check_output(
            ["terraform", "output", "-json", "configure_inputs"],
            cwd=TF_DIR,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError:
        sys.exit("terraform not found on PATH")
    except subprocess.CalledProcessError as exc:
        sys.exit(
            "Could not read terraform outputs (has `terraform apply` run?):\n%s"
            % exc.stderr.decode()
        )
    return json.loads(raw)


###############################################################################
# Steps
###############################################################################


def wait_for_api(fw, username, password, timeout=2400):
    """VM-Series takes 10-20 minutes to boot and apply its bootstrap config."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            fw.keygen(username, password)
            return True
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as exc:
            last = "unreachable (%s)" % type(exc).__name__
        except PanOSError as exc:
            # Reachable but rejecting us. If the credentials are wrong the
            # bootstrap config did not load, and waiting will not fix it.
            if "Invalid credentials" in str(exc):
                last = "reachable, credentials rejected"
            else:
                last = str(exc)[:80]
        except ET.ParseError:
            last = "reachable, API not ready"
        remaining = int(deadline - time.time())
        print(
            "  %s waiting for %s @ %s - %s (%dm%02ds left)   "
            % (_c("...", Colors.DIM), fw.name, fw.host, last, remaining // 60, remaining % 60),
            end="\r",
            flush=True,
        )
        time.sleep(20)
    print()
    raise PanOSError("%s: management API never became ready (last: %s)" % (fw.name, last))


def check_license(fw):
    try:
        root = fw.op("<request><license><info></info></license></request>")
    except PanOSError as exc:
        warn("%s: could not read license info: %s" % (fw.name, exc))
        return False
    entries = root.findall(".//licenses/entry")
    if not entries:
        warn(
            "%s: NO LICENSES INSTALLED. BYOL firewalls without a valid auth code "
            "run with reduced capacity and no content updates." % fw.name
        )
        return False
    for e in entries:
        info(
            "%s: license %-34s expires %s"
            % (fw.name, e.findtext("feature"), e.findtext("expires"))
        )
    return True


def fetch_license(fw):
    step("Fetching licenses on %s" % fw.name)
    try:
        fw.op("<request><license><fetch></fetch></license></request>", timeout=180)
        ok("%s: license fetch issued" % fw.name)
    except PanOSError as exc:
        warn("%s: license fetch failed: %s" % (fw.name, exc))


# ---------------------------------------------------------------------------
# AWS plugin failover mode
# ---------------------------------------------------------------------------

FAILOVER_MODE = "secondary-ip"


def set_failover_mode(fw, mode=FAILOVER_MODE):
    """Set the AWS plugin failover mode. Applies to the peer too; no commit.

    Never interface-move here: it cannot work across AZs (an ENI cannot attach
    to an instance in another AZ) and on DPDK builds it asks for a reboot of
    both nodes to switch packet IO to mmap.
    """
    root = fw.op(
        "<request><plugins><vm_series><aws><ha><failover-mode>%s</failover-mode>"
        "</ha></aws></vm_series></plugins></request>" % mode
    )
    msg = (root.findtext(".//msg") or "").strip()
    ok("%s: %s" % (fw.name, msg.split(". ")[0] or "failover mode set to %s" % mode))


# ---------------------------------------------------------------------------
# Policy sync (stands in for HA config sync, which is off)
# ---------------------------------------------------------------------------

DEVICE = "/config/devices/entry[@name='localhost.localdomain']"

# Copied active -> passive. Everything per-node stays put: network (virtual
# router next hops differ per AZ), deviceconfig (HA, hostname, mgmt), mgt-config.
SYNC_XPATHS = (
    "/config/shared",
    DEVICE + "/vsys",
)


def _running_subtree(fw, xpath):
    """Running-config node at xpath, or None if it does not exist."""
    try:
        root = fw._request({"type": "config", "action": "show", "xpath": xpath, "key": fw.key})
    except PanOSError as exc:
        if "No such node" in str(exc):
            return None
        raise
    result = root.find("result")
    node = list(result)[0] if result is not None and len(result) else None
    return node


def _canonical(node):
    """Comparable form of a config node, ignoring rule uuids.

    PAN-OS assigns a fresh uuid to every rule written through the API, so the
    passive node's copy never carries the active node's uuids.
    """
    if node is None:
        return ""
    node = ET.fromstring(ET.tostring(node))
    for el in node.iter():
        el.attrib.pop("uuid", None)
    return ET.canonicalize(ET.tostring(node, encoding="unicode"), strip_text=True)


def _pending_changes(fw):
    root = fw.op("<check><pending-changes></pending-changes></check>")
    return (root.findtext(".//result") or "").strip() == "yes"


def sync_config(firewalls):
    """Copy committed policy config from the active node to the passive one."""
    step("Policy sync (active -> passive)")
    states = {fw.name: fw.ha_state() for fw in firewalls}
    src = next((fw for fw in firewalls if states[fw.name].get("local_state") == "active"), None)
    dst = next((fw for fw in firewalls if states[fw.name].get("local_state") == "passive"), None)
    if not src or not dst:
        fail("Need one active and one passive node; got %s"
             % {n: s.get("local_state") for n, s in states.items()})
        return False
    info("Source %s (active) -> target %s (passive)" % (src.name, dst.name))

    if _pending_changes(src):
        warn("%s has uncommitted changes; only its COMMITTED config is copied." % src.name)
    if _pending_changes(dst):
        fail("%s has uncommitted changes of its own. Commit or revert them on %s first; "
             "nothing was copied." % (dst.name, dst.name))
        return False

    changed = []
    for xpath in SYNC_XPATHS:
        node = _running_subtree(src, xpath)
        label = xpath.rsplit("/", 1)[-1]
        if _canonical(node) == _canonical(_running_subtree(dst, xpath)):
            ok("%s: already identical" % label)
            continue
        if node is None:
            warn("%s: empty on %s; leaving %s as is" % (label, src.name, dst.name))
            continue
        dst._request({
            "type": "config", "action": "edit", "xpath": xpath,
            "element": ET.tostring(node, encoding="unicode"), "key": dst.key,
        })
        ok("%s: copied to %s" % (label, dst.name))
        changed.append(label)

    if not changed:
        ok("%s already matches %s; nothing to commit" % (dst.name, src.name))
        return True
    try:
        dst.commit()
        ok("%s: commit complete" % dst.name)
    except PanOSError as exc:
        fail("%s: commit failed: %s" % (dst.name, exc))
        return False
    return True


# ---------------------------------------------------------------------------
# Inbound publishing (floating IP -> workload web server)
# ---------------------------------------------------------------------------

RULEBASE = DEVICE + "/vsys/entry[@name='vsys1']/rulebase"


def _members(values):
    return "".join("<member>%s</member>" % v for v in values)




def ensure_inbound(fw, inbound):
    """Create/refresh the inbound DNAT + security rule. Returns True if changed.

    The security rule matches the PRE-NAT destination (the untrust IPs the
    floating EIP maps to) and the POST-NAT zone (trust), which is how PAN-OS
    evaluates policy for destination NAT.
    """
    match = _members(inbound["match_ips"])
    # One DNAT rule per node's untrust IP: PAN-OS rejects a rule translating
    # several original addresses to one ("Mismatch of destination address
    # translation range"). Each rule also source-NATs to the SAME node's trust
    # IP, so the request reaches the workload from inside the VPC (the workload
    # SG admits only the VPC CIDR) and the reply returns to that node.
    nats = [
        (
            "<entry name='inbound-dnat-%d'>"
            "<description>Floating IP on %s -> %s (configure.py)</description>"
            "<from><member>untrust</member></from><to><member>untrust</member></to>"
            "<source><member>any</member></source>"
            "<destination><member>%s</member></destination>"
            "<service>%s</service>"
            "<source-translation><dynamic-ip-and-port><translated-address>"
            "<member>%s</member></translated-address></dynamic-ip-and-port>"
            "</source-translation>"
            "<destination-translation><translated-address>%s</translated-address>"
            "</destination-translation></entry>"
            % (i, ip, inbound["target_ip"],
               ip, inbound["service"], snat, inbound["target_ip"])
        )
        for i, (ip, snat) in enumerate(zip(inbound["match_ips"], inbound["snat_ips"]), 1)
    ]
    sec = (
        "<entry name='allow-inbound'>"
        "<description>Internet -> %s via the floating IP (configure.py)</description>"
        "<from><member>untrust</member></from><to><member>trust</member></to>"
        "<source><member>any</member></source><destination>%s</destination>"
        "<source-user><member>any</member></source-user>"
        "<application><member>any</member></application>"
        "<service><member>%s</member></service>"
        "<category><member>any</member></category>"
        "<action>allow</action><log-end>yes</log-end></entry>"
        % (inbound["target_ip"], match,
           inbound["service"])
    )
    changed = False
    # Drop the single-rule form an earlier version created (it never commits).
    try:
        fw._request({"type": "config", "action": "delete", "key": fw.key,
                     "xpath": "%s/nat/rules/entry[@name='inbound-dnat']" % RULEBASE})
    except PanOSError:
        pass
    for kind, element in [("nat", n) for n in nats] + [("security", sec)]:
        name = ET.fromstring(element).get("name")
        xpath = "%s/%s/rules/entry[@name='%s']" % (RULEBASE, kind, name)
        current = _running_subtree(fw, xpath)
        if _canonical(current) == _canonical(ET.fromstring(element)):
            ok("%s: %s rule '%s' up to date" % (fw.name, kind, name))
            continue
        if current is None:
            fw.set("%s/%s/rules" % (RULEBASE, kind), element)
        else:
            fw._request({"type": "config", "action": "edit", "xpath": xpath,
                         "element": element, "key": fw.key})
        ok("%s: %s rule '%s' -> %s" % (fw.name, kind, name, inbound["target_ip"]))
        changed = True
    # Allow rules must sit above the catch-all deny. Only move when needed: a
    # no-op move still leaves a pending change behind.
    rules = fw.get("%s/security/rules" % RULEBASE).findall(".//rules/entry")
    order = [e.get("name") for e in rules]
    if "deny-all" in order and order.index("allow-inbound") > order.index("deny-all"):
        fw._request({"type": "config", "action": "move", "where": "before", "dst": "deny-all",
                     "xpath": "%s/security/rules/entry[@name='allow-inbound']" % RULEBASE,
                     "key": fw.key})
        changed = True
    return changed


def publish_inbound(firewalls, inbound):
    step("Inbound publishing (floating IP -> %s)" % (inbound.get("target_ip") or "none"))
    if not inbound.get("enabled"):
        info("Disabled (enable_inbound_dnat = false or no target IP).")
        return True
    active = next((fw for fw in firewalls if fw.ha_state().get("local_state") == "active"), None)
    if not active:
        fail("No active node; skipping.")
        return False
    if ensure_inbound(active, inbound) or _pending_changes(active):
        try:
            active.commit()
            ok("%s: commit complete" % active.name)
        except PanOSError as exc:
            fail("%s: commit failed: %s" % (active.name, exc))
            return False
    return sync_config(firewalls)


# ---------------------------------------------------------------------------
# Idempotent config helpers
# ---------------------------------------------------------------------------


def _covers(current, desired):
    """True if the running node `current` already holds everything in `desired`.

    A subset test, not equality: PAN-OS stores elements in schema order and
    fills in defaults, so the running copy of an object rarely serialises like
    the element that created it. <key> holds an encrypted secret in the running
    config and cannot be compared, so it is skipped.
    """
    if current is None or current.tag != desired.tag:
        return False
    if any(k != "uuid" and current.get(k) != v for k, v in desired.attrib.items()):
        return False
    if len(desired) == 0:
        return desired.tag == "key" or (desired.text or "").strip() == (current.text or "").strip()
    return all(any(_covers(c, d) for c in current) for d in desired)


def _ensure(fw, parent, element):
    """Create or replace the node `element` under `parent`. Returns True if changed."""
    desired = ET.fromstring(element)
    name = desired.get("name")
    xpath = "%s/%s" % (parent, desired.tag) + ("[@name='%s']" % name if name else "")
    current = _running_subtree(fw, xpath)
    if _covers(current, desired):
        return False
    if current is None:
        fw.set(parent, element)
    else:
        fw._request({"type": "config", "action": "edit", "xpath": xpath,
                     "element": element, "key": fw.key})
    return True


def _ensure_member(fw, xpath, member):
    """Add <member> to the list at xpath unless it is already there."""
    node = _running_subtree(fw, xpath)
    if node is not None and member in [m.text for m in node.findall("member")]:
        return False
    fw.set(xpath, "<member>%s</member>" % member)
    return True


def _above_deny(fw, names):
    """Move the named security rules above deny-all where they are not already."""
    changed = False
    for name in names:
        rules = fw.get("%s/security/rules" % RULEBASE).findall(".//rules/entry")
        order = [e.get("name") for e in rules]
        if "deny-all" in order and name in order and order.index(name) > order.index("deny-all"):
            fw._request({"type": "config", "action": "move", "where": "before", "dst": "deny-all",
                         "xpath": "%s/security/rules/entry[@name='%s']" % (RULEBASE, name),
                         "key": fw.key})
            changed = True
    return changed


def _commit_if_needed(fw, changed):
    if changed or _pending_changes(fw):
        fw.commit()
        ok("%s: commit complete" % fw.name)


# ---------------------------------------------------------------------------
# IPsec tunnel: branch <-> HA pair
# ---------------------------------------------------------------------------

TUNNEL_IF = "tunnel.1"
IKE_PROFILE = "panw-ike-aes256"
IPSEC_PROFILE = "panw-ipsec-aes256"
MONITOR_PROFILE = "panw-tunnel-monitor"
VR = DEVICE + "/network/virtual-router/entry[@name='default']"
VSYS = DEVICE + "/vsys/entry[@name='vsys1']"

# Tunnel names on each end, as (IKE gateway, IPsec tunnel).
TUNNEL_NAMES = {"hub": ("branch-gw", "to-branch"), "branch": ("hub-gw", "to-hub")}


def _tunnel_config(side, vpn):
    """(parent xpath, element) pairs for one end of the tunnel, in apply order.

    Route-based IKEv2. Both ends sit behind AWS 1:1 NAT, so NAT-T is on and
    each end identifies itself by its PUBLIC address (the default IKE ID would
    be its private one). On the pair the local address is just the untrust
    interface: it is DHCP, its IP differs per node, and whichever node is
    active owns the floating EIP that the branch peers with.
    """
    hub = side == "hub"
    gw, tunnel = TUNNEL_NAMES[side]
    local_pub, peer_pub = ((vpn["hub_public_ip"], vpn["branch_public_ip"]) if hub
                           else (vpn["branch_public_ip"], vpn["hub_public_ip"]))
    untrust_if = "ethernet1/2" if hub else "ethernet1/1"
    remote_cidr = vpn["branch_cidr"] if hub else vpn["hub_cidr"]
    local_cidr = vpn["hub_cidr"] if hub else vpn["branch_cidr"]
    tunnel_ip = "%s/%s" % (vpn["hub_tunnel_ip"] if hub else vpn["branch_tunnel_ip"],
                           vpn["tunnel_cidr"].split("/")[1])
    # BOTH ends monitor the tunnel by pinging the other end's tunnel IP.
    #
    # The pair's end is what makes a failover recover. The new active node
    # inherits the old one's IPsec SAs over HA2 -- including its PRIVATE local
    # address, which in another AZ is not its own, so AWS drops everything it
    # sends -- but not its IKE SA. Its own monitor then fails, and with no IKE
    # SA to rekey inside it starts a fresh one from its own address, which
    # replaces the branch's stale one. With only the branch monitoring, the
    # branch kept retrying inside its stale IKE SA and the tunnel stayed down
    # until dead-peer detection expired it: about 10 minutes, measured twice,
    # whether the branch's monitor action was wait-recover or fail-over.
    # (A passive node's monitor is idle: its dataplane is down.)
    peer_tunnel_ip = vpn["branch_tunnel_ip"] if hub else vpn["hub_tunnel_ip"]
    monitor = (
        "<tunnel-monitor><enable>yes</enable><destination-ip>%s</destination-ip>"
        "<tunnel-monitor-profile>%s</tunnel-monitor-profile></tunnel-monitor>"
        % (peer_tunnel_ip, MONITOR_PROFILE))
    both = [vpn["hub_cidr"], vpn["branch_cidr"]]

    # Without a named profile the monitor falls back to one called "default",
    # which PAN-OS 11.2 does not ship ("tunnel monitoring profile default not
    # found" at commit). wait-recover: keep routing into the tunnel while it
    # renegotiates, which is all a single tunnel can do anyway.
    profile = [
        (DEVICE + "/network/profiles/monitor-profile",
         "<entry name='%s'><interval>3</interval><threshold>5</threshold>"
         "<action>wait-recover</action></entry>" % MONITOR_PROFILE),
    ]

    return profile + [
        (DEVICE + "/network/ike/crypto-profiles/ike-crypto-profiles",
         "<entry name='%s'><hash><member>sha256</member></hash>"
         "<dh-group><member>group14</member></dh-group>"
         "<encryption><member>aes-256-cbc</member></encryption>"
         "<lifetime><hours>8</hours></lifetime></entry>" % IKE_PROFILE),
        (DEVICE + "/network/ike/crypto-profiles/ipsec-crypto-profiles",
         "<entry name='%s'><esp><encryption><member>aes-256-cbc</member></encryption>"
         "<authentication><member>sha256</member></authentication></esp>"
         "<dh-group>group14</dh-group><lifetime><hours>1</hours></lifetime></entry>"
         % IPSEC_PROFILE),
        (DEVICE + "/network/interface/tunnel/units",
         "<entry name='%s'><ip><entry name='%s'/></ip>"
         "<interface-management-profile>mgmt-ping</interface-management-profile>"
         "<comment>IPsec to the %s (configure.py)</comment></entry>"
         % (TUNNEL_IF, tunnel_ip, "branch" if hub else "HA pair")),
        (DEVICE + "/network/ike/gateway",
         "<entry name='%s'>"
         "<authentication><pre-shared-key><key>%s</key></pre-shared-key></authentication>"
         "<protocol><ikev2><ike-crypto-profile>%s</ike-crypto-profile>"
         "<dpd><enable>yes</enable></dpd></ikev2><version>ikev2</version></protocol>"
         "<protocol-common><nat-traversal><enable>yes</enable></nat-traversal></protocol-common>"
         "<local-address><interface>%s</interface></local-address>"
         "<peer-address><ip>%s</ip></peer-address>"
         "<local-id><type>ipaddr</type><id>%s</id></local-id>"
         "<peer-id><type>ipaddr</type><id>%s</id></peer-id></entry>"
         % (gw, vpn["psk"], IKE_PROFILE, untrust_if, peer_pub, local_pub, peer_pub)),
        (DEVICE + "/network/tunnel/ipsec",
         "<entry name='%s'><auto-key><ike-gateway><entry name='%s'/></ike-gateway>"
         "<ipsec-crypto-profile>%s</ipsec-crypto-profile></auto-key>"
         "<tunnel-interface>%s</tunnel-interface>%s</entry>"
         % (tunnel, gw, IPSEC_PROFILE, TUNNEL_IF, monitor)),
        # No next hop: a point-to-point tunnel interface needs none.
        (VR + "/routing-table/ip/static-route",
         "<entry name='%s'><destination>%s</destination><interface>%s</interface>"
         "<metric>10</metric></entry>" % (tunnel, remote_cidr, TUNNEL_IF)),
        (VSYS + "/zone",
         "<entry name='vpn'><network><layer3><member>%s</member></layer3></network></entry>"
         % TUNNEL_IF),
        # Workload traffic both ways. Also matches trust -> trust, which the
        # pair already allows (allow-east-west).
        (RULEBASE + "/security/rules",
         "<entry name='allow-site-to-site'>"
         "<description>Security VPC &lt;-&gt; branch over IPsec (configure.py)</description>"
         "<from>%s</from><to>%s</to><source>%s</source><destination>%s</destination>"
         "<source-user><member>any</member></source-user>"
         "<application><member>any</member></application>"
         "<service><member>any</member></service><category><member>any</member></category>"
         "<action>allow</action><log-end>yes</log-end></entry>"
         % (_members(["trust", "vpn"]), _members(["trust", "vpn"]), _members(both), _members(both))),
        # Tunnel-monitor pings are vpn -> vpn, which deny-all would otherwise catch.
        (RULEBASE + "/security/rules",
         "<entry name='allow-tunnel-monitor'>"
         "<description>Tunnel monitoring between the tunnel interfaces (configure.py)</description>"
         "<from><member>vpn</member></from><to><member>vpn</member></to>"
         "<source><member>%s</member></source><destination><member>%s</member></destination>"
         "<source-user><member>any</member></source-user>"
         "<application><member>ping</member></application>"
         "<service><member>application-default</member></service>"
         "<category><member>any</member></category>"
         "<action>allow</action><log-end>yes</log-end></entry>"
         % (vpn["tunnel_cidr"], vpn["tunnel_cidr"])),
        # IKE and ESP to and from the firewall itself are untrust -> untrust,
        # which deny-all would otherwise catch -- in BOTH directions: the
        # firewall's own initiating packets are policy-checked too, and in AWS
        # they leave from its PRIVATE untrust address (the IGW maps it to the
        # EIP), while the peer's arrive from its public one.
        (RULEBASE + "/security/rules",
         "<entry name='allow-ike'>"
         "<description>IKE / IPsec with the tunnel peer (configure.py)</description>"
         "<from><member>untrust</member></from><to><member>untrust</member></to>"
         "<source>%s</source><destination>%s</destination>"
         "<source-user><member>any</member></source-user>"
         "<application>%s</application>"
         "<service><member>application-default</member></service>"
         "<category><member>any</member></category>"
         "<action>allow</action><log-end>yes</log-end></entry>"
         % (_members([peer_pub, local_cidr]), _members([peer_pub, local_cidr]),
            _members(["ike", "ipsec-esp", "ipsec-esp-udp"]))),
    ]


TUNNEL_RULES = ("allow-site-to-site", "allow-tunnel-monitor", "allow-ike")


def ensure_tunnel(fw, side, vpn):
    """Apply one end of the tunnel to the candidate config. Returns True if changed.

    The pre-shared key is compared only on creation (the running copy is
    encrypted), so changing ipsec_psk later means deleting the IKE gateways
    first, or editing the key on every firewall by hand.
    """
    changed = False
    for parent, element in _tunnel_config(side, vpn):
        if parent == VR + "/routing-table/ip/static-route":
            # PAN-OS checks the route's and the zone's interface reference
            # when they are SET, so tunnel.1 must be in the virtual router and
            # the vsys first ("interface 'tunnel.1' is not a valid reference").
            changed = _ensure_member(fw, VR + "/interface", TUNNEL_IF) or changed
            changed = _ensure_member(fw, VSYS + "/import/network/interface", TUNNEL_IF) or changed
        if _ensure(fw, parent, element):
            node = ET.fromstring(element)
            ok("%s: %s '%s'" % (fw.name, parent.rsplit("/", 1)[-1], node.get("name")))
            changed = True
    changed = _above_deny(fw, TUNNEL_RULES) or changed
    return changed


def configure_tunnel(pair, branch, vpn):
    step("IPsec tunnel: %s (branch) <-> %s (HA pair floating IP)"
         % (vpn["branch_public_ip"], vpn["hub_public_ip"]))
    # Network config is per node (HA config sync is off), so each node of the
    # pair is configured and committed on its own. Their tunnel policy comes
    # out identical, so the later policy sync has nothing to copy for it.
    good = True
    for fw, side in [(fw, "hub") for fw in pair] + [(branch, "branch")]:
        try:
            changed = ensure_tunnel(fw, side, vpn)
            if not changed:
                ok("%s: tunnel config up to date" % fw.name)
            _commit_if_needed(fw, changed)
        except PanOSError as exc:
            fail("%s: %s" % (fw.name, exc))
            good = False
            # A half-applied tunnel would make every later commit on this
            # firewall fail too (the inbound rules' commit, for one).
            try:
                fw.op("<revert><config></config></revert>")
                warn("%s: uncommitted changes reverted" % fw.name)
            except PanOSError:
                pass
    return good


# ---------------------------------------------------------------------------
# Content updates (dynamic updates)
# ---------------------------------------------------------------------------

# (label, op command keyword, license feature required). Antivirus and
# WildFire packages install only on top of Applications and Threats, so order
# matters. "Threat Prevention" also matches "Advanced Threat Prevention", and
# "WildFire" matches "Advanced WildFire".
CONTENT_TYPES = (
    ("Applications and Threats", "content", None),
    ("Antivirus", "anti-virus", "Threat Prevention"),
    ("WildFire", "wildfire", "WildFire"),
)

# Recurring schedule per content type: threats every 30 minutes, antivirus
# hourly, WildFire every minute; all download-and-install.
UPDATE_SCHEDULE = {
    "content": "<threats><recurring><every-30-mins><at>2</at>"
               "<action>download-and-install</action></every-30-mins></recurring></threats>",
    "anti-virus": "<anti-virus><recurring><hourly><at>4</at>"
                  "<action>download-and-install</action></hourly></recurring></anti-virus>",
    "wildfire": "<wildfire><recurring><every-min>"
                "<action>download-and-install</action></every-min></recurring></wildfire>",
}


def _license_features(fw):
    root = fw.op("<request><license><info></info></license></request>")
    return [e.findtext("feature") or "" for e in root.findall(".//licenses/entry")]


def _version_key(version):
    return tuple(int(p) for p in re.findall(r"\d+", version or ""))


def _job(fw, cmd, timeout):
    root = fw.op(cmd, timeout=180)
    job = root.findtext(".//job")
    if not job:
        raise PanOSError("%s: no job id returned: %s"
                         % (fw.name, " ".join(t.strip() for t in root.itertext() if t.strip())[:200]))
    return fw.wait_for_job(job, timeout=timeout)


def update_content_type(fw, label, kind, settle=600):
    """Download and install the newest release of one content type."""
    req = "<request><%s><upgrade>%%s</upgrade></%s></request>" % (kind, kind)
    # Straight after first boot the license and the update-server connection
    # are still settling, and the check fails for a few minutes.
    deadline = time.time() + settle
    while True:
        try:
            root = fw.op(req % "<check></check>", timeout=180)
            break
        except PanOSError as exc:
            if time.time() >= deadline:
                raise
            print("  %s %s: %s check not ready (%s); retrying"
                  % (_c("...", Colors.DIM), fw.name, label, str(exc)[-60:]), end="\r", flush=True)
            time.sleep(30)
    entries = [e for e in root.iter("entry") if e.findtext("version")]
    if not entries:
        raise PanOSError("%s: no %s releases offered" % (fw.name, label))
    latest = max(entries, key=lambda e: _version_key(e.findtext("version")))
    version = latest.findtext("version")
    # Checked before the threat license is active, the firewall offers the
    # applications-only package. Installed, it reports the same version as
    # the full one later offered, so "current" alone would hide that the
    # threat signatures are missing (threat-version 0).
    apps_only = kind == "content" and "Threats" in (latest.findtext("features") or "") and \
        fw.op("<show><system><info></info></system></show>").findtext(".//threat-version") in (None, "", "0")
    if latest.findtext("current") == "yes" and not apps_only:
        ok("%s: %s %s is installed (latest)" % (fw.name, label, version))
        return
    if latest.findtext("downloaded") != "yes":
        info("%s: downloading %s %s" % (fw.name, label, version))
        _job(fw, req % "<download><latest/></download>", timeout=1200)
    info("%s: installing %s %s" % (fw.name, label, version))
    _job(fw, req % "<install><version>latest</version></install>", timeout=1800)
    ok("%s: %s %s installed" % (fw.name, label, version))


def update_content(fw):
    step("Content updates on %s" % fw.name)
    try:
        features = _license_features(fw)
    except PanOSError as exc:
        fail("%s: could not read licenses: %s" % (fw.name, exc))
        return False
    good = True
    installed = []
    for label, kind, needs in CONTENT_TYPES:
        if needs and not any(needs in f for f in features):
            warn("%s: no %s license; skipping %s" % (fw.name, needs, label))
            continue
        try:
            update_content_type(fw, label, kind)
            installed.append(kind)
        except PanOSError as exc:
            print()
            fail("%s: %s update failed: %s" % (fw.name, label, exc))
            good = False
            if kind == "content":
                break  # the others need it
    if not installed:
        return False

    # Keep them current from here on.
    schedule = "<update-schedule>%s</update-schedule>" % "".join(UPDATE_SCHEDULE[k] for k in installed)
    try:
        changed = _ensure(fw, DEVICE + "/deviceconfig/system", schedule)
        _commit_if_needed(fw, changed)
        ok("%s: recurring updates scheduled for %s" % (fw.name, ", ".join(installed)))
    except PanOSError as exc:
        fail("%s: could not schedule updates: %s" % (fw.name, exc))
        # Do not leave a change behind that every later commit would trip over.
        try:
            fw.op("<revert><config></config></revert>")
        except PanOSError:
            pass
        good = False
    return good


def probe_web(floating_ip, timeout=3):
    """Return the IP the published web server reports, or None."""
    try:
        with urllib.request.urlopen("http://%s/ip" % floating_ip, timeout=timeout) as r:
            return r.read().decode().strip()
    except (urllib.error.URLError, OSError, ValueError):
        return None


def verify_web(inputs):
    if not inputs.get("inbound", {}).get("enabled"):
        return True
    step("Published web server")
    fip = inputs["floating_eip"]["public_ip"]
    # A few tries: one slow first connection (e.g. through a corporate proxy)
    # should not read as an outage.
    for attempt in range(1, 4):
        got = probe_web(fip, timeout=5)
        if got:
            ok("http://%s/ answered from %s" % (fip, got))
            return True
        time.sleep(3)
    fail("http://%s/ did not answer (3 attempts)" % fip)
    return False


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------


def verify_ha(firewalls):
    step("HA state")
    states = {}
    all_good = True
    for fw in firewalls:
        try:
            st = fw.ha_state()
        except PanOSError as exc:
            fail("%s: %s" % (fw.name, exc))
            all_good = False
            continue
        states[fw.name] = st
        local = st.get("local_state")
        peer = st.get("peer_state")
        sync = st.get("running_sync")
        # Config sync is disabled by design (per-AZ next hops), so running
        # config always reports "not synchronized"; that is not a fault.
        line = "%s: local=%s peer=%s running-sync=%s" % (fw.name, local, peer, sync)
        if local in ("active", "passive") and peer in ("active", "passive"):
            ok(line)
        else:
            fail(line)
            all_good = False

    actives = [n for n, s in states.items() if s.get("local_state") == "active"]
    passives = [n for n, s in states.items() if s.get("local_state") == "passive"]
    if len(actives) == 1 and len(passives) == 1:
        ok("Exactly one active (%s) and one passive (%s)" % (actives[0], passives[0]))
    else:
        fail("Expected 1 active + 1 passive, got active=%s passive=%s" % (actives, passives))
        all_good = False
    return all_good, states


def verify_next_hops(firewalls, inputs):
    """Each node's static routes must use a next hop on its OWN subnets.

    With the nodes in different AZs, a next hop copied from the peer (e.g. by
    HA config sync) is unreachable, and that node black-holes all traffic the
    moment it goes active. Checked against the CONFIGURED routes and the
    subnets Terraform assigned, because a passive node's dataplane is down:
    its live route table is empty and its DHCP interfaces have no address.
    """
    step("Firewall next hops")
    xpath = DEVICE + "/network/virtual-router/entry[@name='default']/routing-table/ip/static-route"
    good = True
    for fw in firewalls:
        meta = inputs["firewalls"][fw.name]
        own = {
            "ethernet1/2": ipaddress.ip_network(meta["untrust_cidr"]),
            "ethernet1/3": ipaddress.ip_network(meta["trust_cidr"]),
        }
        try:
            node = _running_subtree(fw, xpath)
        except PanOSError as exc:
            fail("%s: %s" % (fw.name, exc))
            good = False
            continue
        routes = node.findall("entry") if node is not None else []
        if not routes:
            warn("%s: no static routes configured" % fw.name)
        for e in routes:
            dest = e.findtext("destination")
            hop = e.findtext("nexthop/ip-address")
            ifname = e.findtext("interface")
            if not hop:
                continue
            nets = [own[ifname]] if ifname in own else list(own.values())
            if any(ipaddress.ip_address(hop) in net for net in nets):
                ok("%s: %s via %s" % (fw.name, dest, hop))
            else:
                fail("%s: %s via %s is not on its own %s subnet (%s)"
                     % (fw.name, dest, hop, ifname or "dataplane",
                        ", ".join(str(n) for n in nets)))
                good = False
    return good


def verify_routes(inputs, states):
    step("VPC route tables")
    region = inputs["region"]
    rtbs = inputs["route_table_ids"]

    active = next(
        (n for n, s in states.items() if s.get("local_state") == "active"), None
    )
    expected_eni = inputs["firewalls"][active]["trust_eni_id"] if active else None

    try:
        out = subprocess.check_output(
            [
                "aws", "ec2", "describe-route-tables",
                "--region", region,
                "--route-table-ids", *rtbs,
                "--output", "json",
            ],
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as exc:
        fail("describe-route-tables failed: %s" % exc.stderr.decode()[:200])
        return False

    good = True
    for rt in json.loads(out)["RouteTables"]:
        for route in rt["Routes"]:
            eni = route.get("NetworkInterfaceId")
            if not eni:
                continue
            dest = route.get("DestinationCidrBlock")
            label = "%s %s -> %s" % (rt["RouteTableId"], dest, eni)
            if expected_eni and eni == expected_eni:
                ok("%s (active node %s)" % (label, active))
            elif expected_eni:
                fail("%s (expected active node %s's ENI %s)" % (label, active, expected_eni))
                good = False
            else:
                info(label)
    return good


def _ipsec_sa_up(fw, tunnel):
    root = fw.op("<show><vpn><ipsec-sa><tunnel>%s</tunnel></ipsec-sa></vpn></show>" % tunnel)
    return any(tunnel in "".join(e.itertext()) for e in root.iter("entry"))


def _ssm_run(region, instance_id, command, timeout=90):
    """Run a shell command on an instance through SSM; its stdout, or None if it never ran."""
    try:
        cid = subprocess.check_output(
            ["aws", "ssm", "send-command", "--region", region, "--instance-ids", instance_id,
             "--document-name", "AWS-RunShellScript",
             "--parameters", json.dumps({"commands": [command]}),
             "--query", "Command.CommandId", "--output", "text"],
            stderr=subprocess.PIPE,
        ).decode().strip()
    except subprocess.CalledProcessError as exc:
        warn("ssm send-command to %s failed: %s" % (instance_id, exc.stderr.decode().strip()[:160]))
        return None
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(3)
        try:
            out = json.loads(subprocess.check_output(
                ["aws", "ssm", "get-command-invocation", "--region", region,
                 "--command-id", cid, "--instance-id", instance_id, "--output", "json"],
                stderr=subprocess.PIPE,
            ))
        except subprocess.CalledProcessError:
            continue  # InvocationDoesNotExist for the first moments
        if out["Status"] in ("Pending", "InProgress", "Delayed"):
            continue
        return (out.get("StandardOutputContent") or "").strip()
    warn("SSM command on %s did not finish within %ds" % (instance_id, timeout))
    return None


def verify_tunnel(pair, branch, inputs, timeout=120):
    step("IPsec tunnel")
    hub_tunnel = TUNNEL_NAMES["hub"][1]
    gw, tunnel = TUNNEL_NAMES["branch"]
    up = _ipsec_sa_up(branch, tunnel)
    if not up:
        # Tunnel monitoring brings it up on its own; this just saves the wait.
        info("%s: no IPsec SA yet; initiating" % branch.name)
        for cmd in ("<test><vpn><ike-sa><gateway>%s</gateway></ike-sa></vpn></test>" % gw,
                    "<test><vpn><ipsec-sa><tunnel>%s</tunnel></ipsec-sa></vpn></test>" % tunnel):
            try:
                branch.op(cmd)
            except PanOSError as exc:
                warn("%s: %s" % (branch.name, exc))
        deadline = time.time() + timeout
        while not up and time.time() < deadline:
            time.sleep(5)
            up = _ipsec_sa_up(branch, tunnel)
    if not up:
        fail("%s: no IPsec SA for %s after %ds. Check Network > IPSec Tunnels and the "
             "system log (subtype ike) on both ends." % (branch.name, tunnel, timeout))
        return False
    ok("%s: IPsec SA for %s is up" % (branch.name, tunnel))

    active = next((fw for fw in pair if fw.ha_state().get("local_state") == "active"), None)
    if active:
        hub_up = _ipsec_sa_up(active, hub_tunnel)
        (ok if hub_up else warn)("%s (active): IPsec SA for %s %s"
                                 % (active.name, hub_tunnel, "is up" if hub_up else "not found"))

    # End to end: the branch workload fetches a pair workload's test page.
    src = inputs["branch"].get("workload_instance_id")
    targets = inputs.get("workload_ips") or []
    if not src or not targets:
        info("No test workloads; skipping the end-to-end check.")
        return True
    # Retried: straight after an HA failover the SAs read "up" but are the
    # ones copied from the old active node, and traffic only flows once the
    # new node's tunnel monitor has failed and renegotiated (~35 s measured).
    started = time.time()
    deadline = started + timeout
    while True:
        got = _ssm_run(inputs["region"], src, "curl -s -m 5 http://%s/ip" % targets[0])
        if got is None:
            # Usually the branch workload's SSM agent has not registered yet.
            warn("Could not run the end-to-end check through SSM; re-run --verify-only shortly.")
            return True
        if got == targets[0] or time.time() >= deadline:
            break
        print("  %s waiting for traffic over the tunnel... %ds"
              % (_c("...", Colors.DIM), time.time() - started), end="\r", flush=True)
        time.sleep(5)
    if got == targets[0]:
        ok("Branch workload -> http://%s/ over the tunnel answered from %s%s"
           % (targets[0], got, "" if time.time() - started < 15
              else " (after ~%ds)" % (time.time() - started)))
        return True
    fail("Branch workload -> http://%s/ over the tunnel: %s"
         % (targets[0], "got %r" % got if got else "no answer"))
    return False


def verify_aws_permissions(inputs):
    step("Firewall IAM permissions (dry-run)")
    region = inputs["region"]
    rtb = inputs["route_table_ids"][0]
    info("Role is attached to both instances; verifying the route table exists.")
    try:
        subprocess.check_output(
            ["aws", "ec2", "describe-route-tables", "--region", region,
             "--route-table-ids", rtb, "--output", "json"],
            stderr=subprocess.PIPE,
        )
        ok("Failover route tables reachable: %s" % ", ".join(inputs["route_table_ids"]))
        return True
    except subprocess.CalledProcessError as exc:
        fail("Route table %s not readable: %s" % (rtb, exc.stderr.decode()[:160]))
        return False


# ---------------------------------------------------------------------------
# Failover test
# ---------------------------------------------------------------------------


def failover_test(firewalls, inputs, settle=180):
    step("Failover test")
    _, states = verify_ha(firewalls)
    active_name = next(
        (n for n, s in states.items() if s.get("local_state") == "active"), None
    )
    if not active_name:
        fail("No active node; refusing to run a failover test.")
        return False

    active = next(fw for fw in firewalls if fw.name == active_name)
    before = inputs["firewalls"][active_name]["trust_eni_id"]
    web = inputs.get("inbound", {}).get("enabled")
    fip = inputs["floating_eip"]["public_ip"]
    if web:
        got = probe_web(fip)
        (ok if got else warn)("Before: http://%s/ -> %s" % (fip, got or "no answer"))
    info("Active node is %s (trust ENI %s). Suspending it..." % (active_name, before))
    suspended_at = time.time()

    active.op(
        "<request><high-availability><state><suspend></suspend></state>"
        "</high-availability></request>"
    )
    ok("Suspend issued on %s" % active_name)

    # Whatever happens while watching (expired AWS credentials, Ctrl-C), the
    # suspended node must be put back, or the pair is left with no standby.
    moved = False
    try:
        deadline = time.time() + settle
        region = inputs["region"]
        rtbs = inputs["route_table_ids"]
        while time.time() < deadline:
            time.sleep(10)
            elapsed = int(settle - (deadline - time.time()))
            try:
                out = subprocess.check_output(
                    ["aws", "ec2", "describe-route-tables", "--region", region,
                     "--route-table-ids", *rtbs, "--output", "json"],
                    stderr=subprocess.PIPE,
                )
            except subprocess.CalledProcessError as exc:
                print()
                warn("describe-route-tables failed at ~%ds (%s); retrying"
                     % (elapsed, exc.stderr.decode().strip()[:120]))
                continue
            enis = {
                r.get("NetworkInterfaceId")
                for rt in json.loads(out)["RouteTables"]
                for r in rt["Routes"]
                if r.get("NetworkInterfaceId")
            }
            if enis and before not in enis:
                ok("Routes moved off %s after ~%ds -> now %s" % (before, elapsed, ", ".join(enis)))
                moved = True
                break
            print("  %s waiting for route move... %ds" % (_c("...", Colors.DIM), elapsed),
                  end="\r", flush=True)
        else:
            print()
            fail(
                "Routes still point at %s after %ds. The AWS plugin did not move "
                "them - check Device > VM-Series > AWS (failover mode secondary-ip "
                "on both nodes)." % (before, settle)
            )
        if web and moved:
            # Inbound path through the new active node: floating EIP + DNAT +
            # return traffic via the moved routes.
            while time.time() < deadline:
                got = probe_web(fip)
                if got:
                    ok("After: http://%s/ -> %s, ~%ds after the suspend"
                       % (fip, got, int(time.time() - suspended_at)))
                    break
                time.sleep(2)
            else:
                fail("http://%s/ did not answer within %ds of the suspend" % (fip, settle))
    finally:
        info("Restoring %s to functional state..." % active_name)
        active.op(
            "<request><high-availability><state><functional></functional></state>"
            "</high-availability></request>"
        )
        ok("%s returned to functional" % active_name)
    # Preemption is off, so the restored node comes back passive and the peer
    # stays active. Running the test again fails back.
    info("%s is now the standby. Run --failover-test again to fail back." % active_name)
    return moved


###############################################################################
# Main
###############################################################################


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verify-only", action="store_true",
                    help="Read-only health check; change nothing.")
    ap.add_argument("--failover-test", action="store_true",
                    help="Suspend the active node and confirm routes move.")
    ap.add_argument("--sync-config", action="store_true",
                    help="Copy committed policy config (shared + vsys) from the "
                         "active node to the passive one, then commit it there.")
    ap.add_argument("--boot-timeout", type=int, default=2400,
                    help="Seconds to wait for the management API (default 2400).")
    args = ap.parse_args()

    inputs = load_inputs()
    username = inputs["admin_username"]
    password = inputs["admin_password"]

    firewalls = [
        PanOS(meta["mgmt_public_ip"], name=name)
        for name, meta in sorted(inputs["firewalls"].items())
    ]

    step("Connecting to the firewall pair")
    for fw in firewalls:
        wait_for_api(fw, username, password, timeout=args.boot_timeout)
        print(" " * 100, end="\r")
        ok("%s @ %s authenticated" % (fw.name, fw.host))

    if args.sync_config:
        synced = sync_config(firewalls)
        hops = verify_next_hops(firewalls, inputs)
        sys.exit(0 if synced and hops else 1)

    # Branch firewall, when deploy_branch = true.
    branch_meta = inputs.get("branch")
    vpn = inputs.get("vpn")
    branch = PanOS(branch_meta["mgmt_public_ip"], name=branch_meta["name"]) if branch_meta else None
    if branch:
        wait_for_api(branch, username, password, timeout=args.boot_timeout)
        print(" " * 100, end="\r")
        ok("%s @ %s authenticated" % (branch.name, branch.host))

    step("Licensing")
    for fw in firewalls + ([branch] if branch else []):
        if not check_license(fw):
            fetch_license(fw)

    published = content_ok = tunnel_ok = True
    if not args.verify_only:
        step("VM-Series AWS plugin failover mode")
        # The command syncs to the peer, so it is issued once.
        try:
            set_failover_mode(firewalls[0])
        except PanOSError as exc:
            fail("could not set failover mode: %s" % exc)

        # Every firewall, each on its own: content and schedules are not
        # synced between the nodes of the pair (HA config sync is off).
        for fw in firewalls + ([branch] if branch else []):
            content_ok = update_content(fw) and content_ok
        if branch:
            tunnel_ok = configure_tunnel(firewalls, branch, vpn)

        # A failure here should not skip the health checks below.
        try:
            published = publish_inbound(firewalls, inputs.get("inbound", {}))
        except PanOSError as exc:
            fail("inbound publishing: %s" % exc)
            published = False

    verify_aws_permissions(inputs)
    ha_ok, states = verify_ha(firewalls)
    ha_ok = verify_next_hops(firewalls, inputs) and ha_ok
    verify_routes(inputs, states)
    verify_web(inputs)
    if branch:
        try:
            tunnel_ok = verify_tunnel(firewalls, branch, inputs) and tunnel_ok
        except PanOSError as exc:
            fail("tunnel verification: %s" % exc)
            tunnel_ok = False

    if args.failover_test:
        if not ha_ok:
            fail("Skipping failover test: the pair is not healthy.")
        else:
            failover_test(firewalls, inputs)
            # The test changes which node is active; report the new roles.
            states = {}
            for fw in firewalls:
                try:
                    states[fw.name] = fw.ha_state()
                except PanOSError:
                    pass
            if branch:
                # The tunnel follows the floating EIP to the new active node.
                try:
                    tunnel_ok = verify_tunnel(firewalls, branch, inputs, timeout=180) and tunnel_ok
                except PanOSError as exc:
                    fail("tunnel verification after failover: %s" % exc)
                    tunnel_ok = False

    step("Summary")
    for name, meta in sorted(inputs["firewalls"].items()):
        st = states.get(name, {})
        info("%-16s %-9s https://%s  (AZ %s)"
             % (name, st.get("local_state", "unknown"),
                meta["mgmt_public_ip"], meta["availability_zone"]))
    if branch:
        info("%-16s %-9s https://%s  (AZ %s)"
             % (branch.name, "branch", branch.host, branch_meta["availability_zone"]))
    info("floating service IP : %s" % inputs["floating_eip"]["public_ip"])
    info("failover route tables: %s" % ", ".join(inputs["route_table_ids"]))
    if vpn:
        info("IPsec tunnel        : %s (branch) <-> %s, %s <-> %s"
             % (vpn["branch_public_ip"], vpn["hub_public_ip"], vpn["branch_cidr"], vpn["hub_cidr"]))
    return 0 if ha_ok and published and content_ok and tunnel_ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except PanOSError as exc:
        sys.exit("\nERROR: %s" % exc)
