import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "one-click.sh"
SHELL_HARNESS = r"""
source "$SCRIPT"
need_root() { :; }
run_install() {
  printf 'install|domain=%s|bind=%s|https=%s|strict=%s|menu=%s\n' \
    "${DOMAIN_NAMES:-}" "${PANEL_LISTEN_IP:-unset}" "${HTTPS_SITE_ENABLE:-unset}" \
    "${STRICT_DOMAIN_CERT:-unset}" "${MENU_AFTER_INSTALL:-unset}"
}
run_update() { echo "update"; }
run_amazon_global() { echo "amazon-global"; }
main "$@"
"""


class OneClickTests(unittest.TestCase):
    def run_one_click(self, *args, domain_env=None, existing=False):
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            for key in (
                "DOMAIN_NAMES", "PANEL_LISTEN_IP", "HTTPS_SITE_ENABLE",
                "STRICT_DOMAIN_CERT", "MENU_AFTER_INSTALL", "PUBLIC_HTTP_PANEL",
            ):
                env.pop(key, None)
            script_copy = Path(tmp) / "one-click-test.sh"
            script_copy.write_text(SCRIPT.read_text(encoding="utf-8").rsplit('main "$@"', 1)[0], encoding="utf-8")
            env["SCRIPT"] = str(script_copy)
            env["INSTALL_DIR"] = tmp
            if domain_env is not None:
                env["DOMAIN_NAMES"] = domain_env
            if existing:
                (Path(tmp) / ".env").write_text("PANEL_LISTEN_IP=127.0.0.1\n")
            return subprocess.run(
                ["bash", "-c", SHELL_HARNESS, "test-one-click", *args],
                text=True, capture_output=True, env=env, check=False
            )

    def test_no_domain_defaults_to_public_ip(self):
        result = self.run_one_click()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("install|domain=|bind=0.0.0.0|https=0|strict=0|menu=0", result.stdout)

    def test_domain_arg_enables_strict_https(self):
        result = self.run_one_click("example.com")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("domain=example.com|bind=127.0.0.1|https=1|strict=1|menu=0", result.stdout)

    def test_domain_env_is_supported(self):
        result = self.run_one_click(domain_env="example.com,www.example.com")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("domain=example.com,www.example.com|bind=127.0.0.1|https=1", result.stdout)

    def test_invalid_domains_rejected(self):
        for domain in ("-example.com", "example..com", "example.com/evil", "127.0.0.1"):
            with self.subTest(domain=domain):
                result = self.run_one_click(domain)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Invalid domain", result.stderr)

    def test_existing_install_keeps_panel_bind(self):
        result = self.run_one_click(existing=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bind=unset", result.stdout)

    def test_existing_management_commands_remain(self):
        for action, expected in (("update", "update"), ("amazon-global", "amazon-global")):
            with self.subTest(action=action):
                result = self.run_one_click(action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)


if __name__ == "__main__":
    unittest.main()
