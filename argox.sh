#!/usr/bin/env bash
# ==============================================================================
#  argox — Cloudflare Argo 隧道 + Xray (XHTTP / WS) 一键部署管理脚本
#
#  目标：用 Cloudflare Anycast 就近接入，绕开「移动 CMI → 美国 PCCW → 大阪」
#        的绕美路由（250ms）与晚高峰丢包（24%）。
#
#  链路：客户端 -(H3/QUIC 443, SNI=隧道域名, 入口=优选IP)-> CF 边缘
#        -> (QUIC 隧道 / CF 内网) -> cloudflared -> Xray -> 目标
#
#  适用：Ubuntu / Debian，ARM64 (Oracle A1) 与 AMD64
#  不碰 443（留给 1panel），不覆盖已有 xray.service，全部独立命名。
# ==============================================================================

set -uo pipefail

VERSION="1.0.0"
APP="argox"

# ---- 路径 --------------------------------------------------------------------
BASE="/opt/argox"
CONF="${BASE}/config.json"
NODEF="${BASE}/node.json"
LOGD="${BASE}/logs"
SUBD="${BASE}/sub"
QDIR="${BASE}/qr"
IPSF="${BASE}/ips.txt"
IPMETA="${BASE}/ips.meta"
IPSRCF="${BASE}/ipsrc.txt"
BACKD="${BASE}/backup"
SUBPUB="${BASE}/pub"            # 订阅服务根目录（仅本机 8099）
PYSRV="${BASE}/sub_server.py"
TOKEN_FILE="/etc/argox/token.env"
TOKEN_DIR="/etc/argox"

XRAY_BIN="/usr/local/bin/argox-xray"
CFD_BIN="/usr/local/bin/cloudflared"

SVC_XRAY="argox-xray"
SVC_TUN="argox-tunnel"
SVC_SUB="argox-sub"

# ---- 默认端口（全部仅本机，不开放任何公网端口）-------------------------------
DEF_PORT_XHTTP=8001     # 仅本机，给 Argo 隧道回源
DEF_PORT_WS=8002        # 仅本机，给 Argo 隧道回源（WS 兜底）
DEF_PORT_SUB=8099       # 仅本机，订阅服务

# ==============================================================================
#  基础输出
# ==============================================================================
if [[ -t 1 ]]; then
  C_R=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'; C_MAG=$'\033[35m'
else
  C_R=""; C_B=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_GRN" "$C_R" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YEL" "$C_R" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_RED" "$C_R" "$*" >&2; }
info() { printf '%s·%s %s\n' "$C_BLU" "$C_R" "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$C_BLU" "$C_R" "$C_B" "$*" "$C_R"; }

hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

die() { err "$*"; exit 1; }

# ==============================================================================
#  工具函数
# ==============================================================================
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请用 root 运行：sudo bash $0"
}

has() { command -v "$1" >/dev/null 2>&1; }

rand_hex() { # $1=字节数
  openssl rand -hex "${1:-4}" 2>/dev/null || head -c "${1:-4}" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    printf '%s-%s-4%s-%s%s-%s\n' \
      "$(rand_hex 4)" "$(rand_hex 2)" "$(rand_hex 1 | cut -c1)" \
      "$(rand_hex 1 | cut -c1)" "$(rand_hex 1)" "$(rand_hex 6)"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64)  echo "arm64" ;;
    x86_64|amd64)   echo "amd64" ;;
    *)              echo "unknown" ;;
  esac
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

pkg_install() {
  [[ $# -eq 0 ]] && return 0
  if has apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
  elif has dnf; then
    dnf install -y -q "$@" >/dev/null 2>&1
  elif has yum; then
    yum install -y -q "$@" >/dev/null 2>&1
  else
    return 1
  fi
}

port_in_use() { # $1=port  $2=proto(tcp/udp)
  local p="$1" proto="${2:-tcp}"
  if has ss; then
    if [[ "$proto" == "udp" ]]; then
      ss -lun 2>/dev/null | awk 'NR>1{print $5}' | grep -qE "[:.]${p}$"
    else
      ss -ltn 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]${p}$"
    fi
  else
    return 1
  fi
}

# 多源下载：GitHub 直连 + 两个常用镜像
fetch() { # $1=目标文件  $2=github 原始 URL
  local out="$1" url="$2"
  local -a mirrors=(
    "$url"
    "https://ghfast.top/${url}"
    "https://gh-proxy.com/${url}"
    "https://ghproxy.net/${url}"
  )
  local m
  for m in "${mirrors[@]}"; do
    [[ -z "$m" ]] && continue
    if curl -fsSL --connect-timeout 10 --max-time 300 --retry 1 -o "$out" "$m" 2>/dev/null; then
      if [[ -s "$out" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

svc_exists() { systemctl list-unit-files 2>/dev/null | grep -q "^$1.service"; }

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

load_node() {
  [[ -r "$NODEF" ]] || return 1
  if has jq; then return 0; fi
  return 0
}

node_get() { # $1=key
  [[ -r "$NODEF" ]] || { echo ""; return; }
  if has jq; then
    jq -r --arg k "$1" '.[$k] // ""' "$NODEF" 2>/dev/null
  else
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$NODEF" | head -1
  fi
}

node_set() { # $1=key $2=value  (字符串)
  [[ -r "$NODEF" ]] || { echo '{}' > "$NODEF"; }
  if has jq; then
    local tmp; tmp="$(mktemp)"
    jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$NODEF" > "$tmp" && mv "$tmp" "$NODEF"
  elif has python3; then
    python3 - "$NODEF" "$1" "$2" <<'PY'
import json, sys
p, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(p) as f:
        d = json.load(f)
except Exception:
    d = {}
d[k] = v
with open(p, 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
PY
  else
    # 无 jq / python3 时的极简替换（仅支持已有 key）
    sed -i "s|\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"$1\": \"$2\"|" "$NODEF"
  fi
}

node_set_raw() { # $1=key $2=原始 JSON 值
  if has jq; then
    local tmp; tmp="$(mktemp)"
    jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$NODEF" > "$tmp" && mv "$tmp" "$NODEF"
  fi
}

installed() { [[ -x "$XRAY_BIN" ]] && [[ -f "$CONF" ]]; }

# 由主域名推导同级子域：argo.aucrazy.dpdns.org + ws -> ws.aucrazy.dpdns.org
sub_of() { # $1=host $2=prefix
  local host="$1" pre="$2" rest
  [[ -z "$host" || -z "$pre" ]] && return 0
  case "$host" in
    *.*) rest="${host#*.}" ;;
    *)   return 0 ;;   # 单段域名无从推导
  esac
  case "$rest" in
    *.*) : ;;
    *)   return 0 ;;   # 根域（example.com）不推导，避免得到 ws.com
  esac
  printf '%s.%s' "$pre" "$rest"
}

# WS 兜底子域（配置优先，缺省由主域名推导）
node_ws_host() {
  local h
  h="$(node_get ws_host 2>/dev/null || true)"
  [[ -z "$h" ]] && h="$(sub_of "$(node_get tunnel_host 2>/dev/null || true)" "$DEF_WS_SUB")"
  printf '%s' "$h"
}

# 订阅子域（配置优先，缺省由主域名推导）
node_sub_host() {
  local h
  h="$(node_get sub_host 2>/dev/null || true)"
  [[ -z "$h" ]] && h="$(sub_of "$(node_get tunnel_host 2>/dev/null || true)" "$DEF_SUB_SUB")"
  printf '%s' "$h"
}

# 节点地址模式：domain（域名直连）| ip（展开优选 IP）
node_mode() {
  local m
  m="$(node_get node_mode 2>/dev/null || true)"
  [[ -z "$m" ]] && m="$NODE_MODE_DEFAULT"
  printf '%s' "$m"
}

# ==============================================================================
#  系统优化
# ==============================================================================
apply_sysctl() {
  local f=/etc/sysctl.d/99-argox.conf
  cat > "$f" <<'EOF'
# argox: 高丢包跨境链路优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_local_port_range = 10240 65000
fs.file-max = 1000000
EOF
  sysctl --system >/dev/null 2>&1 || sysctl -p "$f" >/dev/null 2>&1 || true

  # file-max 与 limits
  grep -q '^root soft nofile 65535' /etc/security/limits.conf 2>/dev/null || {
    printf 'root soft nofile 65535\nroot hard nofile 65535\n* soft nofile 65535\n* hard nofile 65535\n' \
      >> /etc/security/limits.conf
  }

  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  if [[ "$cc" == "bbr" ]]; then
    ok "BBR 已生效（拥塞控制 = bbr, qdisc = fq）"
  else
    warn "BBR 未生效（当前 = $cc）。若内核不支持需先升级内核。"
  fi
}

# ==============================================================================
#  下载与安装
# ==============================================================================
install_xray() {
  local arch; arch="$(detect_arch)"
  [[ "$arch" == "unknown" ]] && die "不支持的架构：$(uname -m)"

  if [[ -x "$XRAY_BIN" ]]; then
    local cur; cur="$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')"
    info "已安装 Xray ${cur:-unknown}，跳过下载（菜单 7 可更新）"
    return 0
  fi

  local pkg
  case "$arch" in
    arm64) pkg="Xray-linux-arm64-v8a.zip" ;;
    amd64) pkg="Xray-linux-64.zip" ;;
  esac
  local url="https://github.com/XTLS/Xray-core/releases/latest/download/${pkg}"

  step "下载 Xray（${arch}）"
  local tmp; tmp="$(mktemp -d)"
  fetch "${tmp}/${pkg}" "$url" || die "Xray 下载失败。请检查 VPS 出网，或手动放到 ${tmp}/${pkg}"

  if has unzip; then :; else pkg_install unzip || die "需要 unzip"; fi
  unzip -oq "${tmp}/${pkg}" -d "$tmp" || die "解压失败"
  [[ -f "${tmp}/xray" ]] || die "压缩包内未找到 xray 二进制"

  install -m 0755 "${tmp}/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  ok "Xray 已安装：$("$XRAY_BIN" version 2>/dev/null | head -1)"
}

install_cloudflared() {
  local arch; arch="$(detect_arch)"
  if [[ -x "$CFD_BIN" ]]; then
    info "cloudflared 已存在：$("$CFD_BIN" --version 2>/dev/null | head -1)"
    return 0
  fi
  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  step "下载 cloudflared（${arch}）"
  local tmp; tmp="$(mktemp)"
  fetch "$tmp" "$url" || die "cloudflared 下载失败"
  install -m 0755 "$tmp" "$CFD_BIN"
  rm -f "$tmp"
  ok "cloudflared 已安装：$("$CFD_BIN" --version 2>/dev/null | head -1)"
}

# ==============================================================================
#  配置生成
# ==============================================================================
write_xray_config() {
  local uuid="$1" px="$2" pw="$3"

  cat > "$CONF" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "${LOGD}/access.log",
    "error": "${LOGD}/error.log"
  },
  "inbounds": [
    {
      "tag": "argo-xhttp",
      "listen": "127.0.0.1",
      "port": ${DEF_PORT_XHTTP},
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": { "path": "${px}", "mode": "auto" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true }
    },
    {
      "tag": "argo-ws",
      "listen": "127.0.0.1",
      "port": ${DEF_PORT_WS},
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${uuid}" }], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "${pw}" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","::1/128","fc00::/7"], "outboundTag": "direct" }
    ]
  }
}
EOF
  "$XRAY_BIN" run -test -c "$CONF" >/dev/null 2>&1 || {
    err "Xray 配置校验失败，输出如下："
    "$XRAY_BIN" run -test -c "$CONF" 2>&1 | tail -20
    return 1
  }
}

write_xray_service() {
  cat > "/etc/systemd/system/${SVC_XRAY}.service" <<EOF
[Unit]
Description=argox Xray (XHTTP/WS)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} run -c ${CONF}
Restart=always
RestartSec=3
LimitNOFILE=65535
LimitNPROC=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SVC_XRAY" >/dev/null 2>&1
}

write_tunnel_service() {
  [[ -s "$TOKEN_FILE" ]] || return 1
  cat > "/etc/systemd/system/${SVC_TUN}.service" <<EOF
[Unit]
Description=argox Cloudflare Tunnel
After=network-online.target ${SVC_XRAY}.service
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=${TOKEN_FILE}
ExecStart=${CFD_BIN} tunnel --no-autoupdate --protocol quic --loglevel info run
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SVC_TUN" >/dev/null 2>&1
}

write_sub_server() {
  mkdir -p "$SUBPUB"
  cat > "$PYSRV" <<'PYEOF'
#!/usr/bin/env python3
"""argox 订阅服务：只读、只认白名单文件、不列目录。"""
import http.server
import os
import sys

PORT = int(sys.argv[1])
ROOT = os.path.abspath(sys.argv[2])


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def guess_type(self, path):
        return "text/plain; charset=utf-8"

    def list_directory(self, path):
        self.send_error(404)
        return None

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.serve_forever()
PYEOF
  chmod 755 "$PYSRV"
}

write_sub_service() {
  [[ -f "$PYSRV" ]] || return 1
  cat > "/etc/systemd/system/${SVC_SUB}.service" <<EOF
[Unit]
Description=argox subscription server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 ${PYSRV} ${DEF_PORT_SUB} ${SUBPUB}
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${SUBPUB}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SVC_SUB" >/dev/null 2>&1
}

save_token() { # $1=token
  mkdir -p "$TOKEN_DIR"
  printf 'TUNNEL_TOKEN=%s\n' "$1" > "$TOKEN_FILE"
  chmod 700 "$TOKEN_DIR"
  chmod 600 "$TOKEN_FILE"
  ok "Token 已写入 ${TOKEN_FILE}（权限 600，ps 不可见）"
}

# ==============================================================================
#  优选 IP（远端列表导入 + 校验）
# ==============================================================================
DEFAULT_IPSRC="https://bestcf.pages.dev/uouin/all.txt
https://bestcf.pages.dev/cfyes/ipv4.txt"

DEFAULT_IPS="104.16.132.229
104.16.133.229
104.17.152.130
104.18.40.246
104.19.192.29
104.20.28.5
104.21.64.1
104.22.4.1
104.23.128.1
104.24.0.1
104.25.0.1
104.26.0.1
104.27.0.1
162.159.140.1
172.64.80.1
172.67.64.1"

MAX_IPS=12          # 校验通过后最多保留多少个
MAX_H3_NODES=4      # H3 主力（UDP/QUIC，抗丢包）
MAX_H2_NODES=4      # H2 对照（TCP，H3 被 QoS 时用）
MAX_WS_NODES=2      # WS 兼容兜底
ISP_PREF_DEFAULT="mobile"   # mobile | unicom | telecom | multi | auto

# 节点地址模式：domain = 直接用隧道域名（客户端自己解析，走得最近）
#               ip     = 展开优选 IP（手动筛过才用）
NODE_MODE_DEFAULT="domain"
DEF_WS_SUB="ws"     # WS 兜底子域前缀，实际域名 = ws.<主域名>
DEF_SUB_SUB="sub"   # 订阅子域前缀，实际域名 = sub.<主域名>

ensure_ipsrc() {
  mkdir -p "$BASE"
  [[ -s "$IPSRCF" ]] || printf '%s\n' "$DEFAULT_IPSRC" > "$IPSRCF"
}

# 检测单个 IP：输出探测结果（HTTP 状态码 / tcp 表示仅连通 / 失败返回 1）
ip_alive() {
  local ip="$1" host="$2" code
  if [[ -n "$host" ]]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 \
      --resolve "${host}:443:${ip}" "https://${host}/" 2>/dev/null)"
    if [[ -n "$code" && "$code" != "000" ]]; then
      # 1033 = 该 IP 到不了这条隧道，直接淘汰
      [[ "$code" == "1033" ]] && return 1
      printf '%s' "$code"
      return 0
    fi
    # 拿不到状态码时退化到 TCP 连通性判断
  fi
  timeout 5 bash -c "exec 3<>/dev/tcp/${ip}/443" >/dev/null 2>&1 || return 1
  printf 'tcp'
}

# 判断是否为 Cloudflare anycast 段（粗粒度，用于剔除反代/中转 IP）
is_cf_ip() {
  local ip="$1" o1 o2
  IFS=. read -r o1 o2 _ <<< "$ip"
  [[ "$o1" =~ ^[0-9]+$ && "$o2" =~ ^[0-9]+$ ]] || return 1
  case "$o1" in
    104) (( o2 >= 16  && o2 <= 31  )) && return 0 ;;
    172) (( o2 >= 64  && o2 <= 71  )) && return 0 ;;
    162) (( o2 >= 158 && o2 <= 159 )) && return 0 ;;
    198) (( o2 >= 41               )) && return 0 ;;
    188) (( o2 == 114              )) && return 0 ;;
    190) (( o2 == 93               )) && return 0 ;;
    197) (( o2 == 234              )) && return 0 ;;
    141) (( o2 == 101              )) && return 0 ;;
    108) (( o2 == 162              )) && return 0 ;;
    103) (( o2 == 21 || o2 == 22 || o2 == 31 )) && return 0 ;;
    173) (( o2 == 245              )) && return 0 ;;
    131) (( o2 == 0                )) && return 0 ;;
  esac
  return 1
}

# 解析任意格式列表：IP / IP:PORT#备注 / CSV，输出 "ip<TAB>备注"
parse_ipfile() {
  local line raw port ip note
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" == \#* ]] && continue
    note=""
    [[ "$line" == *"#"* ]] && note="${line#*#}"
    raw="${line%%#*}"
    raw="${raw//[[:space:]]/}"
    if [[ "$raw" == *,* ]]; then raw="${raw%%,*}"; fi
    port=443
    if [[ "$raw" == *:* ]]; then
      port="${raw##*:}"
      raw="${raw%%:*}"
    fi
    [[ "$port" != "443" ]] && continue
    ip="$raw"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    printf '%s\t%s\n' "$ip" "$note"
  done
}

import_ips() {
  require_root
  ensure_ipsrc
  local host; host="$(node_get tunnel_host 2>/dev/null || true)"
  local tmpd; tmpd="$(mktemp -d)"
  local raw="${tmpd}/raw" cand="${tmpd}/cand" okf="${tmpd}/ok"
  : > "$raw"; : > "$okf"

  local url n=0
  while IFS= read -r url; do
    url="${url%$'\r'}"
    [[ -z "${url//[[:space:]]/}" ]] && continue
    [[ "$url" == \#* ]] && continue
    n=$((n+1))
    info "拉取源 ${n}：${url}"
    curl -fsSL --max-time 30 -A "Mozilla/5.0" "$url" >> "$raw" 2>/dev/null \
      || warn "源 ${n} 拉取失败，跳过"
    printf '\n' >> "$raw"
  done < "$IPSRCF"

  parse_ipfile < "$raw" | awk -F'\t' '!seen[$1]++' > "${tmpd}/parsed"
  local dropped=0 ip0 note0
  : > "$cand"
  while IFS=$'\t' read -r ip0 note0; do
    if is_cf_ip "$ip0"; then
      printf '%s\t%s\n' "$ip0" "$note0" >> "$cand"
    else
      dropped=$((dropped+1))
    fi
  done < "${tmpd}/parsed"
  [[ "$dropped" -gt 0 ]] && info "已剔除 ${dropped} 个非 Cloudflare 段 IP（反代/中转机，本方案用不了）"

  local total; total="$(wc -l < "$cand" | tr -d ' ')"
  if [[ "${total:-0}" -eq 0 ]]; then
    warn "未解析到任何候选 IP，保留现有列表"
    rm -rf "$tmpd"
    return 1
  fi

  info "候选 ${total} 个，开始校验（443 端口 + 能否路由到隧道）…"
  [[ -z "$host" ]] && warn "尚未配置隧道域名，本次只测 TCP 连通性，结果仅供参考"

  local i=0 ip note code kept=0
  while IFS=$'\t' read -r ip note; do
    i=$((i+1))
    printf '\r  校验 %d/%d  %-16s' "$i" "$total" "$ip"
    if code="$(ip_alive "$ip" "$host")"; then
      printf '%s\t%s\t%s\n' "$ip" "$code" "$note" >> "$okf"
      kept=$((kept+1))
    fi
  done < <(cat "$cand" 2>/dev/null || true)
  printf '\r%*s\r' 56 ''

  if [[ "$kept" -eq 0 ]]; then
    warn "全部未通过校验，保留现有列表"
    info "常见原因：隧道未运行（cloudflared 未注册）或域名填错"
    rm -rf "$tmpd"
    return 1
  fi

  # 排序：运营商匹配优先 → 下载速度降序 → 延迟升序，再截取前 MAX_IPS 个
  local isp_want; isp_want="$(node_get isp_pref 2>/dev/null || true)"
  [[ -z "$isp_want" ]] && isp_want="$ISP_PREF_DEFAULT"

  awk -F'\t' '{ if (NF >= 3) print $1"\t"$3; else print $1"\t" }' "$okf" \
    | sort_cand "$isp_want" | head -n "$MAX_IPS" > "${tmpd}/final"

  if [[ ! -s "${tmpd}/final" ]]; then
    warn "排序后无有效条目，保留现有列表"
    rm -rf "$tmpd"
    return 1
  fi

  cut -f1 "${tmpd}/final" > "$IPSF"
  local ip1 isp1
  : > "$IPMETA"
  while IFS=$'\t' read -r ip1 isp1; do
    printf '%s\t%s\n' "$ip1" "$(isp_label "$isp1")" >> "$IPMETA"
  done < "${tmpd}/final"
  rm -rf "$tmpd"

  ok "校验通过 ${kept} 个，按「$([[ "$isp_want" == "auto" ]] && echo "速度" || echo "$(isp_label "$isp_want")优先 + 速度")」排序后保留 $(wc -l < "$IPSF" | tr -d ' ') 个"
  awk -F'\t' '{printf "    %-16s %s\n", $1, $2}' "$IPMETA"
}

# 运营商标识 → 中文标签
isp_label() {
  case "$1" in
    mobile)  printf '移动' ;;
    unicom)  printf '联通' ;;
    telecom) printf '电信' ;;
    multi)   printf '多线' ;;
    auto)    printf '不指定' ;;
    *)       printf '其他' ;;
  esac
}

# 排序候选：运营商匹配优先，组内按下载速度降序，速度相同按延迟升序
# 输入 stdin: "ip<TAB>note"   输出: "ip<TAB>isp"（已排序）
sort_cand() {
  local want="${1:-mobile}"
  awk -F'\t' -v want="$want" '
  function ispof(n,  t) {
    t = n
    if (t ~ /移动/) return "mobile"
    if (t ~ /联通/) return "unicom"
    if (t ~ /电信/) return "telecom"
    if (t ~ /多线/) return "multi"
    return "unknown"
  }
  function grab(re, s,  m) {
    if (match(s, re)) { m = substr(s, RSTART, RLENGTH); gsub(/[^0-9.]/, "", m); return m + 0 }
    return -1
  }
  {
    ip = $1; note = $2
    ms = grab("[0-9.]+ms", note)
    sp = grab("[0-9.]+mb/s", note)
    isp = ispof(note)
    # 有备注却不含运营商分组 → 列表页眉/页脚夹带的地址，丢弃
    if (isp == "unknown" && note != "") next
    if (want == "auto" || isp == want)      pri = 0
    else if (isp == "multi")                pri = 1
    else if (isp == "unknown")              pri = 3
    else                                    pri = 2
    if (sp < 0) sp = 0
    if (ms < 0) ms = 9999
    printf "%d\t%.2f\t%.2f\t%s\t%s\n", pri, sp, ms, ip, isp
  }' | sort -t$'\t' -k1,1n -k2,2nr -k3,3n | awk -F'\t' '{ printf "%s\t%s\n", $4, $5 }'
}

manual_ips() {
  require_root
  printf '\n  粘贴 IP（一行一个，可带 :443 和 # 备注），空行结束：\n'
  local tmpd; tmpd="$(mktemp -d)"
  local line
  : > "${tmpd}/in"
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && break
    printf '%s\n' "$line" >> "${tmpd}/in"
  done
  parse_ipfile < "${tmpd}/in" | awk -F'\t' '!seen[$1]++' | cut -f1 > "$IPSF"
  rm -rf "$tmpd"
  local n; n="$(wc -l < "$IPSF" | tr -d ' ')"
  [[ "${n:-0}" -eq 0 ]] && { warn "没有解析到有效 IP，保留原有列表"; return 1; }
  : > "$IPMETA"
  ok "已保存 ${n} 个 IP（未校验）"
}

update_ips() {
  require_root
  import_ips || true
  gen_sub >/dev/null 2>&1 || true
}

list_ips() {
  [[ -s "$IPSF" ]] || { printf '%s\n' "$DEFAULT_IPS" > "$IPSF"; }
  cat "$IPSF"
}

menu_ips() {
  require_root
  ensure_ipsrc
  while true; do
    local cur_isp; cur_isp="$(node_get isp_pref 2>/dev/null || true)"
    [[ -z "$cur_isp" ]] && cur_isp="$ISP_PREF_DEFAULT"
    printf '\n  %s优选 IP%s\n' "$C_B" "$C_R"
    printf '  源链接：\n'
    sed 's/^/    /' "$IPSRCF"
    printf '  当前 IP：%s 个    运营商偏好：%s\n\n' \
      "$(wc -l < "$IPSF" 2>/dev/null || echo 0)" "$(isp_label "$cur_isp")"
    cat <<'EOF'
  1) 查看当前 IP 列表
  2) 编辑 IP 源链接
  3) 立即拉取并校验
  4) 手动粘贴 IP
  5) 运营商偏好（换网络时改这里）
  0) 返回
EOF
    read -rp "  选择: " c
    case "${c:-}" in
      1) if [[ -s "$IPSF" ]]; then
           if [[ -s "$IPMETA" ]]; then awk -F'\t' '{printf "    %-16s %s\n",$1,$2}' "$IPMETA"
           else sed 's/^/    /' "$IPSF"; fi
         else warn "还没有 IP 列表"; fi ;;
      2) printf '\n  一行一个链接，空行结束（留空=保持不变）：\n'
         local tmpd; tmpd="$(mktemp -d)"; : > "${tmpd}/u"
         while IFS= read -r ln; do [[ -z "${ln//[[:space:]]/}" ]] && break; printf '%s\n' "$ln" >> "${tmpd}/u"; done
         if [[ -s "${tmpd}/u" ]]; then cp "${tmpd}/u" "$IPSRCF"; ok "源链接已更新"; else info "未修改"; fi
         rm -rf "$tmpd" ;;
      3) import_ips && gen_sub >/dev/null 2>&1 || true ;;
      4) manual_ips && gen_sub >/dev/null 2>&1 || true ;;
      5) do_set_isp ;;
      0|"") return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

do_set_isp() {
  local cur; cur="$(node_get isp_pref 2>/dev/null || true)"
  [[ -z "$cur" ]] && cur="$ISP_PREF_DEFAULT"
  printf '\n  当前运营商偏好：%s\n' "$(isp_label "$cur")"
  printf '  影响排序：匹配的组排最前，组内按下载速度降序\n\n'
  cat <<'EOF'
  1) 移动
  2) 联通
  3) 电信
  4) 多线
  5) 不指定（全部按速度排序）
  0) 返回
EOF
  local c; read -rp "  选择: " c
  local v=""
  case "${c:-}" in
    1) v="mobile" ;;
    2) v="unicom" ;;
    3) v="telecom" ;;
    4) v="multi" ;;
    5) v="auto" ;;
    0|"") return 0 ;;
    *) warn "无效选项"; return 1 ;;
  esac
  node_set isp_pref "$v"
  ok "已设为「$(isp_label "$v")」"
  printf '\n'
  read -rp "  立即重新拉取并按新偏好排序？（Y/n）: " yn
  if [[ "${yn,,}" != "n" ]]; then
    import_ips && gen_sub >/dev/null 2>&1 || true
  else
    info "已保存，下次拉取时生效"
  fi
}

# ==============================================================================
#  订阅生成 / 二维码
# ==============================================================================
urlenc() { # 简单 URL 编码（path 里的 / 需编码）
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

build_links() {
  local uuid host px pw
  uuid="$(node_get uuid)"
  host="$(node_get tunnel_host)"
  px="$(node_get path_xhttp)"
  pw="$(node_get path_ws)"
  [[ -z "$uuid" || -z "$host" ]] && return 1

  local ex enc_pw ws_host mode
  ex="$(urlenc "$px")"
  enc_pw="$(urlenc "$pw")"
  ws_host="$(node_ws_host)"
  [[ -z "$ws_host" ]] && ws_host="$host"
  mode="$(node_mode)"

  # ---------- 域名模式：3 条，地址写域名，由客户端解析到最近的 CF 节点 ----------
  if [[ "$mode" != "ip" ]]; then
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h3&type=xhttp&path=%s&host=%s&mode=auto#argox-H3\n' \
      "$uuid" "$host" "$host" "$ex" "$host"
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1&type=xhttp&path=%s&host=%s&mode=auto#argox-H2\n' \
      "$uuid" "$host" "$host" "$ex" "$host"
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&path=%s&host=%s#argox-WS\n' \
      "$uuid" "$ws_host" "$ws_host" "$enc_pw" "$ws_host"
    return 0
  fi

  # ---------- IP 模式：展开优选 IP ----------
  local -a ips=() tags=()
  local l t
  while IFS= read -r l; do
    l="${l//[[:space:]]/}"
    [[ -n "$l" ]] && ips+=("$l")
  done < <(list_ips)
  [[ ${#ips[@]} -eq 0 ]] && ips=("104.16.132.229")

  # 与 IPSF 对齐读取运营商标签
  local idx=0
  while IFS=$'\t' read -r l t; do
    (( idx >= ${#ips[@]} )) && break
    tags[$idx]="${t:-其他}"
    idx=$((idx+1))
  done < "$IPMETA" 2>/dev/null
  for (( idx=0; idx<${#ips[@]}; idx++ )); do
    [[ -z "${tags[$idx]}" ]] && tags[$idx]="其他"
  done

  local i n
  # H3 主力：UDP/QUIC，抗丢包
  for (( i=0; i<${#ips[@]} && i<MAX_H3_NODES; i++ )); do
    n=$((i+1))
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h3&type=xhttp&path=%s&host=%s&mode=auto#argox-H3-%02d-%s\n' \
      "$uuid" "${ips[$i]}" "$host" "$ex" "$host" "$n" "${tags[$i]}"
  done
  # H2 对照：同一批 IP 走 TCP，用于 A/B 判断 H3 是否真的更抗丢包
  for (( i=0; i<${#ips[@]} && i<MAX_H2_NODES; i++ )); do
    n=$((i+1))
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1&type=xhttp&path=%s&host=%s&mode=auto#argox-H2-%02d-%s\n' \
      "$uuid" "${ips[$i]}" "$host" "$ex" "$host" "$n" "${tags[$i]}"
  done
  # WS 兜底：必须走 ws 子域（ws 子域在 CF 侧指向 8002）
  for (( i=0; i<${#ips[@]} && i<MAX_WS_NODES; i++ )); do
    n=$((i+1))
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&type=ws&path=%s&host=%s#argox-WS-%02d-%s\n' \
      "$uuid" "${ips[$i]}" "$ws_host" "$enc_pw" "$ws_host" "$n" "${tags[$i]}"
  done
}

gen_sub() {
  mkdir -p "$SUBD" "$QDIR"
  local links; links="$(build_links)"
  [[ -z "$links" ]] && { warn "缺少 UUID / 隧道域名，无法生成订阅"; return 1; }

  printf '%s\n' "$links" > "${SUBD}/argox.txt"
  printf '%s\n' "$links" | base64 -w0 > "${SUBD}/argox.b64" 2>/dev/null \
    || printf '%s\n' "$links" | base64 | tr -d '\n' > "${SUBD}/argox.b64"

  # 发布到订阅服务目录：文件名即 URL 路径，随机不可猜
  local stoken; stoken="$(node_get sub_token 2>/dev/null || true)"
  if [[ -n "$stoken" ]]; then
    mkdir -p "$SUBPUB"
    cp "${SUBD}/argox.b64" "${SUBPUB}/${stoken}"
    chmod 644 "${SUBPUB}/${stoken}"
  fi

  # 每个节点单独一个二维码文件
  local i=0 line name
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    i=$((i+1))
    name="$(printf '%s' "$line" | sed 's/.*#//')"
    name="${name:-node$i}"
    printf '%s' "$line" > "${QDIR}/${name}.txt"
    if has qrencode; then
      qrencode -o "${QDIR}/${name}.png" -s 6 -m 2 < "${QDIR}/${name}.txt" 2>/dev/null || true
    fi
  done <<< "$links"

  declare -a QRLINES=()
  while IFS= read -r line; do QRLINES+=("$line"); done <<< "$links"
  NODE_LINKS=("${QRLINES[@]}")
}

# 打印 Cloudflare 侧需要的三条路由（三条独立子域，Path 全留空）
cf_paths() {
  local host="$1" token ws_host sub_host
  token="$(node_get sub_token 2>/dev/null || true)"
  ws_host="$(node_ws_host)"
  sub_host="$(node_sub_host)"
  printf '\n  Cloudflare → 该隧道 → Public Hostname，需要三条（Path 全部留空）：\n\n'
  printf '    %-30s → 127.0.0.1:%s   H3/H2 主入口\n' "${host:-argo.<主域名>}" "$DEF_PORT_XHTTP"
  printf '    %-30s → 127.0.0.1:%s   WS 兜底\n'    "${ws_host:-ws.<主域名>}"  "$DEF_PORT_WS"
  printf '    %-30s → 127.0.0.1:%s   订阅\n'       "${sub_host:-sub.<主域名>}" "$DEF_PORT_SUB"
  printf '\n  Service 全选 HTTP；三条必须是不同子域，Path 留空，否则会互相抢占。\n'
  if [[ -n "$token" && -n "$sub_host" ]]; then
    printf '  订阅地址：https://%s/%s\n' "$sub_host" "$token"
  fi
  printf '\n'
}

show_nodes() {
  require_root
  local host token sub_host
  host="$(node_get tunnel_host 2>/dev/null || true)"
  token="$(node_get sub_token 2>/dev/null || true)"

  local links; links="$(build_links)"
  if [[ -z "$links" ]]; then
    warn "还没有可用的节点信息，请先完成安装并填写隧道域名与 Token"
    return 1
  fi
  if [[ -z "$token" ]]; then
    warn "缺少订阅令牌，请重新执行菜单 1"
    return 1
  fi

  sub_host="$(node_sub_host)"
  [[ -z "$sub_host" ]] && sub_host="$host"

  local n; n="$(printf '%s\n' "$links" | wc -l | tr -d ' ')"
  step "订阅"
  printf '  节点数    : %s\n' "$n"
  printf '  地址模式  : %s\n' "$(node_mode)"
  printf '  隧道域名  : %s\n' "$host"

  local url="https://${sub_host}/${token}"
  printf '  订阅地址  : %s%s%s\n\n' "$C_B" "$url" "$C_R"

  info "包含节点："
  printf '%s\n' "$links" | sed 's/.*#//' | awk '{printf "    %02d  %s\n", NR, $0}'
  printf '\n'

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    ok "订阅地址已可访问"
  else
    warn "订阅地址暂不可访问（HTTP ${code:-超时}）"
    cf_paths "$host"
    printf '\n  保存后等 1-2 分钟，本机可验证：\n'
    printf '    curl -s -o /dev/null -w "%%{http_code}\\n" %s\n' "$url"
  fi

  if has qrencode; then
    printf '\n%s── 扫码导入订阅 ──%s\n' "$C_DIM" "$C_R"
    qrencode -t ANSIUTF8 -m 1 <<< "$url" 2>/dev/null || true
    mkdir -p "$QDIR"
    qrencode -o "${QDIR}/subscribe.png" -s 8 -m 2 <<< "$url" 2>/dev/null || true
    printf '\n'
    info "二维码 PNG：${QDIR}/subscribe.png"
  fi

  printf '\n'
  hr
  info "karing：添加配置 → 导入配置链接 → 粘贴上面的订阅地址"
  info "文件备用：${SUBD}/argox.b64（Base64 订阅）"
  info "查看单节点链接：bash $0 links"
}

show_links() {
  require_root
  local links; links="$(build_links)"
  [[ -z "$links" ]] && { warn "没有可用节点"; return 1; }
  step "单节点链接"
  local line name i=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    i=$((i+1))
    name="$(printf '%s' "$line" | sed 's/.*#//')"
    printf '\n%s[%d] %s%s\n' "$C_MAG" "$i" "$name" "$C_R"
    printf '%s\n' "$line" | fold -w 100 | sed 's/^/    /'
  done <<< "$links"
}

# ==============================================================================
#  服务控制
# ==============================================================================
do_start() {
  installed || { err "尚未安装，请先执行菜单 1"; return 1; }
  systemctl start "$SVC_XRAY" 2>/dev/null
  sleep 1
  if svc_active "$SVC_XRAY"; then ok "Xray 已启动"; else err "Xray 启动失败，查看日志：journalctl -u ${SVC_XRAY} -n 50"; fi
  if [[ -s "$TOKEN_FILE" ]]; then
    systemctl start "$SVC_TUN" 2>/dev/null
    sleep 1
    if svc_active "$SVC_TUN"; then ok "隧道已启动"; else warn "隧道启动失败，查看日志：journalctl -u ${SVC_TUN} -n 50"; fi
  else
    warn "未配置 Tunnel Token，隧道未启动（菜单 13 可填写）"
  fi
  [[ -f "$PYSRV" ]] && systemctl start "$SVC_SUB" 2>/dev/null
  ok "已启动"
}

do_stop() {
  systemctl stop "$SVC_SUB" 2>/dev/null
  systemctl stop "$SVC_TUN" 2>/dev/null
  systemctl stop "$SVC_XRAY" 2>/dev/null
  ok "已停止"
}

do_restart() {
  systemctl restart "$SVC_XRAY" 2>/dev/null
  [[ -s "$TOKEN_FILE" ]] && systemctl restart "$SVC_TUN" 2>/dev/null
  [[ -f "$PYSRV" ]] && systemctl restart "$SVC_SUB" 2>/dev/null
  sleep 1
  ok "已重启"
}

do_status() {
  printf '\n'
  hr
  printf '%sargox 状态%s\n' "$C_B" "$C_R"
  hr

  local st_x st_t st_s
  if svc_active "$SVC_XRAY"; then st_x="${C_GRN}● 运行中${C_R}"; else st_x="${C_RED}○ 已停止${C_R}"; fi
  if svc_active "$SVC_TUN";  then st_t="${C_GRN}● 运行中${C_R}"; else st_t="${C_RED}○ 已停止${C_R}"; fi
  if svc_active "$SVC_SUB";  then st_s="${C_GRN}● 运行中${C_R}"; else st_s="${C_RED}○ 已停止${C_R}"; fi

  printf '  Xray       : %s\n' "$st_x"
  printf '  Tunnel     : %s\n' "$st_t"
  printf '  订阅服务   : %s\n' "$st_s"
  printf '  版本       : %s\n' "$VERSION"

  if installed; then
    printf '  UUID       : %s\n' "$(node_get uuid)"
    printf '  隧道域名   : %s\n' "$(node_get tunnel_host)"
    printf '  Token      : %s\n' "$([[ -s "$TOKEN_FILE" ]] && echo '已配置' || echo '未配置')"
    printf '  XHTTP 路径 : %s  (127.0.0.1:%s)\n' "$(node_get path_xhttp)" "$DEF_PORT_XHTTP"
    printf '  WS 路径    : %s  (127.0.0.1:%s)\n' "$(node_get path_ws)" "$DEF_PORT_WS"
    printf '  优选 IP    : %s 个（%s）\n' "$(wc -l < "$IPSF" 2>/dev/null || echo 0)" "$IPSF"
    local st; st="$(node_get sub_token 2>/dev/null || true)"
    [[ -n "$st" ]] && printf '  订阅地址   : https://%s/%s\n' "$(node_get tunnel_host)" "$st"
  else
    warn "尚未安装"
  fi

  printf '\n'
  hr
  # 隧道在线状态（CF 侧健康检查）
  if svc_active "$SVC_TUN"; then
    local q; q="$(journalctl -u "$SVC_TUN" -n 40 --no-pager 2>/dev/null | grep -c 'Registered tunnel connection' || true)"
    if [[ "${q:-0}" -gt 0 ]]; then
      ok "隧道已向 CF 注册连接"
    else
      info "隧道进程在跑，但日志中尚未看到注册成功的记录"
    fi
  fi
  hr
}

do_logs() {
  printf '\n  1) Xray 日志\n  2) 隧道日志\n  3) 订阅服务日志\n  4) 实时跟踪 Xray\n  5) 实时跟踪隧道\n  0) 返回\n'
  read -rp "  选择: " c
  case "$c" in
    1) journalctl -u "$SVC_XRAY" -n 80 --no-pager ;;
    2) journalctl -u "$SVC_TUN"  -n 80 --no-pager ;;
    3) journalctl -u "$SVC_SUB"  -n 80 --no-pager ;;
    4) journalctl -u "$SVC_XRAY" -f ;;
    5) journalctl -u "$SVC_TUN"  -f ;;
    *) return 0 ;;
  esac
}

# ==============================================================================
#  安装 / 重新部署
# ==============================================================================
do_install() {
  require_root
  printf '\n'
  hr
  printf '%sargox 安装向导%s  %s(v%s)%s\n' "$C_B" "$C_R" "$C_DIM" "$VERSION" "$C_R"
  hr

  # ---------- 预检 ----------
  step "环境预检"
  local arch os
  arch="$(detect_arch)"; os="$(detect_os)"
  [[ "$arch" == "unknown" ]] && die "不支持的架构：$(uname -m)（仅支持 arm64 / amd64）"
  ok "架构：${arch}   系统：${os}   内核：$(uname -r)"

  local mem avail
  mem="$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  avail="$(df -m /opt 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
  info "内存：${mem} GB    /opt 可用：${avail} MB"
  [[ "${avail:-0}" -lt 100 ]] && die "/opt 剩余空间不足 100MB"

  # 依赖
  local need=()
  for b in curl unzip openssl tar; do has "$b" || need+=("$b"); done
  has jq || need+=("jq")
  if [[ ${#need[@]} -gt 0 ]]; then
    step "安装依赖：${need[*]}"
    pkg_install "${need[@]}" || warn "依赖安装可能失败，继续尝试"
  fi
  has qrencode || pkg_install qrencode >/dev/null 2>&1 || true

  # 端口检测
  step "端口检测"
  local p
  for p in "$DEF_PORT_XHTTP" "$DEF_PORT_WS"; do
    if port_in_use "$p" tcp; then die "端口 ${p} 已被占用（Argo 回源端口需要空闲）"; fi
  done
  ok "Argo 回源端口 ${DEF_PORT_XHTTP}/${DEF_PORT_WS} 空闲"

  # ---------- 交互参数 ----------
  step "隧道参数"
  printf '  说明：隧道需在 CF Dashboard 建（Zero Trust → Networks → Tunnels）。\n'
  printf '        现在没有可以先跳过，装完用菜单 13 补填。\n\n'

  local host token cur_host
  host=""
  cur_host="$(node_get tunnel_host 2>/dev/null || true)"
  read -rp "  隧道域名（如 argo.example.com，留空=保持不变）: " host
  host="${host// /}"
  [[ -z "$host" && -n "$cur_host" ]] && host="$cur_host"
  if [[ -n "$host" ]]; then
    if [[ ! "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
      die "域名格式不合法：$host"
    fi
  fi

  token=""
  printf '\n'
  read -rp "  现在粘贴 Tunnel Token？（y/N）: " yn
  if [[ "${yn,,}" == "y" ]]; then
    printf '  粘贴 Token 后回车（输入不回显）: '
    read -rs token
    printf '\n'
    token="${token// /}"
    if [[ -z "$token" ]]; then
      warn "Token 为空，跳过"
    elif [[ ${#token} -lt 20 ]]; then
      warn "Token 长度异常（${#token} 字符），请确认是否完整粘贴"
    fi
  fi

  # ---------- 目录与密钥 ----------
  step "生成配置"
  mkdir -p "$BASE" "$LOGD" "$SUBD" "$QDIR" "$BACKD"

  local uuid px pw
  if [[ -f "$NODEF" ]]; then
    uuid="$(node_get uuid)"
    px="$(node_get path_xhttp)"
    pw="$(node_get path_ws)"
  fi
  [[ -z "${uuid:-}" ]] && uuid="$(gen_uuid)"
  [[ -z "${px:-}"   ]] && px="/$(rand_hex 8)"
  # WS 路径固定 /ws 前缀，便于识别；CF 侧靠 ws 子域转发到 8002
  [[ -z "${pw:-}"   ]] && pw="/ws$(rand_hex 6)"

  # 新旧路径不能相同
  [[ "$px" == "$pw" ]] && pw="/$(rand_hex 8)"

  local isp_prev; isp_prev="$(node_get isp_pref 2>/dev/null || true)"
  [[ -z "$isp_prev" ]] && isp_prev="$ISP_PREF_DEFAULT"

  # 订阅令牌：重装时沿用，避免客户端已填的订阅链接失效
  local sub_token; sub_token="$(node_get sub_token 2>/dev/null || true)"
  [[ -z "$sub_token" ]] && sub_token="$(rand_hex 16)"

  # 子域与地址模式：重装时沿用已有设置
  local ws_prev sub_prev mode_prev
  ws_prev="$(node_get ws_host 2>/dev/null || true)"
  sub_prev="$(node_get sub_host 2>/dev/null || true)"
  mode_prev="$(node_get node_mode 2>/dev/null || true)"
  [[ -z "$ws_prev"   ]] && ws_prev="$(sub_of "$host" "$DEF_WS_SUB")"
  [[ -z "$sub_prev"  ]] && sub_prev="$(sub_of "$host" "$DEF_SUB_SUB")"
  [[ -z "$mode_prev" ]] && mode_prev="$NODE_MODE_DEFAULT"

  cat > "$NODEF" <<EOF
{
  "uuid": "${uuid}",
  "tunnel_host": "${host}",
  "ws_host": "${ws_prev}",
  "sub_host": "${sub_prev}",
  "node_mode": "${mode_prev}",
  "path_xhttp": "${px}",
  "path_ws": "${pw}",
  "isp_pref": "${isp_prev}",
  "sub_token": "${sub_token}",
  "installed_at": "$(date -Iseconds)",
  "version": "${VERSION}"
}
EOF
  chmod 600 "$NODEF"

  ok "UUID: ${uuid}"
  ok "XHTTP 路径: ${px}"
  ok "WS 路径: ${pw}"
  ok "节点地址模式: ${mode_prev}（domain=域名直连 / ip=优选IP）"

  # ---------- 安装二进制 ----------
  install_xray || die "Xray 安装失败"
  install_cloudflared || die "cloudflared 安装失败"

  # ---------- 写配置 ----------
  step "写入配置"
  write_xray_config "$uuid" "$px" "$pw" || die "配置生成失败"
  ok "Xray 配置校验通过：${CONF}"

  if [[ -n "$token" ]]; then
    save_token "$token"
    write_tunnel_service
    ok "隧道服务已注册：${SVC_TUN}.service"
  else
    warn "未提供 Token，隧道服务暂不创建"
  fi

  write_xray_service
  ok "Xray 服务已注册：${SVC_XRAY}.service"

  # 订阅服务（仅监听 127.0.0.1）
  write_sub_server
  write_sub_service
  ok "订阅服务已注册：${SVC_SUB}.service（127.0.0.1:${DEF_PORT_SUB}）"

  # ---------- 系统优化 ----------
  step "系统优化"
  apply_sysctl

  # ---------- 启动 ----------
  step "启动服务"
  systemctl restart "$SVC_XRAY"
  sleep 2
  if svc_active "$SVC_XRAY"; then
    ok "Xray 运行中"
  else
    err "Xray 启动失败："
    journalctl -u "$SVC_XRAY" -n 25 --no-pager
    return 1
  fi

  systemctl restart "$SVC_SUB" 2>/dev/null
  sleep 1
  if svc_active "$SVC_SUB"; then ok "订阅服务运行中"; else warn "订阅服务启动失败：journalctl -u ${SVC_SUB} -n 30"; fi

  if [[ -s "$TOKEN_FILE" ]]; then
    systemctl restart "$SVC_TUN"
    sleep 3
    if svc_active "$SVC_TUN"; then
      ok "隧道进程运行中"
      local think
      think="$(journalctl -u "$SVC_TUN" -n 30 --no-pager 2>/dev/null | grep -c 'Registered tunnel connection' || true)"
      if [[ "${think:-0}" -gt 0 ]]; then
        ok "隧道已成功注册到 Cloudflare"
      else
        warn "隧道尚未注册成功（DNS/防火墙/Token 不匹配都可能）"
      fi
    else
      warn "隧道启动失败，检查 Token：journalctl -u ${SVC_TUN} -n 30"
    fi
  fi

  # ---------- 本地回源自检 ----------
  step "回源自检"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:${DEF_PORT_XHTTP}${px}" 2>/dev/null || echo "000")"
  if [[ "$code" == "000" ]]; then
    warn "本地入站无响应（HTTP ${code}）—— 若 Xray 在跑，XHTTP 对普通 GET 返回 404/400 属正常，继续用客户端验证"
  else
    ok "本地入站响应 HTTP ${code}（非 502 即可）"
  fi

  # ---------- 优选 IP ----------
  if [[ "$mode_prev" == "ip" ]]; then
    step "优选 IP"
    if [[ -s "$IPSF" ]]; then
      info "已有 $(wc -l < "$IPSF") 个 IP，跳过（菜单 14 可更新）"
    else
      read -rp "  现在导入优选 IP 并校验？约需 1-3 分钟（Y/n）: " yn2
      if [[ "${yn2,,}" != "n" ]]; then
        import_ips || printf '%s\n' "$DEFAULT_IPS" > "$IPSF"
      else
        printf '%s\n' "$DEFAULT_IPS" > "$IPSF"
        info "已写入默认 IP 列表（菜单 14 可重新导入）"
      fi
    fi
  else
    step "节点地址"
    ok "使用域名直连（$host），跳过优选 IP"
    info "如需改用优选 IP：菜单 13 → 6) 切换地址模式"
  fi

  # ---------- 收尾 ----------
  gen_sub >/dev/null 2>&1 || true

  printf '\n'
  hr
  printf '%s安装完成%s\n' "$C_GRN$C_B" "$C_R"
  hr
  printf '  UUID        : %s\n' "$uuid"
  printf '  隧道域名    : %s\n' "${host:-（未填写）}"
  printf '  WS 子域     : %s\n' "${ws_prev:-（未设置）}"
  printf '  订阅子域    : %s\n' "${sub_prev:-（未设置）}"
  printf '  地址模式    : %s\n' "$mode_prev"
  printf '  Token       : %s\n' "$([[ -s "$TOKEN_FILE" ]] && echo 已配置 || echo 未配置)"
  printf '  XHTTP 路径  : %s\n' "$px"
  printf '  WS 路径     : %s\n' "$pw"
  printf '  配置目录    : %s\n' "$BASE"
  printf '  Token 文件  : %s（600）\n' "$TOKEN_FILE"
  hr

  if [[ -z "$host" ]]; then
    warn "还需在 CF Dashboard 配置 Public Hostname，然后回到菜单 13 填域名"
  fi

  printf '\n'
  show_nodes
}

# ==============================================================================
#  菜单动作
# ==============================================================================
do_update() {
  require_root
  installed || { err "尚未安装"; return 1; }
  step "更新 Xray / cloudflared"

  local arch; arch="$(detect_arch)"
  local pkg
  case "$arch" in
    arm64) pkg="Xray-linux-arm64-v8a.zip" ;;
    amd64) pkg="Xray-linux-64.zip" ;;
  esac
  local tmp; tmp="$(mktemp -d)"
  if fetch "${tmp}/${pkg}" "https://github.com/XTLS/Xray-core/releases/latest/download/${pkg}"; then
    unzip -oq "${tmp}/${pkg}" -d "$tmp" && install -m 0755 "${tmp}/xray" "$XRAY_BIN"
    ok "Xray 更新为：$("$XRAY_BIN" version 2>/dev/null | head -1)"
  else
    warn "Xray 更新失败（保持原版本）"
  fi
  rm -rf "$tmp"

  tmp="$(mktemp)"
  if fetch "$tmp" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"; then
    install -m 0755 "$tmp" "$CFD_BIN"
    ok "cloudflared 更新为：$("$CFD_BIN" --version 2>/dev/null | head -1)"
  else
    warn "cloudflared 更新失败（保持原版本）"
  fi
  rm -f "$tmp"

  systemctl restart "$SVC_XRAY" 2>/dev/null
  [[ -s "$TOKEN_FILE" ]] && systemctl restart "$SVC_TUN" 2>/dev/null
  sleep 1
  ok "服务已按新版本重启"
}

do_change_uuid() {
  require_root
  installed || { err "尚未安装"; return 1; }
  printf '\n  当前 UUID：%s\n' "$(node_get uuid)"
  printf '  %s更换后所有客户端都需要重新导入，旧链接立即失效。%s\n\n' "$C_YEL" "$C_R"
  local yn; read -rp "  确认更换？(y/N): " yn
  [[ "${yn,,}" != "y" ]] && return 0

  local uuid; uuid="$(gen_uuid)"
  node_set uuid "$uuid"
  local px pw
  px="$(node_get path_xhttp)"; pw="$(node_get path_ws)"
  write_xray_config "$uuid" "$px" "$pw" || { err "配置生成失败"; return 1; }
  systemctl restart "$SVC_XRAY"; sleep 1
  gen_sub >/dev/null 2>&1 || true
  ok "UUID 已更换：${uuid}"
  show_nodes
}

do_sysopt() {
  require_root
  printf '\n  系统优化\n'
  printf '  1) 全套优化（BBR + fq + 端口范围 + 文件句柄）\n'
  printf '  2) 仅检查当前状态\n'
  printf '  3) 设置 MTU 1400（QUIC 大包分片问题时用）\n'
  printf '  4) 重启策略（systemd 自动拉起）\n'
  printf '  5) 日志轮转（限制 xray/cloudflared 日志体积）\n'
  printf '  0) 返回\n'
  local c; read -rp "  选择: " c
  case "$c" in
    1) apply_sysctl ;;
    2)
      printf '\n  qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
      printf '  cc   : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
      printf '  fastopen: %s\n' "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)"
      printf '  mtu_probing: %s\n' "$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null)"
      ;;
    3)
      local ifc; ifc="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
      [[ -z "$ifc" ]] && { err "找不到默认网卡"; return 1; }
      ip link set dev "$ifc" mtu 1400 && ok "已将 ${ifc} MTU 设为 1400"
      printf '  持久化：echo "MTU=1400" >> /etc/network/interfaces.d/50-cloud-init\n'
      ;;
    4)
      systemctl enable "$SVC_XRAY" >/dev/null 2>&1 && ok "Xray 已设为开机自启"
      [[ -s "$TOKEN_FILE" ]] && systemctl enable "$SVC_TUN" >/dev/null 2>&1 && ok "隧道已设为开机自启"
      ;;
    5)
      cat > /etc/logrotate.d/argox <<'EOF'
/opt/argox/logs/*.log {
    daily
    rotate 5
    missingok
    notifempty
    compress
    copytruncate
}
EOF
      ok "日志轮转已配置（保留 5 天）"
      ;;
    *) return 0 ;;
  esac
}

do_clean() {
  require_root
  printf '\n  清理内容：\n'
  printf '  · Xray 访问/错误日志\n'
  printf '  · journal 中超过 3 天的 argox 日志\n'
  printf '  · 旧的订阅/二维码文件\n'
  printf '  · 下载临时文件\n\n'
  local yn; read -rp "  确认清理？(y/N): " yn
  [[ "${yn,,}" != "y" ]] && return 0

  local before after
  before="$(du -sm "$BASE" 2>/dev/null | awk '{print $1}')"
  : > "${LOGD}/access.log" 2>/dev/null || true
  : > "${LOGD}/error.log" 2>/dev/null || true
  journalctl --vacuum-time=3d >/dev/null 2>&1 || true
  rm -f "${SUBD}"/*.tmp "${QDIR}"/*.tmp 2>/dev/null || true
  find /tmp -maxdepth 1 -name 'tmp.*' -mtime +1 -delete 2>/dev/null || true
  after="$(du -sm "$BASE" 2>/dev/null | awk '{print $1}')"
  ok "清理完成（${before:-?} MB → ${after:-?} MB）"
}

do_backup() {
  require_root
  installed || { err "尚未安装"; return 1; }
  mkdir -p "$BACKD"
  local ts f
  ts="$(date +%Y%m%d-%H%M%S)"
  f="${BACKD}/argox-${ts}.tar.gz"

  local items=()
  [[ -f "$NODEF" ]] && items+=("$NODEF")
  [[ -f "$CONF" ]]  && items+=("$CONF")
  [[ -f "$TOKEN_FILE" ]] && items+=("$TOKEN_FILE")
  [[ -f "$IPSF" ]] && items+=("$IPSF")

  tar -czf "$f" -P "${items[@]}" 2>/dev/null || { err "备份失败"; return 1; }
  chmod 600 "$f"
  ok "已备份：$f（$(du -h "$f" | awk '{print $1}')）"

  local n; n="$(ls -1 "${BACKD}"/argox-*.tar.gz 2>/dev/null | wc -l)"
  if [[ "$n" -gt 5 ]]; then
    ls -1t "${BACKD}"/argox-*.tar.gz | tail -n +6 | xargs -r rm -f
    info "已保留最近 5 份备份"
  fi
  warn "备份含 Token 与 UUID，注意保管"
}

do_uninstall() {
  require_root
  installed || { warn "看起来没有安装"; }
  printf '\n  %s将会删除：%s\n' "$C_RED" "$C_R"
  printf '  · systemd 服务 argox-xray / argox-tunnel / argox-sub\n'
  printf '  · 二进制 /usr/local/bin/argox-xray\n'
  printf '  · 配置目录 /opt/argox（含 UUID/Token/日志/订阅）\n'
  printf '  · /etc/argox/token.env\n'
  printf '  · /etc/sysctl.d/99-argox.conf\n\n'
  printf '  %s不会动的：%s1panel、已有 xray.service、443 端口、cdnx 相关文件\n\n' "$C_GRN" "$C_R"
  local yn; read -rp "  确认卸载？(输入 yes 继续): " yn
  [[ "$yn" != "yes" ]] && { info "已取消"; return 0; }

  step "卸载"
  systemctl stop "$SVC_SUB" 2>/dev/null
  systemctl stop "$SVC_TUN" 2>/dev/null
  systemctl stop "$SVC_XRAY" 2>/dev/null
  systemctl disable "$SVC_SUB" 2>/dev/null
  systemctl disable "$SVC_TUN" 2>/dev/null
  systemctl disable "$SVC_XRAY" 2>/dev/null
  rm -f "/etc/systemd/system/${SVC_XRAY}.service" "/etc/systemd/system/${SVC_TUN}.service" \
        "/etc/systemd/system/${SVC_SUB}.service"
  systemctl daemon-reload

  rm -f "$XRAY_BIN"
  rm -rf "$BASE"
  rm -rf "$TOKEN_DIR"
  rm -f /etc/sysctl.d/99-argox.conf
  rm -f /etc/logrotate.d/argox
  sysctl --system >/dev/null 2>&1 || true

  ok "已卸载"
  warn "cloudflared 二进制保留在 ${CFD_BIN}（可能被其他服务使用），如需删除：rm -f ${CFD_BIN}"
  warn "记得去 CF Dashboard 删除对应 Tunnel，否则会留下孤儿隧道"
}

do_tunnel_setup() {
  require_root
  local ws_h sub_h mode_v
  ws_h="$(node_ws_host)"; sub_h="$(node_sub_host)"; mode_v="$(node_mode)"
  printf '\n  隧道配置\n'
  printf '  1) 填写 / 更换 Tunnel Token\n'
  printf '  2) 设置 / 更换隧道域名（主入口，用于生成节点）\n'
  printf '  3) 测试三条子域连通性\n'
  printf '  4) WS 兜底子域（当前：%s）\n' "${ws_h:-未设置}"
  printf '  5) 订阅子域（当前：%s）\n' "${sub_h:-未设置}"
  printf '  6) 节点地址模式（当前：%s）\n' "$mode_v"
  printf '  0) 返回\n'
  local c; read -rp "  选择: " c
  case "$c" in
    1)
      printf '\n  粘贴 Token 后回车（不回显）: '
      local t; read -rs t; printf '\n'
      t="${t// /}"
      [[ -z "$t" ]] && { err "Token 为空"; return 1; }
      save_token "$t"
      write_tunnel_service
      systemctl daemon-reload
      systemctl restart "$SVC_TUN" 2>/dev/null
      sleep 3
      if svc_active "$SVC_TUN"; then
        if journalctl -u "$SVC_TUN" -n 30 --no-pager 2>/dev/null | grep -q 'Registered tunnel connection'; then
          ok "隧道已注册成功"
        else
          warn "进程在跑但未注册，检查：journalctl -u ${SVC_TUN} -n 40"
        fi
      else
        err "启动失败：journalctl -u ${SVC_TUN} -n 40"
      fi
      gen_sub >/dev/null 2>&1 || true
      ;;
    2)
      local h; h="$(node_get tunnel_host)"
      read -rp "  隧道域名（当前：${h:-未设置}）: " h
      [[ -z "$h" ]] && return 0
      if [[ ! "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        err "域名格式不合法"; return 1
      fi
      node_set tunnel_host "$h"
      ok "隧道域名已设为 ${h}"
      gen_sub >/dev/null 2>&1 || true
      show_nodes
      ;;
    3)
      local h; h="$(node_get tunnel_host)"
      [[ -z "$h" ]] && { err "先设置隧道域名"; return 1; }
      local w s t r1 r2 r3
      w="$(node_ws_host)"; s="$(node_sub_host)"; t="$(node_get sub_token 2>/dev/null || true)"
      step "测试三条子域"
      r1="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${h}/" 2>/dev/null || echo 000)"
      [[ -n "$w" ]] && r2="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${w}/" 2>/dev/null || echo 000)"
      [[ -n "$s" && -n "$t" ]] && r3="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${s}/${t}" 2>/dev/null || echo 000)"
      printf '  主入口  %-34s HTTP %s\n' "$h" "${r1:-—}"
      printf '  WS      %-34s HTTP %s\n' "${w:-未设置}" "${r2:-—}"
      printf '  订阅    %-34s HTTP %s\n\n' "${s:-未设置}" "${r3:-—}"

      case "${r1:-000}" in
        000)     err "主入口不通：DNS 未解析 / 证书异常 / 隧道离线" ;;
        530|1033) err "主入口 HTTP ${r1}：CF 找不到该子域的路由（DNS 记录或 Public Hostname 缺失）" ;;
        502|503) err "主入口 HTTP ${r1}：CF 到了但回源失败（确认 127.0.0.1:${DEF_PORT_XHTTP} 在监听）" ;;
        *)       ok "主入口 HTTP ${r1}" ;;
      esac
      if [[ -n "$r2" ]]; then
        case "$r2" in
          000|530|1033|502|503) err "WS 子域异常：HTTP ${r2}（应指向 127.0.0.1:${DEF_PORT_WS}）" ;;
          *) ok "WS 子域 HTTP ${r2}" ;;
        esac
      fi
      if [[ -n "$r3" ]]; then
        [[ "$r3" == "200" ]] && ok "订阅可访问（HTTP 200）" \
          || err "订阅 HTTP ${r3}（应指向 127.0.0.1:${DEF_PORT_SUB}，正常只有 200）"
      fi
      ;;
    4)
      local w; w="$(node_ws_host)"
      read -rp "  WS 子域（当前：${w:-未设置}，如 ws.example.com）: " w
      [[ -z "$w" ]] && return 0
      if [[ ! "$w" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        err "域名格式不合法"; return 1
      fi
      node_set ws_host "$w"
      ok "WS 子域已设为 ${w}"
      info "CF 侧需有同名路由 → 127.0.0.1:${DEF_PORT_WS}"
      gen_sub >/dev/null 2>&1 || true
      show_nodes
      ;;
    5)
      local s; s="$(node_sub_host)"
      read -rp "  订阅子域（当前：${s:-未设置}，如 sub.example.com）: " s
      [[ -z "$s" ]] && return 0
      if [[ ! "$s" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
        err "域名格式不合法"; return 1
      fi
      node_set sub_host "$s"
      ok "订阅子域已设为 ${s}"
      info "CF 侧需有同名路由 → 127.0.0.1:${DEF_PORT_SUB}"
      show_nodes
      ;;
    6)
      printf '\n  当前：%s\n' "$(node_mode)"
      printf '  1) domain  域名直连（推荐：客户端自行解析到最近的 CF 节点）\n'
      printf '  2) ip      展开优选 IP（需自己测速筛选，否则多半更慢）\n'
      local m; read -rp "  选择（回车不改）: " m
      case "$m" in
        1) node_set node_mode domain ;;
        2) node_set node_mode ip ;;
        *) return 0 ;;
      esac
      ok "地址模式已设为 $(node_mode)"
      gen_sub >/dev/null 2>&1 || true
      show_nodes
      ;;
    *) return 0 ;;
  esac
}

# ==============================================================================
#  菜单
# ==============================================================================
menu_header() {
  local st_x st_t host
  if svc_active "$SVC_XRAY"; then st_x="${C_GRN}●运行${C_R}"; else st_x="${C_DIM}○停止${C_R}"; fi
  if [[ -s "$TOKEN_FILE" ]]; then
    if svc_active "$SVC_TUN"; then st_t="${C_GRN}●在线${C_R}"; else st_t="${C_YEL}○未运行${C_R}"; fi
  else
    st_t="${C_DIM}未配置${C_R}"
  fi
  host="$(node_get tunnel_host 2>/dev/null)"
  printf '\n'
  printf '%s╔══════════════════════════════════════════════════╗%s\n' "$C_B$C_BLU" "$C_R"
  printf '%s║%s  argox  ·  Argo 隧道 + Xray(XHTTP/WS)  %s%-8s%s%s║%s\n' "$C_B$C_BLU" "$C_R$C_B" "$C_DIM" "v${VERSION}" "$C_R" "$C_B$C_BLU" "$C_R"
  printf '%s╚══════════════════════════════════════════════════╝%s\n' "$C_B$C_BLU" "$C_R"
  printf '  Xray %s   Tunnel %s   域名 %s\n' "$st_x" "$st_t" "${host:-${C_DIM}未设置${C_R}}"
  printf '%s\n' "──────────────────────────────────────────────────"
}

menu_main() {
  while true; do
    menu_header
    cat <<'EOF'
   1) 安装 / 重新部署           9) 系统优化（BBR / 重启 / 日志）
   2) 启动                     10) 清理缓存
   3) 停止                     11) 备份配置
   4) 重启                     12) 卸载
   5) 查看状态                 13) 隧道设置（Token / 域名 / 测试）
   6) 查看日志                 14) 优选 IP 源
   7) 更新到最新版             15) 订阅地址 / 二维码
   8) 更换 UUID（用户名/密码）
    0) 退出
EOF
    printf '%s\n' "──────────────────────────────────────────────────"
    read -rp "  请选择: " choice
    case "${choice:-}" in
      1)  do_install ;;
      2)  do_start ;;
      3)  do_stop ;;
      4)  do_restart ;;
      5)  do_status ;;
      6)  do_logs ;;
      7)  do_update ;;
      8)  do_change_uuid ;;
      9)  do_sysopt ;;
      10) do_clean ;;
      11) do_backup ;;
      12) do_uninstall ;;
      13) do_tunnel_setup ;;
      14) menu_ips ;;
      15) show_nodes ;;
      0|q|Q) printf '\n  再见\n\n'; exit 0 ;;
      *) warn "无效选项：${choice:-<空>}" ;;
    esac
    printf '\n'
    read -rp "  按回车返回菜单…" _ || true
  done
}

# ==============================================================================
#  入口
# ==============================================================================
main() {
  case "${1:-}" in
    install)   do_install ;;
    start)     do_start ;;
    stop)      do_stop ;;
    restart)   do_restart ;;
    status)    do_status ;;
    logs)      do_logs ;;
    update)    do_update ;;
    ips)       update_ips ;;
    nodes|show) show_nodes ;;
    links)     show_links ;;
    sub)       gen_sub && cat "${SUBD}/argox.b64" ;;
    uninstall) do_uninstall ;;
    ""|menu)   require_root; menu_main ;;
    -h|--help|help)
      cat <<EOF
argox v${VERSION} — Cloudflare Argo 隧道 + Xray 一键部署

用法：
  bash $0              进入交互菜单（推荐）
  bash $0 install      直接部署
  bash $0 status       查看状态
  bash $0 nodes        打印订阅地址 + 二维码
  bash $0 links        打印单节点链接
  bash $0 sub          输出 Base64 订阅内容
  bash $0 ips          从 IP 源拉取并校验（菜单 14）
  bash $0 uninstall    卸载

  curl -fsSL <地址> | bash     ← 不推荐，请先 curl -o 下来看一眼
EOF
      ;;
    *) err "未知命令：$1（用 --help 查看）"; exit 1 ;;
  esac
}

main "$@"

