import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "ibkr-vpn.py"
SPEC = importlib.util.spec_from_file_location("ibkr_vpn", SCRIPT)
ibkr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ibkr)


def fixture():
    return {
        "mode": "rule",
        "custom": {"keep": [1, 2]},
        "proxies": [{"name": "fixed-node", "type": "vless", "server": "vpn.example", "port": 443}],
        "proxy-groups": [{"name": "automatic", "type": "url-test", "proxies": ["fixed-node", "DIRECT"]}],
        "rules": ["DOMAIN-SUFFIX,ibllc.com,DIRECT", "GEOIP,CN,DIRECT", "MATCH,automatic"],
        "dns": {"enable": True, "proxy-server-nameserver": ["https://dns.alidns.com/dns-query"],
                "nameserver-policy": {"+.example.org": "system"}, "custom-dns": "keep"},
    }


class IbkrVpnTests(unittest.TestCase):
    def test_fixed_node_rules_precede_direct_and_original_is_preserved(self):
        original = fixture()
        before = copy.deepcopy(original)
        rendered = ibkr.apply_mihomo(original, "fixed-node")
        self.assertEqual(original, before)
        self.assertEqual(rendered["proxy-groups"][-1], {"name": "IBKR固定VPN", "type": "select", "proxies": ["fixed-node"]})
        self.assertEqual(rendered["rules"][len(ibkr.SUFFIXES):], before["rules"])
        self.assertEqual(rendered["custom"], before["custom"])
        self.assertEqual(rendered["proxies"], before["proxies"])
        self.assertEqual(rendered["proxy-groups"][:-1], before["proxy-groups"])
        self.assertEqual(ibkr.apply_mihomo(rendered, "fixed-node"), rendered)

    def test_scoped_encrypted_dns_uses_same_proxy_without_system_fallback(self):
        rendered = ibkr.apply_mihomo(fixture(), "fixed-node")
        for suffix in ibkr.SUFFIXES:
            resolvers = rendered["dns"]["nameserver-policy"]["+." + suffix]
            self.assertTrue(all(url.startswith("https://") and url.endswith("#IBKR固定VPN") for url in resolvers))
        self.assertEqual(rendered["dns"]["nameserver-policy"]["+.example.org"], "system")
        self.assertEqual(rendered["dns"]["custom-dns"], "keep")

    def test_rejects_groups_direct_nodes_and_chained_nodes(self):
        for name in ("DIRECT", "automatic", "missing"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                ibkr.apply_mihomo(fixture(), name)
        for change in ({"type": "direct"}, {"dialer-proxy": "automatic"}):
            config = fixture()
            config["proxies"][0].update(change)
            with self.assertRaises(ValueError):
                ibkr.apply_mihomo(config, "fixed-node")

    def test_rejects_group_collision_and_missing_dns_bootstrap(self):
        config = fixture()
        config["proxy-groups"].append({"name": "IBKR固定VPN", "type": "select", "proxies": ["DIRECT"]})
        with self.assertRaises(ValueError):
            ibkr.apply_mihomo(config, "fixed-node")
        for key in ("enable", "proxy-server-nameserver"):
            config = fixture()
            config["dns"].pop(key)
            with self.assertRaises(ValueError):
                ibkr.apply_mihomo(config, "fixed-node")

    def test_shadowrocket_unicode_node_and_dns_are_fixed_without_direct(self):
        module = ibkr.render_shadowrocket("我的VPN节点")
        rules = [line for line in module.splitlines() if line.startswith("DOMAIN-SUFFIX,")]
        self.assertEqual(len(rules), len(ibkr.SUFFIXES))
        self.assertTrue(all(line.endswith(",我的VPN节点") for line in rules))
        self.assertNotIn(",DIRECT", module)
        self.assertIn("#proxy=%E6%88%91", module)
        self.assertIn("ibllc.com = server:https://", module)
        for name in ("DIRECT", "node\n[Rule]", "node,other", " node "):
            with self.assertRaises(ValueError):
                ibkr.render_shadowrocket(name)

    def test_sensitive_config_output_is_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "client.yaml"
            ibkr.write_private(path, "example config")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.read_text(), "example config")


if __name__ == "__main__":
    unittest.main()
