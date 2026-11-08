# Cloudflare 隧道配置手册

> 这一步脚本代做不了，必须在 Cloudflare 后台点。全程约 5 分钟。
> 做完之后，把 Token 粘贴给脚本（安装时，或菜单 15）。

---

## 0. 前置检查

| 项 | 要求 |
|---|---|
| 域名 | 已托管到 Cloudflare（NS 指向 CF，状态 Active） |
| 账号 | 已开通 Zero Trust（首次进入会让你取个 team 名，免费版即可） |
| VPS | 能正常出网访问 `*.cloudflare.com` |

---

## 1. 建隧道

1. 打开 <https://one.dash.cloudflare.com/>
2. 左侧 **Networks → Tunnels**（旧版叫 **Access → Tunnels**）
3. 点 **Create a tunnel**
4. Connector 类型选 **Cloudflared**，Next
5. 隧道名填 `argox`（随便，自己认得就行），Save

---

## 2. 复制 Token（关键）

创建后会跳到「Install connector」页面，给你几条不同系统的安装命令。

**只需要这里面的 Token 字符串**，也就是 `--token` 后面那一长串 `eyJhIjoi...`。

它一般在这样的位置：

```bash
sudo cloudflared service install eyJhIjoiXXXXXXXXXXXXXXXX...
```

> ⚠️ 不要真的执行这条命令。argox 自己管 cloudflared，重复安装会造成两套服务抢同一条隧道。
>
> 只复制 `eyJ...` 这一串，回到脚本里粘贴。

**如果这页已经关掉了**：Tunnels 列表 → 点进 `argox` → **Configure** → 顶部能看到 token，或点 **Refresh token** 重新生成（旧的立即失效）。

---

## 3. 配 Public Hostname（决定流量往哪走）

**v2.7.0 起只需要一条路由。** 订阅已经改成直连 VPS 的 TCP 端口，不再经过隧道；
WS 入站也已删除（H2 节点走 `XHTTP + ALPN=h2`，和 H3 共用同一个回源）。

| # | Subdomain | Path | Service → Type | Service → URL | 用途 |
|---|---|---|---|---|---|
| 1 | `argo` | **留空** | `HTTP` | `127.0.0.1:8001` | H3 / H2 主入口 |

路径：该隧道页面 → **Public Hostname** 标签（新版叫 **Published application routes** / **Routes**）→ **Add a public hostname**，加一条就够。

单条的填写模板：

| 表单字段 | 填什么 |
|---|---|
| Subdomain | `argo` |
| Domain | 你的域名 |
| Path | **什么都不填** |
| Service → Type | `HTTP` |
| Service → URL | `127.0.0.1:8001` |

保存后，**DNS 页面**应自动出现一条「隧道」类型记录（橙色云，目标指向你的隧道）。

```
argo.example.com     ← 唯一入口，脚本里填这个
```

**`argo.example.com` 就是脚本里要填的「隧道域名」。**

### 3.1 面板里多余的 Public Hostname

隧道只需要上面这一条。如果面板里还有 `ws` / `sub` 之类的子域路由，删掉：

1. 删掉 `ws` 和 `sub` 两条 **Public Hostname**
2. 去 **DNS 页面**确认对应的两条 CNAME 也消失了 —— 删路由**不一定**连带删 DNS 记录，
   残留的记录会让域名继续解析到隧道，访问得到 1033 而不是干净地 NXDOMAIN
3. `sub` 这条尤其要确认，否则你可能以为订阅还在走隧道

删不干净不会导致节点不可用（只是留了个 1033 的空壳域名），但排查问题时容易误判。

### 3.2 订阅地址与令牌

订阅令牌是安装时随机生成的 32 位十六进制，装完才有：

```bash
grep -o '"sub_token": *"[^"]*"' /opt/argox/node.json
```

订阅地址固定为（**直连，不经隧道**）：

```
http://<VPS 公网 IP>:<订阅端口>/<你的32位令牌>
```

端口默认 `8099`。直接打印，不用自己拼：

```bash
bash /root/argox.sh nodes      # 菜单 16 也会显示
```

两个前提：

- Oracle 安全组放行 **TCP 8099**（本机防火墙脚本会自动放行）
- 想换端口：`bash argox.sh port sub 9000`，改完记得同步放行新端口

令牌**每人每台机都不一样**，复制命令输出，不要照抄文档里的任何示例串（照抄必 404）。

### 3.3 主域名解析不到（NXDOMAIN）

**面板里有记录 ≠ 权威服务器上有记录。** 用命令行验证，别信页面：

```bash
dig +short argo.example.com @8.8.8.8
```

返回 `104.x` / `172.6x` 才算真的生效。返回空则是记录没写进去，表现是客户端全连不上（530）。

修法：把该条 Public Hostname 删掉重加（CF 会连带重建 DNS），或者去 **DNS 页面**手动加：

| 类型 | 名称 | 内容 | 代理 |
|---|---|---|---|
| CNAME | `argo` | `<隧道UUID>.cfargotunnel.com` | 已代理（橙色云） |

隧道 UUID 在隧道详情页顶部或地址栏 `.../networks/tunnels/<UUID>`，**不是副本 ID**。

### 3.4 必须注意的点

1. **Path 留空**。填了具体 Path 不会更安全，只会引入匹配歧义（cloudflared 是按顺序命中第一条，不是最长匹配）。
2. **URL 只填 `host:port`**，不要带 `http://`；协议由 Type 下拉框决定。选 `HTTP`（源站是明文监听），选 HTTPS 会握手失败。
3. **不需要再配多条子域**。想用自定义域名当 SNI，可以给同一条隧道再加 Public Hostname 指向 `127.0.0.1:8001`，那是「优选域名」玩法，不是必需的。

## 4. 开启 HTTP/3（用 H3 节点必须）

**注意：这是 Zone（域名）级设置，不是 Zero Trust 里的。要回主控制台操作。**

1. 打开 <https://dash.cloudflare.com/>，**点进你的域名**（不是账号首页）
2. 左侧菜单 **Speed**（速度）
3. 进 **Optimization**（优化）
   > 部分账号这栏叫 **Speed → Settings**，两个是同一个页面，看哪个有就点哪个
4. 找到 **Protocol Optimization**（协议优化）折叠区，展开
5. 把 **HTTP/3 (with QUIC)** 的开关打到 **On**

直达链接（把 `你的域名.com` 换掉）：

```
https://dash.cloudflare.com/?to=/:account/你的域名.com/speed/optimization
```

生效通常要 **1–5 分钟**，不用重启任何东西。

### 怎么确认真的开了

在任意一台机器上跑（本机就行，不用在 VPS 上）：

```bash
curl -sI https://argo.你的域名.com | grep -i alt-svc
```

看到类似这行就说明生效了：

```
alt-svc: h3=":443"; ma=86400
```

没有 `alt-svc` 这行 = 还没开，或者还没生效，等几分钟再试。

### 两个重要边界

**① 只作用于「用户 → CF 边缘」这一段**

Cloudflare 官方明确：`This setting is for connection between the user and Cloudflare. HTTP/3 connection to the origin is not yet supported.`

这**正好是我们要的**——你的瓶颈就是「移动 → CF 边缘」这段国际出口。CF 到你的 VPS 走的是隧道（CF 内网），本来就不需要 H3。

**② 开了不代表一定更快**

有些运营商对 UDP 的 QoS 比 TCP 更狠，或者客户端内核不支持 XHTTP over QUIC，这时 H3 会连不上。所以订阅默认给两条走 CF 的：

- `Argo-H3`（UDP/QUIC）— 实测通常最快，抗丢包
- `Argo-H2`（TCP，同一个回源、只换 ALPN）— UDP 被限速时切过去

用数据决定主用哪条，别只看名字。

不开 HTTP/3 也不影响主流程：H2 照常工作，只是 H3 节点会握手失败。
CF 侧路不理想时，直接切直连那几条（Hy2 / TUIC / AnyTLS / Reality），它们不经过 CF。

> 实测提醒：客户端内核要支持 XHTTP over QUIC 才能用 H3。**v2rayN（Xray 内核）可以，karing（sing-box 内核）不行**——后者表现是 H3 全部 ×，且服务端 `access.log` 里一条请求都收不到。

---

## 5. 交给脚本

```bash
# 用 WindTerm 的 SFTP 面板把 argox.sh 拖到 /root/ ，然后：
chmod +x /root/argox.sh
bash /root/argox.sh
```

菜单选 `1`，按提示：

1. 隧道域名填 `argo.你的域名.com`
2. 提示粘贴 Token 时选 `y`，粘贴刚才复制的 `eyJ...`

---

## 6. 验证

脚本装完会自动检查。手动复查：

```bash
# 隧道进程 + 注册状态
systemctl status argox-tunnel
journalctl -u argox-tunnel -n 30 --no-pager | grep "Registered tunnel connection"

# 回源是否通（在 VPS 上跑）
curl -sI http://127.0.0.1:8001/<path_xhttp>

# 从外部访问隧道域名，应该不是 1033 / 502
curl -sI https://argo.你的域名.com

# 订阅地址（直连 VPS，应返回一屏 Base64 文本）
curl -s http://<VPS公网IP>:8099/<订阅令牌> | head -c 120

# 主域名解析到了 CF 才算配齐（订阅不吃 DNS，走 IP）
dig +short argo.你的域名.com @8.8.8.8
```

或者直接用菜单 `15 → 3` 测试，脚本会翻译错误码。

### 错误码对照

| 码 | 含义 | 怎么修 |
|---|---|---|
| **1033** | Cloudflare 找不到这条隧道的路由 | Public Hostname 没配，或域名写错 |
| **530** | 隧道离线 | `systemctl status argox-tunnel`，看 Token 是否有效 |
| **502 / 503** | CF 到了，但源站没响应 | `127.0.0.1:8001` 没在听 → `systemctl status argox-xray` |
| **1033 + 域名对** | Token 与域名不属于同一隧道 | 重新确认 Token 来源 |

---

## 7. 常见问题

**Q：隧道列表显示 DOWN / Inactive？**
A：cloudflared 没跑起来，或 Token 过期。菜单 15 重新粘贴 Token。

**Q：一定要用正式隧道吗，临时 trycloudflare 行不行？**
A：临时隧道域名每次重启都变，不能长期用。只适合当 10 分钟的可行性探针。日常必须用这条 token 隧道。

**Q：改 Public Hostname 需要重启脚本吗？**
A：不需要。remotely-managed 隧道配置在 CF 侧，改完几十秒内自动生效。

**Q：能不能绑多个域名？**
A：可以。同一条隧道下加多个 Public Hostname 都指向 `127.0.0.1:8001`，每个都能在客户端当 SNI 用。这是自建「优选域名」的正确姿势。

**Q：为什么不直接橙云回源（cdnx 那种）？**
A：橙云回源要 CF 走公网连你 VPS，VPS 的 IP 被封就全挂。隧道是 VPS 主动外连，IP 被封也能活。两者的入口段体验接近，区别在抗封锁。
