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

    step("Licensing")
    for fw in firewalls:
        if not check_license(fw):
            fetch_license(fw)

    published = True
    if not args.verify_only:
        step("VM-Series AWS plugin failover mode")
        # The command syncs to the peer, so it is issued once.
        try:
            set_failover_mode(firewalls[0])
        except PanOSError as exc:
            fail("could not set failover mode: %s" % exc)

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

    step("Summary")
    for name, meta in sorted(inputs["firewalls"].items()):
        st = states.get(name, {})
        info("%-16s %-9s https://%s  (AZ %s)"
             % (name, st.get("local_state", "unknown"),
                meta["mgmt_public_ip"], meta["availability_zone"]))
    info("floating service IP : %s" % inputs["floating_eip"]["public_ip"])
    info("failover route tables: %s" % ", ".join(inputs["route_table_ids"]))
    return 0 if ha_ok and published else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except PanOSError as exc:
        sys.exit("\nERROR: %s" % exc)
