import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RENAMED = {
    "scripts": "n6j0p",
    "site": "k4q8c",
    "caddy": "a9f2x",
    "subconfig-api": "u3t7w",
}
INSTALL = (ROOT / "install.sh").read_text(encoding="utf-8")
UPDATE = (ROOT / "n6j0p" / "safe-update.sh").read_text(encoding="utf-8")


def execute_source_mapping(source, original):
    match = re.search(r"(?ms)^repo_source_path\(\) \{\n.*?^\}\n", source)
    if not match:
        raise AssertionError("source mapper missing")
    result = subprocess.run(
        ["bash", "-c", match.group() + '\nrepo_source_path "$1"\n', "test", original],
        text=True, capture_output=True, check=True,
    )
    return result.stdout


class RepositoryLayoutTests(unittest.TestCase):
    def test_both_downloaders_map_into_repository_paths(self):
        files = set(re.findall(r'^    "((?:scripts|site|caddy|subconfig-api)/[^"]+)"$', INSTALL, re.M))
        files.update(re.findall(r'^    "((?:scripts|site|caddy|subconfig-api)/[^"]+)"$', UPDATE, re.M))
        self.assertGreater(len(files), 20)
        for original in files:
            parts = original.split("/", 1)
            expected = RENAMED[parts[0]] + "/" + parts[1]
            with self.subTest(path=original):
                self.assertEqual(execute_source_mapping(INSTALL, original), expected)
                self.assertEqual(execute_source_mapping(UPDATE, original), expected)
                self.assertTrue((ROOT / expected).is_file(), expected)

    def test_repository_keeps_runtime_compatible_file_list(self):
        for folder in RENAMED:
            self.assertFalse((ROOT / folder).is_dir())
        self.assertIn('"scripts/manage.sh"', INSTALL)
        self.assertIn('"site/sub/config/3.5.yaml"', INSTALL)
        self.assertIn('"${INSTALL_DIR}/${f}"', INSTALL)
