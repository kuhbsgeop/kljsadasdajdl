import base64
import importlib.util
import json
import socket
import tempfile
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


class ShortLinkTests(unittest.TestCase):
    def test_short_link_persists_direct_nodes(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(api, "SHORT_LINK_DIR", Path(tmp)):
                short_id, count = api.save_short_link(VLESS + "\n" + TROJAN)
                source, config = api.load_short_link(short_id)
                self.assertEqual(count, 2)
                self.assertEqual(source, VLESS + "\n" + TROJAN)
                self.assertEqual(config, "")
                self.assertLessEqual(len(short_id), 32)

    def test_short_link_rejects_path_traversal(self):
        with self.assertRaisesRegex(ValueError, "Invalid short link id"):
            api.short_link_path("../../secret")


class DomainNodeTests(unittest.TestCase):
    def test_domain_node_groups_align_without_cartesian_expansion(self):
        links = [
            VLESS.replace("example.com", "source.example", 1) + str(index)
            for index in range(4)
        ]
        aliases = "a.example,b.example"
        with mock.patch.object(api, "DOMAIN_NODE_MODE", True), mock.patch.object(
            api, "SERVER_ALIASES", aliases
        ):
            aligned = api.align_links_to_aliases(links)
        self.assertEqual(len(aligned), 4)
        self.assertEqual([api.urlparse(link).hostname for link in aligned], [
            "a.example", "b.example", "a.example", "b.example"
        ])

    def test_single_link_still_expands_to_each_domain(self):
        with mock.patch.object(api, "DOMAIN_NODE_MODE", True), mock.patch.object(
            api, "SERVER_ALIASES", "a.example,b.example"
        ):
            self.assertIsNone(api.align_links_to_aliases([VLESS]))
            expanded = api.expand_links_for_aliases([VLESS])
        self.assertEqual(len(expanded), 2)


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

    def test_node_count_and_groups_match_input(self):
        proxies = "\n".join(
            f"  - {{name: {index}, server: old.example, port: 443, type: vmess}}"
            for index in range(1, 21)
        )
        group_nodes = "\n".join(f"      - {index}" for index in range(1, 21))
        config = (
            "port: 7890\nproxies:\n" + proxies + "\nproxy-groups:\n"
            "  - name: manual\n    type: select\n    proxies:\n" + group_nodes +
            "\nrules:\n  - MATCH,manual\n"
        )
        link_base = VLESS.rsplit("#", 1)[0]
        for count in (1, 5, 20, 21):
            with self.subTest(count=count):
                rendered = api.render_clash_config(
                    config,
                    [f"{link_base}#node-{index}" for index in range(1, count + 1)],
                )
                parsed = api.yaml.safe_load(rendered)
                expected = [str(i) for i in range(1, count + 1)]
                self.assertEqual([proxy["name"] for proxy in parsed["proxies"]], expected)
                self.assertEqual(parsed["proxy-groups"][0]["proxies"], expected)

    def test_config_requires_expected_sections(self):
        with self.assertRaisesRegex(ValueError, "proxy-groups"):
            api.validate_config_text("proxies:\n  []\nrules:\n  []\n")

    def test_config_reports_yaml_error_location(self):
        broken = "proxies:\n  - {name: broken server: x}\nproxy-groups:\nrules:\n"
        with self.assertRaisesRegex(ValueError, r"line 2, column 25"):
            api.validate_config_text(broken)


if __name__ == "__main__":
    unittest.main()
