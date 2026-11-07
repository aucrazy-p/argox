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
 1) 安装 / 重新部署        10) 清理缓存
 2) 启动                  11) 备份配置
 3) 停止                  12) 卸载
 4) 重启                  13) 隧道设置
 5) 查看状态              14) 优选 IP（导入本机测速结果）
 6) 查看日志              15) 订阅地址
 7) 更新到最新版          16) 出口跳板
 8) 更换 UUID             17) 自检 check
 9) 系统优化              18) 升级配置（补字段）
                          19) 住宅落地
                          20) 直连协议（Hy2 / TUIC / AnyTLS）
```

## 订阅

安装后菜单 15 输出订阅地址：

```
https://<订阅子域>/<订阅令牌>
```

默认输出 5 个节点（`domain` 模式），节点名与顺序固定：

```
Argo-H3     CF 隧道，QUIC 抗丢包（CF 线路差时就废）
Argo-H2     CF 隧道，TCP 对照
Hy2         直连 VPS，UDP，带端口跳跃（速度最快）
TUIC        直连 VPS，UDP，备选
AnyTLS      直连 VPS，TCP，UDP 被限速时的唯一出路
```

命名约定：走 Cloudflare 隧道的加 `Argo-` 前缀；直连 VPS 公网端口的用裸协议名；
住宅落地版统一加 `-RH` 后缀，且全部排在列表最后。

**WS 已下线**：它和 H2 同为 TCP 443、路径完全重叠，属于下位替代，
留着只会干扰选择。

地址都写域名，由客户端自行解析到最近的 CF 节点。
需要按 IP 展开时，先用下面的「优选 IP」把列表准备好，再菜单 13 → `6) 节点地址模式` 切成 `ip`。
直连协议（Hy2 / TUIC / AnyTLS）不受地址模式影响，永远写 VPS 公网 IP。

## 优选 IP（两条路，别搞混）

**快慢只有你的网络说了算**。VPS 在大阪，它测 Cloudflare 是毫秒级直连，
测出来的顺序对你毫无意义。所以这里分工是：

| 谁 | 负责什么 |
|---|---|
| 你的电脑 | 哪个 IP 对你快 → 用 cfst 之类工具跑一份结果 |
| VPS | 这个 IP 能不能到达本隧道（anycast 全局一致，1033 的谁来测都用不了） |

**推荐：从链接导入本机测速结果**（保序，不重排）

```bash
bash argox.sh ips https://gist.githubusercontent.com/.../raw/result.csv
bash argox.sh ips /root/result.csv      # 也可以直接给本机路径
```

或者菜单 14 → `6) 从链接导入`。把 cfst 跑出来的 CSV 传到任意能直链打开的网页
（Gist 要用 **raw** 地址），脚本会：

1. 只取第一列 IP，兼容 `IP,已发送,已接收,丢包率,平均延迟,下载速度,地区码` 这类 CSV
2. 剔除非 Cloudflare 段（反代/中转机本方案用不了）
3. **严格保持你上传的顺序**，取前 12 个
4. 可选地用 VPS 再验一次「能否路由到本隧道」（默认跳过，直接信任你的结果）
5. 问你要不要顺手切成 `ip` 模式并重建订阅

**另一条：社区列表**（菜单 14 → 3 拉取校验）。会按源备注里的运营商和 `ms`/`MB·s⁻¹`
排序——但那些数字是列表作者在自己网络测的，**跟你的线路无关**，仅供兜底。

## 直连协议（Hy2 / TUIC / AnyTLS）

不走 Cloudflare，直接连 VPS 公网端口。CF 线路差的时候这是主力。

```bash
bash argox.sh direct               # 状态 + 交互菜单（菜单 20）
bash argox.sh direct on all        # 一次开启 Hy2 + TUIC + AnyTLS（推荐）
bash argox.sh direct on hy2
bash argox.sh direct off tuic
bash argox.sh hy2 hop 20000-30000  # 改 Hy2 端口跳跃段
bash argox.sh cert                 # 查看自签证书
bash argox.sh cert gen --force     # 重签
```

首次开启会自动装 sing-box、生成 ECC P-256 自签证书（10 年）、写配置、起服务。

**云安全组必须放行三条**：

| 协议 | 端口 | 类型 |
|---|---|---|
| Hy2 | `20000-30000`（整段） | UDP |
| TUIC | `30001` | UDP |
| AnyTLS | `8445` | TCP |

Hy2 的端口跳跃靠 nftables 的 `redirect` 实现，sing-box 实际只监听 `20000` 一个口，
其余 9999 个端口只是重定向规则，不占进程不占内存。**整段必须放行**——
只放单个端口会导致客户端跳到未放行端口时随机断流，极难排查。

自签证书没有受信 CA，客户端要勾「跳过证书验证」，订阅链接里已自动带 `insecure=1`。

### 协议优先级

```
Hy2      ← 首选，UDP + BBR，速度最好
TUIC     ← Hy2 被限速时换它，同样 UDP
AnyTLS   ← UDP 全被 QoS 时的唯一活路（TCP，靠 TLS 伪装）
Argo-*   ← 上面全挂才用（走 CF；国内到 CF 丢包严重时不可用）
```

## 自检

```bash
bash argox.sh check      # 配置 / 服务 / 端口 / 订阅 / 链接 / DNS / 隧道，全只读
bash argox.sh check -q   # 静默，只用退出码（0=全通过），适合脚本调用
```

专治踩过的坑：`path` 带前导空格导致节点全不通、订阅文件名与令牌不一致、
服务 active 但端口没起、WS 链接的 Host 写错。

## 升级

从 v1.x 升到 v2：

```bash
bash argox.sh upgrade
```

只做三件事：备份 `node.json` → 补齐新字段 → 对齐 systemd 单元 + 重建订阅。
**不重启任何服务**，运行中的连接不受影响。

注意：节点名从 `argox-*` 改成了 `Argo-*`，客户端里旧节点请删掉后重新导入。

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

## 住宅落地

VPS 上装了住宅 IP / 商业 VPN 客户端（如 AimiliVPN），并提供本地 socks5 或 http 端口时，
可以让订阅里多出 `-RH` 结尾的节点，这些节点从住宅 IP 出去，其余节点完全不受影响。

```bash
bash argox.sh landing                   # 状态 + 交互菜单
bash argox.sh landing on                # 开启（多出 Argo-H3-RH / Argo-H2-RH）
bash argox.sh landing off               # 关闭
bash argox.sh landing target h3,h2,ws   # 选择哪些入口带落地版
bash argox.sh landing proto socks|http  # 落地出口协议
```

与「出口跳板」的区别：

| | 出口跳板 hop | 住宅落地 landing |
|---|---|---|
| 作用范围 | VPS 上所有流量 | 只有 `-RH` 结尾的节点 |
| 切换方式 | 服务端开关，全部节点都变 | 客户端换节点 |
| 用途 | 整台机器换出口 | 临时给某个目标站换住宅 IP |

两者可以同时开：落地路由规则排在跳板兜底规则之前，跳板开着也不会污染 `-RH` 节点。

实现上不额外开端口、不额外加入站——同一条隧道挂第二个 UUID，
靠 Xray 的路由 `user` 条件分流到本地代理出口。`-RH` 节点永远排在订阅最后。

## 命令行

```bash
bash argox.sh status
bash argox.sh nodes      # 订阅地址 + 二维码
bash argox.sh links      # 单节点链接
bash argox.sh sub        # Base64 订阅内容
bash argox.sh ips                      # 从社区源拉取并校验
bash argox.sh ips <链接|文件>           # 导入本机测速结果（保序，不重排）
bash argox.sh hop on     # 出口跳板（off / on [socks|http]）
bash argox.sh landing on # 住宅落地（off / status / target h3,h2,ws）
bash argox.sh direct on all # 直连协议（status / on|off hy2|tuic|anytls|all）
bash argox.sh hy2 hop 20000-30000 # Hy2 端口跳跃段
bash argox.sh cert       # 自签证书（show / gen [--force]）
bash argox.sh diag       # cloudflared 出站诊断（DNS / TCP 7844 / 注册情况）
bash argox.sh diag http2 # UDP 7844 被封时强制走 TCP
bash argox.sh check      # 自检（-q 静默，只返回退出码）
bash argox.sh upgrade    # 老版本补齐字段（不重启服务）
bash argox.sh restart
bash argox.sh uninstall
```

## 相关文档

- [docs/cloudflare-setup.md](docs/cloudflare-setup.md) — 隧道创建、Token、HTTP/3
- [docs/design.md](docs/design.md) — 设计文档
- [docs/plan-v2.md](docs/plan-v2.md) — v2.0 双核方案（Argo + Hy2 + TUIC，分 5 阶段实施）
