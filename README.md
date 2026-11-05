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
- 8001 / 8002 端口空闲；不开放任何公网端口，不占用 443

## 菜单

```
 1) 安装 / 重新部署        9) 系统优化
 2) 启动                  10) 清理缓存
 3) 停止                  11) 备份配置
 4) 重启                  12) 卸载
 5) 查看状态              13) 隧道设置
 6) 查看日志              14) 更新优选 IP
 7) 更新到最新版          15) 显示节点
 8) 更换 UUID
```

## 命令行

```bash
bash argox.sh status
bash argox.sh nodes
bash argox.sh ips
bash argox.sh restart
bash argox.sh uninstall
```

## 相关文档

- [docs/cloudflare-setup.md](docs/cloudflare-setup.md) — 隧道创建、Token、HTTP/3
- [docs/design.md](docs/design.md) — 设计文档
