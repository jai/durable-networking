"""The relay's cloud-init rendered from its deployment templates."""

import unittest
from pathlib import Path
from typing import Any

import relay

HOST = Path(__file__).parents[2] / "host"


def cfg() -> dict[str, Any]:
    return {
        "satmux_commit": "2922ebb835d0eb939ddbdfa3b5e7e0f247a0dc0c",
        "satmux_sha256": "98f5e4f439883b806c211acacca63abf8eb1c1748f4179098ad087e8ff404d04",
        "egress_alarm_gb": 5,
        "files": {path.name: path.read_text() for path in HOST.iterdir()},
    }


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
