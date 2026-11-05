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

同一个隧道页面 → **Public Hostname** 标签 → **Add a public hostname**。

一共三条规则，**都填同一个 Subdomain + Domain，靠 Path 区分**：

| # | Path | Type | URL | 用途 |
|---|---|---|---|---|
| 1 | 留空 | HTTP | `127.0.0.1:8001` | 主入口，H3 / H2 节点 |
| 2 | `/ws*` | HTTP | `127.0.0.1:8002` | WS 兜底节点（可选） |
| 3 | `/<订阅令牌>` | HTTP | `127.0.0.1:8099` | 订阅地址 |

第 3 条的「订阅令牌」是安装后脚本打印的 32 位随机串，在 `/opt/argox/node.json` 的 `sub_token` 里，或菜单 15 直接看。

Cloudflare 按 Path 最长匹配，`/<令牌>` 和 `/ws*` 都比「留空」更具体，不会互相抢。

保存后得到 `https://argo.你的域名.com`。**这个域名就是脚本里要填的「隧道域名」。**

> 只想要节点、不需要订阅链接的话，第 3 条可以不配，脚本会给出 Base64 订阅文件。

---

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

有些运营商对 UDP 的 QoS 比 TCP 更狠，开了 H3 反而更慢，甚至出现 `ERR_QUIC_PROTOCOL_ERROR`。所以脚本给了两个节点：

- `argox-XHTTP-H2`（TCP）— 默认用这个
- `argox-XHTTP-H3`（UDP）— 晚高峰掉速时切过去对比

**不要只留一个**，用数据决定。

不开 HTTP/3 也不影响主流程：H2 和 WS 节点照常工作，只是 H3 节点会握手失败。

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
