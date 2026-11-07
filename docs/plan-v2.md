# argox v2.0 方案（双核合并版 · 决策已定稿）

> 状态：**阶段 1、2、3 已完成**（v2.0.0 新命名 + `check` + `upgrade`；v2.1.0 住宅落地；
> v2.2.0 sing-box 双核 + 自签证书 + Hy2 / TUIC / AnyTLS + 端口跳跃，WS 下线）。
> 下一步：阶段 4（Reality，默认关）。
> 变更：**v2.3.2 起 Hy2 默认段 `20000-30000` → `23000-27000`**（用户 VPS 上 RustDesk 与
> 其他服务占用 20000-30000，实测冲突）。监听口同步改为段首 `23000`；`hy2 hop` 会
> **自动把监听口对齐到段首**，`upgrade` 对「仍是旧默认值」的实例自动迁移。
> 原状态记录：5 项决策已拍板（A/B/C/D/E 见第 0 节）。
> 目标：把现有 `argox.sh`（Argo + Xray XHTTP）与 `install_myproxy.sh`（多协议直连）合并为一套脚本，
> 双核（Xray + sing-box）各管一半协议，全量使用自签证书。

---

## 0. 决策记录（本轮拍板）

| 项 | 决策 | 落地方式 |
|---|---|---|
| **A** 目录与命名 | 保持 `/opt/argox` + `argox.sh`，版本号 `2.0.0`；**走隧道的加 `Argo-` 前缀，直连用裸协议名，住宅加 `-RH`** | 见 2.1 节点表 |
| **B** Hy2 端口段 | **菜单可配置**，默认 `23000-27000` | 见 5.4，含"要不要一万个"的解答 |
| **C** Reality / AnyTLS | Reality **默认关**；**AnyTLS 默认开**（唯一 TCP 兜底） | 见 2.1 + 2.3 |
| **D** Shadowsocks 2022 | **不加** | 从方案中彻底移除 |
| **E** 默认安装模式 | **模式 B：Argo + Hy2 + TUIC**；`Reality-RH` 暂不开，但**以后菜单可随时加** | 见 2.5 + 7 |

---

## 1. 先澄清三件事（避免理解偏差）

### 1.1 "其他都可以用自签证书" —— 成立

| 协议 | 证书来源 | 需要自签吗 |
|---|---|---|
| Argo-H3 / H2 / WS | Cloudflare 边缘自动签发 | 不需要，VPS 上无证书 |
| Hysteria2 | VPS 本地 | **需要**，自签 + 客户端 `insecure` |
| TUIC v5 | VPS 本地 | **需要**，自签 + 客户端 `skip-cert-verify` |
| AnyTLS | VPS 本地 | **需要**，自签 + 客户端 `insecure` |
| Reality | 不需要证书（借目标站点的真证书） | 不需要 |

自签证书一份，Hy2 / TUIC / AnyTLS 三个协议共用。

**关于 AnyTLS 原脚本的坑**：原脚本去找 1Panel 站点的 Let's Encrypt 证书，并要求那个域名解析到本机，
没有校验域名是否在橙云后面（橙云域名解析到 CF，客户端连 8445 会被 CF 拦，握手必失败）。
**这不是 AnyTLS 的问题，是那个实现的依赖问题。改用自签证书后依赖完全消失**。

### 1.2 "双核"的确切含义

**两个独立进程，各跑各的协议，互不依赖**：

```
argox-xray   ← Argo 回源入口（XHTTP / WS）+ Reality
argox-sb     ← Hysteria2 + TUIC（+ AnyTLS）
```

不采用"Xray 转发给 sing-box"这类链式结构——那会引入单点，一个核挂了另一核跟着废。
两个进程独立崩溃、独立重启、独立升级。

### 1.3 加直连协议 = 放弃"零公网端口"

这是必须明确的取舍。现有 argox 的全部优势建立在"不开任何公网端口"上。
加入 Hy2 / TUIC 后，VPS 必须开放一段公网 UDP 端口，IP 会被主动扫描到。

sing-box 官方文档对此有一句直白警告：

> Even though GFW rarely blocks UDP-based proxies, such protocols actually have far more
> obvious characteristics than TCP based proxies.

**结论**：Argo 那 3 条节点保持"隐蔽优先"，直连那几条是"速度优先"。
两者并存，客户端按需切换，而不是互相替代。

---

## 2. 最终协议清单

### 2.1 节点表（A：命名规则）

**命名规则**：
- 走 Cloudflare 隧道的 → `Argo-` 前缀（`Argo-H3`）
- 直连 VPS 公网端口的 → **裸协议名，不加任何前缀**（`Hy2` / `TUIC` / `Reality` / `AnyTLS`）
- 住宅落地版 → 后缀 `-RH`（residential home），如 `Argo-H3-RH`

靠「**有无 `Argo-` 前缀**」区分两类，直连组直接用协议名，最短最好认。

| # | 节点名 | 内核 | 入口 | 出口 | 证书 | 默认 |
|---|---|---|---|---|---|---|
| 1 | `Argo-H3` | Xray | CF 隧道（QUIC） | VPS 原生 | CF 托管 | 开 |
| 2 | `Argo-H2` | Xray | CF 隧道（TCP） | VPS 原生 | CF 托管 | 开 |
| 3 | `Hy2` | sing-box | 直连 UDP + 端口跳跃 | VPS 原生 | 自签 | 开 |
| 4 | `TUIC` | sing-box | 直连 UDP | VPS 原生 | 自签 | 开 |
| 5 | `AnyTLS` | sing-box | 直连 TCP 8445 | VPS 原生 | 自签 | 开 |
| 6 | `Argo-H3-RH` | Xray | CF 隧道（QUIC，UID②） | Aimili | CF 托管 | 开 |
| 7 | `Argo-H2-RH` | Xray | CF 隧道（TCP，UID②） | Aimili | CF 托管 | 开 |
| 8 | `Reality` | Xray | 直连 TCP 8443 | VPS 原生 | 无 | **关** |
| 9 | `Reality-RH` | Xray | 直连 TCP 8443（UID②） | Aimili | 无 | **关** |

**默认开启 7 条**（1–7）。Reality 两条默认关，菜单 8 一键开。

> **v2.2.0 两处调整**（实测驱动）：
> - **`Argo-WS` 下线**：与 `Argo-H2` 同为 TCP 443、路径完全重叠，属于下位替代，
>   留着只增加选择成本。8002 入站保留，避免 CF 侧 ws 子域路由 502。
> - **`AnyTLS` 改为默认开**：实测本机到 CF 丢包 60% 时 Argo 全灭，
>   而 Hy2/TUIC 都是 UDP，一旦运营商对 UDP 限速就没有任何 TCP 通路。
>   AnyTLS 是唯一的 TCP 兜底，必须默认开。

> 命名替换对照（脚本内部 tag 不变，只改客户端显示名，避免配置漂移）：
> `argox-H3 → Argo-H3`、`argox-H3-住宅 → Argo-H3-RH`、`argox-Hy2 → Hy2`、`argox-Reality → Reality` …

**Hy2 / TUIC 不做住宅落地版**：端到端 UDP 经 SOCKS5 的 UDP ASSOCIATE 转发，
多数商业代理（含 Aimili）只实现 CONNECT，不实现 UDP ASSOCIATE，做了也是坏的。

### 2.1b 节点排列顺序（已在代码里写死约定）

订阅里的顺序固定为：

```
Argo-H3  →  Argo-H2                    ← 走 CF，备用
Hy2      →  TUIC  →  AnyTLS            ← 直连 VPS，主力（UDP 两条 + TCP 一条）
Argo-H3-RH  →  Argo-H2-RH              ← 落地家宽，永远排最后
```

原则：**默认出口的节点在前，落地家宽整体垫底**。
直连组内部维持「UDP 主力 → UDP 备选 → TCP 兜底」的顺序，
客户端里从上往下试，最后那条 TCP 一定能通。
`-RH` 是特殊用途（目标站要求住宅 IP 时临时切），放末尾不干扰日常切换。

`build_links()` 顶部有注释固化这条约定，加新协议时按段落插入，不要打乱顺序。

### 2.2 去掉的（及理由）

| 协议 | 处理 | 理由 |
|---|---|---|
| CDN-XHTTP | 去掉 | 与 Argo-H2 功能重叠（都是 CF 前置 TCP），却要多开公网端口 |
| CDN-家宽落地 | **合并进落地机制** | 原脚本用 2054 端口（CF 不支持，必挂）。落地不需要独立端口，双 UUID 即可 |
| VMess | 去掉 | 多一层无用加密，客户端对它的 XHTTP 支持也弱 |
| Shadowsocks 2022 | **不加**（D） | 已有 Hy2/TUIC 两条速度快线，SS 定位重复 |

### 2.3 AnyTLS 的定位（v2.2.0 起改为默认开）

AnyTLS 解决的是 **TLS-in-TLS 指纹**：代理把用户 TLS 流量装进自己 TLS 里发出去，
形成"套娃"模式，USENIX Security 2024 有专文用包长/时序统计特征检测它。

**改成默认开的理由不是防指纹，是保命：**

实测沈阳本地到 Cloudflare 丢包 60%、328ms 时，`Argo-H3` / `Argo-H2` 全部 -1，
而同一时刻到 VPS 直连是 **0% 丢包**。结论：Argo 只能当备用，不能当主力。

但 `Hy2` 和 `TUIC` **都是 UDP**。运营商一旦对 UDP 做 QoS（晚高峰很常见），
两条同时失效，就只剩 Argo 那条已经废掉的 CF 隧道——等于全挂。

**AnyTLS 是唯一既不依赖 UDP、也不依赖 CF 的通路**，所以必须默认开。

客户端支持情况（决定它在你设备上能不能用）：

| 客户端 | AnyTLS |
|---|---|
| **Throne（Xray + sing-box 双内核）** | **支持**（当前在用，无兼容问题） |
| sing-box 1.12+ | 支持 |
| mihomo / FlClash | 支持 |
| Shadowrocket 2.2.65+ | 支持 |
| v2rayN 7.x（sing-box 内核） | 支持 |
| v2rayN 6.x / 纯 Xray 内核 | **不支持** |

v2rayN 的 Xray 内核没有 AnyTLS 实现。7.x 可以按节点切 sing-box 内核；
6.x 无解，那条节点在客户端里点不动。

**客户端不支持 AnyTLS 时的替代方案**：开 `Reality`（Xray 内核原生支持）。
它同样是直连 TCP，需要额外放行 TCP 8443，用菜单 8 开启，效果等价。

### 2.4 家宽落地：双 UUID 分流（不占额外端口）

**问题背景**：需要"同一条隧道、同一个域名，既能从 VPS 原生 IP 出去，又能从住宅 IP 出去"。

原脚本的做法是**开额外入站 + 额外端口**：

| 入站 | 端口 | 出口 |
|---|---|---|
| `reality-in` | 8443 | direct |
| `reality-home-in` | 8444 | landing |
| `cdn-in` | 2053 | direct |
| `cdn-home-in` | **2054** | landing（CF 不支持该端口，必挂） |

**这些端口全是浪费。** Xray 的同一入站可以配多个 client，按 `email` 区分，
再用路由规则 `user` 字段分流到不同出站：

```json
"inbounds": [{
  "tag": "argo-xhttp",
  "settings": { "clients": [
    { "id": "<主UUID>",   "email": "main"    },
    { "id": "<落地UUID>", "email": "landing" }
  ]}
}],
"outbounds": [
  { "protocol": "freedom", "tag": "direct" },
  { "protocol": "socks",   "tag": "landing",
    "settings": { "servers": [{ "address": "127.0.0.1", "port": 7928 }] } }
],
"routing": { "rules": [
  { "type": "field", "user": ["landing"], "outboundTag": "landing" },
  { "type": "field", "ip": [私网段],      "outboundTag": "direct" }
]}
```

**为什么 H3 节点也能用 SOCKS5 落地**（这是最容易误解的一点）：

```
客户端 ──QUIC/UDP──▶ CF 边缘 ──TCP──▶ cloudflared ──TCP──▶ 127.0.0.1:8001
                                                                  │
                                                        Xray 出站 ──TCP──▶ 127.0.0.1:7928
```

QUIC 在 CF 边缘就终结了，进入 Xray 之后到 Aimili 那段**永远是 TCP**。
所以 UDP 只在第一跳，落地环节纯 TCP，SOCKS5 完全够用。

**与 `hop` 的关系：共存，互不干扰。**

| | `hop`（全局跳板） | 落地 UUID |
|---|---|---|
| 作用范围 | VPS 上所有流量 | 只有那一条节点 |
| 切换方式 | 服务端开关，要 SSH | 客户端换节点 |
| 适用 | "整台机器都换出口" | "临时切一条" |
| 同时开 | — | 落地规则在前，`hop` 不影响落地节点 |

落地规则的 `user:["landing"]` 排在最前面，所以开了 `hop` 也不会污染落地节点。

**检测**：`check` 会增加一条——Aimili 7928 是否可达。不可达时给警告而不是直接报错
（Aimili 是临时用的，挂了不该阻塞其他节点）。

### 2.5 落地范围可扩展（E：以后能加）

`node.json` 里 `landing.target` 是个**数组**，决定给哪些入口生成 `-RH` 版本：

| target 值 | 对应节点 | 默认 | 可随时开 |
|---|---|---|---|
| `h3` | `Argo-H3-RH` | ✓ | 菜单勾选 |
| `h2` | `Argo-H2-RH` | ✓ | 菜单勾选 |
| `ws` | `Argo-WS-RH` | ✗ | 菜单勾选 |
| `reality` | `Reality-RH` | ✗ | 菜单勾选（需先开 Reality 协议本身） |

**加一条落地版 = 往数组里加一个值 + 重建订阅，零新端口、零重启 Xray**
（Xray 支持热加载配置，`argox.sh` 用 `--reconfigure` 或直接 reload）。

所以你现在不开 `Reality-RH` 完全不影响以后：等哪天 Reality 节点测通了，
菜单 8 → 勾一下 `Reality` 的落地，订阅里立刻多一条 `Reality-RH`。

---

## 3. 进程 / 端口 / 目录

### 3.1 进程

| 服务 | 二进制 | 职责 | 启动依赖 |
|---|---|---|---|
| `argox-xray` | `/usr/local/bin/argox-xray` | 8001(XHTTP) / 8002(WS) / 8443(Reality) | 无 |
| `argox-sb` | `/usr/local/bin/argox-sb` | Hy2 / TUIC / AnyTLS | 无 |
| `argox-tunnel` | `/usr/local/bin/cloudflared` | Argo 出站 | xray |
| `argox-sub` | python3 标准库 | 订阅 + 三种格式输出 | 无 |

### 3.2 端口

| 用途 | 端口 | 协议 | 监听地址 | 需云安全组 | 模式 B 下 |
|---|---|---|---|---|---|
| XHTTP 回源 | 8001 | TCP | `127.0.0.1` | 否 | 用 |
| WS 回源 | 8002 | TCP | `127.0.0.1` | 否 | 用 |
| 订阅 | 8099 | TCP | `127.0.0.1` | 否 | 用 |
| Hy2 实监听 | 23000 | UDP | `0.0.0.0` | 是（含在段内） | 用 |
| Hy2 跳跃段 | 23000–27000 | UDP | nftables redirect | **是（整段）** | 用 |
| TUIC | 30001 | UDP | `0.0.0.0` | 是 | 用 |
| Reality | 8443 | TCP | `0.0.0.0` | 是 | **关**（不监听） |
| AnyTLS | 8445 | TCP | `0.0.0.0` | 是 | **关**（不监听） |

**模式 B 只需在云安全组放行两条**：`UDP 23000-27000`、`UDP 30001`。
Reality / AnyTLS 的 TCP 端口在协议关闭时**根本不监听**，不配安全组也不影响。

**住宅落地不占任何端口**：走同一个入站的第二个 UUID，见 2.4 节。

端口全部可配置，默认值避开常见服务端口与你的 1panel 占用（443）。
**冲突检测**：安装时检查端口是否被占用，被占用则要求改，不静默覆盖；
TUIC 端口若落在 Hy2 跳跃段内，直接拒绝并提示。

### 3.3 目录（保持 `/opt/argox` 不变，零迁移）

```
/opt/argox/
├── config.json          # Xray 配置
├── sb.json              # sing-box 配置（新增）
├── node.json            # 状态文件（沿用，只加字段）
├── cert/                # 自签证书（新增）
│   ├── cert.pem         600
│   └── key.pem          600
├── sub/                 # 订阅明文（argox.txt / argox.b64 / argox.yaml / argox-sb.json）
├── pub/                 # 订阅对外文件（按 token 命名）
├── logs/
│   ├── access.log  error.log        # Xray
│   └── sb.log                        # sing-box（新增）
└── ips.txt / ips.meta   # 优选 IP（domain 模式下闲置）

/etc/argox/token.env     # TUNNEL_TOKEN，600
```

服务名与二进制名保持 `argox-*`，**只有客户端可见的节点显示名改成 `Argo-` / 裸协议名 / `-RH`**，
服务、单元、文件路径一律不动——零迁移。

---

## 4. 自签证书

### 4.1 生成策略

- 算法：ECC P-256（ARM 上握手更快，证书体积小）
- 有效期：3650 天（10 年，避免频繁轮换）
- SAN：默认填**主域名**（`argo.aucrazy.dpdns.org`），可配置
- 生成命令：`openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 ...`

**为什么 SAN 用主域名而不是假域名**：这个域名真实存在（有 DNS 记录指向 CF），
被动观测看到的是一个"看起来正常"的 SNI；用随机假域名反而更显眼。

### 4.2 客户端侧

| 客户端 | Hy2 | TUIC | AnyTLS |
|---|---|---|---|
| v2rayN | `allowInsecure=1` | `allow_insecure=1` | 不支持 |
| 订阅链接 | `insecure=1` | `insecure=1` | `insecure=1` |
| mihomo / Clash | `skip-cert-verify: true` | `skip-cert-verify: true` | `skip-cert-verify: true` |
| sing-box | `tls.insecure: true` | `tls.insecure: true` | `tls.insecure: true` |

订阅链接里自动带 `insecure=1`，用户不用手填。

### 4.3 证书管理

- `argox.sh cert show` → 打印 SAN、指纹、剩余天数
- `argox.sh cert gen` → 重新生成（会同时更新三个协议配置并重启对应服务）
- `status` 里显示剩余天数，低于 30 天给警告
- 证书轮换后订阅无需重发（`insecure` 不校验）

---

## 5. Hysteria2 端口跳跃

### 5.1 原理与实现

sing-box **不支持监听端口段**，所以走 nftables 重定向：

```nft
table inet argox_hop {
  chain prerouting {
    type nat hook prerouting priority dstnat - 5; policy accept;
    udp dport 23000-27000 redirect to :23000
  }
}
```

- `redirect` 只改目的端口，不改地址，命中本机流量，sing-box 收到的就是 23000
- 用独立 table 名，不污染 1panel / Docker 的规则
- 停止服务时按需删除该 table

### 5.2 客户端

订阅里写成 `mport=23000-27000`，客户端按间隔随机切换端口。
v2rayN 的 `port hopping` 字段、mihomo 的 `ports` 字段都对应这个值。

### 5.3 "真需要一万个端口吗" —— 不需要，但成本几乎为零

这一步常被误解，说清楚：

| 你以为的 | 实际发生的 |
|---|---|
| 服务端要监听 4001 个 UDP socket | **只监听 1 个**（23000）。其余 4000 个只是 nftables 里的一条 `redirect` 规则，一次查表命中，不占进程、不占内存、不占 CPU |
| 云安全组要加 4001 条规则 | **加 1 条**：`UDP 23000-27000`。Oracle Security List / NSG 原生支持端口范围 |
| 端口越多越容易被扫到 | 全端口 UDP 扫描要几小时且丢包严重，扫描器基本只扫 53/123/443 这些常用口。段再宽，被扫到的概率主要由"IP 是否被盯上"决定，不由端口数量决定 |

**那为什么不干脆用 256 个？** 关键是**规避已知被限速的区间**，而非数量本身。
运营商/机房对 UDP 的 QoS 往往作用于某一段（例如整段 10000–20000），
跳跃段越宽、越靠近"冷门高位"，越不容易整段被限。1000 个和 10000 个的抗限速效果差别不大，
但 10000 个的"跨区间"容错更好。

**结论：默认 23000–27000（避开 RustDesk 21115-21119 等常用段，客户端兼容最好），但做成可配置。**

### 5.4 端口段可配置（B）

`node.json` 里新增 `hy2.hop`（格式 `起-止`），三处联动：

1. **菜单 10 → 端口与证书 → Hy2 跳跃段**：输入 `23000-27000`，回车保留原值
2. **命令行**：`argox.sh hy2 hop 23000-25000`
3. **订阅**：`mport=` 字段自动跟着变，客户端重新拉订阅即生效

**输入校验**（防止改坏）：

| 规则 | 说明 |
|---|---|
| 格式 | 必须 `数字-数字`，`start < end` |
| 范围 | 两端都在 `1024–65535` |
| 跨度 | ≤ 20000，防手滑写出 `1-65535` |
| 冲突 | 不得包含 TUIC 端口；不得包含 Hy2 实监听端口以外的已占用端口 |
| 提示 | 改窄/改宽都会提示"需同步放行云安全组整段" |

改动后动作：重写 nft 规则 → 重建订阅 → 提示去云安全组更新范围。**不重启 sing-box**（监听端口没变）。

### 5.5 已知风险（必须写进文档）

1. **云安全组必须放行整段**。只放行单个端口的话，客户端跳到未放行端口会表现为"随机断流"，
   极难排查。`check` 会随机挑 3 个段内端口做可达性探测。
2. **Docker 会接管 nftables**。装了 1panel / Docker 的机器，需要在 `DOCKER-USER` 链里
   补一条，或者关闭 Docker 的 iptables 管理。安装时检测并处理。
3. **端口段越宽，扫描面越大**（影响有限，见 5.3）。
4. **Oracle 免费层有月流量限制**（10 TB 出站）。Brutal 会跑满带宽，别挂大流量任务。

### 5.6 Brutal 带宽参数

`up_mbps` / `down_mbps` 是"声称带宽"，设高了会自己制造拥塞。
默认 `up 50 / down 300`（可配置），对 Oracle 免费层是保守值。
方案里会加一行提示：设成超过实测值只会更慢。

---

## 6. 订阅输出（三种视图）

订阅走独立子域（`sub_host`），Path 留空，由 Python 服务解析路径后缀：

| 路径 | 输出 | 适用客户端 |
|---|---|---|
| `/sub/<token>` | Base64 全协议合集 | v2rayN / v2rayNG / Throne |
| `/sub/<token>/clash` | mihomo YAML（含 proxy-groups） | FlClash / Clash Verge / OpenClash |
| `/sub/<token>/sb` | sing-box JSON | 纯 sing-box 客户端 |

要点：
- Clash 版自动跳过 `Argo-H3`（mihomo 不支持 XHTTP over QUIC），并在注释里说明原因
- Clash 版包含 AnyTLS（mihomo 支持），但只有开启时才输出
- 三份视图同一数据源，UUID / 密码 / 端口全部来自 `node.json`，不会漂移
- 未知路径一律 404，不泄露文件清单（沿用现有实现）
- 节点名严格按 2.1 表：`Argo-*` / 裸协议名 / `-RH` 后缀
- 住宅版必须带 `-RH`，客户端里一眼可辨

---

## 7. 菜单

> 下面是阶段 5 的最终布局。当前 v2.1.0 为了不打乱用户习惯，1–16 沿用旧编号，
> 新功能追加在末尾：`17) 自检 check`、`18) 升级配置`、`19) 住宅落地`。
> 等阶段 4 全部功能齐了再统一重排。

```
── 部署 ────────────────────────────────────
  1) 安装 / 重新部署          2) 服务控制（启/停/重启）
── 观测 ────────────────────────────────────
  3) 状态总览                4) 日志
  5) 订阅地址 / 二维码        6) 节点链接（逐条）
── 配置 ────────────────────────────────────
  7) 更换 UUID / 密码         8) 协议开关
  9) 隧道设置（Token/域名）   10) 端口与证书
── 网络 ────────────────────────────────────
 11) 出口跳板                12) 出站诊断 diag
 13) 路由分流
── 系统 ────────────────────────────────────
 14) 系统（优化/清理/备份）   15) 自检 check
 16) 卸载
```

`8) 协议开关` 进去是两段：**协议** + **住宅落地范围**（对应 E 的可扩展需求）：

```
── 协议 ──────────────────────────────
   Argo（H3/H2/WS） [开]      Hysteria2 [开]
   TUIC             [开]      Reality   [关]
   AnyTLS           [关]

── 住宅落地范围（Aimili） ────────────
   [x] Argo-H3 (Res)   [x] Argo-H2 (Res)
   [ ] Argo-WS (Res)   [ ] Reality (Res)
```

- 打开 Reality / AnyTLS 时：写端口配置 → 起监听 → 提示放行云安全组 → 重建订阅
- 关闭时：先停监听再删配置，端口回到"不监听"状态
- 落地范围勾选：改 `landing.target` 数组 → 增删对应入站的第二个 client → 重建订阅
- 关落地某个入口时，**同步从 clients 里删掉落地 UUID**，不留静默走原生出口的坑（原脚本问题 #11）

切任何一项 = 改 `node.json` → 重写对应核的配置 → 校验 → 重启**单个**服务 → 重建订阅。

---

## 8. 命令行

```
argox.sh install|start|stop|restart|status|logs|update
argox.sh nodes|links|sub|qr
argox.sh proto [list|on <name>|off <name>]     # argo|hy2|tuic|reality|anytls
argox.sh landing [on|off|status|target <list>|proto socks|http]  # target h3,h2,ws,reality
argox.sh hy2 hop <start-end>                   # 端口段（B）
argox.sh tunnel [token|host|proto]
argox.sh port [show|set]
argox.sh cert [show|gen]
argox.sh hop [on|off|status]
argox.sh diag [auto|quic|http2]
argox.sh check
argox.sh backup|uninstall
```

---

## 9. 状态文件（沿用 node.json，只加字段）

```json
{
  "uuid": "…",
  "tunnel_host": "argo.aucrazy.dpdns.org",
  "ws_host": "ws.aucrazy.dpdns.org",
  "sub_host": "subx.aucrazy.dpdns.org",
  "sub_token": "…",
  "path_xhttp": "/0730beac6daadf19",
  "path_ws": "/ws81a35bde768c",
  "tunnel_proto": "auto",
  "node_mode": "domain",
  "hop_mode": "off",
  "hop_proto": "socks",
  "hop_addr": "127.0.0.1",
  "hop_port": "7928",

  "install_mode": "B",
  "proto": {
    "argo": true,
    "hy2": true,
    "tuic": true,
    "reality": false,
    "anytls": false
  },
  "landing": { "enabled": true, "uuid": "…", "target": ["h3", "h2"] },
  "anytls":  { "port": 8445, "password": "…" },
  "hy2":     { "port": 23000, "hop": "23000-27000", "obfs": false, "up": 50, "down": 300 },
  "tuic":    { "port": 30001, "password": "…", "cc": "bbr" },
  "reality": { "port": 8443, "sni": "www.microsoft.com", "short_id": "…" },
  "cert":    { "sni": "argo.aucrazy.dpdns.org", "path": "/opt/argox/cert" }
}
```

`landing.target` 是数组，支持 `h3` / `h2` / `ws` / `reality`，加值即多一条节点（见 2.5）。
`landing.uuid` 是第二个 UUID，与 `uuid` 独立；更换 UUID 时两个一起换。
`hy2.hop` 是端口段（见 5.4）。

**向后兼容**：所有新字段缺失时按上面的默认值补齐，旧 `node.json` 不改也能跑。
`landing.enabled` 缺失时视为 `false`——升级后不会凭空多出两条节点。

---

## 10. 安装 / 升级流程

### 10.1 安装（交互式，每步带默认值）

```
0. 预检：root / 架构(arm64|amd64) / 发行版 / 端口占用 / 是否 Oracle Cloud / 是否装 Docker
1. 模式选择（默认 B）：
   A) 仅 Argo（零公网端口，保持现状）
   B) Argo + 直连 UDP（Hy2 / TUIC）   ← 默认，回车即选
   C) 全量（含 Reality 8443）
2. 已有安装？→ 逐项显示当前值，回车保留（绝不清空）
3. Tunnel Token（可跳过）
4. 隧道域名
5. 直连协议勾选（模式 B 下 Hy2/TUIC 已勾）
6. 端口（默认值回车采用；Hy2 跳跃段默认 23000-27000）
7. 自签证书：已存在则复用，否则生成
8. 写配置 → 语法校验 → 防火墙 → 起服务 → 探测 → 订阅
9. 结尾打印：需要在云安全组放行的端口清单（按模式动态生成）
```

**关键防呆**（原 myproxy 脚本出过事故的地方）：
- 所有 `read` 都做 `v="${v:-$prev}"`，空输入 = 保留原值
- 端口冲突、域名格式非法直接拒绝，不静默继续
- 配置校验失败则回滚到上一份配置并重启

### 10.2 升级（对现有 v1.2.1）

```bash
curl -fsSL …/argox.sh -o /root/argox.sh && chmod +x /root/argox.sh
bash /root/argox.sh check     # 先看现状
bash /root/argox.sh upgrade   # 补字段，不动服务
```

升级动作只做四件事：
1. 补齐 `node.json` 新字段（直连协议默认全关、`landing.enabled=false`）
2. 重写 systemd 单元（路径对齐新脚本）
3. 重建订阅（节点名换成 `Argo-*` 新命名，数量与升级前一致）
4. 装 sing-box 二进制但**不启动**（等你菜单里开协议）

**升级后现状完全不变**，用户主动去菜单 8 打开某个协议才生效。

---

## 11. 自检 `check` 清单

参考 myproxy 的 `--self-check`，但检查项针对我们踩过的坑：

| 检查 | 方法 | 对应历史故障 |
|---|---|---|
| JSON/YAML 语法 | `xray run -test` / `sing-box check` | 手改配置写错 |
| 路径含空白字符 | 正则扫 `node.json` 与两份配置 | `path_xhttp` 前导空格导致节点全挂 |
| 配置端口 vs 实际监听 | `ss -lntup` 比对 | 服务 active 但端口没起 |
| 订阅文件名 vs 令牌 | 比对 `pub/` 与 `sub_token` | 订阅 404 |
| 客户端链接参数 vs 服务端 | 解析链接，逐字段比对 | 链接里的 host 写错（WS 必然不通） |
| 隧道注册状态 | 时间窗日志 + 实际请求（沿用 v1.2.1） | diag 误报 |
| 防火墙规则存在性 | `nft list ruleset` / `iptables -S` | 端口跳跃失效 |
| 端口段 vs 安全组 | 随机 3 个段内端口外部探测（需确认） | 安全组没放行整段 |
| 证书有效期 | `openssl x509 -enddate` | 自签过期 |
| Aimili 7928 可达性 | TCP connect | 落地节点静默失效 |

全部只读，不修改任何东西。

---

## 12. 对 myproxy 15 个问题的规避

| # | 原问题 | 本方案处理 |
|---|---|---|
| 1 | 四二进制写死 amd64 | `detect_arch` 统一解析 `arm64/amd64`，所有下载走变量；且只装 Xray + sing-box + cloudflared 三个 |
| 2 | CDN 落地用 2054（CF 不支持） | 落地不需要独立端口，改双 UUID 分流（2.4 节） |
| 3 | `mode=stream-one` | 统一 `mode=auto`（实测 stream-one 在 CF 隧道下不通） |
| 4 | 卸载删掉 argox 在用的 cloudflared | 卸载只删自己创建的二进制，先比对 md5 |
| 5 | token 明文写在 ExecStart | 沿用 `EnvironmentFile` |
| 6 | ExecStart 路径写死 | 二进制路径统一常量 + 实际校验存在性 |
| 7 | 临时隧道 nohup 无 systemd | 只用固定隧道，不做临时隧道 |
| 8 | 重装回车清空域名 | 所有输入 `v="${v:-$prev}"` |
| 9 | 订阅服务 0.0.0.0 明文 | 保持 127.0.0.1 + 走隧道 |
| 10 | AnyTLS 未校验橙云 / 依赖 1Panel 证书 | 改用自签证书，不再依赖任何已有站点与真域名 |
| 11 | 关落地不移除 UUID | 关落地时同步从 clients 里删掉 landing UUID，并重建订阅 |
| 12 | Hy2 带宽参数虚高 | 默认保守值 + 配置时可改 + 提示原理 |
| 13 | `sing-box check` 失败仍启动 | 校验失败拒绝启动，自动回滚 |
| 14 | 端口不联动、8443 冲突 | 统一端口分配表 + 冲突检测（含跳跃段与 TUIC 交叉校验） |
| 15 | 一键升全核 | 两核独立升级，可只升一个 |

---

## 13. 实施阶段（分五步，每步可独立验证）

| 阶段 | 内容 | 产出 | 回退 |
|---|---|---|---|
| **1** | 骨架重构：双核配置生成抽象、节点新命名（`Argo-*` + 裸协议名 + `-RH`）、`check` 自检、`upgrade` | 功能与现状完全一致，只是节点改名 | 换回 v1.2.1 脚本 |
| **2** | 住宅落地：双 UUID 分流 + `Argo-H3-RH` / `Argo-H2-RH` | 新增 2 条节点，零新端口 | 菜单关落地 |
| **3** | sing-box 接入：自签证书 + Hy2 + TUIC + 端口跳跃（默认 23000-27000，可配） | 新增 2 条节点 | 菜单关两协议 |
| **4** | Reality + AnyTLS（均**默认关**，只装不启） | 各 1–2 条，手动开 | 菜单关 |
| **5** | Clash YAML + sing-box JSON 订阅 | 多格式订阅 | 保留 vless 订阅 |

每阶段单独提交、单独推送，你实测通过再进下一阶段。
**阶段 1 严格不改动运行中的服务**，只动脚本结构与节点显示名——改名后订阅要重新导入一次，其余无感。

---

## 14. 风险清单（知情项）

1. **开公网端口 = 放弃零端口**，IP 会被扫描，这是最深的一处取舍（模式 B 只开 UDP 23000-27000 + 30001）
2. **UDP 协议特征比 TCP 明显**（sing-box 官方原话），加 Hy2/TUIC 是"拿隐蔽换速度"
3. **端口跳跃依赖云安全组放行整段**，配错会表现为随机断流，极难查
4. **自签 + insecure** 降低了中间人门槛（对翻墙场景影响有限，但要知道）
5. **落地 UUID 依赖 Aimili 存活**，Aimili 挂了那两条节点直接不可用（主节点不受影响）
6. **AnyTLS 与 H3 在客户端里互斥**——v2rayN 切 sing-box 内核后 H3 失效，要来回切
7. **双核 = 两个更新源**，将来某次升级可能不兼容；两核独立升级，可只升一个
8. **Reality 用 8443 非标端口**，本身就是一个特征，效果不如占 443
9. **节点改名后老订阅失效**：客户端里旧的 `argox-H3` 会残留，需删掉重新导入
