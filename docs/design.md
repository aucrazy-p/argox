# argox 设计文档

> 目标：在不使用付费中转的前提下，用 Cloudflare 边缘网络抵消跨境链路上的绕路延迟与晚高峰丢包。
> 状态：**已实现**，脚本见 `argox.sh`。

---

## 1. 背景与约束

### 典型场景（2026-11 实测样本）

| 指标 | 数值 |
|---|---|
| 白天 ping | 251 ms 平均，0% 丢包 |
| 晚高峰 ping | 242 ms 平均，**24% 丢包** |
| 路由 | 移动 CMNET → CMI(69ms) → PCCW 美国段(230ms) → 大阪(234ms) |
| 根因 | CMI 与 PCCW 的互联点在美国，去程绕美 |

**关键观察**：晚高峰延迟几乎不变（251 → 242ms），只有丢包从 0% 涨到 24%。
说明不是带宽跑满，而是**互联端口队列溢出**。对 TCP 是灾难（重传 + 拥塞窗口收缩），
对 QUIC 是可控的（多流独立重传）。

### 设计约束

| 项 | 值 |
|---|---|
| VPS | Oracle Cloud 大阪（案例），**ARM64 (Ampere A1)** |
| 系统 | Ubuntu 22.04 / 24.04（Debian 兼容） |
| 域名 | 已托管 Cloudflare，隧道需自行创建 |
| 客户端 | karing（Xray 内核），兼容 v2rayN / Clash Meta |
| 现有部署 | 已有 1panel 占用 443 |
| 预算 | 0（不买中转、不买 Argo Smart Routing） |

---

## 2. 目标架构

```
客户端 (karing / Xray 内核)
  │  H3 / QUIC (UDP 443)，SNI = 隧道域名，入口 = 优选 IP
  ▼
Cloudflare 边缘 (HKG / NRT，Anycast 就近)
  │  QUIC 隧道（CF 内网，不经公网）
  ▼
cloudflared (VPS 本地)
  │  明文 HTTP → 127.0.0.1:8001
  ▼
Xray (VLESS + XHTTP, security: none)
  │  直连出站
  ▼
目标站点
```

### 预期收益

| 段 | 现状 | 目标 |
|---|---|---|
| 你 → CF 边缘 | — | 30–50 ms |
| CF → 大阪（隧道） | — | 10–30 ms |
| 合计 | 250 ms / 24% 丢包 | **40–80 ms**，丢包由 QUIC 吸收 |

---

## 3. 为什么能提速（四个独立机制）

1. **绕开 CMI→PCCW 美国互联点**：客户端不再直连 VPS 公网 IP，改由 CF 边缘接入。
2. **CF 骨干 + 隧道内网**：cloudflared 主动外连最近 colo，CF 边缘到 VPS 不走公网 transit。
3. **QUIC 抗丢包**：24% 丢包下，TCP 吞吐会崩到 1/10，QUIC 多流独立重传可维持大部分吞吐。
4. **优选 IP**：入口再优化 10–30 ms，且可随时更换。

---

## 4. 入站设计

> **443 被 1panel 占用，本方案完全不碰 443。REALITY 方案已移除。**

| Tag | 用途 | 监听 | security | 说明 |
|---|---|---|---|---|
| `argo-xhttp` | **主力**，走 Argo 隧道 | 127.0.0.1:8001 | none | 仅本地监听，TLS 由 CF 终止；XHTTP `mode:auto` |
| `argo-ws` | **兼容兜底**，走 Argo 隧道 | 127.0.0.1:8002 | none | 客户端不支持 XHTTP 时切这个，任何客户端都能跑 |

**两个入站都只监听 `127.0.0.1`，服务端不开放任何公网端口。** REALITY（占 443，与 1panel 冲突）与直连备用（8443/WS+TLS、8443/udp H3）均已移除：前者冲突，后者解决不了绕路问题，且白白暴露一个公网入口。

### argo-xhttp（核心）

```json
{
  "tag": "argo-xhttp",
  "listen": "127.0.0.1",
  "port": 8001,
  "protocol": "vless",
  "settings": {
    "clients": [{ "id": "<UUID>" }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": { "path": "/<RANDOM>", "mode": "auto" }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": true
  }
}
```

### argo-ws（兼容兜底）

```json
{
  "tag": "argo-ws",
  "listen": "127.0.0.1",
  "port": 8002,
  "protocol": "vless",
  "settings": { "clients": [{ "id": "<UUID>" }], "decryption": "none" },
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": { "path": "/<RANDOM2>" }
  }
}
```

---

## 5. 隧道设计

采用 **remotely-managed tunnel（token 模式）**，ingress 在 CF Dashboard 配置，本地不写 `config.yml`。

### systemd 单元

```ini
[Unit]
Description=argox Cloudflare Tunnel
After=network-online.target argox-xray.service
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=/etc/argox/token.env
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol quic run
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

`/etc/argox/token.env`（目录 700 / 文件 600）：

```
TUNNEL_TOKEN=<安装时粘贴>
```

### 关键决策

| 项 | 选择 | 理由 |
|---|---|---|
| token 传递 | `EnvironmentFile` + `TUNNEL_TOKEN` | 不出现在 `ps` / `/proc/cmdline`，规避 Xray-go 的 P0 问题 |
| 协议 | `--protocol quic` | 全段 UDP，与客户端 H3 对齐 |
| `--ha-connections` | quic 用默认 1；http2 用 4 | 该参数只对 http2 有效 |
| 启动方式 | systemd，`Restart=always` | 规避 Xray-go 的 nohup 不自启问题 |
| ingress | Dashboard → Public Hostname → `http://127.0.0.1:8001` | remotely-managed 不在本地配 |

---

## 6. 系统优化

```
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 10240 65000
```
另加：`ulimit -n 65535`（systemd `LimitNOFILE`）。

MTU：隧道场景建议 1400，写入 cloudflared 所在网络的接口（仅当实测出现分片问题时调整）。

---

## 7. 优选 IP（怎么来的）

**来源一：自动测速（推荐）**

脚本内置 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)，菜单 16 触发：

```
cfst -tp 443 -tl 250 -tll 0.2 -dn 10 -p 10 -o ips.tmp
```

含义：只测 443 端口、延迟上限 250ms、丢包率上限 0.2、下载测速 10 个、取前 10 名。
结果写入 `/opt/argox/ips.txt`，订阅生成时取前两个 IP 分别给 H2 / H3 节点。

**来源二：内置兜底列表**

测速失败（VPS 出网受限、镜像被墙）时写入 16 个常见 CF 段 IP，保证订阅可用。

**来源三：手动指定**

直接编辑 `/opt/argox/ips.txt`，一行一个 IP，菜单 17 重新出链接即可。

### 三个必须知道的点

| 点 | 说明 |
|---|---|
| **时段性** | 优选 IP 早晚差别极大。凌晨测的 30ms，晚高峰可能 150ms + 丢包。**要在 20:00–23:00 测**才有效 |
| **协议错配** | `cfst` 测的是 TCP/ICMP，而 H3 走 UDP。TCP 延迟低的 IP，UDP 可能很差。**最终以客户端实测吞吐为准** |
| **IP 只是入口** | 换 IP 只改「你 → CF 边缘」这一段，改不了「CF → 你的 VPS」回源段 |

### 公共优选域名为什么不能直接用

Argo 隧道的路由靠 **SNI 精确匹配**到绑定的 hostname。用别人的优选域名当 SNI 会返回 **1033（Tunnel error）**。所以：

- 优选 **IP** + SNI 填**自己的隧道域名** → ✅ 可行
- 优选 **域名** + SNI 填自己的域名 → ✅ 需客户端支持 SNI 与地址分离
- 优选域名直接当 SNI → ❌ 必然 1033

---

## 8. 客户端与订阅

**客户端：karing（支持 Xray 内核 → 原生支持 XHTTP）**。因此输出的是通用 VLESS 分享链接，而不是 sing-box 专用 JSON，这样 karing / v2rayN / Clash Meta 都能直接导入。

每个节点一条链接：

```
vless://<UUID>@<优选IP>:443
  ?encryption=none&security=tls&sni=<隧道域名>&fp=chrome
  &type=xhttp&path=<编码后的路径>&host=<隧道域名>&mode=auto
  #argox-XHTTP-H2
```

### 四个节点

| 节点 | alpn | 用途 |
|---|---|---|
| `argox-XHTTP-H2` | `h2,http/1.1` | **主力**。TCP 系，兼容性最好 |
| `argox-XHTTP-H3` | `h3` | QUIC 系，抗丢包。客户端不支持则忽略 |
| `argox-WS` | 默认 | 兼容兜底，任何客户端都能跑 |

**为什么必须同时给 H2 和 H3**：移动对 UDP 的 QoS 可能比 TCP 更狠。如果 H3 反而更慢，直接切 H2，不用改服务端。这是整套方案唯一的「不确定性保险」。

### 导入方式

- 二维码：`/opt/argox/qr/*.png`，karing 扫码
- 文本：`/opt/argox/sub/argox.txt`（原始链接）/ `argox.b64`（Base64 订阅）
- 菜单 17 直接在终端打印链接 + ANSI 二维码

---

## 9. 文件布局

```
/opt/argox/
├── config.json              # Xray 配置（三入站）
├── node.json                # UUID / 域名 / 路径 / 端口（600）
├── ips.txt                  # 优选 IP
├── sub/argox.txt            # 节点链接
├── sub/argox.b64            # Base64 订阅
├── qr/*.png                 # 节点二维码
├── logs/access.log,error.log
└── backup/argox-*.tar.gz    # 菜单 13 备份

/etc/argox/token.env         # TUNNEL_TOKEN（700/600）
/usr/local/bin/argox-xray    # 独立二进制，不与已有 xray 冲突
/usr/local/bin/cloudflared
/usr/local/bin/cfst          # 优选测速工具
/etc/systemd/system/argox-xray.service
/etc/systemd/system/argox-tunnel.service
/etc/sysctl.d/99-argox.conf
/etc/logrotate.d/argox
```

### 与现有环境的隔离

| 项 | 处理 |
|---|---|
| 1panel 占用的 443 | **完全不动**，本方案不用 443 |
| 已有的 `xray.service` / `/etc/xray` | **不碰**。服务名 `argox-xray`，配置在 `/opt/argox` |
| cdnx（橙云回源） | 互不冲突；本方案不占用任何公网端口 |
| cloudflared 二进制 | 放 `/usr/local/bin/cloudflared`，卸载时保留（可能被他人复用） |

---

## 10. 安装流程

```
bash argox.sh            → 进入菜单 → 选 1
  ├─ 预检：root / 架构(arm64|amd64) / 内存 / 磁盘 / 依赖
  ├─ 端口检测：8001、8002 必须空闲（仅监听本地回环）
  ├─ 交互 1：隧道域名（可留空，菜单 15 后补）
  ├─ 交互 2：现在粘贴 Tunnel Token？（y/N，可跳过）
  ├─ 生成：UUID / 两个随机 path / 自签证书
  ├─ 下载 Xray + cloudflared（多镜像回退）
  ├─ 写 Xray 配置 → xray -test 校验 → 失败即中止
  ├─ 写 systemd（argox-xray / argox-tunnel）
  ├─ 系统优化（BBR + fq + 文件句柄 + 端口范围）
  ├─ 启动 + 健康检查（含隧道注册状态）
  ├─ 优选 IP 测速（可跳过，用内置列表）
  └─ 打印 UUID / 路径 / 全部节点链接 / 二维码
```

### 菜单（17 项）

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

也支持非交互调用：`argox.sh install|start|stop|restart|status|logs|update|ips|nodes|sub|uninstall`。

---

## 11. 需要你手动完成的（脚本无法代做）

1. **CF Dashboard 建隧道**：Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared → 复制 token。
2. **配 Public Hostname**：子域名 → 服务 `http://127.0.0.1:8001`（XHTTP）。若要用 WS 兜底节点，再加一条 `http://127.0.0.1:8002`。
3. **开启 HTTP/3**：Speed → Optimization → Protocol Optimization → HTTP/3 打开（用 H3 节点必须开）。
4. **SSL/TLS 模式**：隧道模式不涉及；若同时保留 cdnx 橙云回源，设 Full。
5. 把 token 粘贴给脚本（安装时，或菜单 15）。

详细步骤见 `docs/cloudflare-setup.md`。

---

## 12. 验证清单

| 检查 | 命令 / 方法 | 期望 |
|---|---|---|
| Xray 启动 | `systemctl status argox-xray` | active |
| 隧道在线 | `systemctl status argox-tunnel` + Dashboard Healthy | 是 |
| 隧道注册 | `journalctl -u argox-tunnel -n 30 \| grep Registered` | 有记录 |
| 本地入站 | `curl -sI http://127.0.0.1:8001/<path>` | 非 000 / 非 502 |
| 隧道回源 | 菜单 15 → 3 测试 | 非 1033 / 530 / 502 |
| 客户端连通 | karing 日志 | 无 handshake 失败 |
| 延迟 | `ping <优选IP>` 晚高峰 | < 80 ms，丢包 < 3% |
| 吞吐 | 实测下载 | 对比直连 250ms 时的速度 |

**排错对照表**

| 现象 | 原因 |
|---|---|
| HTTP 1033 | Public Hostname 没指向本隧道，或隧道没起 |
| HTTP 530 | 隧道离线 |
| HTTP 502 | CF 到源站了，但 127.0.0.1:8001 没在听 |
| 连上但很快断 | Xray 路径与客户端不一致，或 Free CPU 限制 |
| H3 节点全不通 | CF 后台没开 HTTP/3 |
| 只有 WS 能连 | 客户端不支持 XHTTP，正常，用 WS 即可 |

---

## 13. 风险与限制

1. **CF ToS 禁止代理类流量**，隧道跑代理同样违规，账号可能被限制。
2. **移动 UDP QoS**：H3 的理论优势在丢包，但运营商若直接限 UDP 带宽，H3 会输给 H2/TCP。因此 H2/H3 双节点对照。
3. **CF 免费版带宽共享**：晚高峰 HKG 节点也会拥塞，收益不保证。
4. **单点依赖 CF**：CF 抽风则全挂，无直连兜底（已按需求移除公网入站）。
5. **不占 443 的代价**：放弃 REALITY，抗主动探测能力弱于 REALITY，但本方案本来就不靠 VPS 入站 IP 暴露。

---

## 14. 待实测项

| 项 | 验证方式 | 影响 |
|---|---|---|
| karing 的 Xray 内核对 `type=xhttp` 解析 | 导入后看日志 | 若否，切 WS 节点 |
| XHTTP `mode:auto` 在 `security:none` 下是否正常 | 客户端实测 | 若异常，服务端改 `stream-one` |
| QUIC 隧道在移动晚高峰的实际表现 | 20:00–23:00 实测 | 决定 H3 是否为主力 |
| CF 大阪回源延迟 | 隧道建立后测 | 决定整体收益 |

---

## 15. 已实现清单

| 文件 | 行数 | 说明 |
|---|---|---|
| `argox.sh` | ~1350 | 单文件：安装 / 菜单 / 订阅 / 优选 / 卸载 全部内联 |
| `docs/design.md` | — | 本文档 |
| `docs/cloudflare-setup.md` | — | Dashboard 建隧道图文步骤 |

单文件设计的理由：只需 `scp` 一个文件到 VPS，不依赖 git、不依赖二级目录，降低部署门槛。

已规避的 Xray-go 问题：token 不进命令行、systemd 自启、配置不覆盖已有 xray、端口合法性校验、架构严格判断、路径随机化。
