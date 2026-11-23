"""Run only in a disposable network namespace (sudo unshare --net)."""
import importlib.util
from pathlib import Path
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
        with patch.object(firewall, "topology", return_value=fixture):
            with self.assertRaises(ValueError):
                firewall.main("check")
            firewall.main("apply")
            firewall.main("check")
            before = {family: firewall.rules(family) for family in ("iptables", "ip6tables")}
            firewall.main("apply")
            self.assertEqual(before["iptables"], firewall.rules("iptables"))
            self.assertEqual(before["ip6tables"], firewall.rules("ip6tables"))

            # A foreign rule before our host boundary must prevent admission.
            subprocess.run(["iptables", "-t", "mangle", "-I", "INPUT", "1",
                            "-i", firewall.EGRESS, "-j", "ACCEPT"], check=True)
            with self.assertRaises(ValueError):
                firewall.main("check")
            with self.assertRaises(ValueError):
                firewall.main("apply")
            self.assertEqual(firewall.rules("iptables")["INPUT"][0],
                             ("-i", firewall.EGRESS, "-j", "ACCEPT"))

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
