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
- 8001 端口空闲（隧道回源，仅本机）；8099 端口空闲且**对外开放**（订阅直连）
- VPS 能**出站**访问 `7844`（cloudflared 隧道端口，UDP + TCP）；出站被封时隧道进程在跑但永远注册不上

## 菜单

左列是常用动作，右列是配置项：

```
   1) 安装 / 重新部署           9) 更换 UUID
   2) 启动                     10) 升级配置（补字段）
   3) 停止                     11) 隧道设置（Token / 域名 / 测试）
   4) 重启                     12) 优选 IP（导入测速结果）
   5) 查看状态                 13) 出口跳板
   6) 查看日志                 14) 直连协议（Hy2/TUIC/AnyTLS/Reality）
   7) 更新到最新版             15) 住宅落地
   8) 自检 check               16) 订阅地址 / 二维码
   17) 端口管理                18) 系统优化
   19) 清理缓存                20) 卸载
```

> v2.6.0 重排过编号：自检 check 从 17 → **8**，隧道设置 13 → **11**，
> 直连协议 20 → **14**，住宅落地 19 → **15**，优选 IP 14 → **12**，出口跳板 16 → **13**。
> v2.7.0 插入 **17) 端口管理**，系统优化起顺移至 18–20（v2.8.0 移除备份，卸载回到 20）。

## 订阅

安装后菜单 16 输出订阅地址。**v2.7.0 起订阅直连 VPS，不再走 Cloudflare 隧道**：

```
http://<VPS 公网 IP>:<订阅端口>/<订阅令牌>
```

这样 CF 侧只需要一条路由，也省掉一条 DNS 和一份 CF 流量。代价是订阅走明文 HTTP
（内容里是 UUID 和密码，没有 TLS 私钥），且要放行订阅端口（默认 `8099/TCP`）。
端口可改：`bash argox.sh port sub 9000`。

### 订阅格式：同一个地址，按客户端自动切换

订阅服务按 `User-Agent` 返回对应格式，**地址不变、令牌不变**：

| 客户端 | 拿到的格式 |
|---|---|
| Clash Verge / mihomo / FlClash / Stash | Clash Meta YAML（8 个节点） |
| sing-box 官方客户端（SFA / SFI / Karing） | sing-box JSON（**5 个节点**） |
| v2rayN / v2rayNG / Shadowrocket / 其他 | base64 链接列表（8 个节点，与旧版完全一致） |

UA 判断偶尔会失灵，也可以显式指定，加后缀即可：

```
http://<IP>:<port>/<令牌>.yaml      Clash
http://<IP>:<port>/<令牌>.json      sing-box
```

**sing-box 少 3 个节点的原因**：官方内核不支持 XHTTP 传输（只有 `tcp / ws / grpc /
http / httpupgrade / quic`），所以 `Argo-H3`、`Argo-H2`、`Argo-H3-RH` 写不进去。
Clash Meta（mihomo ≥ 1.19.6）原生支持 `network: xhttp`，八个节点全都在。
另外 Hy2 端口跳跃在 sing-box 里写成 `server_ports: ["23000:27000"]`（冒号，非短横线）。

默认输出 8 个节点（`domain` 模式；直连协议全开且落地开启时），节点名与顺序固定：

```
Argo-H3     CF 隧道，QUIC 抗丢包（CF 线路差时就废）
Argo-H2     CF 隧道，TCP 对照
Hy2         直连 VPS，UDP，带端口跳跃（速度最快）
TUIC        直连 VPS，UDP，备选
AnyTLS      直连 VPS，TCP，UDP 被限速时的唯一出路
Reality     直连 VPS，TCP，Xray 内核（默认关，纯 Xray 客户端用）
Argo-H3-RH  走隧道，出口走家里（落地）
AnyTLS-RH   直连 VPS，出口走家里（落地）
```

命名约定：走 Cloudflare 隧道的加 `Argo-` 前缀；直连 VPS 公网端口的用裸协议名；
住宅落地版统一加 `-RH` 后缀，且全部排在列表最后。

**WS 已在 v2.7.0 彻底移除**（入站、子域、8xxx 回源端口全部删除）。H2 节点走的是
`XHTTP + ALPN=h2`，和 H3 共用同一个回源端口，只是 ALPN 不同——所以删掉 WS 不影响任何节点。

地址都写域名，由客户端自行解析到最近的 CF 节点。
需要按 IP 展开时，先用下面的「优选 IP」把列表准备好，再菜单 11 → `6) 节点地址模式` 切成 `ip`。
直连协议（Hy2 / TUIC / AnyTLS / Reality）不受地址模式影响，永远写 VPS 公网 IP。

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

或者菜单 12 → `6) 从链接导入`。把 cfst 跑出来的 CSV 传到任意能直链打开的网页
（Gist 要用 **raw** 地址），脚本会：

1. 只取第一列，兼容这几种（都实测过）：cfst 的逗号 CSV、**Excel 里直接复制出来的
   Tab 分隔表格**、纯 IP 一行一个、`IP:443`、`IP#移动`
2. 剔除非 Cloudflare 段（反代/中转机本方案用不了）
3. **严格保持你上传的顺序**，取前 12 个
4. 表格最后一列是「地区码」时直接拿来当节点后缀，节点名会变成 `Argo-H3-01-SJC`
5. 可选地用 VPS 再验一次「能否路由到本隧道」（默认跳过，直接信任你的结果）
6. 问你要不要顺手切成 `ip` 模式并重建订阅

> 订阅里实际展开的规则：**取前 4 个 IP**，各生成 4 条 H3 + 4 条 H2（同一批 IP，
> 只差 QUIC / TCP）。列表里第 5 个往后的 IP 会被存下来但不进订阅，避免节点爆炸。
> 想要更多可以在脚本里改 `MAX_H3_NODES` / `MAX_H2_NODES`。

**另一条：社区列表**（菜单 12 → 3 拉取校验）。会按源备注里的运营商和 `ms`/`MB·s⁻¹`
排序——但那些数字是列表作者在自己网络测的，**跟你的线路无关**，仅供兜底。

## 直连协议（Hy2 / TUIC / AnyTLS / Reality）

不走 Cloudflare，直接连 VPS 公网端口。CF 线路差的时候这是主力。

```bash
bash argox.sh direct               # 状态 + 交互菜单（菜单 14）
bash argox.sh direct on all        # 一次开启四个协议（推荐）：四个开关一次写完，sing-box / Xray 各只重启 1 次
bash argox.sh direct on hy2
bash argox.sh direct off tuic
bash argox.sh direct on reality    # Xray 内核，默认关；纯 Xray 客户端（v2rayN 6.x）用它
bash argox.sh hy2 hop 23000-27000  # 改 Hy2 端口跳跃段
bash argox.sh reality              # Reality 状态（伪装目标 / 端口 / 密钥）
bash argox.sh reality probe        # 体检伪装目标：证书大小 / 握手 / 跨域跳转
bash argox.sh reality sni <域名>   # 换伪装目标（先体检，超 8192 直接拒绝）
bash argox.sh cert                 # 查看自签证书
bash argox.sh cert gen --force     # 重签
```

首次开启会自动装 sing-box、生成 ECC P-256 自签证书（10 年）、写配置、起服务。

**云安全组必须放行**（前两条常开，其余按需开）：

| 协议 | 端口 | 类型 |
|---|---|---|
| Hy2 | `23000-27000`（整段） | UDP |
| TUIC | `30001` | UDP |
| AnyTLS | `8445` | TCP |
| AnyTLS-RH | `8444` | TCP（落地开启时才有，与 8445 连号，可一次放行 `8444-8445`） |
| Reality | `8443` | TCP（默认关，不开不监听） |
| 订阅服务 | `8099` | TCP（v2.7.0 起直连，必须放行） |

装完脚本会自动打印这张清单（含你改过的端口值），照抄到 Oracle 控制台即可：

```bash
bash argox.sh port        # 端口一览（菜单 17）
```

所有端口都能改，改完自动重建服务与订阅，并提示要放行哪个新端口：

```bash
bash argox.sh port sub 9000      # 订阅
bash argox.sh port hy2 24000     # Hy2 监听口（跳跃段另用 hy2 hop）
bash argox.sh port tuic 30001
bash argox.sh port anytls 8445   # 落地口自动跟随（−1）
bash argox.sh port reality 8443
```

安装时想直接指定，用环境变量（不用交互）：

```bash
SUB_PORT=9000 ANYTLS_PORT=9443 bash argox.sh install
```

Hy2 的端口跳跃靠 nftables 的 `redirect` 实现，sing-box 实际只监听 `23000` 一个口，
其余 3999 个端口只是重定向规则，不占进程不占内存。**整段必须放行**——
只放单个端口会导致客户端跳到未放行端口时随机断流，极难排查。

> 默认段 `23000-27000` 是刻意避开 `20000-30000` 的：那一段常被 RustDesk（21115-21119）、
> 各种自建服务、面板占用。改段用 `hy2 hop <起-止>`，**监听口会自动跟随段首**，
> 不用手动改端口；段首被占用时直接报错并保持原配置不变。
> 老版本升级到 v2.3.2 时，若端口和段都还是旧默认值（`20000` / `20000-30000`），`upgrade` 会自动迁移。

自签证书没有受信 CA，客户端要勾「跳过证书验证」，订阅链接里已自动带 `insecure=1`。

### Reality（可选，Xray 内核）

默认关闭。它不用证书、不用域名、不依赖 sing-box，是**纯 Xray 内核客户端的兜底**
（v2rayN 6.x、老版 v2rayNG 等不认识 AnyTLS 的客户端）。

- 端口 `8443/TCP`，开启后需在云安全组放行
- 伪装目标默认 `www.lovelive-anime.jp:443`（CloudFront 托管，证书链固定 3821 字节）
- 首次开启自动用 `xray x25519` 生成密钥对，写入 `node.json`，之后不再变动
- 走 `xtls-rprx-vision` 流控，Throne / v2rayN 7.x / v2rayNG / sing-box 都支持
- 想要「Reality 也走家宽」：菜单 15 勾上 `REALITY`，订阅末尾会多一条 `Reality-RH`
  （同一个 8443 入站的第二个 UUID，不占新端口）

**伪装目标为什么不能随便选**：Xray 对目标站证书的 TLS 记录有 **8192 字节硬编码上限**，
超了握手直接失败，而且 Xray 不报错、不打日志——只表现成"节点连不上"。
这个大小还会随 CDN 边缘节点与证书轮换变化，同一域名不同机器测出来不一样，
所以别照抄网上的清单，换之前先体检：

```bash
bash argox.sh reality              # 当前目标 / 端口 / 密钥
bash argox.sh reality probe        # 体检当前目标 + 内置候选
bash argox.sh reality sni <域名>   # 换目标（先体检，超限直接拒绝写入）
```

`check` 也会自动探测当前 dest，超 8192 直接报红。选型标准与 2026-11 实测记录见
[`docs/plan-v2.md` 2.6](docs/plan-v2.md)。

```bash
bash argox.sh direct on reality    # 开（自动生成密钥 + 重启 Xray + 放行端口）
bash argox.sh direct off reality   # 关（8443 停止监听）
```

### 协议优先级

```
Hy2      ← 首选，UDP + BBR，速度最好
TUIC     ← Hy2 被限速时换它，同样 UDP
AnyTLS   ← UDP 全被 QoS 时的唯一活路（TCP，靠 TLS 伪装）
Reality  ← 同上是 TCP，Xray 内核原生支持；客户端不支持 AnyTLS 时换它
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
bash argox.sh landing on                # 开启（默认多出 Argo-H3-RH / AnyTLS-RH）
bash argox.sh landing off               # 关闭
bash argox.sh landing target h3,anytls  # 选择哪些入口带落地版（h3/h2/ws/anytls/reality）
bash argox.sh landing proto socks|http  # 落地出口协议
```

与「出口跳板」的区别：

| | 出口跳板 hop | 住宅落地 landing |
|---|---|---|
| 作用范围 | VPS 上所有流量 | 只有 `-RH` 结尾的节点 |
| 切换方式 | 服务端开关，全部节点都变 | 客户端换节点 |
| 用途 | 整台机器换出口 | 临时给某个目标站换住宅 IP |

两者可以同时开：落地路由规则排在跳板兜底规则之前，跳板开着也不会污染 `-RH` 节点。

实现分两条链路，`-RH` 节点永远排在订阅最后：

| 入口 | 实现方式 | 端口 |
|---|---|---|
| `h3` / `h2` / `ws` / `reality` | Xray 同一条入站挂第二个 UUID，路由按 `user` 条件分流 | 复用原端口 |
| `anytls` | sing-box **独立入站** `anytls-rh-in` + `socks` 出口 + 路由规则 | `8444`（主口 8445 − 1，连号） |

AnyTLS 之所以要独立端口：sing-box 的入站无法按「用户」分流，只能按入站分流。
它也是**唯一能做落地版的直连协议**——Hy2 / TUIC 是 UDP，本地代理不支持 UDP ASSOCIATE。

默认 `target` 是 `h3 + anytls`：H2 与 H3 同走 CF，再给 H2 一个落地版意义不大；
AnyTLS 是 TCP 兜底，配上家宽出口更实用。

## 命令行

```bash
bash argox.sh status
bash argox.sh nodes      # 订阅地址 + 二维码
bash argox.sh links      # 单节点链接
bash argox.sh sub        # Base64 订阅内容
bash argox.sh ips                      # 从社区源拉取并校验
bash argox.sh ips <链接|文件>           # 导入本机测速结果（保序，不重排）
bash argox.sh hop on     # 出口跳板（off / on [socks|http]）
bash argox.sh landing on # 住宅落地（off / status / target h3,anytls）
bash argox.sh direct on all # 直连协议（status / on|off hy2|tuic|anytls|all）
bash argox.sh hy2 hop 23000-27000 # Hy2 端口跳跃段
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
