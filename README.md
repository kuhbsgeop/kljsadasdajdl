# 3x-ui Selfhost Kit

自用一键部署项目：安装最新官方 `3x-ui`，默认生成 `VLESS + REALITY` 和 `Shadowsocks 2022` 节点，并把域名证书、Trojan TLS、链式代理、伪装站点、订阅转换 Web UI 都放进一个 `x-ui` 命令行菜单里。

仓库只保存部署脚本、Compose 和配置模板，不保存 3x-ui / Xray / acme.sh / subconverter 的上游代码。安装和更新时实时拉取：

- `ghcr.io/mhsanaei/3x-ui:latest`
- `caddy:2-alpine`
- `tindy2013/subconverter:latest`
- `python:3-alpine`，用于受 token 保护的 3.5.yaml 规则编辑 API
- `https://get.acme.sh`

## 一键安装

默认交互式安装：

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/3xui-selfhost-kit/main/install.sh \
  | sudo env CONFIG_WIZARD=1 MENU_AFTER_INSTALL=1 ENABLE_SYSTEMD_AUTOSTART=1 bash
```

完整一键安装，有域名并启用 HTTPS、订阅、端口转发 Web 页面：

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/3xui-selfhost-kit/main/install.sh \
  | sudo env CONFIG_WIZARD=0 'DOMAIN_NAMES=fsdfsfsdfxcvxvg.heubhkldhuu.shop,heubhkldhuu.shop,www.heubhkldhuu.shop,newctshpm.icu,safkdsajfkajfasfdyidsf.newctshpm.icu,www.newctshpm.icu' DOMAIN_NODE_MODE=1 DOMAIN_PORT_MODE=1 RECREATE_ON_DOMAIN_UPDATE=1 ENABLE_ACME=1 ACME_SERVER=letsencrypt ACME_FALLBACK_SERVER=zerossl REQUIRE_DOMAIN_ORIGIN=1 STRICT_DOMAIN_CERT=0 USE_DOMAIN_FOR_LINKS=1 HTTPS_SITE_ENABLE=1 HTTPS_HTTP_MODE=redirect AUTO_ENABLE_TROJAN=1 ENABLE_TROJAN=1 ENABLE_PROTOCOL_GUARD=1 REQUIRE_SECURE_TRANSPORT=1 ENABLE_SUBCONVERTER=1 SUBSCRIPTION_EXPAND_ALIASES=1 XUI_BUILTIN_SUB_ENABLE=1 XUI_BUILTIN_ALL_NODES=1 MENU_AFTER_INSTALL=1 ENABLE_SYSTEMD_AUTOSTART=1 bash
```

完整一键安装，没有域名时使用公网 IP + HTTP 入口：

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/3xui-selfhost-kit/main/install.sh \
  | sudo env CONFIG_WIZARD=0 DOMAIN_NAMES= SERVER_ALIASES= PANEL_LISTEN_IP=0.0.0.0 ENABLE_ACME=0 STRICT_DOMAIN_CERT=0 USE_DOMAIN_FOR_LINKS=0 TLS_SERVER_NAME= TLS_CERT_FILE= TLS_KEY_FILE= HTTPS_SITE_ENABLE=0 HTTPS_HTTP_MODE=allow AUTO_ENABLE_TROJAN=0 ENABLE_TROJAN=0 RECREATE_ON_DOMAIN_UPDATE=1 ENABLE_SUBCONVERTER=1 SUBSCRIPTION_EXPAND_ALIASES=1 DOMAIN_NODE_MODE=1 DOMAIN_PORT_MODE=1 XUI_BUILTIN_SUB_ENABLE=1 XUI_BUILTIN_ALL_NODES=1 MENU_AFTER_INSTALL=1 ENABLE_SYSTEMD_AUTOSTART=1 bash
```

无域名模式会自动检测公网 IP 并写入 `SERVER_ADDR`。如果服务器检测到的 IP 不对，可以在命令中额外加上 `SERVER_ADDR=你的服务器公网IP`。
上面的公网 HTTP 命令会把面板监听改成 `0.0.0.0`，并自动放行安装摘要里显示的随机面板端口。安装完成后直接打开 `http://公网IP:面板端口/随机路径/`。

上面两条完整命令都可以用于覆盖安装：已有 `.env` 时不会重置面板账号、密码和数据库，但会把命令里显式传入的域名、HTTPS、订阅参数写回 `.env`，然后按当前模式刷新 Caddy、刷新 `/sub/`、`/forward/` 和 3X-UI 内置 `all-nodes` 订阅。

如果之前按“无域名公网 IP + HTTP 入口”安装，现在补域名切到 HTTPS，直接运行有域名命令即可。脚本会自动过滤旧的 IP 别名，重建脚本自动管理的域名节点，去掉旧的 IP/HTTP 分享节点，重新生成 `https://域名/...` 的面板、订阅和域名节点；手动创建的入站不会按 remark 自动删除。

如果已经是域名 HTTPS 模式，后续再增加域名，只需要把新域名写进 `DOMAIN_NAMES` 重新运行有域名命令。脚本会把旧域名和新域名合并去重，并把所有已激活域名的自动节点重新生成一遍；某个域名 DNS/证书失败时会跳过它继续执行，失败域名会留在 `PENDING_DOMAIN_NAMES`。

通过菜单 `sudo x-ui` -> `10. 管理 Acme 申请域名证书` 补域名也会执行同样的迁移逻辑：只需要输入新增域名或完整域名列表，后面的 HTTPS、Trojan TLS、协议守护、全量重建都会自动执行；旧 IP/HTTP 自动节点会被清理，自动节点的分享地址会切到域名。

如果补域名后 HTTPS 标红，通常是新域名还没有被当前证书覆盖，常见原因是 DNS 没解析到本机、Cloudflare 开了橙云代理、80/443 没放行，或证书申请时只签到了部分域名。脚本会先检查证书覆盖范围：未覆盖的新域名会暂存为 `PENDING_DOMAIN_NAMES`，不会写入 HTTPS 面板地址和自动节点，避免生成红锁节点；修好 DNS/端口后重新运行菜单 10 或有域名命令即可追加。

默认 `DOMAIN_PORT_MODE=1`：每个域名会使用不同端口建立独立安全节点。启用 HTTPS 站点时，VLESS Reality 默认从 `8443` 开始，Trojan WS TLS 默认从 `9443` 开始，然后按域名顺序递增，例如 VLESS `8443,8444,8445...`，Trojan `9443,9444,9445...`。可以用 `DOMAIN_PORT_START=端口` 和 `DOMAIN_PORT_STEP=步长` 自定义 VLESS 起始端口和递增步长，Trojan 起始端口使用 `TROJAN_PORT`。

多个域名、多个前缀都写进 `DOMAIN_NAMES`，例如：

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/3xui-selfhost-kit/main/install.sh \
  | sudo env \
      CONFIG_WIZARD=0 \
      'DOMAIN_NAMES=example.com,www.example.com,a.example.com,b.example.com' \
      DOMAIN_NODE_MODE=1 \
      DOMAIN_PORT_MODE=1 \
      RECREATE_ON_DOMAIN_UPDATE=1 \
      ENABLE_ACME=1 \
      ACME_SERVER=letsencrypt \
      ACME_FALLBACK_SERVER=zerossl \
      REQUIRE_DOMAIN_ORIGIN=1 \
      STRICT_DOMAIN_CERT=0 \
      USE_DOMAIN_FOR_LINKS=1 \
      HTTPS_SITE_ENABLE=1 \
      HTTPS_HTTP_MODE=redirect \
      AUTO_ENABLE_TROJAN=1 \
      ENABLE_TROJAN=1 \
      ENABLE_PROTOCOL_GUARD=1 \
      REQUIRE_SECURE_TRANSPORT=1 \
      ENABLE_SUBCONVERTER=1 \
      SUBSCRIPTION_EXPAND_ALIASES=1 \
      XUI_BUILTIN_SUB_ENABLE=1 \
      XUI_BUILTIN_ALL_NODES=1 \
      MENU_AFTER_INSTALL=1 \
      ENABLE_SYSTEMD_AUTOSTART=1 \
      bash
```

注意：`DOMAIN_NAMES=...` 必须作为一个完整参数传给 `env`。长域名列表请放在引号里，不要把逗号开头的下一段单独换到新行，否则 Shell 会把下一行当作命令执行。

如果不小心少写了逗号，例如把 `a.example.com,www.example.com` 写成 `a.example.com.www.example.com`，脚本会尽量自动拆成两个域名，避免后面的 `www`、`api`、`sub` 等前缀被当作一个不存在的长域名跳过。但仍建议手动用逗号分隔每个域名，避免 DNS 和证书结果不符合预期。

脚本会把这些域名写入 Caddy HTTPS 站点和 `SERVER_ALIASES`。申请证书前会先检查 DNS；开启 `STRICT_DOMAIN_CERT=1` 时，所有域名必须都签进同一张证书，否则安装直接失败，避免只配置好一部分域名。默认命令使用 `STRICT_DOMAIN_CERT=0`，会跳过 DNS/证书失败的域名继续执行，未覆盖的域名先放入 `PENDING_DOMAIN_NAMES`，避免 HTTPS 红锁。默认 `REQUIRE_DOMAIN_ORIGIN=1`，只有 A/AAAA 解析到本 VPS 公网 IP 的域名才会激活节点；Cloudflare 橙云或解析到其他 IP 的域名会被跳过，修好 DNS 后再跑菜单 10。默认 `ACME_SERVER=letsencrypt`、`ACME_FALLBACK_SERVER=zerossl`，遇到 Let’s Encrypt 临时 `serverInternal/overloaded` 会尝试备用 CA；如果所有 CA 都失败，会保留 pending，稍后重新运行菜单 10。默认 `DOMAIN_NODE_MODE=1` 且 `DOMAIN_PORT_MODE=1`，安装时传入几个已激活域名，就会为每个域名创建一个不同端口的 VLESS REALITY 入站节点和一个不同端口的 Trojan WS TLS 入站节点，并把这些域名节点同步到 3X-UI 内置 all-nodes 订阅。

如果某个前缀后续补好了 DNS，运行下面任一命令即可把它追加进证书：

```bash
sudo x-ui
# 选择 10 或 16
```

只要提供了 `DOMAIN_NAMES`，安装脚本会自动：

- 用第一个域名作为面板、节点和订阅显示地址
- 申请 Let's Encrypt 证书并启用自动续期
- 启用 443 HTTPS 伪装站点
- 将 HTTP 80 自动 308 跳转到 HTTPS
- 将面板和 3X-UI 内置订阅服务改为本机监听，再由 Caddy 通过 HTTPS 随机路径反代

使用默认交互式安装时会进入配置向导。直接回车即可使用安全默认值；也可以输入一个或多个域名，例如：

```text
heubhkldhuu.shop,www.heubhkldhuu.shop
```

安装完成会在命令行直接显示：

- 面板公网显示地址、监听 IP、端口和随机路径
- 面板用户名和密码
- 面板直接访问地址
- VLESS REALITY、Shadowsocks、Trojan 等节点链接文件
- 域名、证书、HTTPS/HTTP 模式
- 订阅转换 Web UI 地址
- 开机自启动状态

之后 SSH 登录服务器，直接输入：

```bash
sudo x-ui
```

也可以用：

```bash
sudo 3xui-kit
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh status
sudo ./scripts/manage.sh links
sudo x-ui forward 27677 127.0.0.1 9999 tcp 0.0.0.0
```

如果想按提示一步步填，直接运行 `sudo x-ui`，选择：

```text
19. 打开端口转发 Web 页面【自动填Token】
```

## 默认功能

默认自动部署：

- 最新官方 3x-ui Docker 镜像
- 随机面板用户名、密码、API token、根路径
- `VLESS + TCP/Raw + XTLS Vision + REALITY`
- `Shadowsocks 2022`
- 80 端口普通伪装页面
- 订阅转换 Web UI：`/sub/`
- 端口转发 Web UI：`/forward/`，用当前服务器域名和端口访问其他域名/IP 的端口
- 3X-UI 内置订阅服务的 HTTPS 反代 URI，避免面板导出 `http://:2096` 链接
- 安全协议守护：默认禁用 `vmess/http/mixed/mtproto/tun` 入站，保留 `vless/trojan/shadowsocks/wireguard/hysteria/tunnel`；域名 HTTPS 模式默认启用 `REQUIRE_SECURE_TRANSPORT=1`，会继续禁用没有 `tls` 或 `reality` 传输安全的旧入站
- `dokodemo-door` 转发预设；在 3X-UI 官方面板中协议名显示为 `tunnel`
- `3.5.yaml` 规则配置 Web 编辑器，使用安装时生成的编辑 token
- Web 一键刷新全部 3X-UI 入站链接，并用本地 `3.5.yaml` 渲染 Clash 订阅
- Docker `restart: unless-stopped`
- systemd 自启动服务：`3xui-kit.service`

默认会开放/提示这些基础端口：

- `22/tcp`
- `80/tcp`
- `443/tcp`
- `8388/tcp,udp`，默认 Shadowsocks 2022 使用

如果启用 Trojan、Hysteria2 或 HTTPS 站点，脚本会继续放行对应端口。

## 面板访问

有域名完整安装会启用 HTTPS 站点，面板直接通过第一个域名和随机路径打开：

```text
https://your.domain/随机路径/
```

无域名公网 IP + HTTP 入口命令会把面板监听改成 `0.0.0.0`，面板直接通过公网 IP、随机端口和随机路径打开：

```text
http://your.server.ip:面板端口/随机路径/
```

默认交互式安装如果选择安全本机模式，面板会绑定 `127.0.0.1`，公网不能直接打开。要改成公网 IP 直连，可以在菜单里修改监听 IP 为 `0.0.0.0`，或重新运行无域名公网 HTTP 命令覆盖安装。


## 域名与 HTTPS

在 `sudo x-ui` 菜单里选择：

```text
10. 管理 Acme 申请域名证书
```

每一个要访问的前缀都必须有 DNS 记录并写进 `DOMAIN_NAMES`，例如 `www.example.com`、`a.example.com`。如果只写 `example.com`，证书不会自动覆盖 `www` 或其他前缀。除非你自行配置 DNS API 申请通配符证书，否则本项目默认使用 HTTP-01，按域名逐个申请证书。

IPv6 也支持，但 VPS 必须真的有公网 IPv6，并且每个域名/前缀都要添加 AAAA 记录。检查命令：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh network-check
```

如果域名套了 Cloudflare 橙云代理，网页可能能打开，但 VLESS/Trojan/Shadowsocks 这类非 HTTP 代理协议通常会失败。节点域名建议保持 DNS-only。

输入一个或多个域名后，脚本会：

- 用官方 acme.sh 申请 Let's Encrypt 证书
- 写入 3x-ui 容器可读证书路径
- 自动续期
- 自动把 `SERVER_ADDR`、面板显示地址、节点分享地址和订阅地址切到第一个域名
- 可选自动启用 Trojan TLS 节点
- 可选启用 443 HTTPS 伪装站点
- 自动显示域名、IP、证书路径、面板路径和订阅转换入口
- 自动刷新 Caddy 反代，让 3X-UI 面板导出的订阅链接变成 `https://域名/随机路径/<subId>`

安全策略：

- 如果启用 443 HTTPS 伪装站点，HTTP 80 只做 308 跳转到 HTTPS。
- 如果只申请证书、不启用 HTTPS 站点，证书成功后 HTTP 80 默认返回 403，不继续提供明文页面。
- 如果 443 被 HTTPS 站点占用，脚本会把自动生成的 VLESS REALITY 从 `443/tcp` 移到 `8443/tcp`，并重建脚本生成的 `auto-*` 入站。
- 3X-UI 内置订阅端口默认绑定 `127.0.0.1:2096`，公网不能直接访问；公网只走 HTTPS 反代随机路径。

## 订阅转换

安装脚本默认启用本机 subconverter，并生成 Web UI：

```text
http://your.server/sub/
```

启用 HTTPS 站点后变成：

```text
https://your.domain/sub/
```

Web UI 会默认读取本机 token 化订阅：

```text
/subscriptions/<token>.txt
```

同时会生成给 subconverter 使用的 Base64 订阅：

```text
/subscriptions/<token>.b64
```

支持转换为 Clash、sing-box、V2Ray、Surge、Quantumult X 等格式，默认规则配置使用本机内置的 `3.5.yaml`：

```text
https://your.domain/sub/config/3.5.yaml
```

仓库内置的 `site/sub/config/3.5.yaml` 来自你的默认分流模板，但已经去掉真实服务器、UUID、密码等敏感值。节点名称保持原样，例如 `测试3ip`、`测试4域名`、`测试5V6`、`测试6域名`、`测试10域名`，这样下面的分流组引用不会断。你可以在 `/sub/` 页面把“规则配置”改成其他 URL，并点“保存为默认”保存在浏览器里。

如果要直接修改服务器上的规则，在 `/sub/` 页面下方的 `3.5.yaml 规则` 区域输入安装摘要里显示的 `Rules editor token`，然后读取、编辑、保存。保存后转换链接仍然使用：

```text
https://your.domain/sub/config/3.5.yaml
```

也就是你的订阅转换会继续按这份 `3.5.yaml` 的分流规则生成配置。

最推荐给 Clash 使用的是这个渲染后的订阅链接，它会读取当前 all-nodes 节点，再把节点参数填入 `3.5.yaml` 的 `proxies:`，并保留原来的节点名称和下面所有分流规则。默认 `DOMAIN_NODE_MODE=1` 且 `DOMAIN_PORT_MODE=1` 时，安装传入几个域名就创建几个不同端口的 VLESS REALITY 域名节点；如果节点数量超过模板里的默认名称，会自动追加 `@域名` 并同步写入自动选择、故障转移、负载均衡等分组：

```text
https://your.domain/subconfig-api/render/clash?token=<token>
```

重新生成订阅页：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh subscription
```

## 协议和链式代理

重新套用默认节点：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh apply-presets
```

启用 Trojan TLS：

```bash
sudo ENABLE_TROJAN=1 TLS_CERT_FILE=/root/cert/domains/fullchain.pem TLS_KEY_FILE=/root/cert/domains/privkey.pem ./scripts/apply-presets.sh
```

添加 SOCKS 链式出口：

```bash
sudo CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=socks CHAIN_ADDRESS=1.2.3.4 CHAIN_PORT=1080 ./scripts/apply-presets.sh
```

添加 Trojan 链式出口：

```bash
sudo CHAIN_ENABLED=1 CHAIN_MODE=all CHAIN_TYPE=trojan CHAIN_ADDRESS=upstream.example.com CHAIN_PORT=443 CHAIN_PASS=trojan-password CHAIN_SERVER_NAME=upstream.example.com ./scripts/apply-presets.sh
```

`CHAIN_MODE=all` 会把流量路由到链式出口；`CHAIN_MODE=manual` 只添加出口，不自动改默认路由。

添加 dokodemo-door 转发入站：

Web 页面方式：

```text
https://你的域名/forward/
```

页面使用安装摘要里的 `Rules editor token` 作为管理 Token，可以创建多个节点：`当前服务器域名:外部端口 -> 目标域名:目标端口`。

命令行菜单里选择“打开端口转发 Web 页面【自动填Token】”后，会自动给出并尝试打开带 Token 的 `/forward/#token=...` 链接。页面读取 Token 后会写入当前浏览器，并立即清理地址栏里的 Token。

如果忘记 Token，可以在服务器上查看：

```bash
cd /opt/3xui-selfhost-kit
sudo awk -F= '/^SUB_CONFIG_ADMIN_TOKEN=/{print $2}' .env
```

命令行方式：

```bash
sudo x-ui forward 27677 127.0.0.1 9999 tcp 0.0.0.0
```

参数顺序是：`监听端口 目标地址 目标端口 网络 监听IP`。如果只运行 `sudo x-ui forward`，脚本会在命令框里逐项询问。3X-UI 官方面板里这个协议显示为 `tunnel`，它对应 Xray 的 dokodemo-door 风格转发器。

也可以直接用环境变量方式添加：

```bash
sudo ENABLE_DOKODEMO=1 \
  DOKODEMO_LISTEN=127.0.0.1 \
  DOKODEMO_PORT=18080 \
  DOKODEMO_TARGET_ADDRESS=127.0.0.1 \
  DOKODEMO_TARGET_PORT=80 \
  DOKODEMO_NETWORK=tcp \
  ./scripts/apply-presets.sh
```

说明：3X-UI 官方面板里这个协议显示为 `tunnel`，它对应 Xray 的 dokodemo-door 风格转发器。为了安全，默认监听 `127.0.0.1`；如果确实要公网转发，再把 `DOKODEMO_LISTEN` 改成 `0.0.0.0` 并确认 VPS 防火墙只开放必要端口。

一键安装/覆盖安装时也可以直接带上转发参数，已有 `.env` 时这些 `DOKODEMO_*` 参数会被写回：

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/3xui-selfhost-kit/main/install.sh \
  | sudo env CONFIG_WIZARD=0 ENABLE_DOKODEMO=1 DOKODEMO_LISTEN=0.0.0.0 DOKODEMO_PORT=27677 DOKODEMO_TARGET_ADDRESS=127.0.0.1 DOKODEMO_TARGET_PORT=9999 DOKODEMO_NETWORK=tcp MENU_AFTER_INSTALL=1 bash
```

如果要一键生成多个转发节点，使用 `DOKODEMO_FORWARDS`，每个节点格式是 `外部端口,目标域名或IP,目标端口,协议,监听IP`，多个节点用英文分号分隔：

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/3xui-selfhost-kit/main/install.sh \
  | sudo env CONFIG_WIZARD=0 \
      'DOKODEMO_FORWARDS=27677,api.example.com,9999,tcp,0.0.0.0;27678,pay.example.net,443,tcp,0.0.0.0' \
      MENU_AFTER_INSTALL=1 \
      bash
```

禁用不安全入站协议：

```bash
sudo ./scripts/manage.sh protocol-guard
```

默认允许列表是 `vless,trojan,shadowsocks,wireguard,hysteria,tunnel`。默认动作是禁用，不删除。域名 HTTPS 模式会设置 `REQUIRE_SECURE_TRANSPORT=1`，只保留带 `tls` 或 `reality` 传输安全的入站；如果要删除不安全入站：

```bash
sudo PROTOCOL_GUARD_ACTION=delete ./scripts/protocol-guard.sh
```

## 更新

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh update
```

如果已经打开了 `/forward/` 页面但保存显示 `Not found`，说明页面已更新、后台 `subconfig-api` 还在跑旧进程。执行下面命令补更新并重建接口服务：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh update
sudo docker compose up -d --force-recreate subconfig-api
```

这会先备份本地数据库和 `.env`，然后在后台拉取最新官方 3x-ui 镜像，并自动运行：

- 本仓库脚本、Web 页面和配置模板同步
- 面板端口/路径/监听 IP 恢复
- 域名 HTTPS/Caddy 恢复
- VLESS/Trojan/Shadowsocks/dokodemo 预设幂等检查
- 不安全协议守护
- `/sub/` 订阅和 `3.5.yaml` 渲染刷新
- 3X-UI 内置订阅 HTTPS URI 修复

如果当前服务器还是很旧的脚本，出现 `set_env_var: command not found`，先用下面命令补一次仓库脚本；它会保留已有 `.env`、面板账号、密码和数据库：

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/3xui-selfhost-kit/main/install.sh \
  | sudo env CONFIG_WIZARD=0 MENU_AFTER_INSTALL=0 ENABLE_SYSTEMD_AUTOSTART=1 bash
```

如果官方版本升级导致 API 暂时不兼容，脚本不会覆盖你的数据库备份；查看日志：

```bash
tail -f /opt/3xui-selfhost-kit/runtime/safe-update.log
sudo ./scripts/manage.sh reconcile
```

严格来说，任何第三方官方项目的未来破坏性更新都无法“数学保证永不失效”，但本项目把所有自定义配置放在 `.env`、脚本、Caddy、订阅 API 里，更新后会自动重放配置，并保留更新前备份用于回滚。

## 全部入站订阅

Web 入口：

```text
https://your.domain/sub/
```

在页面输入“规则编辑 Token”，点击“刷新全部入站链接”，会从 3X-UI 读取 all-nodes 订阅客户端。默认 `DOMAIN_NODE_MODE=1` 且 `DOMAIN_PORT_MODE=1` 时，会把这些客户端按 `SERVER_ALIASES` 一对一映射成多个域名 + 不同端口节点。`dokodemo-door/tunnel` 是转发入站，没有客户端订阅 URL。

命令行刷新：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh refresh-links
```

## 3X-UI 内置订阅路径

3X-UI 官方内置订阅的有效格式是“随机前缀 + subId”。例如 `/xui-sub-xxxx/<subId>` 才是可用订阅；只打开 `/xui-sub-xxxx/` 没有客户端上下文，官方服务会返回 404。

本项目会把基础路径自动跳转到 `/sub/`。默认 `XUI_BUILTIN_ALL_NODES=1` 且 `DOMAIN_NODE_MODE=1` 时，会把自动生成的 `domain-node:*` 客户端同步到同一个 `ALL_NODES_SUB_ID`，因此 `runtime/xui-builtin-sub-links.txt` 里的 `all-nodes` 链接会按安装时传入的域名数量生成节点。新增或重建默认域名节点后运行 `sudo ./scripts/manage.sh refresh-links` 即可刷新 `/sub/` 和 3X-UI 内置全量订阅。

## 常用命令

```bash
sudo x-ui
sudo 3xui-kit
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh status
sudo ./scripts/manage.sh links
sudo ./scripts/manage.sh logs
sudo ./scripts/manage.sh backup
sudo ./scripts/manage.sh autostart
sudo ./scripts/manage.sh domain
sudo ./scripts/manage.sh subscription
sudo ./scripts/manage.sh xui-subscription
sudo ./scripts/manage.sh refresh-links
sudo ./scripts/manage.sh reconcile
sudo ./scripts/manage.sh network-check
sudo ./scripts/manage.sh mask-site
sudo ./scripts/manage.sh protocol-guard
```

请只在你有合法授权的服务器和网络环境里使用。
