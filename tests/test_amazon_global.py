import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "amazon-global.py"
LINK = (
    "vless://11111111-1111-4111-8111-111111111111@198.51.100.84:443"
    "?type=tcp&security=reality&pbk=publicKey&fp=chrome"
    "&sni=www.cloudflare.com&sid=0123456789abcdef"
    "&spx=%2F&flow=xtls-rprx-vision#test"
)


class AmazonGlobalConfigTests(unittest.TestCase):
    def render(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "amazon.yaml"
            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--link",
                    LINK,
                    "--output",
                    str(output),
                    "--node-name",
                    "Amazon住宅节点",
                    "--group-name",
                    "Amazon全局代理",
                ],
                check=True,
            )
            return yaml.safe_load(output.read_text(encoding="utf-8"))

    def test_forces_amazon_and_everything_else_through_node(self):
        config = self.render()
        self.assertEqual(config["mode"], "rule")
        self.assertFalse(config["ipv6"])
        self.assertEqual(config["tun"]["mtu"], 1400)
        self.assertEqual(config["tun"]["route-exclude-address"], ["198.51.100.84/32"])
        self.assertTrue(config["dns"]["respect-rules"])
        self.assertIn("DOMAIN-SUFFIX,amazon.com,Amazon全局代理", config["rules"])
        self.assertIn("DOMAIN-SUFFIX,sellercentral.amazon.com,Amazon全局代理", config["rules"])
        self.assertEqual(config["rules"][-1], "MATCH,Amazon全局代理")

    def test_renders_single_reality_proxy(self):
        config = self.render()
        self.assertEqual(len(config["proxies"]), 1)
        proxy = config["proxies"][0]
        self.assertEqual(proxy["server"], "198.51.100.84")
        self.assertEqual(proxy["port"], 443)
        self.assertEqual(proxy["type"], "vless")
        self.assertEqual(proxy["reality-opts"]["short-id"], "0123456789abcdef")
        self.assertEqual(config["proxy-groups"][0]["proxies"], ["Amazon住宅节点"])

    def test_rejects_non_reality_source(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--link",
                "vless://id@example.com:443?type=tcp&security=tls",
            ],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VLESS REALITY", result.stderr)


if __name__ == "__main__":
    unittest.main()
