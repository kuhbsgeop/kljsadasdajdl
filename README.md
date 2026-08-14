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
