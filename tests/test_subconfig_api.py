import base64
import importlib.util
import json
import socket
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "subconfig-api.py"
SPEC = importlib.util.spec_from_file_location("subconfig_api", MODULE_PATH)
api = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(api)


VLESS = (
    "vless://11111111-1111-1111-1111-111111111111@example.com:8443"
    "?type=tcp&security=reality&sni=www.example.com&fp=chrome&pbk=public-key&sid=abcd#node-a"
)
TROJAN = "trojan://secret@example.net:443?type=ws&sni=example.net&path=%2Fws#node-b"


class SubscriptionSourceTests(unittest.TestCase):
    def test_extracts_plain_and_base64_links(self):
        plain = VLESS + "\n" + TROJAN + "\n"
        encoded = base64.b64encode(plain.encode()).decode()
        self.assertEqual(api.extract_subscription_links(plain), [VLESS, TROJAN])
        self.assertEqual(api.extract_subscription_links(encoded), [VLESS, TROJAN])

    def test_direct_source_does_not_require_network(self):
        self.assertEqual(api.load_source_links(VLESS), [VLESS])

    @mock.patch.object(
        api.socket,
        "getaddrinfo",
        return_value=[(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443))],
    )
    def test_private_remote_source_is_rejected(self, _getaddrinfo):
        with self.assertRaisesRegex(ValueError, "private or reserved"):
            api.validate_remote_url("https://internal.example/sub")


class NodeParserTests(unittest.TestCase):
    def test_vless_reality_is_rendered_for_clash(self):
        node = api.parse_node(VLESS)
        text = ", ".join(node)
        self.assertIn("type: vless", text)
        self.assertIn("reality-opts:", text)
        self.assertIn('servername: "www.example.com"', text)

    def test_vmess_and_hysteria2_are_supported(self):
        payload = {
            "v": "2",
            "ps": "vmess-node",
            "add": "vmess.example",
            "port": "443",
            "id": "22222222-2222-2222-2222-222222222222",
            "aid": "0",
            "scy": "auto",
            "net": "ws",
            "host": "cdn.example",
            "path": "/ws",
            "tls": "tls",
            "sni": "cdn.example",
        }
        vmess = "vmess://" + base64.b64encode(json.dumps(payload).encode()).decode()
        self.assertIn("type: vmess", api.parse_node(vmess))

        hysteria = "hysteria2://password@hy.example:8443?sni=hy.example&insecure=1#hy-node"
        self.assertIn("type: hysteria2", api.parse_node(hysteria))

    def test_legacy_base64_shadowsocks_is_supported(self):
        body = base64.urlsafe_b64encode(b"aes-256-gcm:secret@ss.example:8388").decode().rstrip("=")
        node = api.parse_node("ss://" + body + "#ss-node")
        text = ", ".join(node)
        self.assertIn('server: "ss.example"', text)
        self.assertIn('cipher: "aes-256-gcm"', text)


class ClashRenderTests(unittest.TestCase):
    def test_source_nodes_replace_placeholders_and_expand_groups(self):
        config = """port: 7890
proxies:
  - {name: placeholder-a, server: example.com, port: 443, type: vmess}
proxy-groups:
  - name: select
    type: select
    proxies:
      - placeholder-a
rules:
  - MATCH,select
"""
        rendered = api.render_clash_config(config, [VLESS, TROJAN])
        self.assertIn("type: vless", rendered)
        self.assertIn("type: trojan", rendered)
        self.assertIn("placeholder-a@example.net", rendered)
        self.assertNotIn("server: example.com", rendered)

    def test_config_requires_expected_sections(self):
        with self.assertRaisesRegex(ValueError, "proxy-groups"):
            api.validate_config_text("proxies:\n  []\nrules:\n  []\n")

    def test_config_reports_yaml_error_location(self):
        broken = "proxies:\n  - {name: broken server: x}\nproxy-groups:\nrules:\n"
        with self.assertRaisesRegex(ValueError, r"line 2, column 25"):
            api.validate_config_text(broken)


if __name__ == "__main__":
    unittest.main()
