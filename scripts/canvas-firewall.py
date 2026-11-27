#!/usr/bin/env python3
"""Install and verify Haven's Canvas-only rules without touching legacy rules."""
import ipaddress
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

INGRESS = "haven-canvas-in"
EGRESS = "haven-canvas-eg"
PROXY_IP = "172.31.253.2"
CANVAS_IP = "172.31.253.3"
RESOLVERS = ("1.1.1.1", "1.0.0.1")
TAG = ("-m", "comment", "--comment", "haven-canvas")
BLOCKED = (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16",
    "192.0.2.0/24", "192.88.99.0/24", "198.18.0.0/15", "198.51.100.0/24",
    "203.0.113.0/24", "224.0.0.0/3",
)


def command(*args, data=None):
    return subprocess.run(args, input=data, check=True, capture_output=True,
                          text=True, timeout=15).stdout


def network(name, bridge, *, internal, allowed):
    config, = json.loads(command("docker", "network", "inspect", name))
    options = config["Options"]
    if not internal and ((config.get("Labels") or {}).get("dev.haven.canvas") != "egress"
                         or options.get("com.docker.network.bridge.enable_icc") != "false"):
        raise ValueError("unowned or misconfigured Canvas egress bridge")
    members = {container["Name"]: container["IPv4Address"].split("/")[0]
               for container in (config["Containers"] or {}).values()}
    mode = options.get("com.docker.network.bridge.gateway_mode_ipv4", "nat")
    if (config["Driver"] != "bridge" or config["Internal"] != internal
            or config["EnableIPv6"] or not config.get("EnableIPv4", True)
            or options.get("com.docker.network.bridge.name") != bridge
            or mode != ("isolated" if internal else "nat")
            or options.get("com.docker.network.bridge.trusted_host_interfaces")
            or not Path(f"/sys/class/net/{bridge}/bridge").is_dir()
            or members.keys() - allowed.keys()
            or any(address and members.get(service, address) != address
                   for service, address in allowed.items())):
        raise ValueError("unexpected Canvas bridge configuration or membership")
    return members


def topology():
    ingress = network("haven-canvas-ingress", INGRESS, internal=True,
                      allowed={"haven-proxy": PROXY_IP, "haven-canvas": CANVAS_IP})
    egress = network("haven-canvas-egress", EGRESS, internal=False,
                     allowed={"haven-canvas": None})
    if ("haven-proxy" not in ingress
            or ("haven-canvas" in ingress) != ("haven-canvas" in egress)):
        raise ValueError("Canvas ingress and egress attachments are incomplete")
    for family in ("iptables", "ip6tables"):
        if Path(f"/proc/sys/net/bridge/bridge-nf-call-{family}").read_text().strip() != "1":
            raise ValueError("bridge filtering is disabled")
    return public_uplink()


def public_uplink():
    route, = json.loads(command("ip", "-j", "-4", "route", "get", RESOLVERS[0]))
    uplink = route["dev"]
    if (not route.get("gateway") or not re.fullmatch(r"[A-Za-z0-9_.-]+", uplink)
            or uplink in (INGRESS, EGRESS, "lo", "docker0")
            or Path(f"/sys/class/net/{uplink}/bridge").exists()):
        raise ValueError("no eligible public IPv4 uplink")
    on_link = json.loads(command("ip", "-j", "-4", "route", "show",
                                 "table", "all", "scope", "link", "dev", uplink))
    destinations = {ipaddress.IPv4Network(prefix, strict=False)
                    for prefix in (*BLOCKED, *(route["dst"] for route in on_link))}
    return uplink, tuple(map(str, ipaddress.collapse_addresses(sorted(destinations))))


def policy(uplink, blocked, *, ipv6):
    hooks = {"INPUT": [], "OUTPUT": [], "FORWARD": []}
    chains = {}

    def hook(table_chain, *match, target="DROP"):
        hooks[table_chain].append((*match, *TAG, "-j", target))

    for bridge in (INGRESS, EGRESS):
        hook("INPUT", "-i", bridge)
        hook("OUTPUT", "-o", bridge)
        if ipv6:
            hook("FORWARD", "-i", bridge)
            hook("FORWARD", "-o", bridge)

    if not ipv6:
        for bridge, direction, name in (
            (INGRESS, "-i", "HAVEN-CANVAS-LAN"), (INGRESS, "-o", "HAVEN-CANVAS-LAN"),
            (EGRESS, "-i", "HAVEN-CANVAS-OUT"), (EGRESS, "-o", "HAVEN-CANVAS-IN"),
        ):
            hook("FORWARD", direction, bridge, target=name)
        established = ("-m", "conntrack", "--ctstate", "ESTABLISHED")
        tcp = ("-p", "tcp", "-m", "tcp")
        chains["HAVEN-CANVAS-LAN"] = [
            ("-s", PROXY_IP + "/32", "-d", CANVAS_IP + "/32", "-i", INGRESS, "-o", INGRESS,
             *tcp, "--dport", "8000", "-j", "RETURN"),
            ("-s", CANVAS_IP + "/32", "-d", PROXY_IP + "/32", "-i", INGRESS, "-o", INGRESS,
             *established, "-j", "RETURN"),
        ]
        chains["HAVEN-CANVAS-OUT"] = [
            ("-m", "conntrack", "--ctstate", "INVALID,DNAT", "-j", "DROP"),
            *(("-d", dest, "-j", "DROP") for dest in blocked),
            ("-o", uplink, *tcp, "--dport", "443", "-j", "RETURN"),
            *(("-d", resolver + "/32", "-o", uplink, "-p", proto, "-m", proto,
               "--dport", "53", "-j", "RETURN")
              for resolver in RESOLVERS for proto in ("udp", "tcp")),
        ]
        chains["HAVEN-CANVAS-IN"] = [("-i", uplink, *established, "-j", "RETURN")]
        for rules in chains.values():
            rules.append(("-j", "DROP"))
    return hooks, chains


def rules(family, table):
    listing = {}
    for line in command(family, "-w", "5", "-t", table, "-S").splitlines():
        action, chain, *arguments = shlex.split(line)
        if action in ("-N", "-P"):
            listing[chain] = []
        elif action == "-A":
            listing[chain].append(tuple(arguments))
    return listing


def verify(listing, hooks, chains):
    return (all(listing.get(chain) == expected for chain, expected in chains.items())
            and all([rule for rule in listing.get(chain, [])
                     if "haven-persona" not in rule][:len(expected)] == expected
                    and sum("haven-canvas" in rule for rule in listing[chain]) == len(expected)
                    for chain, expected in hooks.items()))


def install(family, table, listing, hooks, chains):
    # Refuse to overwrite a foreign or partially modified policy. The
    # supervisor keeps Canvas stopped until an administrator resolves drift.
    if (chains.keys() & listing.keys()
            or any("haven-canvas" in rule for entries in listing.values() for rule in entries)):
        raise ValueError("existing Canvas firewall policy drift")
    lines = [f"*{table}", *(f"-N {chain}" for chain in chains)]
    for chain, entries in chains.items():
        lines.extend(f"-A {chain} " + " ".join(entry) for entry in entries)
    for chain, entries in hooks.items():
        lines.extend(f"-I {chain} 1 " + " ".join(entry) for entry in reversed(entries))
    command(family + "-restore", "-w", "5", "--noflush", data="\n".join([*lines, "COMMIT", ""]))


def main(mode):
    uplink, blocked = topology()
    # Both tables enforce the same allowlist. A flush or reordering in one
    # table leaves the other boundary in force until the supervisor stops
    # Canvas. Docker manages its own filter chains below these early hooks.
    for family in ("ip6tables", "iptables"):
        hooks, chains = policy(uplink, blocked, ipv6=family == "ip6tables")
        for table in ("mangle", "filter"):
            listing = rules(family, table)
            if mode == "apply" and not verify(listing, hooks, chains):
                install(family, table, listing, hooks, chains)
                listing = rules(family, table)
            if not verify(listing, hooks, chains):
                raise ValueError("Canvas firewall rules are absent or out of policy")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("apply", "check"):
        sys.exit("usage: canvas-firewall.py {apply|check}")
    try:
        main(sys.argv[1])
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        # Command and config exceptions can contain private network details.
        reason = str(error) if type(error) is ValueError else type(error).__name__
        sys.exit(f"Canvas firewall: verification failed ({reason})")
