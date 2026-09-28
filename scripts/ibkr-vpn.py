#!/usr/bin/env python3
"""Generate scoped IBKR rules for one explicit VPN node, without DIRECT fallback."""

import argparse
import copy
import os
import tempfile
from pathlib import Path
from urllib.parse import quote

import yaml


SUFFIXES = ("ibllc.com", "ibllc.com.cn", "ibkr.com", "ibkr.com.cn", "interactivebrokers.com")
RESOLVERS = ("https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query")
BUILTINS = {"DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"}


def validate_name(name):
    if not isinstance(name, str) or not name.strip() or name != name.strip():
        raise ValueError("A non-empty, unpadded node/group name is required")
    if any(character in name for character in ",\r\n#=&[]"):
        raise ValueError("The node/group name contains a configuration delimiter")
    if name.upper() in BUILTINS:
        raise ValueError("Use an explicit VPN node, not a built-in policy")
    return name


def render_shadowrocket(node_name):
    validate_name(node_name)
    resolver = "https://dns.google/dns-query#proxy=" + quote(node_name, safe="")
    lines = [
        "#!name=IBKR稳定连接",
        "#!desc=IBKR相关域名固定VPN节点；不设DIRECT备用；不使用自动选择或轮询。",
        "# 域名分流不是按进程的系统断网保护；VPN关闭后不能保证阻断应用。",
        "[General]",
        "use-local-host-item-for-proxy = true",
        "",
        "[Host]",
    ]
    # Include apex names as well as wildcard subdomains.
    for suffix in SUFFIXES:
        lines.extend((f"{suffix} = server:{resolver}", f"*.{suffix} = server:{resolver}"))
    lines.extend(("", "[Rule]"))
    lines.extend(f"DOMAIN-SUFFIX,{suffix},{node_name}" for suffix in SUFFIXES)
    return "\n".join(lines) + "\n"


def apply_mihomo(config, node_name, group_name="IBKR固定VPN"):
    validate_name(node_name)
    validate_name(group_name)
    if not isinstance(config, dict) or config.get("mode", "rule") != "rule":
        raise ValueError("The input must be a Mihomo configuration in rule mode")
    proxies = config.get("proxies")
    groups = config.get("proxy-groups")
    rules = config.get("rules")
    if not isinstance(proxies, list) or not isinstance(groups, list) or not isinstance(rules, list):
        raise ValueError("Input requires proxies, proxy-groups and rules lists")
    matches = [node for node in proxies if isinstance(node, dict) and node.get("name") == node_name]
    if len(matches) != 1 or any(group.get("name") == node_name for group in groups if isinstance(group, dict)):
        raise ValueError("Select exactly one concrete proxy node, not a policy group")
    node = matches[0]
    if not node.get("type") or str(node["type"]).lower() in ("direct", "reject", "dns"):
        raise ValueError("The selected proxy must be a VPN node")
    if node.get("dialer-proxy"):
        raise ValueError("Choose a node without an upstream dialer policy")
    if any(isinstance(proxy, dict) and proxy.get("name") == group_name for proxy in proxies):
        raise ValueError("The IBKR group name conflicts with a proxy name")
    fixed_group = {"name": group_name, "type": "select", "proxies": [node_name]}
    existing = [group for group in groups if isinstance(group, dict) and group.get("name") == group_name]
    if existing and existing != [fixed_group]:
        raise ValueError("The IBKR group name is already used; choose another group name")
    dns = config.get("dns")
    if not isinstance(dns, dict) or dns.get("enable") is not True:
        raise ValueError("Enable the client DNS service before adding IBKR DNS policies")
    if "nameserver-policy" in dns and not isinstance(dns["nameserver-policy"], dict):
        raise ValueError("DNS nameserver-policy must be a mapping")
    # A named proxy needs its own bootstrap DNS to avoid a resolver/proxy loop.
    if not dns.get("proxy-server-nameserver"):
        raise ValueError("Configure proxy-server-nameserver for VPN node bootstrap DNS")

    result = copy.deepcopy(config)
    if not existing:
        result["proxy-groups"].append(fixed_group)
    priority = [f"DOMAIN-SUFFIX,{suffix},{group_name}" for suffix in SUFFIXES]
    result["rules"] = priority + [rule for rule in rules if rule not in priority]
    policy = result["dns"].setdefault("nameserver-policy", {})
    for suffix in SUFFIXES:
        policy["+." + suffix] = [resolver + "#" + group_name for resolver in RESOLVERS]
    return result


def write_private(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=("shadowrocket", "mihomo"), required=True)
    parser.add_argument("--node-name", required=True, help="Existing concrete VPN node name")
    parser.add_argument("--group-name", default="IBKR固定VPN")
    parser.add_argument("--input", type=Path, help="Existing Mihomo YAML; never pass node credentials on CLI")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.input and args.input.resolve() == args.output.resolve():
        parser.error("Use a separate output file to preserve the source")
    try:
        if args.format == "shadowrocket":
            if args.input:
                raise ValueError("Shadowrocket modules only need the existing node name")
            content = render_shadowrocket(args.node_name)
        else:
            if not args.input:
                raise ValueError("Mihomo mode requires --input")
            config = yaml.safe_load(args.input.read_text(encoding="utf-8"))
            content = yaml.safe_dump(apply_mihomo(config, args.node_name, args.group_name), allow_unicode=True, sort_keys=False)
        write_private(args.output, content)
    except yaml.YAMLError:
        parser.error("Invalid YAML input; details omitted to protect credentials")
    except ValueError as exc:
        parser.error(str(exc))
    except OSError:
        parser.error("Could not read or write the configuration file")
    print("IBKR configuration written; import/reload the client and verify the connection")


if __name__ == "__main__":
    main()
