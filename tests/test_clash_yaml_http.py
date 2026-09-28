import http.client
import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from test_subconfig_api import api, VLESS, TROJAN


TEMPLATE = """port: 7890
proxies:
  - {name: template-node, server: old.example, port: 443, type: vmess}
proxy-groups:
  - name: fixed-choice
    type: select
    proxies:
      - template-node
rules:
  - MATCH,fixed-choice
"""


class ClashYamlHttpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        config = root / "config.yaml"
        config.write_text(TEMPLATE)
        self.links = root / "unit-test-subscription.txt"
        self.links.write_text(VLESS + "\n" + TROJAN + "\n")
        self.patchers = [
            mock.patch.object(api, "SUBSCRIPTION_TOKEN", "unit-test-subscription"),
            mock.patch.object(api, "SUBSCRIPTION_DIR", root),
            mock.patch.object(api, "SHORT_LINK_DIR", root / "short-links"),
            mock.patch.object(api, "CONFIG_PATH", config),
            mock.patch.object(api, "LOCAL_CONFIG_CACHE", {"mtime_ns": None, "size": None, "text": None}),
            mock.patch.object(api, "refresh_public_subscription_links", return_value=(2, False)),
            mock.patch("builtins.print"),
        ]
        self.mocks = [patcher.start() for patcher in self.patchers]
        self.server = api.ThreadingHTTPServer(("127.0.0.1", 0), api.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        for patcher in reversed(self.patchers):
            patcher.stop()
        self.temp.cleanup()

    def request(self, path, method="GET", payload=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        try:
            body = json.dumps(payload) if payload is not None else None
            connection.request(method, path, body, {"Content-Type": "application/json"})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read().decode()
        finally:
            connection.close()

    def assert_yaml(self, response, count=2):
        status, headers, body = response
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "application/yaml; charset=utf-8")
        self.assertEqual(headers["Content-Disposition"], 'attachment; filename="clash.yaml"')
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(int(headers["Content-Length"]), len(body.encode()))
        config = api.yaml.safe_load(body)
        self.assertEqual(len(config["proxies"]), count)
        self.assertEqual(config["rules"], ["MATCH,fixed-choice"])
        self.assertEqual(len(config["proxy-groups"][0]["proxies"]), count)
        return config

    def test_default_yaml_is_complete_and_refreshes_current_nodes(self):
        first = self.assert_yaml(self.request("/clash.yaml?token=unit-test-subscription"))
        self.assertEqual([node["type"] for node in first["proxies"]], ["vless", "trojan"])
        self.links.write_text(VLESS + "\n")
        second = self.assert_yaml(self.request("/clash.yaml?token=unit-test-subscription"), count=1)
        self.assertEqual(second["proxies"][0]["type"], "vless")
        self.assertEqual(self.mocks[5].call_count, 2)

    def test_new_short_links_have_yaml_suffix_and_old_paths_still_work(self):
        status, _, body = self.request("/shorten?token=unit-test-subscription", "POST", {"managed": True})
        self.assertEqual(status, 200)
        record = json.loads(body)
        self.assertEqual(record["path"], "/subconfig-api/s/" + record["id"] + ".yaml")
        for suffix in (".yaml", ".yml", ""):
            with self.subTest(suffix=suffix):
                self.assert_yaml(self.request("/s/" + record["id"] + suffix))

    def test_old_render_route_keeps_working(self):
        self.assert_yaml(self.request("/render/clash?token=unit-test-subscription"))

    def test_missing_or_wrong_token_cannot_download_yaml(self):
        for path in ("/clash.yaml", "/clash.yaml?token=wrong"):
            with self.subTest(path=path):
                status, _, body = self.request(path)
                self.assertEqual(status, 401)
                self.assertNotIn("proxies:", body)

    def test_missing_or_invalid_short_link_is_not_yaml(self):
        for path in ("/s/unknown-id.yaml", "/s/../bad.yaml", "/s/unknown-id.yaml.yaml"):
            with self.subTest(path=path):
                self.assertEqual(self.request(path)[0], 404)

    def test_token_and_source_are_not_logged_and_default_ignores_source_override(self):
        self.assert_yaml(self.request("/clash.yaml?token=unit-test-subscription&source=private-source-marker"))
        logs = str(self.mocks[6].call_args_list)
        self.assertNotIn("unit-test-subscription", logs)
        self.assertNotIn("private-source-marker", logs)
        self.assertNotIn("/clash.yaml", logs)

    def test_render_failure_does_not_leak_source_credentials(self):
        with mock.patch.object(api, "render_clash_config", side_effect=ValueError("private-source-marker")):
            status, _, body = self.request("/clash.yaml?token=unit-test-subscription")
        self.assertEqual(status, 500)
        self.assertNotIn("private-source-marker", body)

    def test_short_link_failure_does_not_leak_source_credentials(self):
        with mock.patch.object(api, "save_short_link", side_effect=ValueError("private-source-marker")):
            status, _, body = self.request("/shorten?token=unit-test-subscription", "POST", {"managed": True})
        self.assertEqual(status, 400)
        self.assertNotIn("private-source-marker", body)


if __name__ == "__main__":
    unittest.main()
