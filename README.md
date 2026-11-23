# Cloudflare DDNS

## 一键启动

在脚本所在目录执行：

```bash
chmod +x cloudflare-ddns.sh && sudo ./cloudflare-ddns.sh
```

首次启动时，按提示输入 Cloudflare API Token、需要更新的域名，以及可选的 Telegram 通知信息。

## 常用命令

### 查看运行状态

```bash
sudo ./cloudflare-ddns.sh --status
```

### 停止服务

```bash
sudo ./cloudflare-ddns.sh --stop
```

### 查看实时日志

```bash
sudo tail -f /var/log/cloudflare-ddns.log
```
