import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APPLY_PRESETS = (ROOT / "scripts" / "apply-presets.sh").read_text(encoding="utf-8")
INSTALL = (ROOT / "install.sh").read_text(encoding="utf-8")
RECONCILE = (ROOT / "scripts" / "reconcile.sh").read_text(encoding="utf-8")
SAFE_UPDATE = (ROOT / "scripts" / "safe-update.sh").read_text(encoding="utf-8")


class RealityCompatibilityTests(unittest.TestCase):
    def test_new_inbounds_set_mihomo_compatible_minimum(self):
        self.assertEqual(
            len(re.findall(r"minClientVer: \$minClientVer", APPLY_PRESETS)),
            2,
        )
        self.assertIn(
            'REALITY_MIN_CLIENT_VERSION="${REALITY_MIN_CLIENT_VERSION:-1.8.2}"',
            APPLY_PRESETS,
        )

    def test_existing_managed_inbounds_are_updated_without_recreation(self):
        self.assertIn("sync_reality_client_compatibility()", APPLY_PRESETS)
        self.assertIn('.realitySettings.minClientVer = $minClientVer', APPLY_PRESETS)
        self.assertIn('startswith("auto-vless-reality-")', APPLY_PRESETS)
        self.assertIn("Reality compatibility update incomplete", APPLY_PRESETS)
        self.assertIn(
            "write_vless_reality\nsync_reality_client_compatibility\n",
            APPLY_PRESETS,
        )

    def test_installer_persists_compatibility_default(self):
        self.assertIn(
            "REALITY_MIN_CLIENT_VERSION=${REALITY_MIN_CLIENT_VERSION:-1.8.2}",
            INSTALL,
        )
        self.assertIn(
            'ensure_env_var REALITY_MIN_CLIENT_VERSION "1.8.2"',
            INSTALL,
        )

    def test_safe_update_runs_compatibility_reconcile(self):
        self.assertIn("./scripts/reconcile.sh", SAFE_UPDATE)
        self.assertIn("./scripts/apply-presets.sh", RECONCILE)


if __name__ == "__main__":
    unittest.main()
