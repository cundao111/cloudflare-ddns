# Cloudflare DDNS

------------------------------------------------

更新内容：

1:更新DDNS对应服务器重启，DDNS服务不自启动的问题


------------------------------------------------

## 一键安装并启动

在服务器上直接执行下面整行命令：

```bash
sudo mkdir -p /opt/cloudflare-ddns && sudo curl -fsSL https://raw.githubusercontent.com/cundao111/cloudflare-ddns/main/cloudflare-ddns.sh -o /opt/cloudflare-ddns/cloudflare-ddns.sh && sudo chmod +x /opt/cloudflare-ddns/cloudflare-ddns.sh && sudo /opt/cloudflare-ddns/cloudflare-ddns.sh
```

首次启动时，按提示输入 Cloudflare API Token、需要更新的域名，以及可选的 Telegram 通知信息。

## 常用命令

### 查看运行状态

```bash
sudo /opt/cloudflare-ddns/cloudflare-ddns.sh --status
```

### 停止服务

```bash
sudo /opt/cloudflare-ddns/cloudflare-ddns.sh --stop
```

### 查看实时日志

```bash
sudo tail -f /var/log/cloudflare-ddns.log
```
