# Cloudflare 隧道配置

这一步脚本代做不了，必须在 Cloudflare 后台点，约 5 分钟。
做完把 Token 和隧道域名填给脚本（安装时，或菜单 11）。

---

## 0. 前置

- 域名已托管到 Cloudflare（NS 指向 CF，状态 Active）
- 已开通 Zero Trust（首次进入会让你取个 team 名，免费版够用）
- VPS 能出网访问 `*.cloudflare.com`

---

## 1. 建隧道

1. 打开 <https://one.dash.cloudflare.com/>
2. 左侧 **Networks → Tunnels**（旧版入口叫 **Access → Tunnels**）
3. **Create a tunnel**
4. Connector 类型选 **Cloudflared**，Next
5. 名字随便填（自己认得就行），Save

---

## 2. 复制 Token

创建完会跳到「Install connector」页，给你几条不同系统的安装命令。

**只要 `--token` 后面那一长串**，形如 `eyJhIjoi...`：

```bash
sudo cloudflared service install eyJhIjoiXXXXXXXXXXXXXXXX...
```

> 不要执行这条命令。脚本自己管 cloudflared，重复安装会造成两套服务抢同一条隧道。
> 只复制 `eyJ...` 这一串。

页面关掉了：Tunnels 列表 → 点进隧道 → **Configure** → 顶部能看到 Token，或点 **Refresh token** 重新生成（旧的立即失效）。

---

## 3. 配 Public Hostname

**只需要一条。**

隧道页面 → **Public Hostname** 标签（新版叫 **Published application routes** / **Routes**）→ **Add a public hostname**。

| 表单字段 | 填什么 |
|---|---|
| Subdomain | `argo` |
| Domain | 你的域名 |
| Path | **什么都不填** |
| Service → Type | `HTTP` |
| Service → URL | `127.0.0.1:8001` |

保存后 **DNS 页面**会自动出现一条「隧道」类型记录（橙色云，指向你的隧道）。

```
argo.你的域名.com     ← 唯一入口，脚本里填这个就是「隧道域名」
```

端口 `8001` 是回源口，改了 XHTTP 端口的话这里要跟着改。

### 三个必须注意的点

1. **Path 留空**。填了不会更安全，只会引入匹配歧义 —— cloudflared 按顺序命中第一条，不是最长匹配。
2. **URL 只填 `host:port`**，不要带 `http://`，协议由 Type 下拉框决定。选 `HTTP`（源站明文监听），选 HTTPS 会握手失败。
3. **面板里多余的子域路由要删掉**。如果还有 `ws` / `sub` 之类的 Public Hostname，删掉后去 **DNS 页面**确认对应 CNAME 也消失了 —— 删路由不一定连带删 DNS，残留会得到 1033 的空壳域名。

### 解析验证

面板里有记录不等于权威服务器上有记录，用命令行确认：

```bash
dig +short argo.你的域名.com @8.8.8.8
```

返回 `104.x` / `172.6x` 才算生效。返回空说明记录没写进去，客户端会报 530。

修法：删掉该条 Public Hostname 重加（CF 会连带重建 DNS），或去 DNS 页面手动加：

| 类型 | 名称 | 内容 | 代理 |
|---|---|---|---|
| CNAME | `argo` | `<隧道UUID>.cfargotunnel.com` | 已代理（橙色云） |

隧道 UUID 在隧道详情页顶部或地址栏 `.../networks/tunnels/<UUID>` 里，不是副本 ID。

---

## 4. 开启 HTTP/3

用 H3 节点必须开，H2 不需要。**这是 Zone 级设置，不在 Zero Trust 里。**

1. 打开 <https://dash.cloudflare.com/>，**点进你的域名**
2. 左侧 **Speed**
3. 进 **Optimization**（部分账号叫 **Speed → Settings**，同一个页面）
4. 展开 **Protocol Optimization**
5. **HTTP/3 (with QUIC)** 打到 On

直达链接（替换域名）：

```
https://dash.cloudflare.com/?to=/:account/你的域名.com/speed/optimization
```

1–5 分钟生效，不用重启任何东西。验证：

```bash
curl -sI https://argo.你的域名.com | grep -i alt-svc
```

看到 `alt-svc: h3=":443"; ma=86400` 即生效。

不开也不影响主流程：H2 照常工作，只是 H3 节点握手失败。另外这个开关只作用于「用户 → CF 边缘」这一段，CF 到 VPS 走隧道内网，本来就不需要 H3。

---

## 错误码

| 码 | 含义 | 怎么修 |
|---|---|---|
| **1033** | CF 找不到这条隧道的路由 | Public Hostname 没配，或域名写错 |
| **1033 + 域名没错** | Token 与域名不属于同一条隧道 | 重新确认 Token 来源 |
| **530** | 隧道离线 | `systemctl status argox-tunnel`，多半是 Token 失效 |
| **502 / 503** | CF 到了，但源站没响应 | `127.0.0.1:8001` 没在听 → `systemctl status argox-xray` |

脚本内置了同样的判断，菜单 11 → 3 会直接把错误码翻译成原因。

---

## 两条常见疑问

**改 Public Hostname 要重启脚本吗？**
不用。remotely-managed 隧道的配置在 CF 侧，改完几十秒内自动下发。

**能绑多个域名吗？**
可以。同一条隧道下加多条 Public Hostname 都指向 `127.0.0.1:8001`，每个都能在客户端当 SNI 用，这是自建「优选域名」的常见玩法。
