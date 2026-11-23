"""Run only in a disposable network namespace (sudo unshare --net)."""
import importlib.util
from pathlib import Path
import socket
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "canvas_firewall", Path(__file__).with_name("canvas-firewall.py"))
firewall = importlib.util.module_from_spec(spec)
spec.loader.exec_module(firewall)


class CanvasFirewallTests(unittest.TestCase):
    def test_kernel_policy_and_drift(self):
        # The namespace starts with no physical interfaces and no host rules.
        fixture = ("public0", ("10.0.0.0/8", "172.16.0.0/12", "100.64.0.0/10"))
        with subprocess.Popen(["unshare", "--net", "sh", "-c", "echo ready; exec sleep 30"],
                              stdout=subprocess.PIPE, text=True) as peer:
            try:
                self.assertEqual(peer.stdout.readline().strip(), "ready")
                self.host_input_boundary(peer.pid, fixture)
            finally:
                peer.terminate()

    def host_input_boundary(self, peer, fixture):
        def ip(*args):
            subprocess.run(["ip", *args], check=True)

        def peer_run(*args):
            return subprocess.run(["nsenter", "--target", str(peer), "--net", *args],
                                  capture_output=True, check=False)

        ip("link", "add", firewall.EGRESS, "type", "veth", "peer", "name", "canvas-peer0")
        ip("link", "set", "canvas-peer0", "netns", str(peer))
        ip("addr", "add", "198.18.0.1/30", "dev", firewall.EGRESS)
        ip("link", "set", firewall.EGRESS, "up")
        self.assertEqual(peer_run("ip", "addr", "add", "198.18.0.2/30",
                                  "dev", "canvas-peer0").returncode, 0)
        self.assertEqual(peer_run("ip", "link", "set", "canvas-peer0", "up").returncode, 0)
        with socket.socket() as server, patch.object(firewall, "topology", return_value=fixture):
            server.bind(("198.18.0.1", 0))
            server.listen()
            port = server.getsockname()[1]
            connect = ("python3", "-c", f"import socket; socket.create_connection(('198.18.0.1', {port}), 1)")
            self.assertEqual(peer_run(*connect).returncode, 0)
            with self.assertRaises(ValueError):
                firewall.main("check")
            firewall.main("apply")
            firewall.main("check")
            self.assertEqual(peer_run(*connect).returncode, 1)
            tables = [(family, table) for family in ("iptables", "ip6tables")
                      for table in ("mangle", "filter")]
            before = {pair: firewall.rules(*pair) for pair in tables}
            firewall.main("apply")
            self.assertEqual(before, {pair: firewall.rules(*pair) for pair in tables})

            # A foreign rule before our host boundary must prevent admission.
            subprocess.run(["iptables", "-t", "mangle", "-I", "INPUT", "1",
                            "-i", firewall.EGRESS, "-j", "ACCEPT"], check=True)
            self.assertEqual(peer_run(*connect).returncode, 1)
            with self.assertRaises(ValueError):
                firewall.main("check")
            with self.assertRaises(ValueError):
                firewall.main("apply")
            self.assertEqual(firewall.rules("iptables", "mangle")["INPUT"][0],
                             ("-i", firewall.EGRESS, "-j", "ACCEPT"))
            self.assertEqual(before["iptables", "filter"], firewall.rules("iptables", "filter"))

    def test_missing_bridge_does_not_modify_rules(self):
        with patch.object(firewall, "topology", side_effect=ValueError("missing bridge")):
            with patch.object(firewall, "install") as install:
                with self.assertRaises(ValueError):
                    firewall.main("apply")
                install.assert_not_called()


if __name__ == "__main__":
    if Path("/proc/self/ns/net").readlink() == Path("/proc/1/ns/net").readlink():
        raise SystemExit("refusing to test in the initial network namespace")
    unittest.main()
