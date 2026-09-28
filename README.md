# 一键安装

| 方式 | 区别 |
| --- | --- |
| 默认 | 无域名；管理入口仅限服务器本机/SSH |
| 域名 HTTPS | 自动申请证书；页面和订阅使用服务器域名 |
| 公网 IP + HTTP | 无域名；管理入口直接暴露到公网 |
| 交互安装 | 安装时逐项询问配置 |

## 默认

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh | sudo bash
```

## 域名 HTTPS

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh \
  | sudo env 'DOMAIN_NAMES=example.com,www.example.com' bash
```

## 公网 IP + HTTP

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh \
  | sudo env PUBLIC_HTTP_PANEL=1 bash
```

## 已安装服务器一键更新

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh \
  | sudo bash -s -- update
```

更新会同步脚本和订阅页面、保留已有 `.env`、数据库与 3.5.yaml 规则，然后滚动更新服务。

## 亚马逊住宅 IP 全局节点

新服务器和已经安装过本项目的服务器都使用同一条命令：

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/one-click.sh \
  | sudo bash -s -- amazon-global
```

新服务器会先完成 3x-ui 安装、自动创建 VLESS Reality 节点，再生成独立的安卓 Clash/Mihomo YAML 订阅；已安装服务器会直接创建或刷新该订阅。

这份订阅不依赖 Clash 内置的 `GLOBAL` 分组。Amazon、Seller Central、AWS、Prime Video 等域名会显式走节点，最后一条 `MATCH` 规则会让其他网页、应用和服务也全部走同一个节点。DNS 启用 Fake-IP 和规则跟随，IPv6 默认关闭，Android TUN MTU 默认是 1400。

客户端导入安装结果打印的 URL 后必须保持“规则 / Rule”模式，不要切换 Clash 自带的 Global 模式。

已安装服务器也可以直接运行：

```bash
cd /opt/3xui-selfhost-kit
sudo ./scripts/manage.sh amazon-global
```

订阅 URL 和敏感源节点保存在服务器本机的 `runtime/amazon-global.txt`，该文件权限为 600；随机订阅 token 保存在 `.env`。

## Reality 与 Clash/Mihomo 兼容

一键安装默认写入 `REALITY_MIN_CLIENT_VERSION=1.8.2`。这是为了兼容 Clash/Mihomo 的 Reality ClientHello；新版 Xray 服务端在该值留空时会采用更高的默认最低版本，表现为端口和测速正常，但 VLESS Reality 握手失败、流量一直为 0。

新安装会直接使用兼容参数；安全更新和 `./scripts/manage.sh apply-presets` 会无损修正已有的 `auto-vless-reality-*` 入站，只更新 `minClientVer`，保留 UUID、Reality 密钥、Short ID、端口和现有订阅链接。

## 交互安装

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/install.sh \
  | sudo env CONFIG_WIZARD=1 MENU_AFTER_INSTALL=1 ENABLE_SYSTEMD_AUTOSTART=1 bash
```


## IBKR 固定 VPN 连接

IBKR Desktop 的长连接不适合自动切换或负载均衡轮询。此工具生成**可选客户端配置**：IBKR 域名优先使用一个明确的 VPN 节点，DNS 通过同一节点查询可信 DoH，不设置 `DIRECT` 备用。它不修改 3x-ui 入站、账户、节点凭据或现有订阅。

在仓库目录安装已有 Python 依赖后，使用客户端里真实存在的**具体节点名称**，不要填自动选择、故障转移或负载均衡分组名称。名称不包含节点密码或订阅令牌。

```bash
python3 -m pip install -r subconfig-api/requirements.txt
python3 scripts/ibkr-vpn.py --format shadowrocket --node-name '我的固定VPN节点' --output /tmp/IBKR-Stable-Connection.sgmodule
```

将输出文件导入 Shadowrocket 模块，启用后重新应用配置，再退出并打开 IBKR。模块会覆盖 `ibllc.com`、`ibllc.com.cn`、`ibkr.com`、`ibkr.com.cn`、`interactivebrokers.com` 的域名分流和 DNS；`use-local-host-item-for-proxy` 是配置级选项，导入前需要检查其他既有 Host 映射。关闭或删除模块即可回滚。

已有 Mihomo 配置可生成一份独立副本，原文件和未知字段保留：

```bash
python3 scripts/ibkr-vpn.py --format mihomo --node-name '我的固定VPN节点' --input /安全目录/current.yaml --output /安全目录/ibkr.yaml
```

输入必须处于 Rule 模式，已启用 DNS 并配置 `proxy-server-nameserver`，且包含该具体节点。生成器拒绝 `DIRECT`、策略组、上游拨号策略和名称冲突；新增单节点 `IBKR固定VPN` 分组，并把 IBKR 规则放到原有规则之前。输出 YAML 可能包含输入中的节点凭据，权限为 `600`，不得提交、公开或粘贴到聊天。恢复原配置即可回滚。

客户端重新加载后连续检查公共端点：

```bash
python3 scripts/ibkr-network-check.py --proxy http://127.0.0.1:1082 --rounds 3
```

Mihomo 用户将端口换为实际 HTTP/mixed 代理端口。脚本只通过所指定代理探测公开 HTTPS 和交易网关端口，不进行账户登录、下单、直连备用或关闭证书校验；代理 URL 不接受凭据。输出只含主机、端口、耗时和错误类别。HTTPS `403` 表示已连接并通过证书校验，不能解释为该页面业务成功；交易端口通过也不能解释为 IBKR 已登录或行情恢复。

验收必须分别记录：配置生成、客户端导入、规则重新加载、实际节点/出口、IBKR 登录后行情刷新、连续使用是否再弹窗。域名规则不是按进程的全流量强制代理，也不是 VPN 关闭时的系统断网保护；未知域名、直接 IP 和代理客户端关闭后的流量仍需客户端/系统的应用级强制代理与阻断机制。不能把此工具宣称为“永久禁止 IBKR 直连”或“客户端卡断已经彻底修复”。

DNS 代理参数依据 [Mihomo 官方 DNS 文档](https://wiki.metacubex.one/en/config/dns/)。未改变默认安装、Amazon 全局订阅或服务部署。
