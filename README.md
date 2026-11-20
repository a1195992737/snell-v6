# Snell v6 一键安装脚本

适用于 Debian / Ubuntu / Alpine Linux 的 Snell v6 服务端一键部署脚本（支持 `x86_64` 与 `aarch64` 架构）。

## 一键安装

**Debian / Ubuntu / RHEL 系：**
```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/a1195992737/snell-v6/main/snell.sh](https://raw.githubusercontent.com/a1195992737/snell-v6/main/snell.sh))

**Alpine Linux：**
```bash
apk add --no-cache bash curl ca-certificates && bash <(curl -fsSL [https://raw.githubusercontent.com/a1195992737/snell-v6/main/snell.sh](https://raw.githubusercontent.com/a1195992737/snell-v6/main/snell.sh))
