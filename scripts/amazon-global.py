#!/usr/bin/env python3
"""Render a one-node Clash/Mihomo config that sends every service via VLESS."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import tempfile
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse


AMAZON_SUFFIXES = (
    "sellercentral.amazon.com",
    "amazon.com",
    "amazon.ca",
    "amazon.com.mx",
    "amazon.com.br",
    "amazon.co.uk",
    "amazon.de",
    "amazon.fr",
    "amazon.it",
    "amazon.es",
    "amazon.nl",
    "amazon.se",
    "amazon.pl",
    "amazon.com.be",
    "amazon.co.jp",
    "amazon.com.au",
    "amazon.in",
    "amazon.sg",
    "amazon.ae",
    "amazon.sa",
    "amazon.com.tr",
    "amazon.cn",
    "amazonaws.com",
    "amazonservices.com",
    "amazonbusiness.com",
    "amazonpay.com",
    "amazontrust.com",
    "amazon-adsystem.com",
    "amazonvideo.com",
    "primevideo.com",
    "aiv-cdn.net",
    "media-amazon.com",
    "ssl-images-amazon.com",
    "images-amazon.com",
    "cloudfront.net",
    "awsstatic.com",
)


def quoted(value: object) -> str:
    return json.dumps(str(value), ensure_ascii=False)


def first(query: dict[str, list[str]], key: str, default: str = "") -> str:
    values = query.get(key)
    return values[0] if values else default


def parse_vless(link: str) -> dict[str, object]:
    parsed = urlparse(link.strip())
    if parsed.scheme.lower() != "vless":
        raise ValueError("Amazon global mode requires a vless:// source link")
    if not parsed.username or not parsed.hostname or not parsed.port:
        raise ValueError("The VLESS link must include UUID, server, and port")

    query = parse_qs(parsed.query, keep_blank_values=True)
    security = first(query, "security", "none").lower()
    network = first(query, "type", "tcp").lower()
    public_key = first(query, "pbk")
    if security != "reality" or not public_key:
        raise ValueError("The source node must use VLESS REALITY")
    if network not in ("tcp", "raw"):
        raise ValueError("The source node must use VLESS TCP/Raw")

    return {
        "uuid": unquote(parsed.username),
        "server": parsed.hostname,
        "port": parsed.port,
        "network": "tcp",
        "security": security,
        "public_key": public_key,
        "short_id": first(query, "sid"),
        "server_name": first(query, "sni", parsed.hostname),
        "fingerprint": first(query, "fp", "chrome"),
        "flow": first(query, "flow", "xtls-rprx-vision"),
        "spider_x": first(query, "spx", "/"),
        "fragment": unquote(parsed.fragment),
    }


def route_exclusion(server: str) -> str | None:
    try:
        address = ipaddress.ip_address(server)
    except ValueError:
        return None
    return f"{address}/{32 if address.version == 4 else 128}"


def render_config(link: str, node_name: str, group_name: str, mtu: int) -> str:
    node = parse_vless(link)
    exclusion = route_exclusion(str(node["server"]))
    lines = [
        "mixed-port: 7890",
        "allow-lan: false",
        'bind-address: "*"',
        "mode: rule",
        "log-level: info",
        "ipv6: false",
        "unified-delay: true",
        "tcp-concurrent: true",
        "",
        "profile:",
        "  store-selected: true",
        "  store-fake-ip: true",
        "",
        "tun:",
        "  enable: true",
        "  stack: mixed",
        "  dns-hijack:",
        "    - any:53",
        "    - tcp://any:53",
        "  auto-route: true",
        "  auto-detect-interface: true",
        "  strict-route: true",
        f"  mtu: {mtu}",
    ]
    if exclusion:
        lines.extend(("  route-exclude-address:", f"    - {exclusion}"))

    lines.extend(
        (
            "",
            "dns:",
            "  enable: true",
            "  listen: 0.0.0.0:1053",
            "  ipv6: false",
            "  enhanced-mode: fake-ip",
            "  fake-ip-range: 198.18.0.1/16",
            "  fake-ip-filter-mode: blacklist",
            "  respect-rules: true",
            "  fake-ip-filter:",
            '    - "*.lan"',
            '    - "*.local"',
            '    - "localhost"',
            '    - "localhost.ptlogin2.qq.com"',
            "  default-nameserver:",
            "    - 223.5.5.5",
            "    - 119.29.29.29",
            "  nameserver:",
            "    - https://1.1.1.1/dns-query",
            "    - https://8.8.8.8/dns-query",
            "  proxy-server-nameserver:",
            "    - https://dns.alidns.com/dns-query",
            "    - https://doh.pub/dns-query",
            "",
            "proxies:",
            f"  - name: {quoted(node_name)}",
            "    type: vless",
            f"    server: {quoted(node['server'])}",
            f"    port: {node['port']}",
            f"    uuid: {quoted(node['uuid'])}",
            f"    network: {node['network']}",
            "    udp: true",
            "    tls: true",
            f"    flow: {quoted(node['flow'])}",
            f"    servername: {quoted(node['server_name'])}",
            f"    client-fingerprint: {quoted(node['fingerprint'])}",
            "    reality-opts:",
            f"      public-key: {quoted(node['public_key'])}",
        )
    )
    if node["short_id"]:
        lines.append(f"      short-id: {quoted(node['short_id'])}")

    lines.extend(
        (
            "",
            "proxy-groups:",
            f"  - name: {quoted(group_name)}",
            "    type: select",
            "    proxies:",
            f"      - {quoted(node_name)}",
            "",
            "rules:",
        )
    )
    lines.extend(f"  - DOMAIN-SUFFIX,{suffix},{group_name}" for suffix in AMAZON_SUFFIXES)
    lines.append(f"  - MATCH,{group_name}")
    return "\n".join(lines) + "\n"


def write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--link", required=True)
    parser.add_argument("--output", default="-")
    parser.add_argument("--node-name", default="Amazon住宅全局节点")
    parser.add_argument("--group-name", default="Amazon住宅IP全局代理")
    parser.add_argument("--mtu", type=int, default=1400)
    args = parser.parse_args()
    if not 1200 <= args.mtu <= 1500:
        parser.error("--mtu must be between 1200 and 1500")

    content = render_config(args.link, args.node_name, args.group_name, args.mtu)
    if args.output == "-":
        print(content, end="")
    else:
        write_atomic(Path(args.output), content)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
