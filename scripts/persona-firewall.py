#!/usr/bin/env python3
"""Apply Haven's existing bridge-firewall model to a persona network."""
from hashlib import sha256
import importlib.util
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


def policy(bridge, uplink, blocked):
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
    if uplink:
        outbound = [
            ("-m", "conntrack", "--ctstate", "INVALID,DNAT", "-j", "DROP"),
            *(("-d", dest, "-j", "DROP") for dest in blocked),
            ("-o", uplink, "-j", "RETURN"),
        ]
        inbound = [("-i", uplink, "-m", "conntrack", "--ctstate", "ESTABLISHED",
                    "-j", "RETURN")]
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


def prepare(name, internet):
    bridge = "hp" + sha256(name.encode()).hexdigest()[:12]
    current = network(name, bridge)
    if current is not None and current["Internal"] == internet:
        # The launcher has already stopped the old project. Docker refuses
        # removal if any other service remains attached.
        command(*DOCKER, "network", "rm", name)
        current = None
    if current is None:
        mode = "nat" if internet else "isolated"
        command(*DOCKER, "network", "create", "--driver", "bridge", "--ipv6=false",
                "--label", f"dev.haven.persona={name}",
                "--opt", f"com.docker.network.bridge.name={bridge}",
                "--opt", "com.docker.network.bridge.enable_icc=true",
                "--opt", f"com.docker.network.bridge.gateway_mode_ipv4={mode}",
                *([] if internet else ["--internal"]), name)
        current = network(name, bridge)
    if current is None or current["Internal"] == internet:
        raise ValueError("persona network mode failed verification")
    uplink, blocked = firewall.public_uplink() if internet else (None, ())
    for family in ("ip6tables", "iptables"):
        hooks, chains = policy(bridge, uplink if family == "iptables" else None, blocked)
        for table in ("mangle", "filter"):
            apply(family, table, bridge, hooks, chains)


if __name__ == "__main__":
    import re

    if (len(sys.argv) != 3 or not re.fullmatch(r"haven-persona-[a-z][a-z0-9-]{0,25}", sys.argv[1])
            or sys.argv[2] not in ("true", "false")):
        sys.exit("usage: persona-firewall.py haven-persona-NAME {true|false}")
    try:
        prepare(sys.argv[1], sys.argv[2] == "true")
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        reason = str(error) if type(error) is ValueError else type(error).__name__
        sys.exit(f"Persona firewall: network setup failed ({reason})")
