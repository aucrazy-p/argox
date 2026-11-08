# h3-argo

Cloudflare Argo 隧道 + Xray (XHTTP) + sing-box 双核一键部署，Ubuntu / Debian。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/h3-argo/main/argox.sh)
```

下载失败换镜像：

```bash
bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/aucrazy-p/h3-argo/main/argox.sh)
```

## 注意

- root 运行，Ubuntu / Debian，ARM64 / AMD64
- 需要已托管到 Cloudflare 的域名和隧道，见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md)
- 装完按脚本提示走：订阅地址、要放行的端口都会打印出来
- 不要用 `curl ... | bash`，脚本是交互式的，管道会占掉 stdin
