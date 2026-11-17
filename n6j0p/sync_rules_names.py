#!/usr/bin/env python3
"""Sync the 3.5.yaml template's node names to the CURRENT subscription node
names (in subscription-file order): rewrites the proxies block and the five
node-listing proxy-groups. Run by install.sh after the nodes are created and
the subscription is refreshed, so a fresh install's rendered subscription
uses the real node names instead of the template placeholders.

Idempotent -- safe to re-run after any node add/remove. Backs up the
original 3.5.yaml first (timestamped). Prints only names and counts,
never credentials.

Usage: python3 sync_rules_names.py [install-dir]
  install-dir defaults to the current directory.
"""
import datetime
import re
import shutil
import sys
import urllib.parse
from pathlib import Path

NODE_GROUPS = {'🚀 手动切换', '♻️ 自动选择', '🔯 故障转移', '🔮 负载均衡', '⚖️ 负载均衡-轮询'}
PLACEHOLDERS = {'测试3ip', '测试4域名', '测试5V6', '测试6域名', '测试10域名'}
PROXY_TEMPLATE = ('  - {name: %s, server: example.com, port: 443, type: vmess, '
                  'uuid: 00000000-0000-0000-0000-000000000000, alterId: 0, '
                  'cipher: auto, tls: true}')
GROUP_NAME_RE = re.compile(r'^(\s{2}-\s+name:\s*)(.+?)\s*$')
ITEM_RE = re.compile(r'^(\s{4,}-\s+)(.+?)\s*$')
TOP_KEY_RE = re.compile(r'^[A-Za-z0-9_-][^:]*:\s*')


def load_subscription_token(install_dir):
    env_file = install_dir / '.env'
    if not env_file.is_file():
        raise SystemExit(f'.env not found in {install_dir}')
    for line in env_file.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if line.startswith('SUBSCRIPTION_TOKEN='):
            return line.split('=', 1)[1].strip().strip('"').strip("'")
    raise SystemExit('SUBSCRIPTION_TOKEN missing from .env')


def main():
    install_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sub_txt = (install_dir / 'site' / 'subscriptions'
               / (load_subscription_token(install_dir) + '.txt'))
    rules = install_dir / 'site' / 'sub' / 'config' / '3.5.yaml'
    if not sub_txt.is_file():
        raise SystemExit(f'subscription file not found: {sub_txt}')
    if not rules.is_file():
        raise SystemExit(f'rules file not found: {rules}')

    # 1. Current node names, in subscription-file order.
    names = []
    for line in sub_txt.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if '://' not in line or '#' not in line:
            continue
        remark = urllib.parse.unquote(line.split('#', 1)[1])
        if remark:
            names.append(remark)
    if not names:
        raise SystemExit('no node names found in subscription file')
    name_set = set(names)
    print(f'subscription nodes: {len(names)}')

    # 2. Read the rules file.
    lines = rules.read_text(encoding='utf-8').splitlines()

    # 3. Replace the proxies block (from 'proxies:' to the next top-level key).
    start = next(i for i, l in enumerate(lines)
                 if re.match(r'^proxies:\s*$', l))
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if TOP_KEY_RE.match(lines[i]):
            end = i
            break
    old_proxy_count = end - start - 1
    lines = (lines[:start + 1]
             + [PROXY_TEMPLATE % n for n in names]
             + lines[end:])
    print(f'proxies block: {old_proxy_count} -> {len(names)}')

    # 4. Replace the node-name lists of the five node groups.
    out = []
    i = 0
    groups_fixed = 0
    in_groups = False
    while i < len(lines):
        line = lines[i]
        if re.match(r'^proxy-groups:\s*$', line):
            in_groups = True
            out.append(line)
            i += 1
            continue
        if in_groups and TOP_KEY_RE.match(line):
            in_groups = False
        if in_groups:
            m = GROUP_NAME_RE.match(line)
            if m:
                gname = m.group(2).strip().strip('"').strip("'")
                out.append(line)
                i += 1
                # Copy group fields until its proxies: list (or next group).
                while i < len(lines):
                    if GROUP_NAME_RE.match(lines[i]):
                        break
                    if TOP_KEY_RE.match(lines[i]):
                        break
                    pm = re.match(r'^(\s+)proxies:\s*$', lines[i])
                    if pm:
                        out.append(lines[i])
                        i += 1
                        items = []
                        while i < len(lines):
                            if GROUP_NAME_RE.match(lines[i]):
                                break
                            im = ITEM_RE.match(lines[i])
                            if not im:
                                break
                            items.append((im.group(1),
                                          im.group(2).strip().strip('"').strip("'")))
                            i += 1
                        if gname in NODE_GROUPS:
                            indent = items[0][0] if items else '      - '
                            kept = [(ind, val) for ind, val in items
                                    if val not in name_set
                                    and val not in PLACEHOLDERS]
                            dropped = len(items) - len(kept)
                            for n in names:
                                out.append(f'{indent}{n}')
                            for ind, val in kept:
                                out.append(f'{ind}{val}')
                            groups_fixed += 1
                            print(f'group [{gname}]: {len(items)} items '
                                  f'({dropped} node names replaced, '
                                  f'{len(kept)} non-node kept) -> {len(names)} names')
                        else:
                            for ind, val in items:
                                out.append(f'{ind}{val}')
                        break
                    out.append(lines[i])
                    i += 1
                continue
        out.append(line)
        i += 1
    print(f'groups updated: {groups_fixed} (expected {len(NODE_GROUPS)})')
    if groups_fixed != len(NODE_GROUPS):
        raise SystemExit('not all node groups were found; aborting')

    # 5. Safety: every new name appears exactly 6 times (1 proxies + 5 groups),
    # and no placeholder name remains.
    text = '\n'.join(out) + '\n'
    for n in names:
        count = text.count(n)
        if count != 6:
            raise SystemExit(
                f'name {n!r} appears {count} times (expected 6); aborting')
    for ph in PLACEHOLDERS:
        if ph in text:
            raise SystemExit(f'placeholder {ph!r} still present; aborting')

    # 6. Backup + write.
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backup = rules.with_name(rules.name + f'.bak-{stamp}')
    shutil.copy2(rules, backup)
    rules.write_text(text, encoding='utf-8')
    print(f'wrote {rules} (backup {backup})')


if __name__ == '__main__':
    main()
