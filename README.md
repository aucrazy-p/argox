# argox

Cloudflare Argo 隧道 + Xray (XHTTP) + sing-box 双核一键部署，Ubuntu / Debian。

## 安装

```bash
curl -fsSL -o ~/argox.sh https://raw.githubusercontent.com/aucrazy-p/argox/main/argox.sh && bash ~/argox.sh
```

首次拉脚本失败时换镜像（只替换中间那段地址）：

```bash
curl -fsSL -o ~/argox.sh https://ghfast.top/https://raw.githubusercontent.com/aucrazy-p/argox/main/argox.sh && bash ~/argox.sh
```

脚本运行期间的 GitHub 下载（Xray / cloudflared / sing-box）会自动探测可用源并缓存到
`/opt/argox/gh_proxy`，删掉该文件即重新选源。

## 注意

- root 运行，Ubuntu / Debian，ARM64 / AMD64
- 需要已托管到 Cloudflare 的域名和隧道，见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md)
- 装完按脚本提示走：订阅地址、要放行的端口都会打印出来
- 以后进菜单直接敲 `argox`（装完自动生成，不用记路径）
