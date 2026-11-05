# h3-argo

把 Cloudflare 边缘当成你的入口，用 **Argo 隧道 + XHTTP/H3** 绕开跨境链路上的绕路与丢包。

适合这种场景：VPS 在海外，但你的宽带国际出口绕路（比如移动 CMI 经美国 PCCW 中转到日本，RTT 250ms），晚高峰丢包 20%+，TCP 协议直接躺平。

```
客户端 (karing / v2rayN / Clash Meta)
   │  优选 IP:443，SNI = 你的隧道域名，H2 或 H3
   ▼
Cloudflare 边缘（Anycast 就近接入）
   │  QUIC 隧道，走 CF 内网，不经公网 transit
   ▼
cloudflared ──► Xray (XHTTP / WS) ──► 目标站点
```

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/aucrazy-p/h3-argo/main/argox.sh)
```

> 用进程替换而不是 `curl | bash`。这个脚本是**交互式**的（要问你域名、Token、是否测速），管道会把 stdin 占掉，`read` 全部失效。

下载失败就换镜像：

```bash
bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/aucrazy-p/h3-argo/main/argox.sh)
```

想先看代码再跑（推荐）：

```bash
curl -fsSL -o /root/argox.sh https://raw.githubusercontent.com/aucrazy-p/h3-argo/main/argox.sh
less /root/argox.sh
bash /root/argox.sh
```

跑起来先进菜单，选 `1` 开始安装。

## 前置条件

| 项 | 要求 |
|---|---|
| 系统 | Ubuntu / Debian 兼容发行版 |
| 架构 | ARM64 或 AMD64（自动识别） |
| 权限 | root |
| 域名 | 已托管 Cloudflare |
| CF 隧道 | **需要你自己在 Dashboard 建**，见 [docs/cloudflare-setup.md](docs/cloudflare-setup.md) |
| 端口 | 8001 / 8002 空闲，443 **不占用** |

安装过程会依次问你：隧道域名 → 是否现在粘贴 Token → 是否测速优选 IP。都可以跳过，之后在菜单里补。

## 菜单

```
 1) 安装 / 重新部署           9) 更换 UUID（用户名/密码）
 2) 启动                     10) 更换访问方式（对外 / 仅本机）
 3) 停止                     11) 系统优化（BBR / 重启 / 日志 / 防火墙）
 4) 重启                     12) 清理缓存
 5) 查看状态                 13) 备份配置
 6) 查看日志                 14) 卸载
 7) 更新到最新版             15) 隧道设置（Token / 域名 / 测试）
 8) 更换端口                 16) 更新优选 IP
                             17) 显示节点 / 二维码
```

也支持非交互调用：

```bash
bash argox.sh status      # 查看状态
bash argox.sh nodes       # 打印节点链接 + 二维码
bash argox.sh ips         # 重新测速优选 IP
bash argox.sh restart
bash argox.sh uninstall
```

## 安装后得到 4 个节点

| 节点 | 传输 | 什么时候用 |
|---|---|---|
| `argox-XHTTP-H2` | XHTTP over TCP | **默认主力**，兼容性最好 |
| `argox-XHTTP-H3` | XHTTP over QUIC | 晚高峰掉速时切；需 CF 后台开 HTTP/3 |
| `argox-WS` | WebSocket | 客户端不支持 XHTTP 时的兜底 |
| `argox-DIRECT` | WS + TLS（自签） | CF 出问题时直连 VPS |

导入方式：karing / v2rayN 从剪贴板导入，或菜单 `17` 出二维码扫码。
订阅文件在 `/opt/argox/sub/argox.txt`，Base64 版在 `argox.b64`。

**为什么给两条 H2/H3**：移动等运营商对 UDP 的 QoS 有时比 TCP 更狠，H3 不一定更快。留两条你自己 A/B，别只信理论。

## 端口占用

| 端口 | 用途 | 说明 |
|---|---|---|
| 443 | — | **不碰**，留给已有服务（1panel / Nginx） |
| 8001 / 8002 | Argo 隧道回源 | 只监听 `127.0.0.1` |
| 8443 | 直连备用 | 被占用时自动顺延到 8543 |

## 不覆盖你已有的环境

| 项 | 处理 |
|---|---|
| 已有的 `xray.service` / `/etc/xray` | **不动**。本项目的服务名是 `argox-xray`，配置在 `/opt/argox/` |
| 443 端口 | 完全不用 |
| cloudflared | 装在 `/usr/local/bin/cloudflared`，卸载时保留 |
| 系统 sysctl | 只加 BBR/fq/文件句柄，不改已有项 |

## 优选 IP

三种来源：

1. **自动测速** —— 内置 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)，测 443 端口延迟+丢包，取前 10 写入 `/opt/argox/ips.txt`
2. **内置兜底** —— 测速失败时写 16 个常见 CF 段 IP
3. **手动** —— 直接编辑 `ips.txt`，菜单 16 重新生成链接

两个坑：

- **时段性**：优选 IP 早晚差别极大，凌晨测的 30ms 晚上可能 150ms。请在 **20:00–23:00** 测
- **协议错配**：`cfst` 测的是 TCP，H3 走 UDP。TCP 延迟低的 IP 在 UDP 上可能很差，最终以客户端实测吞吐为准

## 排错

| 现象 | 原因 |
|---|---|
| HTTP **1033** | Public Hostname 没指向这条隧道，或域名写错 |
| HTTP **530** | 隧道离线（Token 失效 / 进程没起） |
| HTTP **502** | CF 到了，但 `127.0.0.1:8001` 没在听 |
| H3 节点全不通 | CF 后台没开 HTTP/3，或客户端不支持 `xhttp + alpn h3` |
| 只有 WS 能连 | 客户端不支持 XHTTP，正常，用 WS 即可 |

```bash
systemctl status argox-xray argox-tunnel
journalctl -u argox-tunnel -n 30 --no-pager | grep "Registered tunnel connection"
curl -sI https://你的隧道域名 | grep -i alt-svc   # 有 h3=":443" 说明 HTTP/3 已开
```

## 注意

1. **Cloudflare 服务条款禁止用其网络跑代理类流量**，账号存在被限制的风险。
2. **CF 免费版带宽共享**，晚高峰边缘节点本身也会拥塞，本方案不保证一定更快。
3. 安装后 `/opt/argox/node.json` 与 `/etc/argox/token.env` 含密钥，权限已设 600，不要外传。
4. 请在所在地法律法规允许的范围内使用。

## 文档

- [docs/cloudflare-setup.md](docs/cloudflare-setup.md) — 建隧道、拿 Token、开 HTTP/3 的完整步骤
- [docs/design.md](docs/design.md) — 设计取舍与原理说明
