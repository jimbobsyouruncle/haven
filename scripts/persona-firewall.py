#!/usr/bin/env python3
"""Apply Haven's existing bridge-firewall model to a persona network."""
from hashlib import sha256
import importlib.util
from ipaddress import IPv4Network
import re
import json
from pathlib import Path
import sys
import subprocess

# Share the rule reader, atomic installer primitives and uplink selection with
# the existing Canvas firewall, which is also an executable entry point.
spec = importlib.util.spec_from_file_location(
    "canvas_firewall", Path(__file__).with_name("canvas-firewall.py")
)
firewall = importlib.util.module_from_spec(spec)
spec.loader.exec_module(firewall)
command = firewall.command
DOCKER = ("docker", "--host", "unix:///var/run/docker.sock")
TAG = ("-m", "comment", "--comment", "haven-persona")
PROXY_BRIDGE = "haven-files-in"
PROXY_IP = "10.231.32.2"
FILES_PORT = "8080"


def network(name, bridge):
    names = command(*DOCKER, "network", "ls", "--filter", f"name=^{name}$",
                    "--format", "{{.Name}}").splitlines()
    if not names:
        return None
    if names != [name]:
        raise ValueError("ambiguous persona network")
    current, = json.loads(command(*DOCKER, "network", "inspect", name))
    options = current["Options"]
    expected_mode = "isolated" if current["Internal"] else "nat"
    if (current["Driver"] != "bridge" or current["Scope"] != "local"
            or (current.get("Labels") or {}).get("dev.haven.persona") != name
            or current["EnableIPv6"] or not current.get("EnableIPv4", True)
            or options.get("com.docker.network.bridge.name") != bridge
            or options.get("com.docker.network.bridge.enable_icc") != "true"
            or options.get("com.docker.network.bridge.gateway_mode_ipv4") != expected_mode
            or options.get("com.docker.network.bridge.trusted_host_interfaces")
            or not Path(f"/sys/class/net/{bridge}/bridge").is_dir()):
        raise ValueError("unexpected persona network configuration")
    return current


def policy(bridge, uplink, blocked, backend=None):
    outgoing, incoming = f"{bridge}-out", f"{bridge}-in"
    hooks = {
        "INPUT": [("-i", bridge, *TAG, "-j", "DROP")],
        "OUTPUT": [("-o", bridge, *TAG, "-j", "DROP")],
        "FORWARD": [
            ("-i", bridge, "!", "-o", bridge, *TAG, "-j", outgoing),
            ("!", "-i", bridge, "-o", bridge, *TAG, "-j", incoming),
        ],
    }
    outbound = []
    inbound = []
    if backend:
        # ACCEPT in the filter table lets this specific flow through Docker's
        # unpublished-port drop. Interface matches exclude other bridges.
        # Keep addresses ahead of interfaces, as emitted by iptables -S.
        inbound.append(("-s", PROXY_IP + "/32", "-d", backend + "/32",
                        "-i", PROXY_BRIDGE, "-p", "tcp", "-m", "tcp", "--dport", FILES_PORT,
                        "-m", "conntrack",
                        "--ctstate", "NEW,ESTABLISHED", "--ctdir", "ORIGINAL",
                        "-j", "ACCEPT"))
        outbound.append(("-s", backend + "/32", "-d", PROXY_IP + "/32",
                         "-o", PROXY_BRIDGE, "-p", "tcp", "-m", "tcp", "--sport", FILES_PORT,
                         "-m", "conntrack",
                         "--ctstate", "ESTABLISHED", "--ctdir", "REPLY",
                         "-j", "ACCEPT"))
    if uplink:
        outbound.extend([
            ("-m", "conntrack", "--ctstate", "INVALID,DNAT", "-j", "DROP"),
            *(("-d", dest, "-j", "DROP") for dest in blocked),
            ("-o", uplink, "-j", "RETURN"),
        ])
        inbound.append(("-i", uplink, "-m", "conntrack", "--ctstate", "ESTABLISHED",
                        "-j", "RETURN"))
    chains = {
        outgoing: [(*rule[:-2], *TAG, *rule[-2:]) for rule in outbound],
        incoming: [(*rule[:-2], *TAG, *rule[-2:]) for rule in inbound],
    }
    for entries in chains.values():
        entries.append((*TAG, "-j", "DROP"))
    return hooks, chains


def verify(listing, bridge, hooks, chains):
    for chain, expected in hooks.items():
        def is_ours(rule):
            return "haven-persona" in rule and bridge in rule

        # Managed Canvas and other persona hooks can precede ours. Require
        # ours ahead of every foreign hook without skipping mismatched rules.
        relevant = [
            rule for rule in listing[chain]
            if is_ours(rule) or not ({"haven-canvas", "haven-persona"} & set(rule))
        ]
        if relevant[:len(expected)] != expected or sum(map(is_ours, relevant)) != len(expected):
            return False
    return all(listing.get(chain) == entries for chain, entries in chains.items())


def apply(family, table, bridge, hooks, chains):
    listing = firewall.rules(family, table)
    if verify(listing, bridge, hooks, chains):
        return
    lines = [f"*{table}"]
    for chain, entries in chains.items():
        if chain in listing:
            if not listing[chain] or any("haven-persona" not in rule for rule in listing[chain]):
                raise ValueError("refusing to replace a foreign firewall chain")
            lines.append(f"-F {chain}")
        else:
            lines.append(f"-N {chain}")
        lines.extend(f"-A {chain} " + " ".join(entry) for entry in entries)
    for chain, entries in hooks.items():
        for rule in listing[chain]:
            if bridge in rule and "haven-persona" in rule:
                lines.append(f"-D {chain} " + " ".join(rule))
        for entry in reversed(entries):
            lines.append(f"-I {chain} 1 " + " ".join(entry))
    command(family + "-restore", "-w", "5", "--noflush",
            data="\n".join([*lines, "COMMIT", ""]))
    if not verify(firewall.rules(family, table), bridge, hooks, chains):
        raise ValueError("persona firewall policy failed verification")


def apply_proxy_prerouting(bridge, backend):
    # Docker can drop directly routed traffic to NAT bridge endpoints in raw
    # PREROUTING, before the verified mangle and filter policy sees it.
    # This early ACCEPT only ends processing in raw. Forwarding still requires
    # the narrow, stateful companion rules in both later tables.
    hooks = {"PREROUTING": []}
    chains = {}
    if backend:
        hooks["PREROUTING"].append(("-i", PROXY_BRIDGE, *TAG, "-j", bridge))
        chains[bridge] = [
            ("-s", PROXY_IP + "/32", "-d", backend + "/32", "-p", "tcp", "-m", "tcp",
             "--dport", FILES_PORT, *TAG, "-j", "ACCEPT"),
            (*TAG, "-j", "RETURN"),
        ]
    apply("iptables", "raw", bridge, hooks, chains)


def prepare(name, internet, files_uid=None):
    bridge = "hp" + sha256(name.encode()).hexdigest()[:12]
    # A reserved, non-reused UID identifies one /29. Keep Docker's dynamic
    # allocation in the upper half so it cannot reserve the FileBrowser IP.
    subnet = IPv4Network((int(IPv4Network("10.231.0.0/16").network_address)
                          + files_uid * 8, 29)) if files_uid is not None else None
    ip_range = list(subnet.subnets())[1] if subnet else None
    backend = str(subnet.network_address + 2) if subnet else None
    expected_ipam = {"Subnet": str(subnet), "IPRange": str(ip_range)}
    current = network(name, bridge)
    if current is not None and (
        current["Internal"] or (
            subnet and not any(
                all(entry.get(key) == value for key, value in expected_ipam.items())
                for entry in current["IPAM"]["Config"]
            )
        )
    ):
        # The launcher has already stopped the project. Docker refuses to
        # remove the network if another container is still attached.
        command(*DOCKER, "network", "rm", name)
        current = None
    if current is None:
        ipam = ("--subnet", str(subnet), "--ip-range", str(ip_range)) if subnet else ()
        command(*DOCKER, "network", "create", "--driver", "bridge", "--ipv6=false",
                "--label", f"dev.haven.persona={name}",
                "--opt", f"com.docker.network.bridge.name={bridge}",
                "--opt", "com.docker.network.bridge.enable_icc=true",
                "--opt", "com.docker.network.bridge.gateway_mode_ipv4=nat",
                *ipam, name)
        current = network(name, bridge)
    if current is None or current["Internal"]:
        raise ValueError("persona network mode failed verification")
    uplink, blocked = firewall.public_uplink() if internet else (None, ())
    for family in ("ip6tables", "iptables"):
        ipv4 = family == "iptables"
        hooks, chains = policy(bridge, uplink if ipv4 else None, blocked,
                               backend if ipv4 else None)
        for table in ("mangle", "filter"):
            apply(family, table, bridge, hooks, chains)
    apply_proxy_prerouting(bridge, backend)
    return backend


if __name__ == "__main__":
    if (len(sys.argv) not in (3, 4)
            or not re.fullmatch(r"haven-persona-[a-z][a-z0-9-]{0,25}", sys.argv[1])
            or sys.argv[2] not in ("true", "false")
            or (len(sys.argv) == 4 and not re.fullmatch(r"[1-9][0-9]{2}", sys.argv[3]))):
        sys.exit("usage: persona-firewall.py haven-persona-NAME {true|false} [FILES_UID]")
    try:
        backend = prepare(sys.argv[1], sys.argv[2] == "true",
                          int(sys.argv[3]) if len(sys.argv) == 4 else None)
        if backend:
            print(backend)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        reason = str(error) if type(error) is ValueError else type(error).__name__
        sys.exit(f"Persona firewall: network setup failed ({reason})")
