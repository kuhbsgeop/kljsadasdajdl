import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "n6j0p" / "sync_rules_names.py"

MINIMAL_RULES = """port: 7890
proxies:
  - {name: 测试3ip, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
  - {name: 测试4域名, server: example.com, port: 443, type: vmess, uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, cipher: auto, tls: true}
proxy-groups:
  - name: 🚀 手动切换
    type: select
    proxies:
      - 测试3ip
      - 测试4域名
      - DIRECT
  - name: ♻️ 自动选择
    type: url-test
    proxies:
      - 测试3ip
      - 测试4域名
  - name: 🔯 故障转移
    type: fallback
    proxies:
      - 测试3ip
      - 测试4域名
  - name: 🔮 负载均衡
    type: load-balance
    proxies:
      - 测试3ip
      - 测试4域名
  - name: ⚖️ 负载均衡-轮询
    type: load-balance
    proxies:
      - 测试3ip
      - 测试4域名
  - name: 📲 电报消息
    type: select
    proxies:
      - 🚀 手动切换
      - DIRECT
rules:
  - MATCH,🚀 手动切换
"""


class SyncRulesNamesTests(unittest.TestCase):
    def run_sync(self, sub_links, rules_text=MINIMAL_RULES):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / ".env").write_text(
                "SUBSCRIPTION_TOKEN=testtoken123\n", encoding="utf-8")
            sub_dir = base / "site" / "subscriptions"
            sub_dir.mkdir(parents=True)
            (sub_dir / "testtoken123.txt").write_text(
                "\n".join(sub_links) + "\n", encoding="utf-8")
            cfg_dir = base / "site" / "sub" / "config"
            cfg_dir.mkdir(parents=True)
            rules_file = cfg_dir / "3.5.yaml"
            rules_file.write_text(rules_text, encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), str(base)],
                text=True, capture_output=True, check=False,
            )
            text = rules_file.read_text(encoding="utf-8")
            return result, text

    def test_syncs_placeholders_to_real_names(self):
        links = [
            "vless://uuid1@1.2.3.4:8443?x=y#node-one",
            "vless://uuid2@1.2.3.4:8444?x=y#node-two",
        ]
        result, text = self.run_sync(links)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("node-one", "node-two"):
            self.assertEqual(text.count(name), 6, name)
        for ph in ("测试3ip", "测试4域名"):
            self.assertNotIn(ph, text)
        # Non-node items (DIRECT) and non-node groups are preserved.
        self.assertIn("- DIRECT", text)
        self.assertIn("电报消息", text)
        self.assertIn("🚀 手动切换", text)

    def test_aborts_when_subscription_is_empty(self):
        result, _ = self.run_sync([])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no node names found", result.stderr)


if __name__ == "__main__":
    unittest.main()
