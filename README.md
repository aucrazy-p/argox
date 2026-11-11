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

## 更新

**脚本自身**（GitHub 上改了 `argox.sh`）——菜单 10，或命令行：

```bash
argox selfupdate
```

这是联网更新：拉取最新脚本覆盖 `/root/argox.sh`（命令入口写死指向这个路径，
curl 到别的文件名不生效），校验通过后自动跑 `upgrade` 同步 `node.json` 字段、
systemd 单元和订阅服务。因为每次都自动同步配置，菜单不再单列「升级配置」一项。
手工等价两步：

```bash
curl -fsSL -o /root/argox.sh https://raw.githubusercontent.com/aucrazy-p/argox/main/argox.sh
argox upgrade          # 不联网，只同步配置
```

**内核程序**（Xray / cloudflared / sing-box 三个二进制）——菜单 7，或 `argox update`。
不含 Linux 内核、脚本自身、配置与订阅服务。sing-box 版本跟随脚本内置 `SB_VER_DEFAULT`，
可用 `SB_VER=1.x.y argox update` 指定。

换脚本后若改过 Xray 配置或 systemd 单元，再跑一次 `argox restart`（菜单 4）。

## 注意

- root 运行，Ubuntu / Debian，ARM64 / AMD64
- 需要已托管到 Cloudflare 的域名和隧道，见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md)
- 装完按脚本提示走：订阅地址、要放行的端口都会打印出来
- 以后进菜单直接敲 `argox`（装完自动生成，不用记路径）
