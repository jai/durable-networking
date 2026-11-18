"""relay.py's pure parts: the VPC resolver address and the cloud-init it renders from host/."""

import unittest
from pathlib import Path
from typing import Any

import relay

HOST = Path(__file__).parent / "host"
FILES = [p.name for p in HOST.iterdir()]


def cfg() -> dict[str, Any]:
    return {
        "satmux_commit": "2922ebb835d0eb939ddbdfa3b5e7e0f247a0dc0c",
        "satmux_sha256": "98f5e4f439883b806c211acacca63abf8eb1c1748f4179098ad087e8ff404d04",
        "egress_alarm_gb": 5,
        "files": {name: (HOST / name).read_text() for name in FILES},
    }


class VpcResolverTest(unittest.TestCase):
    def test_network_plus_two(self) -> None:
        self.assertEqual(relay.vpc_resolver("172.31.0.0/16"), "172.31.0.2")
        self.assertEqual(relay.vpc_resolver("10.20.48.0/20"), "10.20.48.2")

    def test_host_bits_are_masked(self) -> None:
        self.assertEqual(relay.vpc_resolver("10.0.0.7/24"), "10.0.0.2")


class RenderUserDataTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = relay.render_user_data(cfg(), "172.31.0.2")

    def test_fills_every_placeholder(self) -> None:
        self.assertEqual(relay.placeholders(self.text), [])
        self.assertIn("SATMUX_PORT=8444", self.text)
        self.assertIn("tcp dport 443 redirect to :8444", self.text)
        self.assertIn("Th0rgal/satmux/2922ebb835d0eb939ddbdfa3b5e7e0f247a0dc0c/satmux.py", self.text)

    def test_checks_in_with_the_monitor_worker(self) -> None:
        self.assertIn("SATMUX_MONITOR_TOKEN_PARAMETER=/agent-pager/monitor-tokens/satmux-relay", self.text)
        self.assertIn("SATMUX_EGRESS_ALARM_GB=5", self.text)
        self.assertIn("systemctl enable --now satmux-monitor.timer", self.text)

    def test_allows_only_the_dns_stub_and_the_vpc_resolver(self) -> None:
        self.assertIn("IPAddressAllow=127.0.0.53/32 169.254.169.253/32 172.31.0.2/32", self.text)

    def test_embeds_each_file_inside_its_yaml_block(self) -> None:
        lines = self.text.splitlines()
        start = lines.index("  - path: /etc/systemd/system/satmux.service")
        block = []
        for line in lines[start + 2 :]:
            if line.strip() and not line.startswith("      "):
                break
            block.append(line)
        self.assertIn("      ExecStart=/opt/satmux/run.sh", block)
        self.assertIn("      WantedBy=multi-user.target", block)

    def test_refuses_an_unknown_placeholder(self) -> None:
        broken = cfg()
        broken["files"]["cloud-init.yaml"] += "\n# @NEW_THING@\n"
        with self.assertRaises(ValueError):
            relay.render_user_data(broken, "172.31.0.2")


if __name__ == "__main__":
    unittest.main()
