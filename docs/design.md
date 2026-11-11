# argox 设计文档

> 目标：在不使用付费中转的前提下，用 Cloudflare 边缘网络抵消跨境链路上的绕路延迟与晚高峰丢包。
> 状态：**已实现**，脚本见 `argox.sh`。

---

## 1. 背景与约束

### 背景

直连 VPS 公网 IP 时，跨境链路可能出现绕路与高峰时段丢包。用 Cloudflare Anycast
就近接入 + QUIC（H3）可缓解丢包带来的吞吐下降，且不依赖付费中转。

### 设计约束

| 项 | 值 |
|---|---|
| 架构 | ARM64 / AMD64 |
| 系统 | Ubuntu / Debian |
| 域名 | 已托管 Cloudflare，隧道需自行创建 |
| 客户端 | 支持 VLESS + XHTTP / Hy2 / TUIC / AnyTLS 的客户端 |
| 端口 | 不占用 443，不覆盖已有 xray.service，服务全部独立命名 |

---

## 2. 目标架构

```
客户端
  │  H3 / QUIC (UDP 443)，SNI = 隧道域名，入口 = 域名或优选 IP
  ▼
Cloudflare 边缘（Anycast 就近）
  │  QUIC 隧道（CF 内网）
  ▼
cloudflared (VPS 本地)
  │  明文 HTTP → 127.0.0.1:8001
  ▼
Xray (VLESS + XHTTP, security: none)
  │  直连出站
  ▼
目标站点
```

直连协议（Hy2 / TUIC / AnyTLS / Reality）由 sing-box 与 Xray 在公网端口上并行提供，
不经过隧道。

---

## 3. 采用 CF 隧道的原因

1. **就近接入**：客户端连最近的 CF 边缘，不直接连 VPS 公网 IP。
2. **CF 骨干 + 隧道内网**：cloudflared 主动外连最近 colo，回源不走公网 transit。
3. **QUIC 抗丢包**：多流独立重传，丢包时吞吐下降比 TCP 平缓。
4. **优选 IP**：可按需导入已排好序的 IP 列表，进一步优化入口。

---

## 4. 入站设计

> **本方案不占用 443。**
>
> ⚠️ 本节记录的是 **v1（零公网端口）** 阶段的入站设计，仅作历史参考。
> v2 起已恢复公网入站：REALITY 走 `8443/TCP`（仍不碰 443），
> Hy2 / TUIC / AnyTLS 由 sing-box 承载。当前方案见 `plan-v2.md` 第 2 节，
> 伪装目标选型见 `plan-v2.md` **2.6**。

| Tag | 用途 | 监听 | security | 说明 |
|---|---|---|---|---|
| `argo-xhttp` | **主力**，走 Argo 隧道 | 127.0.0.1:8001 | none | 仅本地监听，TLS 由 CF 终止；XHTTP `mode:auto` |
| `argo-ws` | **兼容兜底**，走 Argo 隧道 | 127.0.0.1:8002 | none | 客户端不支持 XHTTP 时切这个，任何客户端都能跑 |

**两个入站都只监听 `127.0.0.1`，服务端不开放任何公网端口。** REALITY（占 443）与直连备用（8443/WS+TLS、8443/udp H3）在 v1 阶段移除：前者占用 443，后者会多暴露一个公网入口。

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
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol auto run
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
| 协议 | `--protocol auto`（`tunnel_proto` 可改 quic / http2） | 先试 QUIC，UDP 7844 不通时自动退 http2；写死 quic 会在 UDP 被封时永久注册不上 |
| `--ha-connections` | quic 用默认 1；http2 用 4 | 该参数只对 http2 有效 |
| 启动方式 | systemd，`Restart=always` | 规避 Xray-go 的 nohup 不自启问题 |
| ingress | Dashboard → Public Hostname → `http://127.0.0.1:8001` | remotely-managed 不在本地配 |

### 出站诊断（`do_diag`）

cloudflared 出站走 **7844**（QUIC=UDP，http2=TCP）。出站被云厂商安全组 / 防火墙拦住时，进程照样
`active`，只是永远注册不上——这是最难自查的一类故障，所以单独做一层检测：

| 检查项 | 方法 | 判读 |
|---|---|---|
| 边缘域名解析 | `python3 socket.gethostbyname` / `getent ahosts` | 解析不到 = 本机 DNS 问题 |
| 出站 TCP 7844 | `timeout 6 bash -c 'exec 3<>/dev/tcp/<host>/7844'` | 不通 = 出站被拦，http2 回退路径也没了 |
| UDP 7844 | 间接：读日志里 `Registered tunnel connection ... protocol=` | `quic` = UDP 通；`http2` = UDP 出不去，已回退 |
| 注册状态 | 日志计数 `Registered tunnel connection`，起点取 `ActiveEnterTimestamp` | 0 条 = 进程在跑但连不上 CF |
| 链路实测 | `curl https://<隧道域名><path_xhttp>` | 400/404 = 通（Xray 对裸 GET 的正常反应）；530/1033 = 路由没指向本隧道；502/503 = 隧道通但回源失败 |

日志计数和链路实测是**双重判据**：cloudflared 只在建连成功那一刻打一条注册日志，稳定运行几小时后
时间窗内可能一条都没有；先按 `-n 200` 取行数又会被抖动时的错误刷屏挤掉。所以注册计数改为按
「本次进程启动时刻」到现在取时间窗，再用一次真实 HTTPS 请求兜底——两者任一通过即判定在线。

入口：安装流程内的「出站预检」、菜单 11 → `5)`、命令行 `argox.sh diag`。

`argox.sh diag quic|http2|auto` 会写入 `tunnel_proto` 并重建 systemd 单元重启，
用于 UDP 被封时强制走 TCP。

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

**唯一的 IP 来源是 Cloudflare 官方公布的段**（`104.16.0.0/12`、`172.64.0.0/13`、`162.158.0.0/15` 等），
候选列表由第三方维护者从这些段里实测产出，脚本只做拉取、过滤、排序。

**为什么脚本不在 VPS 上测速**：VPS 侧测的是「VPS → CF」，而需要优化的是「客户端 → CF」。
两者运营商、路由、拥塞完全不同，VPS 测出的结果对客户端没有参考价值。所以测速不放在服务端做。

### 处理流程（`import_ips()`）

```
1. 拉取       按 ips.src 里列出的 URL 依次下载，合并
2. 解析       兼容 IP / IP:PORT#备注 / CSV；端口非 443 丢弃
3. 段过滤     is_cf_ip() 剔除反代机、落地机（16.x / 23.x / 34.x / 35.x …）
4. 校验       curl --resolve 隧道域名:443:IP，返回 1033 淘汰
5. 排序       运营商匹配优先 → 下载速度降序 → 延迟升序
6. 截取       取前 MAX_IPS=12 个
```

排序细节（`sort_cand()`）：

| 优先级 | 分组 | 说明 |
|---|---|---|
| 0 | 与 `isp_pref` 匹配的组 | 默认 `auto`（不指定），可在菜单 12 → `5)` 改成 移动/联通/电信/多线 |
| 1 | 多线 | 通用性较好，作为次选 |
| 2 | 其他运营商 | 换网络时仍有节点可用 |
| 3 | 未知 | 列表未标分组 |

同组内按 **下载速度降序**，速度相同再按延迟升序。**速度优先于延迟**：优选 IP 之间延迟普遍只差 3–5ms，
但带宽能差两个数量级（0.45 mb/s vs 61.32 mb/s），按延迟排会选出跑不动的节点。

备注里既无 `ms` 也无分组关键词的条目直接丢弃——那是列表页眉页脚夹带的地址（`162.159.198.1` 之类），
不是有效优选结果。

### 从直链导入已排序的 IP（`import_ips_url()`）

`import_ips()` 按列表备注里的延迟/速度重排，那是列表维护者网络里的数据。
另一条通路 `import_ips_url()` 完全不重排，严格保留来源顺序：

```
直链（http(s) / ftp(s) / 本地文件）→ 菜单 12 → 6) 或 argox ips <地址>
  1. 解析     只取第一列，兼容 CSV / 纯 IP / IP:443 / IP#备注
  2. 段过滤   is_cf_ip() 剔除反代机
  3. 保序     ★ 不重排，取前 MAX_IPS=3
  4. 写盘     ips.txt + ips.meta
  5. 询问     是否切 ip 模式并重建订阅
```

地址可存进 `ips_url`，之后 `argox ips` 无参即直接拉取。VPS 侧只判断 IP 能否路由到
本隧道（anycast 结论全局一致），不给 IP 测速排名——延迟/带宽是路径相关量，
由客户端侧决定。

| 点 | 说明 |
|---|---|
| **时段性** | 优选 IP 的表现随时段变化，建议按实际使用时段选取 |
| **IP 只是入口** | 换 IP 只改「客户端 → CF 边缘」这一段，不影响回源 |

### 公共优选域名为什么不能直接用

Argo 隧道的路由靠 **SNI 精确匹配**到绑定的 hostname。用别人的优选域名当 SNI 会返回 **1033（Tunnel error）**。所以：

- 优选 **IP** + SNI 填**自己的隧道域名** → ✅ 可行
- 优选 **域名** + SNI 填自己的域名 → ✅ 需客户端支持 SNI 与地址分离
- 优选域名直接当 SNI → ❌ 必然 1033

---

## 8. 订阅

**只输出一个订阅，不逐条给节点。**

订阅服务 `argox-sub.service` 用 Python 标准库起一个只读 HTTP 服务：

```
/opt/argox/pub/<sub_token>   ← 文件名即 URL 路径
```

- 监听 `127.0.0.1:8099`，不开放公网
- 不列目录，未知路径一律 404
- `Content-Type: text/plain`，内容是 Base64 编码的 10 条 vless 链接
- `<sub_token>` 是 32 位随机串，存 `node.json`，重装沿用

外部通过隧道的 Path 规则暴露：

```
https://<隧道域名>/<sub_token>
```

十条节点：

| 节点 | 数量 | alpn | 用途 |
|---|---|---|---|
| `argox-H3-01` … `-04` | 4 | `h3` | **主力**。QUIC 系，丢包下吞吐不崩 |
| `argox-H2-01` … `-04` | 4 | `h2,http/1.1` | 对照。同一批 IP 走 TCP，用于 A/B |
| `argox-WS-01` … `-02` | 2 | 默认 | 兼容兜底，走 `/ws*` → 8002 |

节点名末尾带运营商标签（`argox-H3-01-移动`）。H2 与 H3 用同一批 IP，`H3-01` 和 `H2-01` 只差协议、不差入口。

备用输出：`sub/argox.b64`、`sub/argox.txt`，订阅服务异常时可直接导入文件。

## 8.1 出口跳板（可选）

把 Xray 的出站挂到 VPS 本机的代理端口上（住宅 IP / 商业 VPN 客户端提供的本地 SOCKS5 或 HTTP）：

| `hop_mode` | 出站 | 目标站看到 |
|---|---|---|
| `off`（默认） | `freedom` | VPS 原生 IP |
| `all` | `socks` / `http` → `hop_addr:hop_port` | 代理的出口 IP |

实现要点：

- `write_xray_config()` 在 `all` 时把 `hop` 放进 `outbounds[0]`（即默认出口），并追加一条 `"network": "tcp,udp"` 兜底路由
- 私网段（`127.0.0.0/8` 等）仍走 `direct`，回环流量不会被绕进代理
- 只连 `127.0.0.1`，不新增任何公网端口；cloudflared 不经过 Xray，隧道不受代理影响
- 切换前先 `curl -x` 探测代理可用性，不通就直接拒绝切换
- 切换后 Xray 起不来自动回滚到切换前的 `hop_mode`
- `domainStrategy: AsIs`，域名原样交给代理服务端解析，落地出口更干净

配置键：`hop_mode` / `hop_proto` / `hop_addr` / `hop_port`，重装时沿用。

## 9. 文件布局

```
/opt/argox/
├── config.json              # Xray 配置（三入站）
├── node.json                # UUID / 域名 / 路径 / 端口（600）
├── ips.txt                  # 优选 IP
├── sub/argox.txt            # 节点链接
├── sub/argox.b64            # Base64 订阅
├── pub/<sub_token>          # 订阅服务实际读取的文件（= 上面的 b64）
├── sub_server.py            # 订阅服务（Python 标准库，只读）
├── qr/*.png                 # 订阅二维码
├── logs/access.log,error.log
└── backup/node.json.<ts>.bak  # upgrade 自动留存

/etc/argox/token.env         # TUNNEL_TOKEN（700/600）
/usr/local/bin/argox-xray    # 独立二进制，不与已有 xray 冲突
/usr/local/bin/cloudflared
/etc/systemd/system/argox-xray.service
/etc/systemd/system/argox-tunnel.service
/etc/systemd/system/argox-sub.service
/etc/sysctl.d/99-argox.conf
/etc/logrotate.d/argox
```

### 与现有环境的隔离

| 项 | 处理 |
|---|---|
| 443 端口 | **完全不动**，本方案不用 443 |
| 已有的 `xray.service` / `/etc/xray` | **不碰**。服务名 `argox-xray`，配置在 `/opt/argox` |
| 其他反向代理 / 回源服务 | 互不冲突；服务与配置目录均独立命名 |
| cloudflared 二进制 | 放 `/usr/local/bin/cloudflared`，卸载时保留（可能被他人复用） |

---

## 10. 安装流程

```
bash argox.sh            → 进入菜单 → 选 1
  ├─ 预检：root / 架构(arm64|amd64) / 内存 / 磁盘 / 依赖
  ├─ 端口检测：8001、8002、8099 必须空闲（仅监听本地回环）
  ├─ 交互 1：隧道域名（可留空，菜单 11 → 2 后补）
  ├─ 交互 2：现在粘贴 Tunnel Token？（y/N，可跳过）
  ├─ 生成：UUID / 两个随机 path / 订阅令牌
  ├─ 下载 Xray + cloudflared（多镜像回退）
  ├─ 写 Xray 配置 → xray -test 校验 → 失败即中止
  ├─ 写 systemd（argox-xray / argox-tunnel / argox-sub）
  ├─ 系统优化（BBR + fq + 文件句柄 + 端口范围）
  ├─ 启动 + 健康检查（含隧道注册状态、订阅服务）
  ├─ 导入优选 IP（可跳过，用内置列表）
  └─ 打印订阅地址 / 二维码
```

### 菜单（20 项，v2.11.0）

```
 1) 安装 / 重新部署           9) 更换 UUID
 2) 启动                     10) 更新脚本自身（联网）
 3) 停止                     11) 隧道设置（Token / 域名 / 测试）
 4) 重启                     12) 优选 IP（导入测速结果）
 5) 查看状态                 13) 出口跳板
 6) 查看日志                 14) 直连协议（Hy2/TUIC/AnyTLS/Reality）
 7) 更新内核程序             15) 住宅落地
 8) 自检 check               16) 订阅地址 / 二维码
 17) 端口管理                18) 系统优化
 19) 清理缓存                20) 卸载
```

菜单有两种更新，互不替代：7 = 内核程序（三个二进制），10 = 脚本自身。
因为更新脚本自身时会自动同步配置，菜单不再单列「升级配置」一项。

菜单 7 `update` 只替换 Xray / cloudflared / sing-box 三个二进制，不更新 Linux 内核、
脚本自身与配置。sing-box 的 release 资产名带版本号、无法拼 `latest`，所以版本跟随
脚本内置的 `SB_VER_DEFAULT`（可用 `SB_VER=x.y.z` 覆盖），换新脚本后跑一次菜单 7 即对齐。
`start` / `stop` / `restart` 均包含第四个服务 `argox-sb`。

**脚本自身更新**（菜单 10 / `argox selfupdate`）：命令入口 `/usr/local/bin/argox`
写死 `exec bash /root/argox.sh`，所以必须覆盖同一路径，curl 到别的文件名不会生效。
`selfupdate` 联网拉取最新脚本、校验后落盘，并自动跑 `do_upgrade` 把字段 / systemd
单元 / 订阅服务同步到 `/opt/argox`。等价手工两步：
`curl -fsSL -o /root/argox.sh <raw 地址> && argox upgrade`（`upgrade` 不联网，
仅同步配置，保留为命令行子命令）。

备份入口 v2.8.0 移除：install 重装本身无损（uuid / sub_token / 端口 / 密钥 /
优选 IP 全部保留），upgrade 会自动留 `node.json.<时间戳>.bak`，单独的手动备份
既没有恢复入口也没有实际场景。

非交互调用：`argox.sh install|start|stop|restart|status|logs|update|selfupdate|upgrade|ips|nodes|links|sub|uninstall`。

---

## 11. 需要你手动完成的（脚本无法代做）

1. **CF Dashboard 建隧道**：Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared → 复制 token。
2. **配 Public Hostname**：子域名 → 服务 `http://127.0.0.1:8001`（XHTTP）。
   v2.7.0 起只需这一条：WS 入站与 8002 已删除，订阅改为直连 VPS 端口，不再需要 `ws` / `sub` 子域。
3. **开启 HTTP/3**：Speed → Optimization → Protocol Optimization → HTTP/3 打开（用 H3 节点必须开）。
4. **SSL/TLS 模式**：隧道模式不涉及；若另有橙云回源，设为 Full。
5. 把 token 粘贴给脚本（安装时，或菜单 11 → 1）。

详细步骤见 `docs/cloudflare-setup.md`。

---

## 12. 验证清单

| 检查 | 命令 / 方法 | 期望 |
|---|---|---|
| Xray 启动 | `systemctl status argox-xray` | active |
| 隧道在线 | `systemctl status argox-tunnel` + Dashboard Healthy | 是 |
| 隧道注册 | `bash argox.sh diag`（日志时间窗 + 链路实测） | 至少一条判据通过 |
| 本地入站 | `curl -sI http://127.0.0.1:8001/<path>` | 非 000 / 非 502 |
| 隧道回源 | 菜单 11 → 3 测试 | 非 1033 / 530 / 502 |
| 客户端连通 | karing 日志 | 无 handshake 失败 |
| 延迟 | `ping <优选IP>` | 视线路而定，越低越好 |
| 吞吐 | 实测下载 | 与直连 VPS 对比 |

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
| QUIC 隧道在高峰时段的实际表现 | 客户端实测 | 决定 H3 是否为主力 |
| CF 回源延迟 | 隧道建立后测 | 决定整体收益 |

---

## 15. 已实现清单

| 文件 | 行数 | 说明 |
|---|---|---|
| `argox.sh` | ~1350 | 单文件：安装 / 菜单 / 订阅 / 优选 / 卸载 全部内联 |
| `docs/design.md` | — | 本文档 |
| `docs/cloudflare-setup.md` | — | Dashboard 建隧道图文步骤 |

单文件设计的理由：只需 `scp` 一个文件到 VPS，不依赖 git、不依赖二级目录，降低部署门槛。

已规避的 Xray-go 问题：token 不进命令行、systemd 自启、配置不覆盖已有 xray、端口合法性校验、架构严格判断、路径随机化。
