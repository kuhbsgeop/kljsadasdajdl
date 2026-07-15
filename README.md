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

## 交互安装

```bash
curl -fsSL https://raw.githubusercontent.com/kuhbsgeop/kljsadasdajdl/main/install.sh \
  | sudo env CONFIG_WIZARD=1 MENU_AFTER_INSTALL=1 ENABLE_SYSTEMD_AUTOSTART=1 bash
```
