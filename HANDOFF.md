# 3x-ui Selfhost Kit Handoff

## Subscription operation

- `/sub/` is the normal user-facing entry: it refreshes the current 3X-UI inbound links, then produces a Clash 3.5 short subscription automatically.
- The direct subscription is `/subscriptions/<SUBSCRIPTION_TOKEN>.b64`. The token is stored only in the server `.env` file.
- Domain-node mode maps every complete group of generated links back to `SERVER_ALIASES`. It must not expand an already grouped list again; a ten-domain, two-protocol deployment must publish 20 nodes, not 200.
- The public refresh endpoint is intentionally input-free and throttled by `PUBLIC_LINK_REFRESH_INTERVAL` (default 60 seconds). Configuration editing and forward management remain protected by `SUB_CONFIG_ADMIN_TOKEN`.

## Update and recovery

- Update an installed host with `curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh | sudo bash -s -- update`.
- The updater preserves `.env`, `data/db`, `data/backups`, and `site/sub/config/3.5.yaml`.
- Validate after an update with `./scripts/manage.sh refresh-links`, `docker compose ps`, and a client download of the generated short subscription.

## Amazon residential-IP forced-global command

- The standalone one-click entrypoint is `curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh | sudo bash -s -- amazon-global`.
- On a fresh host it installs the kit, creates the managed VLESS Reality node, and writes a dedicated one-node YAML subscription. On an installed host it refreshes the existing Amazon subscription without reinstalling the stack.
- `scripts/amazon-global.sh` selects the first generated VLESS Reality link and delegates deterministic YAML rendering to `scripts/amazon-global.py`.
- The client must stay in Rule mode. Explicit Amazon-family domain rules and the final `MATCH` rule use the same proxy group, so all application traffic follows the node without relying on Mihomo's implicit `GLOBAL` selector.
- DNS uses Fake-IP with `respect-rules: true`; IPv6 is disabled; the Android mixed TUN stack uses MTU 1400 and excludes the proxy endpoint IP from the TUN route.
- Reconcile and safe update preserve and refresh this subscription whenever `ENABLE_AMAZON_GLOBAL=1`.

## Reality client compatibility

- Keep `REALITY_MIN_CLIENT_VERSION=1.8.2` unless every client is known to use a recent Xray-compatible Reality ClientHello. Xray 26.7.11 and newer otherwise default to a minimum version that current Clash/Mihomo clients can fail.
- `scripts/apply-presets.sh` writes this value for new Reality inbounds and updates only `streamSettings.realitySettings.minClientVer` on existing managed `auto-vless-reality-*` inbounds. It preserves client UUIDs, Reality keys, short IDs, ports, and subscription URLs.
- Safe update invokes reconcile, so existing deployments receive this compatibility repair automatically after updating.

## Sensitive handoff records

Do not commit credentials. On each deployment host, keep the actual panel account, subscription token, Amazon global token/source VLESS link, rules-editor token, API token, and backup locations in `/opt/3xui-selfhost-kit/runtime/install-summary.txt`, `/opt/3xui-selfhost-kit/runtime/amazon-global.txt`, and `/opt/3xui-selfhost-kit/.env` (owner-readable records must remain mode 600). Update those local records when credentials or endpoints change.

## RustDesk 网页端交接

- 原生客户端继续使用 `ID Server: 域名:21116`、`Relay Server: 域名:21117` 和服务器公钥；不要把网页端的 WSS 路径写进原生客户端。
- `https://rustdesk.com/web/` 的 `ID Server` 只填写域名、不带端口，`API Server` 留空，并填写同一份服务器公钥。
- HTTPS 站点必须提供 `wss://域名/ws/id` 与 `wss://域名/ws/relay`；Caddy 分别反向代理到本机 `21118` 和 `21119`。
- 修改域名或重建 Caddy 配置后，运行 `./scripts/domain-cert.sh --auto`，再用 WebSocket Upgrade 请求确认两个路径均返回 `101 Switching Protocols`。
- 实际 VPS 登录密码、Mac 虚拟机系统密码、RustDesk 设备 ID、公钥和验证结果只记录在部署机 `/opt/3xui-selfhost-kit/runtime/install-summary.txt`，文件权限保持 `600`，不得提交到 Git。
