# h3-argo

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/h3-argo/main/argox.sh)
```

下载失败换镜像：

```bash
bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/aucrazy-p/h3-argo/main/argox.sh)
```

先看代码再运行：

```bash
curl -fsSL -o /root/argox.sh https://raw.githubusercontent.com/aucrazy-p/h3-argo/main/argox.sh
bash /root/argox.sh
```

> 不要用 `curl ... | bash`，脚本是交互式的，管道会占掉 stdin。

## 前置条件

- root 权限，Ubuntu / Debian 系
- ARM64 或 AMD64（自动识别）
- 域名已托管 Cloudflare，并已创建隧道，见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md)
- 8001 / 8002 / 8099 端口空闲；仅监听本机，不开放任何公网端口，不占用 443
- VPS 能**出站**访问 `7844`（cloudflared 隧道端口，UDP + TCP）；出站被封时隧道进程在跑但永远注册不上

## 菜单

```
 1) 安装 / 重新部署        9) 系统优化
 2) 启动                  10) 清理缓存
 3) 停止                  11) 备份配置
 4) 重启                  12) 卸载
 5) 查看状态              13) 隧道设置
 6) 查看日志              14) 优选 IP 源（链接 / 运营商）
 7) 更新到最新版          15) 订阅地址
 8) 更换 UUID             16) 出口跳板
```

## 订阅

安装后菜单 15 输出订阅地址：

```
https://<订阅子域>/<订阅令牌>
```

默认输出 3 个节点（`domain` 模式）：H3 主力 / H2 兜底 / WS 兜底，地址都写域名，由客户端自行解析到最近的 CF 节点。

需要按 IP 展开时，菜单 13 → `6) 节点地址模式` 切成 `ip`，再菜单 14 导入优选 IP。

## 出口跳板

VPS 上另装了住宅 IP / 商业 VPN 客户端，并提供了本地 SOCKS5 或 HTTP 代理端口时，可让目标站看到代理的出口 IP：

```bash
bash argox.sh hop          # 状态 + 开关菜单
bash argox.sh hop on       # 全部流量走跳板（自动识别 socks / http）
bash argox.sh hop on http  # 强制用 HTTP CONNECT
bash argox.sh hop off      # 关闭，回到 VPS 原生出口
```

默认关闭。只需在 VPS 本机监听（如 `127.0.0.1:7928`），不用开放任何公网端口。
代理挂了会自动拒绝切换；切换后 Xray 起不来会自动回滚到原状态。

## 命令行

```bash
bash argox.sh status
bash argox.sh nodes      # 订阅地址 + 二维码
bash argox.sh links      # 单节点链接
bash argox.sh sub        # Base64 订阅内容
bash argox.sh ips
bash argox.sh hop on     # 出口跳板（off / on [socks|http]）
bash argox.sh diag       # cloudflared 出站诊断（DNS / TCP 7844 / 注册情况）
bash argox.sh diag http2 # UDP 7844 被封时强制走 TCP
bash argox.sh restart
bash argox.sh uninstall
```

## 相关文档

- [docs/cloudflare-setup.md](docs/cloudflare-setup.md) — 隧道创建、Token、HTTP/3
- [docs/design.md](docs/design.md) — 设计文档
