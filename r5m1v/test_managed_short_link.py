import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "n6j0p" / "managed-short-link.sh"


def run_script(env_text):
    """Copy the real script into a temp install dir with the given .env,
    run it, and return (returncode, stdout, stderr) before cleanup."""
    tmp = tempfile.mkdtemp()
    try:
        install_dir = Path(tmp)
        (install_dir / "n6j0p").mkdir()
        shutil.copy(SCRIPT, install_dir / "n6j0p" / "managed-short-link.sh")
        (install_dir / ".env").write_text(env_text, encoding="utf-8")
        proc = subprocess.run(
            ["bash", str(install_dir / "n6j0p" / "managed-short-link.sh")],
            capture_output=True,
            text=True,
            timeout=30,
        )
        env_after = (install_dir / ".env").read_text(encoding="utf-8")
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip(), env_after
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


class ManagedShortLinkTests(unittest.TestCase):
    def test_reuses_existing_id_without_api_call(self):
        rc, out, err, _ = run_script(
            "SERVER_ADDR=45.77.222.81\n"
            "MANAGED_SHORT_LINK_ID=urTRVx2IatI\n"
        )
        self.assertEqual(rc, 0)
        self.assertEqual(out, "http://45.77.222.81/subconfig-api/s/urTRVx2IatI")

    def test_https_origin_with_domain(self):
        rc, out, err, _ = run_script(
            "SERVER_ADDR=example.com\n"
            "HTTPS_SITE_ENABLE=1\n"
            "MANAGED_SHORT_LINK_ID=abc12345\n"
        )
        self.assertEqual(rc, 0)
        self.assertEqual(out, "https://example.com/subconfig-api/s/abc12345")

    def test_nonstandard_http_port_in_url(self):
        rc, out, err, _ = run_script(
            "SERVER_ADDR=1.2.3.4\n"
            "SITE_HTTP_PORT=8080\n"
            "MANAGED_SHORT_LINK_ID=xyz98765\n"
        )
        self.assertEqual(rc, 0)
        self.assertEqual(out, "http://1.2.3.4:8080/subconfig-api/s/xyz98765")

    def test_fails_without_token_and_id(self):
        rc, out, err, _ = run_script("SERVER_ADDR=1.2.3.4\n")
        self.assertNotEqual(rc, 0)
        self.assertIn("SUBSCRIPTION_TOKEN", err)
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()
