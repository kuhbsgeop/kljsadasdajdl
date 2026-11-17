# 3x-ui 自托管工具包交接文档

## 安装自动加固

一键安装会在装完后自动做这些加固（无需手动操作）：

- SSH：写 `/etc/ssh/sshd_config.d/00-3xui-hardening.conf`——密钥登录、最多 3 次认证尝试、30 秒登录宽限；只有确认 root 已有 `authorized_keys` 公钥时才关密码登录（`PasswordAuthentication no`、`KbdInteractiveAuthentication no`、`PermitRootLogin prohibit-password`），否则跳过关密码并打印醒目警告；写完 `sshd -t` 校验，通过才 reload。
- fail2ban（默认开，`ENABLE_FAIL2BAN=0` 可关）：sshd jail，`banaction=ufw`，10 分钟内 5 次失败封 1 小时；装不上或无 ufw 时跳过，不影响安装。
- unattended-upgrades（默认开，`ENABLE_UNATTENDED_UPGRADES=0` 可关）：自动安装安全更新。
- UFW：先放行 SSH（22 及当前 sshd 端口），再设默认拒绝并 `ufw --force enable`；启用后核实 active，否则打印醒目失败提示。
- 文件权限：`.env`、面板数据库 `data/db/x-ui.db`（含 `-shm`/`-wal`）、RustDesk 数据库文件均为 600。
- 禁 core 转储：`compose.yaml` 里各服务均设 `ulimits: core: 0`，防止崩溃转储把内存里的敏感内容写盘。
- 隧道默认本机监听：`DOKODEMO_FORWARDS` 未指定监听地址时默认 `127.0.0.1`；监听 `0.0.0.0`/`::` 时打印明确警告（无认证公开转发，任何人都能用），但不改变用户有意选公开监听时的行为。
- 节点凭据：每个节点独立随机生成（VLESS UUID、Trojan 密码、Reality X25519 密钥对、短 ID），无复用、无硬编码默认密码；安装结束时自检脚本会验证凭据无空值、无重复。

安装结束时自动跑一遍只读安全自检（`scripts/security-check.sh`，也可单独跑或 `./scripts/manage.sh security-check`）：输出 PASS/WARN/FAIL 汇总；FAIL 仅用于硬性安全失败（密码登录仍开、UFW 未启用、面板/订阅端口被放行、空令牌、节点凭据空值或重复等），WARN 用于有意但高风险的配置（公开隧道、面板 2FA 未开等）。自检不修改任何东西，不阻断安装/更新。

仍需用户自己做的事（安装总结第 16 节也有清单）：

- 在 3x-ui 面板里开启两步验证（2FA）。
- 在第二个会话验证 SSH 密钥登录可用，再关闭当前会话。
- 公开隧道（如有）确认是自己有意为之；不需要公开时改回 `127.0.0.1`。

## 节点安全模型

主力是 VLESS + REALITY（默认生成）：

- Reality 握手与真实访问目标站的 TLS 握手无法区分；非 Reality 流量会被转发到目标站，探测者看到的是正常网站。每个节点独立随机生成 UUID、X25519 密钥对和短 ID。
- 每个节点的 dest/SNI 各不相同：按节点序号从 `REALITY_DEST_SITES` 轮换分配（默认 10 个高流量站点：www.cloudflare.com、www.microsoft.com、www.apple.com、www.amazon.com、www.github.com、www.bing.com、www.adobe.com、www.mozilla.org、www.ubuntu.com、www.oracle.com；第 11 个节点起从头轮换）。dest 恒为 `<站点>:443`，serverNames 恒为 `[<站点>]`，两者必然一致。`REALITY_TARGET`/`REALITY_SERVER_NAMES` 只在列表被清空时作为旧的单站点回落。注意：已创建的节点不会自动换 dest——更新后需 `RECREATE_MANAGED_INBOUNDS=1` 重建节点才生效（重建会换链接，需重新下发订阅）。安装总结第 5 节列出轮换列表和每个新节点的 dest（来源：`runtime/reality-dest-sites.txt`）。
- 自检（`scripts/security-check.sh`）验证每个 Reality 节点都有 dest、serverNames、shortId 和私钥（缺失为 FAIL）；dest 与 SNI 不一致出 WARN；全部节点 dest 相同出 WARN（提示重建以轮换）。

Trojan（WS + TLS）是备用：默认仍可生成，供不支持 Reality 的客户端使用；WS 握手特征比 Reality 明显，抗检测弱一档。非 Trojan 流量回落到本机伪装站 `:80`（`fallbacks: 127.0.0.1:80`），探测者看到真实网站。

默认不生成的协议：

- Shadowsocks-2022：默认关闭（`ENABLE_SHADOWSOCKS=0`）。流量特征最易被识别；需要时显式开启。
- Hysteria2：默认关闭（`ENABLE_HYSTERIA=0`），可选第二协议——QUIC + TLS 1.3，提供 UDP 传输多样性（TCP 被针对性封锁时仍可连通）与弱网性能；不带 obfs（Xray 侧 obfs 配置未经实测验证，暂不加入）。
- VMess、明文（无 TLS/Reality）节点：永不生成；protocol-guard（`REQUIRE_SECURE_TRANSPORT=1`，默认开启）会禁用已出现的此类入站。Shadowsocks-2022 与 WireGuard 是协议层加密（AEAD/Noise），不在"明文"之列。

端口与 443 方案（下一步推荐，尚未实现）：

- 目前 Reality 在 8443 起的非标准端口（因为 Caddy 占了 443 服务面板/订阅/伪装站），自检会对此出一条 INFO 提示（不是 WARN/FAIL）。端口本身不是指纹——封锁靠协议特征识别，不是端口号；Reality 在 8443 上同样隐蔽，443 只是锦上添花（混入正常 HTTPS 流量）。
- 把 Reality 移到 443 需要先解决面板/订阅的去向（它们现在走 Caddy :443 的域名 HTTPS），涉及安装流程与 Caddy 配置的大改，未在本轮实现；等实测安装验证通过后再排期。

## 订阅运行方式

- `/sub/` 是普通用户入口：先刷新当前 3X-UI 入站链接，再自动生成 Clash 3.5 短订阅。
- 直连订阅地址为 `/subscriptions/<SUBSCRIPTION_TOKEN>.b64`，令牌只保存在服务器 `.env` 文件中。
- 域名节点模式会把每一组完整生成的链接映射回 `SERVER_ALIASES`，不得再次展开已分组列表；十域名、双协议部署应发布 20 个节点，而不是 200 个。
- 公共刷新接口不接收输入，并受 `PUBLIC_LINK_REFRESH_INTERVAL` 限流（默认 60 秒）；配置编辑和转发管理继续使用 `SUB_CONFIG_ADMIN_TOKEN` 保护。

## 更新与恢复

- 已安装主机更新命令：`curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh | sudo bash -s -- update`。
- 更新程序会保留 `.env`、`data/db`、`data/backups` 和 `site/sub/config/3.5.yaml`。
- 更新后依次验证：`./scripts/manage.sh refresh-links`、`docker compose ps`，以及客户端能否下载生成的短订阅。

## 亚马逊住宅 IP 强制全局命令

- 独立一键入口：`curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh | sudo bash -s -- amazon-global`。
- 新主机会安装工具包、创建受管 VLESS Reality 节点并写入专用单节点 YAML；已安装主机只刷新现有亚马逊订阅，不重装整套服务。
- `scripts/amazon-global.sh` 选择第一条生成的 VLESS Reality 链接，再由 `scripts/amazon-global.py` 确定性生成 YAML。
- 客户端必须保持 Rule 模式；亚马逊域名规则和最终 `MATCH` 规则使用同一代理组，使全部应用流量都经过目标节点，不依赖 Mihomo 的隐式 `GLOBAL` 选择器。
- DNS 使用 Fake-IP 并启用 `respect-rules: true`；禁用 IPv6；Android 混合 TUN 使用 MTU 1400，并从 TUN 路由中排除代理端点 IP。
- 启用 `ENABLE_AMAZON_GLOBAL=1` 后，协调与安全更新流程会保留并刷新该订阅。

## Reality 客户端兼容性

- 除非所有客户端均确认支持较新的 Xray Reality ClientHello，否则保持 `REALITY_MIN_CLIENT_VERSION=1.8.2`。Xray 26.7.11 及更高版本的默认最低版本可能导致现有 Clash/Mihomo 客户端连接失败。
- `scripts/apply-presets.sh` 会为新 Reality 入站写入该值，并仅更新现有 `auto-vless-reality-*` 入站的 `streamSettings.realitySettings.minClientVer`；客户端 UUID、Reality 密钥、短 ID、端口和订阅地址均保持不变。
- 安全更新会执行协调流程，因此现有部署在更新后也会自动获得该兼容性修复。

## 敏感交接记录

- 不得把真实凭据提交到 GitHub。每台部署主机的面板账号、订阅令牌、亚马逊全局令牌和源 VLESS 链接、规则编辑令牌、API 令牌、VPS 登录密码、RustDesk 设备 ID、公钥、密码可用性说明和备份位置，统一记录到 `/opt/3xui-selfhost-kit/runtime/install-summary.txt`、`/opt/3xui-selfhost-kit/runtime/amazon-global.txt` 及 `/opt/3xui-selfhost-kit/.env`。
- 含凭据文件必须归 root 所有并保持 `600` 权限；每次凭据或端点变化后同步更新。
- RustDesk OSS 服务端数据库只保存设备 ID、设备身份公钥等注册信息，不保存客户端无人值守访问密码。密码必须在被控设备本机查看或重新设置，交接记录中不得伪造未知密码。

## RustDesk 客户端与网页端

- 原生客户端继续使用 `ID Server: 域名:21116`、`Relay Server: 域名:21117` 和服务器配置公钥；不要把网页端 WSS 路径写进原生客户端。
- `https://rustdesk.com/web/` 的 `ID Server` 只填写域名且不带端口，`API Server` 留空，并填写同一份服务器配置公钥。
- HTTPS 站点必须提供 `wss://域名/ws/id` 与 `wss://域名/ws/relay`；Caddy 分别反向代理到本机 `21118` 和 `21119`。
- 修改域名或重建 Caddy 配置后，运行 `./scripts/domain-cert.sh --auto`，再用 WebSocket Upgrade 请求确认两个路径均返回 `101 Switching Protocols`。

## 2026-08-25 RustDesk 中断诊断与修复

- 部署主机：`64.176.217.138`，Debian 13，Vultr VC2，物理内存约 458 MiB，同时承载 3x-ui/Xray、Caddy 和 RustDesk OSS。
- 诊断时 RustDesk 使用 `rustdesk/rustdesk-server:1.1.15`。`hbbs` 和 `hbbr` 当前未循环重启，TCP 21115 至 21119、UDP 21116 均已监听并由 UFW 放行。
- 当前反复中断主要发生在 `14.120.55.194` 到该美国 VPS 的跨境链路：30 次探测丢包 13.3%，RTT 约 231 ms；21117 会话存在重传、丢包和长时间 `LAST-ACK`。抓包确认客户端侧先发送 FIN，服务端没有主动踢出会话。
- 注册设备曾把 RustDesk 流量通过同一 VPS 上的 3x-ui 代理回送，导致国内设备无法优先直连并被迫绕美国中继。客户端应把 RustDesk 进程以及 `64.176.217.138/32` 的 21115 至 21119 端口设为直连；如仍需中继，应迁移到香港、日本或中国优化线路节点。
- 历史数据目录保留 `hbbs` 崩溃转储。2026-08-14 曾四次出现 `memory allocation of 488135971 bytes failed`；主机也发生过 OOM。服务端默认镜像已升级到 `rustdesk/rustdesk-server:1.1.16`，后续应把 VPS 内存提升到至少 1 GiB，建议 2 GiB。
- 设备 `1934025127` 曾出现四次 `invalid key`。如该设备仍在使用，应确认只有一个有效 RustDesk 实例使用该 ID，并在客户端重新填写本服务器配置公钥；不要复制另一台设备的 RustDesk 配置目录。
- 2026-08-25 13:35 左右 VPS 发生一次没有正常关机日志的强制重启；应在 Vultr 控制台继续核对人工操作和宿主机事件。
- 升级前备份目录、实际部署版本、容器校验结果、设备 ID、服务器配置公钥和密码说明必须继续写入部署机 `runtime/install-summary.txt`，不得写入公开仓库。
