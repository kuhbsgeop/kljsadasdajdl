import re
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
INSTALL = (ROOT / "install.sh").read_text(encoding="utf-8")
APPLY_PRESETS = (ROOT / "n6j0p" / "apply-presets.sh").read_text(encoding="utf-8")
MANAGE = (ROOT / "n6j0p" / "manage.sh").read_text(encoding="utf-8")
SAFE_UPDATE = (ROOT / "n6j0p" / "safe-update.sh").read_text(encoding="utf-8")
START_SERVICES = (ROOT / "n6j0p" / "start-services.sh").read_text(encoding="utf-8")
PROTOCOL_GUARD = (ROOT / "n6j0p" / "protocol-guard.sh").read_text(encoding="utf-8")
ONE_CLICK = (ROOT / "one-click.sh").read_text(encoding="utf-8")
DOMAIN_CERT = (ROOT / "n6j0p" / "domain-cert.sh").read_text(encoding="utf-8")
XUI_BUILTIN_SUB = (ROOT / "n6j0p" / "xui-builtin-subscription.sh").read_text(encoding="utf-8")
SECURITY_CHECK = ROOT / "n6j0p" / "security-check.sh"
SECURITY_CHECK_TEXT = SECURITY_CHECK.read_text(encoding="utf-8")
COMPOSE = yaml.safe_load((ROOT / "compose.yaml").read_text(encoding="utf-8"))


class SecurityHardeningTests(unittest.TestCase):
    def test_installer_has_hardening_functions(self):
        for fn in (
            "harden_ssh() {",
            "install_fail2ban() {",
            "enable_unattended_upgrades() {",
            "harden_file_permissions() {",
            "run_security_check() {",
        ):
            with self.subTest(fn=fn):
                self.assertIn(fn, INSTALL)

    def test_installer_calls_hardening_in_main(self):
        main_body = INSTALL.rsplit("main() {", 1)[1]
        for call in (
            "  harden_ssh",
            "  install_fail2ban",
            "  enable_unattended_upgrades",
            "  harden_file_permissions",
            "  run_security_check",
        ):
            with self.subTest(call=call):
                self.assertIn(call, main_body)
        # Host hardening runs after the firewall is up; file permissions are
        # fixed once the panel database exists; the self-check runs last.
        self.assertLess(
            main_body.index("  configure_firewall_ports"),
            main_body.index("  harden_ssh"),
        )
        self.assertLess(
            main_body.index("  configure_panel"),
            main_body.index("  harden_file_permissions"),
        )
        self.assertLess(
            main_body.index("  print_install_summary"),
            main_body.index("  run_security_check"),
        )

    def test_ssh_hardening_never_locks_out_password_users(self):
        setup = INSTALL.split("harden_ssh() {", 1)[1]
        setup = setup.split("install_fail2ban() {", 1)[0]
        self.assertIn("PasswordAuthentication no", setup)
        self.assertIn("PermitRootLogin prohibit-password", setup)
        self.assertIn("sshd -t", setup)
        self.assertIn("authorized_keys", setup)
        self.assertIn("password login was NOT disabled", setup)

    def test_ssh_password_auth_on_by_default(self):
        setup = INSTALL.split("harden_ssh() {", 1)[1]
        setup = setup.split("install_fail2ban() {", 1)[0]
        self.assertIn("SSH_PASSWORD_AUTH:-1", setup)
        self.assertIn("PasswordAuthentication yes", setup)
        self.assertIn("PermitRootLogin yes", setup)

    def test_panel_binds_public_ip_by_default(self):
        self.assertIn('ensure_env_var PANEL_LISTEN_IP "0.0.0.0"', INSTALL)
        self.assertIn('bind_choice="$(tty_prompt "Choose panel exposure" "2")"', INSTALL)
        self.assertIn('PANEL_LISTEN_IP:-0.0.0.0', INSTALL)
        # The wizard's explicit "Safe" choice still binds localhost.
        self.assertIn('PANEL_LISTEN_IP="${PANEL_LISTEN_IP:-127.0.0.1}"', INSTALL)

    def test_builtin_subscription_port_open_without_domain(self):
        setup = XUI_BUILTIN_SUB.split("secure_firewall() {", 1)[1]
        setup = setup.split("restart_xui_later() {", 1)[0]
        self.assertIn('HTTPS_SITE_ENABLE:-0}" = "1"', setup)
        self.assertIn('ufw deny "${XUI_BUILTIN_SUB_PORT}/tcp"', setup)
        self.assertIn('ufw allow "${XUI_BUILTIN_SUB_PORT}/tcp"', setup)
        self.assertIn("no domain for Caddy proxy", SECURITY_CHECK_TEXT)

    def test_install_validates_server_aliases(self):
        self.assertIn("validate_server_aliases() {", INSTALL)
        self.assertIn('getent hosts "$value"', INSTALL)
        self.assertIn("dropping unresolvable SERVER_ALIASES", INSTALL)
        self.assertIn("set_env_var SERVER_ALIASES \"$kept\"", INSTALL)
        self.assertIn("  validate_server_aliases\n", INSTALL)

    def test_install_syncs_rules_names(self):
        self.assertIn("sync_rules_names() {", INSTALL)
        self.assertIn("scripts/sync_rules_names.py", INSTALL)
        self.assertIn("  sync_rules_names\n", INSTALL)
        self.assertIn('"scripts/sync_rules_names.py"', INSTALL)

    def test_python3_is_a_base_tool(self):
        self.assertIn("for bin in curl openssl jq tar python3; do", INSTALL)

    def test_repo_rules_file_has_dns_block(self):
        rules = (ROOT / "k4q8c" / "sub" / "config" / "3.5.yaml").read_text(encoding="utf-8")
        self.assertIn("\ndns:\n", rules)
        self.assertIn("enhanced-mode: redir-host", rules)
        self.assertIn("fallback-filter:", rules)

    def test_fail2ban_jail_uses_ufw(self):
        setup = INSTALL.split("install_fail2ban() {", 1)[1]
        setup = setup.split("enable_unattended_upgrades() {", 1)[0]
        self.assertIn("banaction = ufw", setup)
        self.assertIn("maxretry = 5", setup)
        self.assertIn("bantime = 1h", setup)
        self.assertIn("findtime = 10m", setup)
        self.assertIn("fail2ban-client -t", setup)

    def test_firewall_enable_is_verified(self):
        setup = INSTALL.split("configure_firewall_ports() {", 1)[1]
        setup = setup.split("generate_mask_site() {", 1)[0]
        self.assertIn("ufw --force enable", setup)
        self.assertIn("ufw default deny incoming", setup)
        self.assertIn("Status: active", setup)
        self.assertIn("NOT active", setup)

    def test_hardening_toggles_persist_to_env(self):
        for key in (
            "ENABLE_SSH_HARDENING",
            "SSH_PASSWORD_AUTH",
            "ENABLE_FAIL2BAN",
            "ENABLE_UNATTENDED_UPGRADES",
        ):
            with self.subTest(key=key):
                self.assertIn(key, INSTALL)
                self.assertIn(f'ensure_env_var {key} "1"', INSTALL)

    def test_tunnel_forward_defaults_to_localhost(self):
        self.assertIn('listen="${listen:-127.0.0.1}"', APPLY_PRESETS)
        self.assertNotIn('listen="${listen:-0.0.0.0}"', APPLY_PRESETS)
        self.assertIn("unauthenticated public forwarder", APPLY_PRESETS)
        self.assertIn("unauthenticated public forwarder", MANAGE)

    def test_dokodemo_forwards_loop_reads_last_entry(self):
        # `read` drops a final line without a trailing newline, so the
        # FORWARDS list must be newline-terminated or the last forward is
        # silently skipped (both in the firewall setup and in preset apply).
        for text in (INSTALL, APPLY_PRESETS):
            self.assertIn('printf \'%s\\n\' "$DOKODEMO_FORWARDS" | tr \';\'', text)

    def test_security_check_script_is_shipped_and_valid(self):
        self.assertTrue(SECURITY_CHECK.is_file())
        result = subprocess.run(
            ["bash", "-n", str(SECURITY_CHECK)],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"scripts/security-check.sh"', INSTALL)
        self.assertIn('"scripts/security-check.sh"', SAFE_UPDATE)
        text = SECURITY_CHECK.read_text(encoding="utf-8")
        self.assertIn("security-check: %d passed", text)
        self.assertIn("twoFactorEnable", text)
        self.assertIn("mode=ro", text)

    def test_safe_update_runs_security_check_after_reconcile(self):
        self.assertIn("./scripts/security-check.sh || true", SAFE_UPDATE)
        self.assertLess(
            SAFE_UPDATE.index("./scripts/reconcile.sh"),
            SAFE_UPDATE.index("./scripts/security-check.sh"),
        )

    def test_manage_exposes_security_check(self):
        self.assertIn("security-check", MANAGE)
        self.assertIn("./scripts/security-check.sh", MANAGE)

    def test_start_services_falls_back_to_docker_start(self):
        self.assertIn("compose_up_or_start", START_SERVICES)
        self.assertIn('docker start "$name"', START_SERVICES)
        self.assertIn("docker compose up -d 3xui", START_SERVICES)

    def test_compose_disables_core_dumps_everywhere(self):
        self.assertGreaterEqual(len(COMPOSE["services"]), 7)
        for name, service in COMPOSE["services"].items():
            with self.subTest(service=name):
                self.assertEqual(service.get("ulimits"), {"core": 0})

    def test_install_summary_has_hardening_checklist(self):
        self.assertIn("Security hardening checklist", INSTALL)
        self.assertIn("two-factor authentication", INSTALL)


class NodeSecurityTests(unittest.TestCase):
    def test_reality_writers_set_target_server_names_and_short_id(self):
        self.assertEqual(APPLY_PRESETS.count("target: $target"), 2)
        self.assertEqual(APPLY_PRESETS.count("serverNames: $serverNames"), 2)
        self.assertEqual(APPLY_PRESETS.count("shortIds: [$shortId]"), 2)
        self.assertEqual(APPLY_PRESETS.count('security: "reality"'), 2)

    def test_reality_dest_sites_rotate_per_node(self):
        self.assertIn("reality_dest_site() {", APPLY_PRESETS)
        self.assertIn('dest_site="$(reality_dest_site "$node_idx")"', APPLY_PRESETS)
        self.assertIn('dest_site="$(reality_dest_site 0)"', APPLY_PRESETS)
        # The default rotation list has 10 distinct high-traffic sites.
        match = re.search(r'DEFAULT_REALITY_DEST_SITES="([^"]+)"', APPLY_PRESETS)
        self.assertIsNotNone(match)
        sites = match.group(1).split(",")
        self.assertEqual(len(sites), 10)
        self.assertEqual(len(set(sites)), 10)
        for site in sites:
            with self.subTest(site=site):
                self.assertTrue(site.startswith("www."))
                self.assertNotIn("google", site)
                self.assertNotIn("wikipedia", site)
        # install.sh and apply-presets.sh must agree on the default list.
        install_match = re.search(r'DEFAULT_REALITY_DEST_SITES="([^"]+)"', INSTALL)
        self.assertIsNotNone(install_match)
        self.assertEqual(install_match.group(1), match.group(1))
        # Per-node dests are recorded for the install summary.
        self.assertIn(": > runtime/reality-dest-sites.txt", APPLY_PRESETS)
        self.assertIn(">> runtime/reality-dest-sites.txt", APPLY_PRESETS)
        self.assertIn("runtime/reality-dest-sites.txt", INSTALL)

    def test_trojan_writers_fall_back_to_masquerade_site(self):
        self.assertEqual(
            APPLY_PRESETS.count('fallbacks: [{dest: "127.0.0.1:80"}]'), 2
        )
        # REALITY inbounds keep empty fallbacks: their target is the fallback.
        self.assertEqual(APPLY_PRESETS.count("fallbacks: []"), 2)

    def test_shadowsocks_is_off_by_default(self):
        self.assertIn("ENABLE_SHADOWSOCKS=${ENABLE_SHADOWSOCKS:-0}", INSTALL)
        self.assertIn('ensure_env_var ENABLE_SHADOWSOCKS "0"', INSTALL)
        self.assertIn('export ENABLE_SHADOWSOCKS="${ENABLE_SHADOWSOCKS:-0}"', ONE_CLICK)
        self.assertIn("ENABLE_SHADOWSOCKS:-0", DOMAIN_CERT)
        self.assertNotIn("ENABLE_SHADOWSOCKS:-1", INSTALL)
        self.assertNotIn("ENABLE_SHADOWSOCKS:-1", ONE_CLICK)
        self.assertNotIn("ENABLE_SHADOWSOCKS:-1", DOMAIN_CERT)

    def test_protocol_guard_requires_secure_transport(self):
        self.assertIn(
            'REQUIRE_SECURE_TRANSPORT="${REQUIRE_SECURE_TRANSPORT:-1}"',
            PROTOCOL_GUARD,
        )
        # Shadowsocks (AEAD) and WireGuard (Noise) encrypt at the protocol
        # layer, so they are exempt from the TLS/Reality transport check.
        self.assertIn("shadowsocks|wireguard)", PROTOCOL_GUARD)
        self.assertIn(
            "REQUIRE_SECURE_TRANSPORT=${REQUIRE_SECURE_TRANSPORT:-1}", INSTALL
        )

    def test_hysteria2_uses_tls_13(self):
        # QUIC requires TLS 1.3; a 1.2 minimum is dead config there.
        self.assertEqual(APPLY_PRESETS.count('minVersion: "1.3"'), 1)

    def test_no_vmess_or_plaintext_node_is_generated(self):
        self.assertNotIn('protocol: "vmess"', APPLY_PRESETS)
        self.assertEqual(APPLY_PRESETS.count('security: "tls"'), 3)
        # The only "none" transports are Shadowsocks (AEAD at the protocol
        # layer), the AdsPower mixed proxy, and tunnel inbounds.
        self.assertEqual(APPLY_PRESETS.count('security: "none"'), 3)

    def test_security_check_covers_node_configuration(self):
        for token in (
            "REALITY_BAD",
            "REALITY_MISMATCH",
            "REALITY_ALL_SAME",
            "REALITY_NON443",
            "VMESS_COUNT",
            "PLAINTEXT_COUNT",
            "INFO_COUNT",
            "[INFO]",
        ):
            with self.subTest(token=token):
                self.assertIn(token, SECURITY_CHECK_TEXT)

    def test_install_summary_documents_node_security_model(self):
        for text in (
            "Node security model",
            "REALITY is the primary protocol",
            "Shadowsocks-2022 is OFF by default",
            "port 443 is the recommended next step",
            "Reality dest sites",
            "reality-dest-sites.txt",
        ):
            with self.subTest(text=text):
                self.assertIn(text, INSTALL)


if __name__ == "__main__":
    unittest.main()
