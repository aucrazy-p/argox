#!/usr/bin/env bash
# ==============================================================================
#  argox — Cloudflare Argo 隧道 + Xray (XHTTP) + sing-box 双核部署管理脚本
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

VERSION="2.10.0"
APP="argox"

# 脚本自身地址：从 /dev/fd/* 运行（bash <(curl ...)）且本地还没有副本时，用它把自己落地
RAW_URL="https://raw.githubusercontent.com/aucrazy-p/argox/main/argox.sh"
SELF_PATH="/root/argox.sh"
CMDBIN="/usr/local/bin/argox"   # 命令入口：install / upgrade 时自动生成，之后直接敲 argox

# ---- 路径 --------------------------------------------------------------------
BASE="/opt/argox"
CONF="${BASE}/config.json"
SBCONF="${BASE}/sb.json"        # sing-box 配置（Hy2 / TUIC）
CERTD="${BASE}/cert"            # 自签证书
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
SUBGEN="${BASE}/subs_gen.py"    # URI -> Clash YAML / sing-box JSON 转换器
TOKEN_FILE="/etc/argox/token.env"
TOKEN_DIR="/etc/argox"

XRAY_BIN="/usr/local/bin/argox-xray"
CFD_BIN="/usr/local/bin/cloudflared"
SB_BIN="/usr/local/bin/argox-sb"

SVC_XRAY="argox-xray"
SVC_TUN="argox-tunnel"
SVC_SUB="argox-sub"
SVC_SB="argox-sb"

# ---- 端口默认值 --------------------------------------------------------------
# 全部可覆盖：安装时用环境变量（如 SUB_PORT=9000 bash argox.sh install），
# 装完用 `bash argox.sh port <协议> <端口>`，都会写进 node.json 持久化。
# 回源端口（XHTTP）只在 127.0.0.1 上，不对外，一般不用改。
DEF_PORT_XHTTP="${XHTTP_PORT:-8001}"   # 仅本机，给 Argo 隧道回源（H3/H2 共用）
DEF_PORT_SUB="${SUB_PORT:-8099}"       # 订阅服务，v2.7.0 起对外监听（直连，不走隧道）

# ---- 直连协议（sing-box）默认值 ----------------------------------------------
# 这几个必须开放公网，Hy2 另需整段跳跃端口
DEF_PORT_HY2="${HY2_PORT:-23000}"          # Hy2 实监听端口（UDP）——取跳跃段首
DEF_PORT_TUIC="${TUIC_PORT:-30001}"        # TUIC 监听端口（UDP）
DEF_PORT_ANYTLS="${ANYTLS_PORT:-8445}"     # AnyTLS 监听端口（TCP）——UDP 全灭时的唯一出路
DEF_PORT_REALITY="${REALITY_PORT:-8443}"   # Reality 监听端口（TCP）——Xray 内核，默认关
DEF_PORT_WS=8002        # 已废弃（v2.7.0 删除 WS 入站），保留常量只为老脚本兼容
# Reality 伪装目标（dest / serverNames）。选型依据见 docs/plan-v2.md 2.6：
#   - 必须 TLS1.3 + ALPN h2，且从 VPS 可直连 443
#   - 证书 TLS 记录须 ≤ 8192 字节（Xray 硬编码上限，超了直接握手失败且不报错）
#   - 优先「证书链由 CDN 自动管理、长度固定」的目标，避免证书轮换后突然越线
# 默认 www.lovelive-anime.jp：CloudFront + AWS ACM，链固定 3 张 ≈3821 字节，
# 余量 2.1 倍；非巨头 SNI，root 带浏览器 UA 返回 200 无跳转。
REALITY_SNI="www.lovelive-anime.jp"
# 备选（VPS 实测均可，按长期稳定性排序）：www.intel.com(2051，链最短) / www.microsoft.com(5902)
# 不推荐：apple|icloud（Xray 启动即硬编码警告）、nvidia（307 跳中国站）、amd（握手 141ms）
REALITY_PROBE_HOSTS="www.lovelive-anime.jp www.intel.com www.microsoft.com www.nvidia.com www.amd.com"
REALITY_CERT_LIMIT=8192   # Xray REALITY 的 TLS Certificate 记录硬编码上限（字节）
DEF_HOP_RANGE="23000-27000"   # Hy2 端口跳跃段，默认不含 RustDesk(21115-21119) 等常用服务段
SB_VER_DEFAULT="1.12.0"       # sing-box 默认版本

# ---- 节点显示名（只影响客户端里看到的名字，不影响服务/tag/路径）--------------
# 规则：走 CF 隧道的加 Argo- 前缀；直连 VPS 公网端口的用裸协议名；
#       住宅落地版统一加 -RH 后缀（residential home）。
NAME_H3="Argo-H3"
NAME_H2="Argo-H2"
NAME_WS="Argo-WS"
NAME_HY2="Hy2"
NAME_TUIC="TUIC"
NAME_REALITY="Reality"
NAME_ANYTLS="AnyTLS"
NAME_RH="-RH"

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

# 读嵌套字段，点分路径：node_jget landing.enabled / landing.target
# 标量原样输出；布尔输出 true|false；数组用空格分隔；缺失输出空
node_jget() {
  [[ -r "$NODEF" ]] || return 0
  if has python3; then
    python3 - "$NODEF" "$1" 2>/dev/null <<'PY'
import json, sys
try:
    cur = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sys.argv[2].split('.'):
    if isinstance(cur, dict) and k in cur:
        cur = cur[k]
    else:
        sys.exit(0)
if isinstance(cur, bool):
    print('true' if cur else 'false')
elif isinstance(cur, list):
    print(' '.join(str(x) for x in cur))
elif isinstance(cur, dict):
    print(json.dumps(cur, ensure_ascii=False))
elif cur is not None:
    print(cur)
PY
  elif has jq; then
    jq -r ".$1 // empty" "$NODEF" 2>/dev/null
  fi
}

# 写嵌套字段，点分路径 + 原始 JSON 值：node_jset landing.enabled true
node_jset() {
  [[ -r "$NODEF" ]] || return 1
  has python3 || return 1
  python3 - "$NODEF" "$1" "$2" 2>/dev/null <<'PY'
import json, sys
p, path, raw = sys.argv[1], sys.argv[2].split('.'), sys.argv[3]
try:
    d = json.load(open(p))
except Exception:
    d = {}
cur = d
for k in path[:-1]:
    if not isinstance(cur.get(k), dict):
        cur[k] = {}
    cur = cur[k]
cur[path[-1]] = json.loads(raw)
with open(p, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
PY
}

installed() { [[ -x "$XRAY_BIN" ]] && [[ -f "$CONF" ]]; }

# 由主域名推导同级子域：argo.example.com + ws -> ws.example.com
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

# v2.7.0 起：WS 子域 / 订阅子域两个概念都废弃了。
#   - WS 入站已删除，H2 节点走 XHTTP + ALPN，与 H3 共用 8001 回源
#   - 订阅改为直连 VPS 公网端口，不经隧道
# sub_of / DEF_WS_SUB / DEF_SUB_SUB 保留仅供老配置推导参考，不再参与节点生成。

# 节点地址模式：domain（域名直连）| ip（展开优选 IP）
node_mode() {
  local m
  m="$(node_get node_mode 2>/dev/null || true)"
  [[ -z "$m" ]] && m="$NODE_MODE_DEFAULT"
  printf '%s' "$m"
}

# 出口跳板：off（走 VPS 本机出口）| all（全部流量交给本地代理）
node_hop_mode() {
  local m
  m="$(node_get hop_mode 2>/dev/null || true)"
  [[ -z "$m" ]] && m="$HOP_MODE_DEFAULT"
  printf '%s' "$m"
}

# 跳板协议：socks（SOCKS5，首选）| http（HTTP CONNECT）
node_hop_proto() {
  local p
  p="$(node_get hop_proto 2>/dev/null || true)"
  case "$p" in socks|http) : ;; *) p="$HOP_PROTO_DEFAULT" ;; esac
  printf '%s' "$p"
}

node_hop_addr() {
  local a
  a="$(node_get hop_addr 2>/dev/null || true)"
  [[ -z "$a" ]] && a="$HOP_ADDR_DEFAULT"
  printf '%s' "$a"
}

node_hop_port() {
  local p
  p="$(node_get hop_port 2>/dev/null || true)"
  [[ "$p" =~ ^[0-9]+$ ]] || p="$HOP_PORT_DEFAULT"
  printf '%s' "$p"
}

# 隧道传输协议：auto（默认，quic 失败自动退 http2）| quic | http2
node_tunnel_proto() {
  local p
  p="$(node_get tunnel_proto 2>/dev/null || true)"
  case "$p" in auto|quic|http2) : ;; *) p="$TUNNEL_PROTO_DEFAULT" ;; esac
  printf '%s' "$p"
}

# 探测本地代理：先 socks5h，再 http；成功输出「协议 出口IP」
hop_probe() {
  local ha hp out
  ha="$(node_hop_addr)"; hp="$(node_hop_port)"
  out="$(curl -s --max-time 8 -x "socks5h://${ha}:${hp}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | sed -n 's/^ip=//p' | head -1)"
  [[ -n "$out" ]] && { printf 'socks %s' "$out"; return 0; }
  out="$(curl -s --max-time 8 -x "http://${ha}:${hp}" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | sed -n 's/^ip=//p' | head -1)"
  [[ -n "$out" ]] && { printf 'http %s' "$out"; return 0; }
  return 1
}

# 探测本机常见代理端口。仅用于「node.json 缺 hop_port」时补齐真实值：
# 默认值只是兜底，缺字段的机器会误判成默认端口连不上。
# 本机地址优先读 ss 监听表（零连接开销），其他地址才逐个试连。
hop_detect_local() {
  local ha p
  ha="$(node_hop_addr)"
  if [[ "$ha" == "127.0.0.1" || "$ha" == "localhost" ]] && has ss; then
    local listen
    listen="$(ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*[:.]//' | sort -u)"
    for p in 7890 7891 1080 1081 7928 2080 8889 6152; do
      printf '%s\n' "$listen" | grep -qx "$p" && { printf '%s' "$p"; return 0; }
    done
    return 1
  fi
  for p in 7890 7891 1080 1081 7928 2080 8889 6152; do
    if timeout 1 bash -c ">/dev/tcp/${ha}/${p}" 2>/dev/null; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# ==============================================================================
#  住宅落地（landing）
#
#  同一条隧道、同一个域名，挂第二个 UUID；带该 UUID 的连接走本地代理出口。
#  不额外开端口、不额外开入站：靠 routing 的 user 条件分流。
# ==============================================================================
landing_on() { [[ "$(node_jget landing.enabled 2>/dev/null)" == "true" ]]; }

landing_uuid() { node_jget landing.uuid 2>/dev/null; }

landing_targets() { node_jget landing.target 2>/dev/null; }   # 空格分隔：h3 h2 ws reality

# 落地出口协议：没单独设置就沿用跳板的（指向同一台代理）
landing_proto() {
  local p; p="$(node_jget landing.proto 2>/dev/null)"
  case "$p" in socks|http) : ;; *) p="$(node_hop_proto)" ;; esac
  printf '%s' "$p"
}

# 当前 target 是否包含某个入口
landing_wants() { # $1=h3|h2|ws|anytls|reality
  local tg; tg=" $(landing_targets) "
  [[ "$tg" == *" $1 "* ]]
}

# AnyTLS 落地入站端口：主入站 -1（8445 → 8444），与主口连成一个连续段，
# 云安全组一次放行 8444-8445 即可，不必再单独加一个端口。
# 两个保护：算出来低于 1024（非 root 端口段），或跟 Reality 端口撞车时，退回主口 +1。
anytls_rh_port() {
  local p; p="$(anytls_port)"; local rh=$(( p - 1 ))
  if [[ $rh -lt 1024 || "$rh" == "$(reality_port)" ]]; then rh=$(( p + 1 )); fi
  printf '%s' "$rh"
}

# ==============================================================================
#  直连协议（sing-box：Hy2 / TUIC）状态读取
# ==============================================================================
sb_installed() { [[ -x "$SB_BIN" ]] && [[ -f "$SBCONF" ]]; }

# proto 开关：proto.hy2 / proto.tuic / proto.argo
proto_on() { [[ "$(node_jget "proto.$1" 2>/dev/null)" == "true" ]]; }

hy2_port() { local p; p="$(node_jget hy2.port 2>/dev/null)"; printf '%s' "${p:-$DEF_PORT_HY2}"; }
hy2_hop()  { local h; h="$(node_jget hy2.hop  2>/dev/null)"; printf '%s' "${h:-$DEF_HOP_RANGE}"; }
tuic_port() { local p; p="$(node_jget tuic.port 2>/dev/null)"; printf '%s' "${p:-$DEF_PORT_TUIC}"; }
anytls_port() { local p; p="$(node_jget anytls.port 2>/dev/null)"; printf '%s' "${p:-$DEF_PORT_ANYTLS}"; }

# ---- Reality（Xray 内核）参数 ------------------------------------------------
reality_port() { local p; p="$(node_jget reality.port 2>/dev/null)"; printf '%s' "${p:-$DEF_PORT_REALITY}"; }
# 订阅端口：v2.7.0 起订阅不再走隧道，改为公网直连，所以端口要可配、要放行
sub_port()    { local p; p="$(node_jget sub.port 2>/dev/null)";    printf '%s' "${p:-$DEF_PORT_SUB}"; }

# 订阅地址：直连 VPS 公网 IP，不经隧道（省掉一条 CF 路由 + 一条 DNS + 一份 CF 流量）
sub_url() {
  local tok; tok="$(node_get sub_token 2>/dev/null || true)"
  [[ -z "$tok" ]] && return 1
  printf 'http://%s:%s/%s' "$(vps_ip)" "$(sub_port)" "$tok"
}
reality_sni()  { local s; s="$(node_jget reality.sni 2>/dev/null)";  printf '%s' "${s:-$REALITY_SNI}"; }
reality_sid()  { node_jget reality.short_id 2>/dev/null; }
reality_pk()   { node_jget reality.private_key 2>/dev/null; }
reality_pub()  { node_jget reality.public_key 2>/dev/null; }

# 生成 / 补齐 Reality 密钥对（x25519）与 shortId；已有则不动
reality_keys() {
  local pk pub sid out
  pk="$(reality_pk)"; pub="$(reality_pub)"; sid="$(reality_sid)"

  if [[ -z "$pk" || -z "$pub" ]]; then
    [[ -x "$XRAY_BIN" ]] || { err "Xray 未安装，无法生成 Reality 密钥"; return 1; }
    out="$("$XRAY_BIN" x25519 2>/dev/null)"
    # 不同 Xray 版本标签不一样（Private key / PrivateKey、Password / Public key），
    # 按行取比按标签匹配稳：第 1 行私钥，第 2 行公钥
    pk="$(printf '%s\n' "$out" | sed -n '1s/.*: *//p' | tr -d '[:space:]')"
    pub="$(printf '%s\n' "$out" | sed -n '2s/.*: *//p' | tr -d '[:space:]')"
    if [[ -z "$pk" || -z "$pub" ]]; then
      err "生成 Reality 密钥失败（xray x25519 无输出，检查 Xray 版本是否 ≥ 1.8）"
      return 1
    fi
    node_jset reality.private_key "\"$pk\"" >/dev/null 2>&1 || true
    node_jset reality.public_key  "\"$pub\"" >/dev/null 2>&1 || true
    ok "Reality 密钥已生成（x25519）"
  fi

  if [[ -z "$sid" ]]; then
    sid="$(rand_hex 8)"
    node_jset reality.short_id "\"$sid\"" >/dev/null 2>&1 || true
  fi
  return 0
}

# Reality 改动后的落地动作：重写 Xray 配置 → 重启 → 放行端口 → 重建订阅
reality_apply() {
  local uuid px pw
  uuid="$(node_get uuid)"; px="$(node_get path_xhttp)"; pw="$(node_get path_ws)"
  write_xray_config "$uuid" "$px" "$pw" || return 1
  systemctl restart "$SVC_XRAY" 2>/dev/null
  sleep 1
  if ! svc_active "$SVC_XRAY"; then
    err "Xray 重启失败："
    journalctl -u "$SVC_XRAY" -n 15 --no-pager 2>/dev/null | tail -15
    return 1
  fi
  proto_on reality && fw_open tcp "$(reality_port)"
  gen_sub >/dev/null 2>&1 || warn "订阅重建失败"
  return 0
}

# ==============================================================================
#  Reality 伪装目标体检（dest / serverNames）
#
#  为什么需要单独体检：Xray 的 REALITY 对目标站下发证书的 TLS Certificate
#  记录有 8192 字节硬编码上限（Xray-core issue #6356），超了握手直接失败；
#  而这个大小随 CDN 边缘节点与证书轮换变化——同一域名在不同机器上测出的值不同。
#  更麻烦的是失效时 Xray 既不报错也不打日志，只能靠主动探测提前发现。
#
#  四项硬指标：TLS1.3 / ALPN h2 / 证书链受信 / 证书记录 ≤ 8192
#  三项加分：非流量巨头、证书链由 CDN 自动管理（长度固定）、root 无跨域跳转
#  选型结论与实测记录见 docs/plan-v2.md 2.6
# ==============================================================================

sni_valid() { # $1=域名
  local s="${1// /}"
  [[ -n "$s" ]] || { err "域名不能为空"; return 1; }
  [[ "$s" == *.* ]] || { err "需要完整域名（含点）：${s}"; return 1; }
  [[ "$s" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || { err "域名格式不合法：${s}"; return 1; }
  return 0
}

# 探测一个目标。返回 0=可用 1=不可用 2=可用但有风险
# $1=域名  $2=1 时静默（结果放全局 PR_REC/PR_MS/PR_CODE/PR_NOTE，供 check 使用）
reality_probe_one() {
  local h="$1" quiet="${2:-0}"
  local pem n body der rec t0 t1 ms pair code redir rhost issuer note mark color rc

  PR_REC=0; PR_MS=0; PR_CODE="000"; PR_NOTE=""

  t0=$(date +%s%3N)
  pem="$(printf '' | timeout 8 openssl s_client -connect "${h}:443" -servername "$h" \
        -tls1_3 -alpn h2 -showcerts 2>/dev/null || true)"
  t1=$(date +%s%3N)
  ms=$((t1 - t0))

  n="$(printf '%s\n' "$pem" | grep -c -- '-----BEGIN CERTIFICATE-----' || true)"
  if [[ -z "$pem" || "${n:-0}" -eq 0 ]]; then
    PR_NOTE="连不上（TLS1.3 / ALPN h2 握手失败或超时）"
    [[ "$quiet" == "1" ]] || printf '  %s✗%s %-26s %s\n' "$C_RED" "$C_R" "$h" "$PR_NOTE"
    return 1
  fi

  # 证书链总长：把所有 PEM 正文拼起来一次性解码，比逐个 openssl x509 更省事
  body="$(printf '%s\n' "$pem" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/{/-----/d;p}')"
  der="$(printf '%s\n' "$body" | tr -d '\r\n ' | base64 -d 2>/dev/null | wc -c || true)"
  # TLS1.3 Certificate 消息 = ΣDER + 5×张数 + 8（含 4 字节 handshake 头），已与 openssl -msg 逐字节核对
  rec=$(( ${der:-0} + 5*n + 8 ))

  # 签发方：只取第一张证书，-nameopt RFC2253 强制统一格式。
  # 不能直接对整段 s_client 输出跑 x509，也不依赖默认 DN 格式——
  # OpenSSL 3.0 输出 "C = US, O = Amazon"（等号带空格），3.5 输出 "C=US, O=Amazon"，
  # 按 "O=" 硬匹配在 3.0 上会静默取空。
  local cert1 issln
  cert1="$(printf '%s\n' "$pem" | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
           | sed -n '1,/-----END CERTIFICATE-----/p')"
  issln="$(printf '%s\n' "$cert1" | openssl x509 -noout -issuer -nameopt RFC2253 2>/dev/null)"
  # 提取顺序：O= → CN= → 整行截断。/ 兼容老式 /C=US/O=X/CN=Y 格式；
  # [[:space:]]* 兼容某些版本忽略 -nameopt 时的 "O = Amazon" 写法。
  issuer="$(printf '%s\n' "$issln" | sed -n 's/.*[=,\/][[:space:]]*O[[:space:]]*=[[:space:]]*\([^,\/]*\).*/\1/p' | head -1)"
  [[ -z "$issuer" ]] && issuer="$(printf '%s\n' "$issln" | sed -n 's/.*[=,\/][[:space:]]*CN[[:space:]]*=[[:space:]]*\([^,\/]*\).*/\1/p' | head -1)"
  [[ -z "$issuer" ]] && issuer="$(printf '%s\n' "$issln" | sed 's/^issuer=//' | cut -c1-28)"
  # 输出列宽是 20（printf %-20s），超长按词边界截断，避免撑破对齐
  issuer="$(printf '%s' "$issuer" | tr -d '\\' | sed 's/[[:space:]]*$//')"
  if (( ${#issuer} > 20 )); then
    local _t="${issuer:0:20}"
    _t="${_t% *}"
    (( ${#_t} >= 8 )) && issuer="$_t" || issuer="${issuer:0:20}"
  fi
  [[ -z "$issuer" ]] && issuer="?"

  pair="$(timeout 8 curl -s -o /dev/null -m 8 \
      -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
      -w '%{http_code}|%{redirect_url}' "https://${h}/" 2>/dev/null || printf '000|')"
  code="${pair%%|*}"; redir="${pair#*|}"
  rhost="${redir#https://}"; rhost="${rhost#http://}"; rhost="${rhost%%/*}"

  mark="✓"; color="$C_GRN"; note=""; rc=0
  if (( rec > REALITY_CERT_LIMIT )); then
    mark="✗"; color="$C_RED"; rc=1
    note="证书 ${rec} > ${REALITY_CERT_LIMIT}，Xray 会直接拒绝握手"
  elif (( rec > REALITY_CERT_LIMIT * 85 / 100 )); then
    mark="!"; color="$C_YEL"; rc=2
    note="余量不足 15%，证书轮换后可能越线"
  fi
  if [[ -n "$rhost" && "$rhost" != "$h" ]]; then
    [[ "$rc" -eq 0 ]] && { mark="!"; color="$C_YEL"; rc=2; }
    note="${note:+${note}；}root 跳到 ${rhost}"
  fi
  if printf '%s' "$h" | grep -qiE '(^|\.)(apple|icloud)\.'; then
    [[ "$rc" -eq 0 ]] && { mark="!"; color="$C_YEL"; rc=2; }
    note="${note:+${note}；}Xray 对 apple/icloud 有硬编码封 IP 警告"
  fi

  PR_REC="$rec"; PR_MS="$ms"; PR_CODE="$code"; PR_NOTE="$note"
  if [[ "$quiet" != "1" ]]; then
    printf '  %s%s%s %-26s %6s  %6sms  %-4s %-20s %s\n' \
      "$color" "$mark" "$C_R" "$h" "$rec" "$ms" "$code" "$issuer" "$note"
  fi
  return $rc
}

# 批量体检；不带参数时测内置候选
reality_probe() {
  local hosts=() h rc bad=0 warn=0 good=0
  for h in "$@"; do hosts+=("$h"); done
  if [[ ${#hosts[@]} -eq 0 ]]; then
    read -ra hosts <<< "$REALITY_PROBE_HOSTS"
  fi

  printf '\n  %sReality 伪装目标体检%s  证书上限 %s 字节\n' "$C_B" "$C_R" "$REALITY_CERT_LIMIT"
  printf '  %s标记 域名                        证书    握手  HTTP  签发方%s\n' "$C_DIM" "$C_R"

  for h in "${hosts[@]}"; do
    sni_valid "$h" || continue
    reality_probe_one "$h"; rc=$?
    case $rc in
      0) good=$((good+1)) ;;
      1) bad=$((bad+1)) ;;
      2) warn=$((warn+1)) ;;
    esac
  done

  printf '\n'
  printf '  当前 dest：%s\n' "$(reality_sni)"
  if [[ $bad -gt 0 ]]; then
    err "${bad} 个目标不可用（标记 ✗）：证书超限或握手失败，选了会导致节点直接连不上"
  fi
  if [[ $warn -gt 0 ]]; then
    warn "${warn} 个目标有风险（标记 !）：能用但余量不足 / 有跳转 / 被官方点名"
  fi
  [[ $good -gt 0 ]] && ok "${good} 个目标可用"
  printf '  %s判断口径：证书越短越抗证书轮换；非巨头 SNI 更不易被单独针对；%s\n' \
    "$C_DIM" "root 无跨域跳转才像真站$C_R"
  if [[ -n "$(reality_sni)" && "$(reality_sni)" != "$REALITY_SNI" ]]; then
    printf '  %s当前不是脚本默认值，切换：bash %s reality sni <域名>%s\n' \
      "$C_DIM" "$APP" "$C_R"
  fi
}

# 改伪装目标：写 node.json → 开了 Reality 就重写配置并重启 → 重建订阅
reality_sni_set() { # $1=域名
  local s="${1// /}" old rc
  sni_valid "$s" || return 1
  old="$(reality_sni)"
  if [[ "$s" == "$old" ]]; then
    info "伪装目标已经是 ${s}，无需改动"
    return 0
  fi

  printf '\n  %s先体检新目标%s\n' "$C_B" "$C_R"
  reality_probe_one "$s"; rc=$?
  if [[ $rc -eq 1 ]]; then
    err "该目标不可用，已放弃修改（原配置一字未动：${old}）"
    return 1
  fi
  [[ $rc -eq 2 ]] && warn "该目标有风险，但可继续（见上面的说明）"

  node_jset reality.sni "\"$s\"" || { err "写入 node.json 失败"; return 1; }
  ok "伪装目标：${old} → ${s}"

  if proto_on reality; then
    reality_apply || { err "应用失败，手动重开：$(cmd_prefix) direct off reality && $(cmd_prefix) direct on reality"; return 1; }
    ok "已重写 Xray 配置并重启 argox-xray"
  else
    gen_sub >/dev/null 2>&1 || warn "订阅重建失败"
    info "Reality 当前未开启，改动已落盘，下次开启时生效"
  fi
  warn "客户端需删旧节点重拉订阅：旧订阅里的 sni 还是 ${old}"
  return 0
}

# Hy2 / AnyTLS 密码直接复用主 UUID：少一个字段，就少一处漂移
hy2_pass() { node_get uuid; }
anytls_pass() { node_get uuid; }

# TUIC 密码：首次读取时生成并落盘，之后固定
tuic_pass() {
  local p; p="$(node_jget tuic.password 2>/dev/null)"
  if [[ -z "$p" ]]; then
    p="$(rand_hex 16)"
    node_jset tuic.password "\"$p\"" >/dev/null 2>&1 || true
  fi
  printf '%s' "$p"
}

# VPS 公网 IP（生成直连节点要用），首次探测后缓存进 node.json
vps_ip() {
  local ip; ip="$(node_jget vps_ip 2>/dev/null)"
  if [[ -z "$ip" || "$ip" == "null" ]]; then
    ip="$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -s --max-time 6 https://ifconfig.me 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -s --max-time 6 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "$ip" ]]; then node_jset vps_ip "\"${ip}\"" >/dev/null 2>&1 || true; fi
  fi
  printf '%s' "${ip:-}"
}

# 跳跃段校验：返回 0 通过，否则打印原因
hop_valid() { # $1=起-止
  local r="$1"
  [[ "$r" =~ ^([0-9]+)-([0-9]+)$ ]] || { err "格式必须是 起-止，如 23000-27000"; return 1; }
  local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
  (( s < e )) || { err "起始端口必须小于结束端口"; return 1; }
  (( s >= 1024 && e <= 65535 )) || { err "端口必须在 1024-65535 之间"; return 1; }
  (( e - s <= 20000 )) || { err "跨度不能超过 20000（防止误写成 1-65535）"; return 1; }
  local tp; tp="$(tuic_port)"
  (( tp < s || tp > e )) || { err "TUIC 端口 ${tp} 落在跳跃段内，会互相抢占"; return 1; }
  return 0
}

# 设置跳跃段：监听口不在段内时自动挪到段首（否则 nft redirect 过来的包没人收）
hy2_hop_set() { # $1=起-止
  local rng="${1// /}"
  local s="${rng%%-*}" e="${rng##*-}"

  hop_valid "$rng" || return 1

  # 先确认新监听口可用，再落盘，避免 hop 改了 port 没改的半截状态
  local old_hp; old_hp="$(hy2_port)"
  local move_port=0
  if (( old_hp < s || old_hp > e )); then
    move_port=1
    if port_in_use "$s" udp; then
      err "UDP ${s}（新段首）已被占用，无法把 Hy2 监听口挪过去"
      info "先停掉占用进程，或先手动换一个空闲监听口再设跳跃段"
      return 1
    fi
  fi

  node_jset hy2.hop "\"$rng\"" || { err "跳跃段写入失败"; return 1; }

  if (( move_port )); then
    node_jset hy2.port "$s" || { err "监听口写入失败"; return 1; }
    ok "Hy2 监听口 ${old_hp} → ${s}（跳跃段首）"
    proto_on hy2 && sb_sync           # 换监听口必须重启 sing-box
  else
    info "Hy2 监听口 ${old_hp} 仍在段内，无需改动"
    proto_on hy2 && sb_hop_apply
  fi

  gen_sub >/dev/null 2>&1 || true
  ok "跳跃段已设为 ${rng}"
  warn "云安全组 / 本机防火墙需同步放行 UDP ${rng}"
  return 0
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

install_singbox() {
  local arch; arch="$(detect_arch)"
  [[ "$arch" == "unknown" ]] && die "不支持的架构：$(uname -m)"

  if [[ -x "$SB_BIN" ]]; then
    info "已安装 sing-box $("$SB_BIN" version 2>/dev/null | head -1 | awk '{print $3}')，跳过下载"
    return 0
  fi

  local ver="${SB_VER:-$SB_VER_DEFAULT}"
  local pkg="sing-box-${ver}-linux-${arch}"
  local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg}.tar.gz"

  step "下载 sing-box v${ver}（${arch}）"
  local tmp; tmp="$(mktemp -d)"
  fetch "${tmp}/sb.tar.gz" "$url" || die "sing-box 下载失败（版本 ${ver} 可能不适用于 ${arch}）"
  tar -xzf "${tmp}/sb.tar.gz" -C "$tmp" 2>/dev/null || die "sing-box 解压失败"

  local bin; bin="$(find "$tmp" -type f -name sing-box -perm -u+x 2>/dev/null | head -1)"
  [[ -n "$bin" ]] || bin="$(find "$tmp" -type f -name sing-box 2>/dev/null | head -1)"
  [[ -n "$bin" ]] || die "压缩包内未找到 sing-box 二进制"

  install -m 0755 "$bin" "$SB_BIN"
  rm -rf "$tmp"
  ok "sing-box 已安装：$("$SB_BIN" version 2>/dev/null | head -1)"
}

# ==============================================================================
#  自签证书（Hy2 / TUIC 共用一份 ECC P-256）
# ==============================================================================
cert_gen() {
  local sni; sni="$(node_get tunnel_host 2>/dev/null || true)"
  [[ -z "$sni" ]] && sni="argox.local"
  mkdir -p "$CERTD"; chmod 700 "$CERTD"

  if [[ -f "${CERTD}/cert.pem" && -f "${CERTD}/key.pem" && "${1:-}" != "--force" ]]; then
    info "证书已存在（cert show 查看；cert gen --force 重签）"
    return 0
  fi

  step "生成自签证书（ECC P-256 / 3650 天 / SAN=${sni}）"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "${CERTD}/key.pem" -out "${CERTD}/cert.pem" \
    -days 3650 -nodes -subj "/CN=${sni}" \
    -addext "subjectAltName=DNS:${sni}" >/dev/null 2>&1 \
    || die "证书生成失败（openssl 版本可能过低，需要 1.1.1+）"
  chmod 600 "${CERTD}/cert.pem" "${CERTD}/key.pem"
  ok "证书已生成"
}

cert_show() {
  if [[ ! -f "${CERTD}/cert.pem" ]]; then
    warn "尚未生成证书（cert gen 生成）"
    return 1
  fi
  local subj end left fp
  subj="$(openssl x509 -noout -subject -in "${CERTD}/cert.pem" 2>/dev/null | sed 's/^subject=//')"
  end="$(openssl x509 -noout -enddate  -in "${CERTD}/cert.pem" 2>/dev/null | sed 's/^notAfter=//')"
  fp="$(openssl x509 -noout -fingerprint -sha256 -in "${CERTD}/cert.pem" 2>/dev/null | sed 's/^.*=//')"
  left=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  printf '  主体     : %s\n' "$subj"
  printf '  到期     : %s（剩 %s 天）\n' "$end" "$left"
  printf '  指纹     : %s\n' "${fp:0:47}..."
  printf '  客户端   : 一律 skip-cert-verify / insecure=1\n'
  [[ $left -lt 30 ]] && warn "证书即将过期，执行 cert gen --force 重签"
  return 0
}

# ==============================================================================
#  sing-box 配置（Hy2 / TUIC）
# ==============================================================================
sb_inbound_hy2() {
  local hp; hp="$(hy2_port)"; local pw; pw="$(hy2_pass)"
  cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${hp},
      "users": [ { "password": "${pw}" } ],
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "${CERTD}/cert.pem",
        "key_path": "${CERTD}/key.pem"
      },
      "masquerade": "https://www.bing.com/"
    }
EOF
}

sb_inbound_tuic() {
  local tp; tp="$(tuic_port)"; local uuid; uuid="$(node_get uuid)"; local pw; pw="$(tuic_pass)"
  cat <<EOF
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${tp},
      "users": [ { "uuid": "${uuid}", "password": "${pw}" } ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [ "h3" ],
        "certificate_path": "${CERTD}/cert.pem",
        "key_path": "${CERTD}/key.pem"
      }
    }
EOF
}

# AnyTLS：TCP + TLS，UDP 全被 QoS 时的唯一活路
sb_inbound_anytls() { # $1=rh 时生成落地入站（独立端口，密码用落地 UUID）
  local tag="anytls-in" ap pw
  if [[ "${1:-}" == "rh" ]]; then
    tag="anytls-rh-in"
    ap="$(anytls_rh_port)"
    pw="$(landing_uuid)"
  else
    ap="$(anytls_port)"
    pw="$(anytls_pass)"
  fi
  cat <<EOF
    {
      "type": "anytls",
      "tag": "${tag}",
      "listen": "::",
      "listen_port": ${ap},
      "users": [ { "password": "${pw}" } ],
      "tls": {
        "enabled": true,
        "alpn": [ "h2", "http/1.1" ],
        "certificate_path": "${CERTD}/cert.pem",
        "key_path": "${CERTD}/key.pem"
      }
    }
EOF
}

write_sb_config() {
  mkdir -p "$LOGD"
  local body="" need_land=0
  if proto_on hy2; then body="$(sb_inbound_hy2)"; fi
  if proto_on tuic; then
    if [[ -n "$body" ]]; then body="${body},"$'\n'; fi
    body="${body}$(sb_inbound_tuic)"
  fi
  if proto_on anytls; then
    if [[ -n "$body" ]]; then body="${body},"$'\n'; fi
    body="${body}$(sb_inbound_anytls)"
    # AnyTLS 落地：独立入站 + socks 出口。sing-box 侧只有它可以走落地，
    # Hy2 / TUIC 是 UDP，落地代理不支持 UDP ASSOCIATE。
    if landing_on && landing_wants anytls && [[ -n "$(landing_uuid)" ]]; then
      body="${body},"$'\n'"$(sb_inbound_anytls rh)"
      need_land=1
    fi
  fi

  if [[ -z "$body" ]]; then
    warn "Hy2 / TUIC / AnyTLS 都未开启，sing-box 不启用"
    return 1
  fi

  local ob="    { \"type\": \"direct\", \"tag\": \"direct\" }" rt=""
  if [[ $need_land -eq 1 ]]; then
    # 落地出口：sing-box 直接把该入站的流量交给本机代理（与 Xray 用同一个本地代理）
    ob="${ob},"$'\n'"    { \"type\": \"$(landing_proto)\", \"tag\": \"landing\", \"server\": \"$(node_hop_addr)\", \"server_port\": $(node_hop_port) }"
    rt=","$'\n'"  \"route\": {"$'\n'"    \"rules\": ["$'\n'"      { \"inbound\": [ \"anytls-rh-in\" ], \"outbound\": \"landing\" }"$'\n'"    ]"$'\n'"  }"
  fi

  cat > "$SBCONF" <<EOF
{
  "log": {
    "level": "warn",
    "output": "${LOGD}/sb.log",
    "timestamp": true
  },
  "inbounds": [
${body}
  ],
  "outbounds": [
${ob}
  ]${rt}
}
EOF
  chmod 600 "$SBCONF"

  "$SB_BIN" check -c "$SBCONF" >/dev/null 2>&1 || {
    err "sing-box 配置校验失败，输出如下："
    "$SB_BIN" check -c "$SBCONF" 2>&1 | tail -10
    return 1
  }
}

# 端口跳跃：nftables redirect，只改目的端口，sing-box 实际只监听一个口
sb_hop_apply() {
  local hp; hp="$(hy2_port)"; local rng; rng="$(hy2_hop)"

  if ! has nft; then
    warn "未安装 nftables，端口跳跃不可用（apt install -y nftables）"
    info "不影响 Hy2 本身：客户端固定用 ${hp} 也能工作"
    return 1
  fi

  nft delete table inet argox_hop 2>/dev/null || true

  if [[ -z "$rng" || "$rng" == "$hp" ]]; then
    info "跳跃段未设置，跳过 nft 规则"
    return 0
  fi

  hop_valid "$rng" || return 1

  if nft -f - 2>/dev/null <<EOF
table inet argox_hop {
  chain prerouting {
    type nat hook prerouting priority dstnat - 5; policy accept;
    udp dport ${rng} redirect to :${hp}
  }
}
EOF
  then
    ok "端口跳跃生效：UDP ${rng} → ${hp}"
    if has docker; then
      warn "检测到 Docker：它可能接管 nftables，跳跃失效时先看 nft list table inet argox_hop"
    fi
    return 0
  else
    err "nft 规则写入失败"
    return 1
  fi
}

# 放行本机防火墙：Oracle 的 Ubuntu 镜像默认在 INPUT 末尾挂 REJECT，
# 云安全组放行了、实例内还是不通，是这个原因。
# 注意端口范围写法三家不同：ufw/iptables 用冒号（23000:27000），firewalld 用短横线（23000-27000）
fw_open() { # $1=tcp|udp  $2=端口 或 起-止
  local pr="$1" p="$2" did=0
  local p_colon="${p/-/:}"                      # ufw / iptables 要冒号
  local p_dash="${p/:/-}"                       # firewalld 要短横线

  if has ufw && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${p_colon}/${pr}" >/dev/null 2>&1 && did=1
  fi

  if has firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${p_dash}/${pr}" >/dev/null 2>&1 \
      && firewall-cmd --reload >/dev/null 2>&1 && did=1
  fi

  if has iptables; then
    if ! iptables -C INPUT -p "$pr" --dport "$p_colon" -j ACCEPT 2>/dev/null; then
      iptables -I INPUT 1 -p "$pr" --dport "$p_colon" -j ACCEPT 2>/dev/null && did=1
    fi
    # 持久化：有 netfilter-persistent 用它，否则写 /etc/iptables/rules.v4
    if has netfilter-persistent; then
      netfilter-persistent save >/dev/null 2>&1 || true
    elif [[ -d /etc/iptables ]]; then
      iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
  fi

  [[ $did -eq 1 ]] && ok "本机防火墙已放行 ${pr^^} ${p_dash}"
  return 0
}

# 直连协议的端口全部放行一遍（云安全组仍需手动配，脚本改不了）
fw_open_direct() {
  proto_on hy2    && fw_open udp "$(hy2_hop)"
  proto_on tuic   && fw_open udp "$(tuic_port)"
  if proto_on anytls; then
    fw_open tcp "$(anytls_port)"
    landing_on && landing_wants anytls && fw_open tcp "$(anytls_rh_port)"
  fi
  proto_on reality && fw_open tcp "$(reality_port)"
  return 0
}

write_sb_service() {
  cat > "/etc/systemd/system/${SVC_SB}.service" <<EOF
[Unit]
Description=argox sing-box (Hysteria2 / TUIC / AnyTLS)
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${SB_BIN} run -c ${SBCONF}
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# 重建 sing-box 配置 → 起服务 → 应用跳跃规则；失败自动停掉服务，不半死不活
sb_sync() {
  if ! proto_on hy2 && ! proto_on tuic && ! proto_on anytls; then
    systemctl stop "$SVC_SB" 2>/dev/null || true
    nft delete table inet argox_hop 2>/dev/null || true
    info "Hy2 / TUIC / AnyTLS 均关闭，sing-box 已停止"
    return 0
  fi

  cert_gen || return 1
  write_sb_config || return 1
  write_sb_service

  systemctl enable "$SVC_SB" >/dev/null 2>&1 || true
  systemctl restart "$SVC_SB" 2>/dev/null
  sleep 2
  if ! svc_active "$SVC_SB"; then
    err "sing-box 启动失败："
    journalctl -u "$SVC_SB" -n 15 --no-pager 2>/dev/null | tail -15
    return 1
  fi

  proto_on hy2 && sb_hop_apply
  fw_open_direct
  ok "sing-box 运行中（$(proto_label_sb)）"
}

proto_label() {
  local out=()
  proto_on hy2    && out+=("Hy2:$(hy2_port)")
  proto_on tuic   && out+=("TUIC:$(tuic_port)")
  proto_on anytls && out+=("AnyTLS:$(anytls_port)")
  proto_on reality && out+=("Reality:$(reality_port)")
  local IFS=" "
  printf '%s' "${out[*]:-无}"
}

# 只列 sing-box 管的三个（Reality 在 Xray 内核里，混进来会让人以为 sing-box 崩了 Reality 就没了）
proto_label_sb() {
  local out=()
  proto_on hy2    && out+=("Hy2:$(hy2_port)")
  proto_on tuic   && out+=("TUIC:$(tuic_port)")
  proto_on anytls && out+=("AnyTLS:$(anytls_port)")
  local IFS=" "
  printf '%s' "${out[*]:-无}"
}

# 只要协议名不带端口，菜单头部状态行用（带端口太长会折行）
proto_label_short() {
  local out=()
  proto_on hy2     && out+=("Hy2")
  proto_on tuic    && out+=("TUIC")
  proto_on anytls  && out+=("AnyTLS")
  proto_on reality && out+=("Reality")
  local IFS="/"
  printf '%s' "${out[*]:-无}"
}

# ==============================================================================
#  配置生成
# ==============================================================================
write_xray_config() {
  local uuid="$1" px="$2" pw="$3"

  # ---- 住宅落地：各入站按 target 决定是否挂第二个 UUID ----
  # v2.7.0 起 WS 入站已彻底移除（订阅里 H2 走的是 XHTTP + ALPN，不占 8002），
  # 所以落地只剩 H3/H2 共用入站、Reality 两种挂法。
  local use_landing=0 luuid="" x_land=0 r_land=0
  if landing_on; then
    luuid="$(landing_uuid)"
    if [[ -n "$luuid" ]]; then
      use_landing=1
      landing_wants h3 && x_land=1
      landing_wants h2 && x_land=1
      # Reality-RH 还要求 Reality 本身开着，否则入站不存在
      proto_on reality && landing_wants reality && r_land=1
    fi
  fi

  local xclients
  if [[ $x_land -eq 1 ]]; then
    xclients="[{ \"id\": \"${uuid}\" }, { \"id\": \"${luuid}\", \"email\": \"landing\" }]"
  else
    xclients="[{ \"id\": \"${uuid}\" }]"
  fi

  # ---- Reality 入站（Xray 内核，默认关；与 sing-box 无关）----
  local reality_in=""
  if proto_on reality; then
    local rp rs rk rsid rclients
    rp="$(reality_port)"; rs="$(reality_sni)"; rk="$(reality_pk)"; rsid="$(reality_sid)"
    if [[ -z "$rk" || -z "$rsid" ]]; then
      err "Reality 密钥 / shortId 缺失，先执行 reality_keys（或重开一次 Reality）"
      return 1
    fi
    if [[ $r_land -eq 1 ]]; then
      rclients="[{ \"id\": \"${uuid}\", \"flow\": \"xtls-rprx-vision\" }, { \"id\": \"${luuid}\", \"flow\": \"xtls-rprx-vision\", \"email\": \"landing\" }]"
    else
      rclients="[{ \"id\": \"${uuid}\", \"flow\": \"xtls-rprx-vision\" }]"
    fi
    reality_in=",
    {
      \"tag\": \"reality\",
      \"listen\": \"0.0.0.0\",
      \"port\": ${rp},
      \"protocol\": \"vless\",
      \"settings\": { \"clients\": ${rclients}, \"decryption\": \"none\" },
      \"streamSettings\": {
        \"network\": \"tcp\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"dest\": \"${rs}:443\",
          \"xver\": 0,
          \"serverNames\": [\"${rs}\"],
          \"privateKey\": \"${rk}\",
          \"shortIds\": [\"${rsid}\"]
        }
      },
      \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\",\"tls\",\"quic\"], \"routeOnly\": true }
    }"
  fi

  # 出站与路由：跳板开启时把 hop 放在第一位（成为默认出口）
  local ob_json rt_json
  if [[ "$(node_hop_mode)" == "all" ]]; then
    local hp ha hport
    hp="$(node_hop_proto)"; ha="$(node_hop_addr)"; hport="$(node_hop_port)"
    ob_json="    { \"protocol\": \"${hp}\", \"tag\": \"hop\", \"settings\": { \"servers\": [{ \"address\": \"${ha}\", \"port\": ${hport} }] } },
    { \"protocol\": \"freedom\", \"tag\": \"direct\" }"
    rt_json='      { "type": "field", "ip": ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","::1/128","fc00::/7"], "outboundTag": "direct" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "hop" }'
  else
    ob_json='    { "protocol": "freedom", "tag": "direct" }'
    rt_json='      { "type": "field", "ip": ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","::1/128","fc00::/7"], "outboundTag": "direct" }'
  fi

  # 落地出站追加在最后：不改变 outbounds[0]，默认出口仍然是 direct / hop
  # 落地路由插在最前：确保比 hop 的兜底规则先匹配，跳板开着也不污染落地节点
  if [[ $use_landing -eq 1 && ( $x_land -eq 1 || $r_land -eq 1 ) ]]; then
    local lp la lport
    lp="$(landing_proto)"; la="$(node_hop_addr)"; lport="$(node_hop_port)"
    ob_json="${ob_json},
    { \"protocol\": \"${lp}\", \"tag\": \"landing\", \"settings\": { \"servers\": [{ \"address\": \"${la}\", \"port\": ${lport} }] } }"
    rt_json="      { \"type\": \"field\", \"user\": [\"landing\"], \"outboundTag\": \"landing\" },
${rt_json}"
  fi

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
      "settings": { "clients": ${xclients}, "decryption": "none" },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": { "path": "${px}", "mode": "auto" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"], "routeOnly": true }
    }${reality_in}
  ],
  "outbounds": [
${ob_json}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
${rt_json}
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
Description=argox Xray (XHTTP)
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
  local proto; proto="$(node_tunnel_proto)"
  cat > "/etc/systemd/system/${SVC_TUN}.service" <<EOF
[Unit]
Description=argox Cloudflare Tunnel
After=network-online.target ${SVC_XRAY}.service
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=${TOKEN_FILE}
ExecStart=${CFD_BIN} tunnel --no-autoupdate --protocol ${proto} --loglevel info run
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SVC_TUN" >/dev/null 2>&1
}

# ==============================================================================
#  cloudflared 出站诊断
#
#  出站走 7844：QUIC 用 UDP，http2 用 TCP。VPS 出站被限制时进程照样 active，
#  只是永远注册不上，日志里只有 dial 失败——这一步专门把这种情况单独指出来。
# ==============================================================================

# 边缘域名能否解析（输出可解析的域名，空=全失败）
edge_dns() {
  local h got=""
  for h in region1.v2.argotunnel.com region2.v2.argotunnel.com; do
    if has python3; then
      python3 -c 'import socket,sys; socket.setdefaulttimeout(4); socket.gethostbyname(sys.argv[1])' "$h" >/dev/null 2>&1 \
        && got="${got}${got:+ }${h}"
    elif has getent; then
      getent ahosts "$h" >/dev/null 2>&1 && got="${got}${got:+ }${h}"
    fi
  done
  printf '%s' "$got"
}

# 出站 TCP 7844（http2 回退路径）：0=通 1=不通 2=无法测试
edge_tcp7844() {
  local h
  has timeout || return 2
  for h in region1.v2.argotunnel.com region2.v2.argotunnel.com; do
    timeout 6 bash -c "exec 3<>/dev/tcp/${h}/7844" >/dev/null 2>&1 && return 0
  done
  return 1
}

# 日志统计起点：本次隧道进程的启动时刻（避免稳定运行后窗口内没有注册日志）
tunnel_since() {
  local ts dt
  ts="$(systemctl show -p ActiveEnterTimestamp --value "$SVC_TUN" 2>/dev/null \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  # 形如 "Fri 2026-11-06 21:05:03 CST"：只取日期与时间，时区交给 journalctl 按本机时区解释
  dt="$(printf '%s' "$ts" | awk 'NF>=3 {print $2, $3}')"
  if [[ "$dt" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    printf '%s' "$dt"; return
  fi
  printf '%s' '-30min'
}

# 已注册的连接条数（本次进程启动以来）
tunnel_registered() {
  local n
  n="$(journalctl -u "$SVC_TUN" --since "$(tunnel_since)" --no-pager 2>/dev/null \
        | grep -c 'Registered tunnel connection' || true)"
  printf '%s' "${n:-0}"
}

# cloudflared 实际使用的协议（quic / http2）
tunnel_live_proto() {
  journalctl -u "$SVC_TUN" --since "$(tunnel_since)" --no-pager 2>/dev/null \
    | grep 'Registered tunnel connection' | tail -1 \
    | sed -n 's/.*protocol=\([a-zA-Z0-9]*\).*/\1/p'
}

# 直接打一次隧道域名，判断链路是否真的可用
# 输出：ok:<code> | origin:<code> | noroute | fail | nohost
tunnel_probe() {
  local host px code
  host="$(node_get tunnel_host 2>/dev/null || true)"
  [[ -z "$host" ]] && { printf 'nohost'; return; }
  px="$(node_get path_xhttp 2>/dev/null || true)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
          "https://${host}${px}" 2>/dev/null || echo 000)"
  case "$code" in
    000)       printf 'fail' ;;
    530|1033)  printf 'noroute' ;;
    502|503)   printf "origin:${code}" ;;
    *)         printf "ok:${code}" ;;
  esac
}

# 等隧道注册（重启后日志落盘有延迟，轮询最多 $1 秒，默认 20）
tunnel_await() {
  local max="${1:-20}" i=0 n
  while (( i < max )); do
    n="$(tunnel_registered)"
    [[ "${n:-0}" -gt 0 ]] && { printf '%s' "$n"; return 0; }
    sleep 2
    i=$((i + 2))
  done
  printf '%s' "$(tunnel_registered)"
  return 1
}

# 未注册时的排查提示（安装和诊断共用）
tunnel_hints() {
  local tcp; edge_tcp7844; tcp=$?
  if [[ "$tcp" -eq 1 ]]; then
    err "出站 TCP 7844 也不通 → 云厂商安全组 / 出站防火墙拦了 cloudflared"
    info "Cloudflare 要求 VPS 能出站访问 7844（UDP 与 TCP）"
    info "Oracle 云检查安全列表出站规则，或 iptables -L OUTPUT"
  else
    info "TCP 7844 通但没注册成功，两种可能："
    info "  a) UDP 7844 被拦（QUIC 出不去）→ bash ${0##*/} diag http2"
    info "  b) Token 不对 / 隧道已在面板删除 → 菜单 11 → 1) 重新粘贴 Token"
  fi
  info "看日志：journalctl -u ${SVC_TUN} -n 60"
}

write_sub_server() {
  mkdir -p "$SUBPUB"
  cat > "$PYSRV" <<'PYEOF'
#!/usr/bin/env python3
"""argox 订阅服务：只读、只认白名单文件、不列目录。
v2.7.0 起订阅不走隧道，监听 0.0.0.0 供客户端直连（内容里只有节点参数，
无 TLS 私钥；访问靠 32 位 hex 令牌，不列目录、不认子路径穿越）。
v2.8.0 起同一个令牌按 User-Agent 分流三种格式：
  <token>        base64（通用，v2rayN / Shadowrocket / 大部分客户端）
  <token>.yaml   Clash Meta / mihomo（Clash Verge / FlClash / Stash）
  <token>.json   sing-box（只含直连协议，xhttp 节点官方内核无法表达）
"""
import http.server
import os
import sys
import urllib.parse

PORT = int(sys.argv[1])
ROOT = os.path.abspath(sys.argv[2])

UA_SINGBOX = ("sing-box", "sfa/", "sfi/", "sfm/", "sft/", "karing")
UA_CLASH = ("clash", "mihomo", "stash", "flclash", "meta/", "clash-verge", "clashx")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def guess_type(self, path):
        p = path.lower()
        if p.endswith((".yaml", ".yml")):
            return "text/yaml; charset=utf-8"
        if p.endswith(".json"):
            return "application/json; charset=utf-8"
        return "text/plain; charset=utf-8"

    def list_directory(self, path):
        self.send_error(404)
        return None

    def do_GET(self):
        # 令牌裸路径按 UA 分流到 .yaml / .json；显式带后缀则原样返回
        raw = urllib.parse.unquote(self.path.split("?", 1)[0])
        name = raw.strip("/")
        if name and "/" not in name and not name.endswith((".yaml", ".json")):
            ua = (self.headers.get("User-Agent") or "").lower()
            ext = None
            if any(k in ua for k in UA_SINGBOX):
                ext = ".json"
            elif any(k in ua for k in UA_CLASH):
                ext = ".yaml"
            if ext and os.path.isfile(os.path.join(ROOT, name + ext)):
                self.path = "/" + urllib.parse.quote(name + ext)
        return super().do_GET()

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
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
ExecStart=/usr/bin/python3 ${PYSRV} $(sub_port) ${SUBPUB}
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

# 出口跳板：把 VPS 的出站交给本机代理（如住宅 IP 客户端）
#   off = 关闭，流量从 VPS 原生 IP 出去
#   all = 全部流量走跳板（目标站只看到代理的出口 IP）
HOP_MODE_DEFAULT="off"
HOP_PROTO_DEFAULT="socks"    # socks（SOCKS5）| http（HTTP CONNECT）
HOP_ADDR_DEFAULT="127.0.0.1"
HOP_PORT_DEFAULT=1080

# cloudflared 传输协议：auto 让它先试 QUIC(UDP 7844)，不通自动退 http2(TCP 7844)
TUNNEL_PROTO_DEFAULT="auto"

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

# 解析任意格式列表，输出 "ip<TAB>备注"
#
# 支持的输入形态（实测都要能吃下，否则用户从 Excel / cfst 复制过来会 0 条）：
#   1. 纯 IP                    104.16.132.229
#   2. IP#备注                  104.16.1.1#移动
#   3. IP:443 / IP:443#备注
#   4. 逗号 CSV（cfst 原样）    104.17.154.227,4,4,0,186.54,5.89,SJC
#   5. Tab 分隔（Excel 复制）   104.17.154.227<TAB>4<TAB>…<TAB>SJC
#   6. 空格分隔                 104.16.1.1 移动 12ms 3.2mb/s
#
# 关键点：Tab 必须先归一成逗号再取第一列。旧实现先把整行空白全删掉，
# 结果 "104.17.154.227\t4\t4…" 会粘成 "104.17.154.227440186.54…"，一条都认不出。
parse_ipfile() {
  local line raw port ip note rest
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" == \#* ]] && continue

    # Tab 归一成逗号，让 Tab 分隔与 CSV 走同一条路径
    line="${line//$'\t'/,}"
    while [[ "$line" == *",,"* ]]; do line="${line//,,/,}"; done

    note=""
    [[ "$line" == *"#"* ]] && note="${line#*#}"

    # cfst / Excel 表格（≥7 列）最后一列是地区码，拿来当备注，节点名更好认
    if [[ -z "$note" && "$line" == *,*,*,*,*,*,* ]]; then
      note="${line##*,}"
      note="${note//[[:space:]]/}"
    fi

    # 空格分隔的社区列表（"104.16.1.1 移动 12ms 3.2mb/s"）：余下部分当备注。
    # 只在没有逗号/Tab 时启用，避免把 CSV 的数字列误当备注（那会让 sort_cand 丢条目）
    if [[ -z "$note" && "$line" != *","* ]]; then
      rest="${line#*[[:space:]]}"
      [[ "$rest" != "$line" ]] && note="$rest"
    fi

    raw="${line%%#*}"
    raw="${raw%%,*}"                                   # 取第一列
    [[ "$raw" == *[[:space:]]* ]] && raw="${raw%%[[:space:]]*}"  # 空格分隔只取首 token
    raw="${raw//[[:space:]]/}"

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
  cat <<'EOF'

  直接粘贴，空行结束。以下三种都认：
    · 纯 IP 一行一个
    · 从 Excel / WPS 复制的整张表格（含表头，Tab 分隔，地区码会保留成节点后缀）
    · IP#移动 这种带备注的
EOF
  printf '  > '
  local tmpd; tmpd="$(mktemp -d)"
  local line
  : > "${tmpd}/in"
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && break
    printf '%s\n' "$line" >> "${tmpd}/in"
  done
  local keptf="${tmpd}/kept"
  parse_ipfile < "${tmpd}/in" | awk -F'\t' '!seen[$1]++' > "$keptf"
  local n; n="$(wc -l < "$keptf" | tr -d ' ')"
  if [[ "${n:-0}" -eq 0 ]]; then
    rm -rf "$tmpd"
    warn "没有解析到有效 IP，保留原有列表"
    return 1
  fi

  cut -f1 "$keptf" > "$IPSF"
  : > "$IPMETA"
  local ip1 note1
  while IFS=$'\t' read -r ip1 note1; do
    printf '%s\t%s\n' "$ip1" "$(note_isp_label "$note1")" >> "$IPMETA"
  done < "$keptf"
  rm -rf "$tmpd"

  ok "已保存 ${n} 个 IP（未校验，保持粘贴顺序）"
  awk -F'\t' '{printf "    %-16s %s\n", $1, $2}' "$IPMETA"

  # 存 IP 和「用不用 IP」是两件事：模式仍是 domain 时订阅一个 IP 都不会展开。
  # 手动粘贴这条路径以前不问，导致「贴完发现订阅没变」。
  printf '\n'
  if [[ "$(node_mode)" == "ip" ]]; then
    gen_sub >/dev/null 2>&1 || true
    ok "订阅已重建（当前已是 ip 模式）"
  else
    read -rp "  切换为 ip 模式并重建订阅？(Y/n) " yn2
    if [[ "${yn2,,}" != "n" ]]; then
      node_set node_mode ip
      gen_sub >/dev/null 2>&1 || true
      ok "已切换为 ip 模式，订阅已重建"
      info "客户端里删掉旧订阅重新导入即可（旧的域名节点会消失）"
    else
      info "保持 domain 模式，IP 列表已存好，随时切：$(cmd_prefix) mode ip"
    fi
  fi
}

update_ips() {
  require_root
  import_ips || true
  gen_sub >/dev/null 2>&1 || true
}

# 备注文字 → 节点名后缀
#   带运营商关键词 → 移动 / 联通 / 电信 / 多线
#   三字母机场码（cfst 的「地区码」列）→ 原样保留，如 SJC / NRT / HKG
#   其余 → 本机
note_isp_label() {
  case "${1:-}" in
    *移动*) printf '移动' ;;
    *联通*) printf '联通' ;;
    *电信*) printf '电信' ;;
    *多线*) printf '多线' ;;
    [A-Z][A-Z][A-Z]) printf '%s' "${1}" ;;
    *)      printf '本机' ;;
  esac
}

# 去掉 URL 里的密码，屏幕输出与日志一律走这里：ftp://u:pass@h → ftp://u:***@h
mask_url() {
  printf '%s' "$1" | sed -E 's#(://[^:/@]+:)[^@]*@#\1***@#'
}

# 从「你本机测速结果」导入 IP：地址可以是 http(s) / ftp(s) 直链，也可以是本地文件路径
#
# 与 import_ips 的本质区别：
#   import_ips       在 VPS 上探测 + 按源备注里的 ms/MB·s⁻¹ 重排 —— 但那是别人网络的数据
#   import_ips_url   完全不重排，严格保留你上传时的顺序 —— 因为快慢只有你的网络说了算
#
# 这样分工才正确：VPS 只负责「这个 IP 能不能到达本隧道」（anycast 全局一致），
# 「哪个 IP 对你的移动宽带快」由你本机测速决定，脚本不越权猜测。
#
# 地址可以存进 node.json 的 ips_url：Windows 测速 → 传到自己的 FTP / 网站 → 这里填直链，
# 之后 ips 无参就直接从它拉，不用每次贴地址。见 do_ips_url。
import_ips_url() {
  require_root
  local src="${1:-}"
  if [[ -z "$src" ]]; then
    src="$(node_get ips_url 2>/dev/null || true)"
    if [[ -n "$src" ]]; then
      info "使用自动更新地址：$(mask_url "$src")"
    else
      printf '\n  粘贴测速结果地址（http(s) 直链 / ftp(s) / 本机路径），回车确认：\n  > '
      read -r src
    fi
  fi
  src="${src//[[:space:]]/}"
  [[ -z "$src" ]] && { err "地址为空（想固定用一个地址：$(cmd_prefix) ips-url）"; return 1; }

  local tmpd; tmpd="$(mktemp -d)"
  local rawf="${tmpd}/raw" cand="${tmpd}/cand" keptf="${tmpd}/kept"
  : > "$cand"; : > "$keptf"

  if [[ -f "$src" ]]; then
    cp "$src" "$rawf" || { err "读取失败：$src"; rm -rf "$tmpd"; return 1; }
    info "已读取本地文件：${src}"
  elif [[ "$src" =~ ^(https?|ftps?):// ]]; then
    info "拉取：$(mask_url "$src")"
    curl -fsSL --max-time 30 -A "Mozilla/5.0" "$src" -o "$rawf" 2>/dev/null \
      || { err "拉取失败：$(mask_url "$src")"; info "http(s) 要能直链打开纯文本；ftp(s) 检查主机 / 端口 / 账号 / 文件路径"; rm -rf "$tmpd"; return 1; }
  else
    if [[ "$src" == /* || "$src" == ./* || "$src" == ~* ]]; then
      err "文件不存在：${src}"
    else
      err "既不是存在的文件，也不是 http(s) / ftp(s) 地址"
    fi
    rm -rf "$tmpd"; return 1
  fi

  # 解析：兼容 cfst 的 CSV（IP,已发送,已接收,丢包率,平均延迟,下载速度,…）、
  #       纯 IP 一行一个、IP:443、IP#备注 —— 一律只取第一列，保持原顺序
  local dropped=0 ip1 note1
  while IFS=$'\t' read -r ip1 note1; do
    if is_cf_ip "$ip1"; then
      printf '%s\t%s\n' "$ip1" "$note1" >> "$cand"
    else
      dropped=$((dropped+1))
    fi
  done < <(parse_ipfile < "$rawf" | awk -F'\t' '!seen[$1]++')

  local total; total="$(wc -l < "$cand" | tr -d ' ')"
  if [[ "${total:-0}" -eq 0 ]]; then
    err "没解析到 Cloudflare 段 IP（文件格式不认识，或内容全是非 CF 段）"
    rm -rf "$tmpd"; return 1
  fi
  [[ "$dropped" -gt 0 ]] && info "已剔除 ${dropped} 个非 Cloudflare 段 IP"

  # 可选：用 VPS 再验一次「能否到达本隧道」。这一步与你在哪测无关，
  # anycast 全局一致，1033 的 IP 谁来测都用不了，所以值得做但可以跳过。
  local host; host="$(node_get tunnel_host 2>/dev/null || true)"
  local verify=0
  if [[ -n "$host" ]]; then
    printf '\n  用 VPS 再验一次「能否路由到本隧道」？(%s个，约 %s 秒)\n' "$total" "$(( total * 2 ))"
    read -rp "  [y/N，默认跳过，直接信任你的结果] " yn
    [[ "${yn,,}" == "y" ]] && verify=1
  fi

  if [[ $verify -eq 1 ]]; then
    local i=0 ip2 note2 code
    while IFS=$'\t' read -r ip2 note2; do
      i=$((i+1))
      printf '\r  校验 %d/%d  %-16s' "$i" "$total" "$ip2"
      if code="$(ip_alive "$ip2" "$host")"; then
        printf '%s\t%s\n' "$ip2" "$note2" >> "$keptf"
      fi
    done < "$cand"
    printf '\r%*s\r' 56 ''
    if [[ ! -s "$keptf" ]]; then
      err "全部未通过隧道校验（隧道没注册？或用错了域名），保留现有列表"
      rm -rf "$tmpd"; return 1
    fi
  else
    cp "$cand" "$keptf"
  fi

  head -n "$MAX_IPS" "$keptf" > "${tmpd}/final"
  cut -f1 "${tmpd}/final" > "$IPSF"
  : > "$IPMETA"
  local ip3 note3
  while IFS=$'\t' read -r ip3 note3; do
    printf '%s\t%s\n' "$ip3" "$(note_isp_label "$note3")" >> "$IPMETA"
  done < "${tmpd}/final"
  rm -rf "$tmpd"

  local got; got="$(wc -l < "$IPSF" | tr -d ' ')"
  ok "已导入 ${got} 个 IP（严格保持你上传的顺序，未重排）"
  awk -F'\t' '{printf "    %-16s %s\n", $1, $2}' "$IPMETA"

  printf '\n'
  if [[ "$(node_mode)" == "ip" ]]; then
    gen_sub >/dev/null 2>&1 || true
    ok "订阅已重建（当前已是 ip 模式）"
  else
    read -rp "  切换为 ip 模式并重建订阅？(Y/n) " yn2
    if [[ "${yn2,,}" != "n" ]]; then
      node_set node_mode ip
      gen_sub >/dev/null 2>&1 || true
      ok "已切换为 ip 模式，订阅已重建"
      info "客户端里删掉旧订阅重新导入即可（旧的域名节点会消失）"
    else
      info "保持 domain 模式，IP 列表已存好，随时切"
    fi
  fi
  # 一次成功后把地址存下来，之后 ips 无参就直接拉它（闭环的最后一步）
  if [[ "$src" =~ ^(https?|ftps?):// && -z "$(node_get ips_url 2>/dev/null || true)" ]]; then
    printf '\n'
    read -rp "  设为自动更新地址？以后 $(cmd_prefix) ips 直接用它 (Y/n) " ynu
    if [[ "${ynu,,}" != "n" ]]; then
      node_set ips_url "$src" && ok "已保存自动更新地址"
    fi
  fi
  info "回退：$(cmd_prefix) tunnel → 6) 节点地址模式 → domain"
}

# 自动更新地址：把「Windows 测速结果上传到 FTP / 网站」的直链存进 node.json，
# 之后 ips 无参直接从它拉。凭据只落在 node.json（600），不进脚本、不进仓库。
do_ips_url() {
  require_root
  local cur act
  while true; do
    cur="$(node_get ips_url 2>/dev/null || true)"
    printf '\n  %s自动更新地址%s\n' "$C_B" "$C_R"
    if [[ -n "$cur" ]]; then
      printf '  当前：%s\n' "$(mask_url "$cur")"
    else
      printf '  当前：未设置\n'
    fi
    printf '  用途：Windows 上测速 → 把结果传到 FTP / 网站 → 这里填直链，\n'
    printf '        以后 %s ips 无参就直接从它拉，不用再贴地址。\n\n' "$(cmd_prefix)"
    cat <<'EOF'
  1) 设置 / 修改（粘贴 ftp(s) 或 http(s) 直链）
  2) 立即拉取一次（导入 + 重建订阅）
  3) 显示完整地址（含账号密码）
  4) 清除
  0) 返回
EOF
    read -rp "  选择: " act
    case "${act:-}" in
      1)
        printf '\n  粘贴地址，回车确认\n  例：ftp://用户:密码@主机:端口/文件名\n  > '
        local u k; read -r u; u="${u//[[:space:]]/}"
        if [[ -z "$u" ]]; then warn "已取消"; continue; fi
        if [[ ! "$u" =~ ^(https?|ftps?):// ]]; then err "只认 http(s) / ftp(s) 开头的地址"; continue; fi
        info "验证：$(mask_url "$u")"
        if curl -fsSL --max-time 20 -A "Mozilla/5.0" "$u" -o /dev/null 2>/dev/null; then
          ok "地址可读"
        else
          warn "暂时读不到（账号错 / 文件名错 / 还没上传）"
          read -rp "  仍然保存？(y/N) " k
          [[ "${k,,}" != "y" ]] && { info "未保存"; continue; }
        fi
        node_set ips_url "$u" && ok "已保存（只写入 ${NODEF}，权限 600）"
        ;;
      2)
        if [[ -z "$cur" ]]; then warn "还没设置地址"; else import_ips_url "$cur"; fi
        ;;
      3)
        if [[ -n "$cur" ]]; then printf '\n  %s\n\n' "$cur"; else warn "还没设置"; fi
        ;;
      4)
        node_set ips_url "" && ok "已清除"
        ;;
      0|"") return 0 ;;
      *) warn "无效选项" ;;
    esac
  done
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
  2) 编辑 IP 源链接（社区列表，VPS 校验后按运营商+备注排序）
  3) 立即拉取并校验
  4) 手动粘贴 IP
  5) 运营商偏好（换网络时改这里）
  6) 从链接导入（本机测速结果，保序不重排）← 推荐
  7) 自动更新地址（测速结果传 FTP/网站，以后 ips 无参直接拉）
  0) 返回
EOF
    read -rp "  选择: " c
    case "${c:-}" in
      1) if [[ -s "$IPSF" ]]; then
           if [[ -s "$IPMETA" ]]; then awk -F'\t' '{printf "    %-16s %s\n",$1,$2}' "$IPMETA"
           else sed 's/^/    /' "$IPSF"; fi
         else warn "还没有 IP 列表"; fi ;;
      6) import_ips_url ;;
      7) do_ips_url ;;
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

# 直连 VPS 节点（Hy2 / TUIC）：不走 CF，地址固定是 VPS 公网 IP。
# 位置固定：Argo 之后、-RH 之前。拿不到公网 IP 就整体跳过，不生成半坏的链接。
emit_direct_links() {
  local ip; ip="$(vps_ip)"
  if [[ -z "$ip" ]]; then
    warn "拿不到 VPS 公网 IP，跳过 Hy2 / TUIC 节点（VPS 出网不通？或手动填 node.json 的 vps_ip）"
    return 0
  fi
  local sni; sni="$(node_get tunnel_host 2>/dev/null || true)"
  [[ -z "$sni" ]] && sni="$ip"

  if proto_on hy2; then
    local hp pw hop q
    hp="$(hy2_port)"; pw="$(hy2_pass)"; hop="$(hy2_hop)"
    q="sni=${sni}&insecure=1&alpn=h3"
    [[ -n "$hop" ]] && q="${q}&mport=${hop}"
    printf 'hysteria2://%s@%s:%s/?%s#%s\n' "$pw" "$ip" "$hp" "$q" "$NAME_HY2"
  fi

  if proto_on tuic; then
    local tp uuid tpw
    tp="$(tuic_port)"; uuid="$(node_get uuid)"; tpw="$(tuic_pass)"
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=1#%s\n' \
      "$uuid" "$tpw" "$ip" "$tp" "$sni" "$NAME_TUIC"
  fi

  # AnyTLS：TCP 通道，UDP 被限速时唯一能用的
  if proto_on anytls; then
    local ap apw
    ap="$(anytls_port)"; apw="$(anytls_pass)"
    printf 'anytls://%s@%s:%s?security=tls&sni=%s&insecure=1&allowInsecure=1#%s\n' \
      "$apw" "$ip" "$ap" "$sni" "$NAME_ANYTLS"
  fi

  # Reality：Xray 内核，不用证书；纯 Xray 客户端（v2rayN 6.x 等）不支持 AnyTLS 时的替代
  if proto_on reality; then
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
      "$(node_get uuid)" "$ip" "$(reality_port)" "$(reality_sni)" "$(reality_pub)" "$(reality_sid)" "$NAME_REALITY"
  fi
}

# 落地家宽节点（-RH）：地址固定用域名，永远排在订阅最后。
# 顺序固定 h3 → h2 → anytls → reality，与主节点保持一致；IP 模式下也用域名，避免节点数翻倍。
# v2.7.0：ws 分支已移除（WS 入站不存在了），target 里若残留 ws 会被忽略。
emit_landing_links() { # $1=host $2=ex
  local host="$1" ex="$2"
  landing_on || return 0
  local lu; lu="$(landing_uuid)"
  [[ -z "$lu" ]] && return 0
  local t
  for t in h3 h2 anytls reality; do
    landing_wants "$t" || continue
    case "$t" in
      h3) printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h3&type=xhttp&path=%s&host=%s&mode=auto#%s%s\n' \
            "$lu" "$host" "$host" "$ex" "$host" "$NAME_H3" "$NAME_RH" ;;
      h2) printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1&type=xhttp&path=%s&host=%s&mode=auto#%s%s\n' \
            "$lu" "$host" "$host" "$ex" "$host" "$NAME_H2" "$NAME_RH" ;;
      anytls)
        # AnyTLS 落地：走 VPS 公网 IP 的独立端口，直连协议没开就没有这条
        proto_on anytls || continue
        printf 'anytls://%s@%s:%s?security=tls&sni=%s&insecure=1&allowInsecure=1#%s%s\n' \
              "$lu" "$(vps_ip)" "$(anytls_rh_port)" "$(node_get tunnel_host)" "$NAME_ANYTLS" "$NAME_RH" ;;
      reality)
        # Reality 走 VPS 公网 IP，与 Argo 域名无关；协议本身没开就没有这条
        proto_on reality || continue
        printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s%s\n' \
              "$lu" "$(vps_ip)" "$(reality_port)" "$(reality_sni)" "$(reality_pub)" "$(reality_sid)" \
              "$NAME_REALITY" "$NAME_RH" ;;
    esac
  done
}

build_links() {
  local uuid host px
  uuid="$(node_get uuid)"
  host="$(node_get tunnel_host)"
  px="$(node_get path_xhttp)"
  [[ -z "$uuid" || -z "$host" ]] && return 1

  local ex mode
  ex="$(urlenc "$px")"
  mode="$(node_mode)"

  # ⚠ 节点顺序约定（客户端按订阅里的先后显示，不要随意打乱）：
  #    1) Argo 两条：H3 → H2（同一入站，只差 ALPN；UDP 挂时靠 H2 兜底）
  #    2) 直连 UDP：Hy2 → TUIC（直连 VPS，不经 CF）
  #    3) 直连 TCP：AnyTLS → Reality（AnyTLS 默认开＝主力兜底；Reality 默认关，给纯 Xray 客户端）
  #    4) 落地家宽（-RH）全部追加在最后
  # 理由：默认出口的节点排前面，-RH 是特殊用途，放末尾不干扰日常切换。
  # WS 已下线：它与 H2 同为 TCP 443，路径完全重叠，属于下位替代，留着只会干扰选择。

  # ---------- 域名模式：地址写域名，由客户端解析到最近的 CF 节点 ----------
  if [[ "$mode" != "ip" ]]; then
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h3&type=xhttp&path=%s&host=%s&mode=auto#%s\n' \
      "$uuid" "$host" "$host" "$ex" "$host" "$NAME_H3"
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1&type=xhttp&path=%s&host=%s&mode=auto#%s\n' \
      "$uuid" "$host" "$host" "$ex" "$host" "$NAME_H2"
    # 直连 UDP（Hy2 / TUIC）
    emit_direct_links
    # 落地家宽垫底
    emit_landing_links "$host" "$ex"
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
  [[ -n "${IPMETA:-}" && -r "${IPMETA:-}" ]] && \
  while IFS=$'\t' read -r l t; do
    (( idx >= ${#ips[@]} )) && break
    tags[$idx]="${t:-其他}"
    idx=$((idx+1))
  done < "$IPMETA"
  for (( idx=0; idx<${#ips[@]}; idx++ )); do
    [[ -z "${tags[$idx]:-}" ]] && tags[$idx]="其他"
  done

  local i n
  # H3 主力：UDP/QUIC，抗丢包
  for (( i=0; i<${#ips[@]} && i<MAX_H3_NODES; i++ )); do
    n=$((i+1))
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h3&type=xhttp&path=%s&host=%s&mode=auto#%s-%02d-%s\n' \
      "$uuid" "${ips[$i]}" "$host" "$ex" "$host" "$NAME_H3" "$n" "${tags[$i]}"
  done
  # H2 对照：同一批 IP 走 TCP，用于 A/B 判断 H3 是否真的更抗丢包
  for (( i=0; i<${#ips[@]} && i<MAX_H2_NODES; i++ )); do
    n=$((i+1))
    printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&fp=chrome&alpn=h2%%2Chttp%%2F1.1&type=xhttp&path=%s&host=%s&mode=auto#%s-%02d-%s\n' \
      "$uuid" "${ips[$i]}" "$host" "$ex" "$host" "$NAME_H2" "$n" "${tags[$i]}"
  done
  # WS 已下线（与 H2 路径重叠），IP 模式下同样不再展开

  # 直连 UDP（Hy2 / TUIC）：走 VPS 公网 IP，与优选 IP 无关
  emit_direct_links

  # 落地家宽垫底（IP 模式下也用域名，住宅落地是特殊用途，稳定优先）
  emit_landing_links "$host" "$ex"
}

# 生成多格式订阅的转换脚本（幂等覆写）。输入是 build_links 产出的 URI 列表，
# 因此节点顺序/参数只有一个真相源：链接。以后改链接逻辑，两种格式自动跟上。
write_subs_gen() {
  cat > "$SUBGEN" <<'PYEOF'
#!/usr/bin/env python3
"""argox 订阅格式转换：URI 列表 -> Clash Meta YAML + sing-box JSON。

只做格式映射，不判断节点该不该存在（那是 build_links 的事）。
官方 sing-box 没有 XHTTP 传输（xhttp 只在 sing-box-lx 等魔改内核里有），
所以 Argo-H3 / Argo-H2 这类 xhttp 节点无法写进 sing-box JSON，会被跳过。
Clash Meta（mihomo 1.19.6+）原生支持 network: xhttp，八条节点全都能表达。
"""
import json
import os
import sys
import urllib.parse

UA_SKIP = {"xhttp"}


def q(s):
    """YAML 标量：统一双引号，转义反斜杠与双引号。"""
    s = str(s)
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def truthy(v):
    return str(v).lower() in ("1", "true", "yes")


def parse(link):
    u = urllib.parse.urlparse(link)
    qs = urllib.parse.parse_qs(u.query, keep_blank_values=True)

    def g(k, d=None):
        v = qs.get(k)
        return v[0] if v else d

    name = urllib.parse.unquote(u.fragment or "")
    if not name:
        name = "%s:%s" % (u.hostname, u.port)
    return u, g, name


def to_clash(link):
    u, g, name = parse(link)
    scheme = u.scheme.lower()
    host = u.hostname
    port = u.port or 443
    qs = urllib.parse.parse_qs(u.query, keep_blank_values=True)
    get = lambda k, d=None: (qs[k][0] if qs.get(k) else d)
    alpn = [a.strip() for a in urllib.parse.unquote(get("alpn", "")).split(",") if a.strip()]
    sni = get("sni") or get("servername") or get("peer") or host
    fp = get("fp") or get("client-fingerprint") or "chrome"

    if scheme == "vless":
        uuid = urllib.parse.unquote(u.username or "")
        net = get("type") or "tcp"
        security = get("security") or "none"
        p = {"name": name, "type": "vless", "server": host, "port": port,
             "uuid": uuid, "udp": True}
        if security in ("tls", "reality"):
            p["tls"] = True
            p["servername"] = sni
            p["client-fingerprint"] = fp
            if alpn:
                p["alpn"] = alpn
        if get("flow"):
            p["flow"] = get("flow")
        if security == "reality":
            p["reality-opts"] = {"public-key": get("pbk", ""), "short-id": get("sid", "")}
        p["network"] = net
        if net == "xhttp":
            opts = {"path": get("path", "/") or "/", "host": get("host") or host}
            if get("mode"):
                opts["mode"] = get("mode")
            p["xhttp-opts"] = opts
        elif net == "ws":
            p["ws-opts"] = {"path": get("path", "/") or "/",
                            "headers": {"Host": get("host") or host}}
        return p

    if scheme == "hysteria2":
        p = {"name": name, "type": "hysteria2", "server": host, "port": port,
             "password": urllib.parse.unquote(u.username or ""), "udp": True}
        if sni:
            p["sni"] = sni
        if alpn:
            p["alpn"] = alpn
        if truthy(get("insecure", get("allow_insecure", "0"))):
            p["skip-cert-verify"] = True
        if get("obfs"):
            p["obfs"] = get("obfs")
            if get("obfs-password"):
                p["obfs-password"] = get("obfs-password")
        if get("mport"):
            p["ports"] = get("mport")
        return p

    if scheme == "tuic":
        p = {"name": name, "type": "tuic", "server": host, "port": port,
             "uuid": urllib.parse.unquote(u.username or ""),
             "password": urllib.parse.unquote(u.password or ""), "udp": True}
        if sni:
            p["sni"] = sni
        if get("congestion_control"):
            p["congestion-controller"] = get("congestion_control")
        if get("udp_relay_mode"):
            p["udp-relay-mode"] = get("udp_relay_mode")
        if alpn:
            p["alpn"] = alpn
        if truthy(get("allow_insecure", get("insecure", "0"))):
            p["skip-cert-verify"] = True
        return p

    if scheme == "anytls":
        p = {"name": name, "type": "anytls", "server": host, "port": port,
             "password": urllib.parse.unquote(u.username or ""), "udp": True}
        if sni:
            p["sni"] = sni
        if alpn:
            p["alpn"] = alpn
        p["client-fingerprint"] = fp
        if truthy(get("insecure", get("allowInsecure", "0"))):
            p["skip-cert-verify"] = True
        return p

    return None


def to_singbox(link):
    """官方 sing-box 无法表达 xhttp，返回 None 让调用方跳过该节点。"""
    u, g, name = parse(link)
    scheme = u.scheme.lower()
    host = u.hostname
    port = u.port or 443
    qs = urllib.parse.parse_qs(u.query, keep_blank_values=True)
    get = lambda k, d=None: (qs[k][0] if qs.get(k) else d)
    alpn = [a.strip() for a in urllib.parse.unquote(get("alpn", "")).split(",") if a.strip()]
    sni = get("sni") or get("servername") or host

    def tls(alpn_list=None, insecure=True, reality=None):
        t = {"enabled": True, "server_name": sni}
        if alpn_list:
            t["alpn"] = alpn_list
        if insecure:
            t["insecure"] = True
        t["utls"] = {"enabled": True, "fingerprint": get("fp") or "chrome"}
        if reality:
            t["reality"] = reality
        return t

    if scheme == "vless":
        net = get("type") or "tcp"
        if net in UA_SKIP:
            return None
        security = get("security") or "none"
        o = {"type": "vless", "tag": name, "server": host, "server_port": port,
             "uuid": urllib.parse.unquote(u.username or "")}
        if get("flow"):
            o["flow"] = get("flow")
        if security in ("tls", "reality"):
            reality = None
            if security == "reality":
                reality = {"enabled": True, "public_key": get("pbk", ""),
                           "short_id": get("sid", "")}
            o["tls"] = tls(alpn or None, insecure=False, reality=reality)
        if net == "ws":
            o["transport"] = {"type": "ws", "path": get("path", "/") or "/",
                              "headers": {"Host": get("host") or host}}
        return o

    if scheme == "hysteria2":
        o = {"type": "hysteria2", "tag": name, "server": host, "server_port": port,
             "password": urllib.parse.unquote(u.username or "")}
        o["tls"] = tls(alpn or ["h3"], insecure=truthy(get("insecure", "0")))
        if get("obfs"):
            o["obfs"] = {"type": get("obfs"), "password": get("obfs-password", "")}
        if get("mport"):
            # sing-box 的端口段写法是冒号，链接里是短横线；
            # 且 server_port 与 server_ports 互斥，同时出现会被内核判为非法配置
            o.pop("server_port", None)
            o["server_ports"] = [get("mport").replace("-", ":")]
        return o

    if scheme == "tuic":
        o = {"type": "tuic", "tag": name, "server": host, "server_port": port,
             "uuid": urllib.parse.unquote(u.username or ""),
             "password": urllib.parse.unquote(u.password or "")}
        if get("congestion_control"):
            o["congestion_control"] = get("congestion_control")
        if get("udp_relay_mode"):
            o["udp_relay_mode"] = get("udp_relay_mode")
        o["tls"] = tls(alpn or ["h3"], insecure=truthy(get("allow_insecure", "0")))
        return o

    if scheme == "anytls":
        o = {"type": "anytls", "tag": name, "server": host, "server_port": port,
             "password": urllib.parse.unquote(u.username or "")}
        o["tls"] = tls(alpn or ["h2", "http/1.1"],
                       insecure=truthy(get("insecure", get("allowInsecure", "0"))))
        return o

    return None


def yaml_proxy(p, indent="  "):
    out = ["%s- name: %s" % (indent, q(p["name"]))]
    sub = indent + "  "
    for k, v in p.items():
        if k == "name":
            continue
        if isinstance(v, dict):
            out.append("%s%s:" % (sub, k))
            for k2, v2 in v.items():
                out.append("%s  %s: %s" % (sub, k2, q(v2)))
        elif isinstance(v, list):
            out.append("%s%s:" % (sub, k))
            for item in v:
                out.append("%s  - %s" % (sub, q(item)))
        elif isinstance(v, bool):
            out.append("%s%s: %s" % (sub, k, "true" if v else "false"))
        elif isinstance(v, int):
            out.append("%s%s: %d" % (sub, k, v))
        else:
            out.append("%s%s: %s" % (sub, k, q(v)))
    return out


def main():
    if len(sys.argv) < 4:
        sys.exit("usage: subs_gen.py <links.txt> <out.yaml> <out.json>")
    src, out_yaml, out_json = sys.argv[1], sys.argv[2], sys.argv[3]
    links = [l.strip() for l in open(src, encoding="utf-8") if l.strip()]

    clash, sb = [], []
    for line in links:
        try:
            c = to_clash(line)
        except Exception as e:                      # 单条写坏不影响其它节点，但要留痕
            sys.stderr.write("skip clash: %s (%s)\n" % (line.split("#")[-1][:24], e))
            c = None
        if c:
            # Clash 不接受重名节点，重名会让整份配置加载失败
            base, n = c["name"], 1
            while any(p["name"] == c["name"] for p in clash):
                n += 1
                c["name"] = "%s %d" % (base, n)
            clash.append(c)
        try:
            s = to_singbox(line)
        except Exception as e:
            sys.stderr.write("skip singbox: %s (%s)\n" % (line.split("#")[-1][:24], e))
            s = None
        if s:
            base, n = s["tag"], 1
            while any(o["tag"] == s["tag"] for o in sb):
                n += 1
                s["tag"] = "%s %d" % (base, n)
            sb.append(s)

    if not clash:
        sys.exit("no node parsed")

    # ---------- Clash（mihomo / Clash Verge / FlClash / Stash）----------
    names = [p["name"] for p in clash]
    lines = [
        "# argox 订阅（Clash Meta / mihomo）",
        "# 服务端生成，改配置请用 bash argox.sh，不要手改此文件",
        "mixed-port: 7890",
        "allow-lan: false",
        "mode: rule",
        "log-level: info",
        "proxies:",
    ]
    for p in clash:
        lines += yaml_proxy(p)
    lines += ["proxy-groups:",
              "  - name: PROXY",
              "    type: select",
              "    proxies:"]
    lines += ["      - %s" % q(n) for n in names]
    lines += ["rules:",
              "  - GEOIP,CN,DIRECT",
              "  - MATCH,PROXY"]
    with open(out_yaml, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    # ---------- sing-box（官方内核，xhttp 节点会被跳过）----------
    if sb:
        tags = [o["tag"] for o in sb]
        cfg = {
            "log": {"level": "info", "timestamp": True},
            "outbounds": sb + [
                {"type": "selector", "tag": "PROXY",
                 "outbounds": tags + ["direct"], "default": tags[0]},
                {"type": "direct", "tag": "direct"},
            ],
            "route": {"final": "PROXY"},
        }
        with open(out_json, "w", encoding="utf-8", newline="\n") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
            f.write("\n")

    print("clash=%d singbox=%d skipped=%d" % (len(clash), len(sb), len(links) - len(sb)))


if __name__ == "__main__":
    main()
PYEOF
  chmod 755 "$SUBGEN"
}

gen_sub() {
  mkdir -p "$SUBD" "$QDIR"
  local links; links="$(build_links)"
  [[ -z "$links" ]] && { warn "缺少 UUID / 隧道域名，无法生成订阅"; return 1; }

  printf '%s\n' "$links" > "${SUBD}/argox.txt"
  printf '%s\n' "$links" | base64 -w0 > "${SUBD}/argox.b64" 2>/dev/null \
    || printf '%s\n' "$links" | base64 | tr -d '\n' > "${SUBD}/argox.b64"

  # ---------- 多格式订阅：Clash YAML + sing-box JSON ----------
  # 失败不影响 base64 订阅（它是主格式，客户端兼容性最好）
  local subnote=""
  if has python3; then
    write_subs_gen
    if python3 "$SUBGEN" "${SUBD}/argox.txt" "${SUBD}/argox.yaml" "${SUBD}/argox.json" \
         >/dev/null 2>&1; then
      :
    else
      rm -f "${SUBD}/argox.yaml" "${SUBD}/argox.json"
      subnote="（Clash/sing-box 格式生成失败，只有 base64）"
    fi
  else
    subnote="（缺 python3，只有 base64）"
  fi

  # 发布到订阅服务目录：文件名即 URL 路径，随机不可猜
  # 三种格式共用同一个令牌，由订阅服务按 UA 分流
  local stoken; stoken="$(node_get sub_token 2>/dev/null || true)"
  if [[ -n "$stoken" ]]; then
    mkdir -p "$SUBPUB"
    cp "${SUBD}/argox.b64" "${SUBPUB}/${stoken}"
    chmod 644 "${SUBPUB}/${stoken}"
    if [[ -f "${SUBD}/argox.yaml" ]]; then
      cp "${SUBD}/argox.yaml" "${SUBPUB}/${stoken}.yaml"
      chmod 644 "${SUBPUB}/${stoken}.yaml"
    fi
    if [[ -f "${SUBD}/argox.json" ]]; then
      cp "${SUBD}/argox.json" "${SUBPUB}/${stoken}.json"
      chmod 644 "${SUBPUB}/${stoken}.json"
    fi
  fi
  [[ -n "$subnote" ]] && warn "多格式订阅${subnote}"

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

# 打印 Cloudflare 侧需要的路由：v2.7.0 起只有一条
cf_paths() {
  local host="$1"
  printf '\n  Cloudflare → 该隧道 → Public Hostname，只需要一条（Path 留空）：\n\n'
  printf '    %-30s → 127.0.0.1:%s   H3 / H2 主入口\n' "${host:-argo.<主域名>}" "$DEF_PORT_XHTTP"
  printf '\n  订阅不走隧道（直连 %s:%s），CF 里只需保留上面这一条，多余的子域路由可以删掉。\n' \
    "$(vps_ip)" "$(sub_port)"
  local u; u="$(sub_url 2>/dev/null || true)"
  [[ -n "$u" ]] && printf '  订阅地址：%s\n' "$u"
  printf '\n'
}

show_nodes() {
  require_root
  local host token
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

  local n; n="$(printf '%s\n' "$links" | wc -l | tr -d ' ')"
  step "订阅"
  printf '  节点数    : %s\n' "$n"
  printf '  地址模式  : %s\n' "$(node_mode)"
  printf '  隧道域名  : %s\n' "$host"

  local url; url="$(sub_url)"
  printf '  订阅地址  : %s%s%s\n\n' "$C_B" "$url" "$C_R"

  info "包含节点："
  printf '%s\n' "$links" | sed 's/.*#//' | awk '{printf "    %02d  %s\n", NR, $0}'
  printf '\n'

  local code lcode
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || true)"
  lcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://127.0.0.1:$(sub_port)/${token}" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    ok "订阅地址已可访问"
  elif [[ "$lcode" == "200" ]]; then
    warn "订阅服务本机正常，但公网地址不通（HTTP ${code:-超时}）"
    info "云安全组放行 TCP $(sub_port)，并确认公网 IP 正确：$(vps_ip)"
    info "本机自测：curl -s -o /dev/null -w '%%{http_code}\\n' http://127.0.0.1:$(sub_port)/${token}"
  else
    warn "订阅服务没响应（HTTP ${lcode:-超时}）"
    info "查看：systemctl status ${SVC_SUB} / journalctl -u ${SVC_SUB} -n 30"
    info "重建订阅：$(cmd_prefix) sub"
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
  info "同一个地址按客户端自动换格式：Clash/mihomo→YAML，sing-box→JSON，其余→base64"
  info "也可显式指定：${url}.yaml / ${url}.json"
  info "karing：添加配置 → 导入配置链接 → 粘贴上面的订阅地址"
  info "文件备用：${SUBD}/argox.b64（Base64 订阅）"
  info "查看单节点链接：$(cmd_prefix) links"
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
    warn "未配置 Tunnel Token，隧道未启动（菜单 11 可填写）"
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

  local st_x st_t st_s st_b
  if svc_active "$SVC_XRAY"; then st_x="${C_GRN}● 运行中${C_R}"; else st_x="${C_RED}○ 已停止${C_R}"; fi
  if svc_active "$SVC_TUN";  then st_t="${C_GRN}● 运行中${C_R}"; else st_t="${C_RED}○ 已停止${C_R}"; fi
  if svc_active "$SVC_SUB";  then st_s="${C_GRN}● 运行中${C_R}"; else st_s="${C_RED}○ 已停止${C_R}"; fi
  if svc_active "$SVC_SB";   then st_b="${C_GRN}● 运行中${C_R}"; else st_b="${C_DIM}○ 未启用${C_R}"; fi

  printf '  Xray       : %s\n' "$st_x"
  printf '  Tunnel     : %s\n' "$st_t"
  printf '  订阅服务   : %s\n' "$st_s"
  printf '  sing-box   : %s\n' "$st_b"
  printf '  版本       : %s\n' "$VERSION"

  if installed; then
    printf '  UUID       : %s\n' "$(node_get uuid)"
    printf '  隧道域名   : %s\n' "$(node_get tunnel_host)"
    printf '  Token      : %s\n' "$([[ -s "$TOKEN_FILE" ]] && echo '已配置' || echo '未配置')"
    printf '  XHTTP 路径 : %s  (127.0.0.1:%s)\n' "$(node_get path_xhttp)" "$DEF_PORT_XHTTP"
    printf '  优选 IP    : %s 个（%s）\n' "$(wc -l < "$IPSF" 2>/dev/null || echo 0)" "$IPSF"
    local su; su="$(sub_url 2>/dev/null || true)"
    [[ -n "$su" ]] && printf '  订阅地址   : %s\n' "$su"
    if [[ "$(node_hop_mode)" == "all" ]]; then
      printf '  出口跳板   : 全部走 %s:%s (%s)\n' "$(node_hop_addr)" "$(node_hop_port)" "$(node_hop_proto)"
    else
      printf '  出口跳板   : 关闭（VPS 原生出口）\n'
    fi
    if proto_on hy2 || proto_on tuic || proto_on anytls; then
      printf '  直连协议   : %s（公网 %s）\n' "$(proto_label)" "$(vps_ip)"
    else
      printf '  直连协议   : 全部关闭（菜单 14 开启）\n'
    fi
  else
    warn "尚未安装"
  fi

  printf '\n'
  hr
  # 隧道在线状态（CF 侧健康检查）
  if svc_active "$SVC_TUN"; then
    local q live pb
    q="$(tunnel_registered)"; live="$(tunnel_live_proto)"
    if [[ "${q:-0}" -gt 0 ]]; then
      ok "隧道已向 CF 注册 ${q} 条连接（实际协议 ${live:-未知}，配置 $(node_tunnel_proto)）"
      [[ "$live" == "http2" ]] && info "走了 TCP/http2：UDP 7844 出不去，QUIC 未生效"
    else
      pb="$(tunnel_probe)"
      if [[ "$pb" == ok:* ]]; then
        ok "隧道在线（实测 HTTP ${pb#ok:}，日志窗口内暂无注册记录属正常）"
      else
        info "隧道进程在跑，但未确认在线（$(cmd_prefix) diag 可查）"
      fi
    fi
  fi
  hr
}

do_logs() {
  printf '\n  1) Xray 日志\n  2) 隧道日志\n  3) 订阅服务日志\n  4) sing-box 日志\n  5) 实时跟踪 Xray\n  6) 实时跟踪隧道\n  7) 实时跟踪 sing-box\n  0) 返回\n'
  read -rp "  选择: " c
  case "$c" in
    1) journalctl -u "$SVC_XRAY" -n 80 --no-pager ;;
    2) journalctl -u "$SVC_TUN"  -n 80 --no-pager ;;
    3) journalctl -u "$SVC_SUB"  -n 80 --no-pager ;;
    4) journalctl -u "$SVC_SB"   -n 80 --no-pager; [[ -f "${LOGD}/sb.log" ]] && tail -30 "${LOGD}/sb.log" ;;
    5) journalctl -u "$SVC_XRAY" -f ;;
    6) journalctl -u "$SVC_TUN"  -f ;;
    7) journalctl -u "$SVC_SB"   -f ;;
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
  for b in curl unzip openssl tar python3; do has "$b" || need+=("$b"); done
  has jq || need+=("jq")
  if [[ ${#need[@]} -gt 0 ]]; then
    step "安装依赖：${need[*]}"
    pkg_install "${need[@]}" || warn "依赖安装可能失败，继续尝试"
  fi
  has qrencode || pkg_install qrencode >/dev/null 2>&1 || true

  # 端口检测
  step "端口检测"
  if port_in_use "$DEF_PORT_XHTTP" tcp; then die "端口 ${DEF_PORT_XHTTP} 已被占用（Argo 回源端口需要空闲）"; fi
  if port_in_use "$(sub_port)" tcp; then die "端口 $(sub_port) 已被占用（订阅服务端口，可用 SUB_PORT 环境变量预指定）"; fi
  ok "回源端口 ${DEF_PORT_XHTTP} / 订阅端口 $(sub_port) 空闲"

  # ---------- 交互参数 ----------
  step "隧道参数"
  printf '  说明：隧道需在 CF Dashboard 建（Zero Trust → Networks → Tunnels）。\n'
  printf '        现在没有可以先跳过，装完用菜单 11 补填。\n\n'

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
  # path_ws 自 v2.7.0 起已无入站使用，仅保留字段兼容老配置（不再参与节点生成）
  [[ -z "${pw:-}"   ]] && pw="/ws$(rand_hex 6)"

  # 新旧路径不能相同
  [[ "$px" == "$pw" ]] && pw="/$(rand_hex 8)"

  local isp_prev; isp_prev="$(node_get isp_pref 2>/dev/null || true)"
  [[ -z "$isp_prev" ]] && isp_prev="$ISP_PREF_DEFAULT"

  # 订阅令牌：重装时沿用，避免客户端已填的订阅链接失效
  local sub_token; sub_token="$(node_get sub_token 2>/dev/null || true)"
  [[ -z "$sub_token" ]] && sub_token="$(rand_hex 16)"

  # 地址模式：重装时沿用已有设置（ws_host / sub_host 两个子域字段 v2.7.0 起废弃，不再写入）
  local mode_prev
  mode_prev="$(node_get node_mode 2>/dev/null || true)"
  [[ -z "$mode_prev" ]] && mode_prev="$NODE_MODE_DEFAULT"

  # 出口跳板：重装时沿用
  local hop_prev hop_proto_prev hop_addr_prev hop_port_prev
  hop_prev="$(node_hop_mode)"; hop_proto_prev="$(node_hop_proto)"
  hop_addr_prev="$(node_hop_addr)"; hop_port_prev="$(node_hop_port)"

  # 隧道传输协议：重装时沿用
  local tproto_prev; tproto_prev="$(node_tunnel_proto)"

  # v2 扩展字段（直连协议 / 落地 / 证书）：重装时原样保留，
  # 否则以后开了 Hy2 再重装一次就被重置成关闭。
  local ext_json=""
  if [[ -f "$NODEF" ]] && has python3; then
    ext_json="$(python3 - "$NODEF" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
keep = {k: d[k] for k in
        ("install_mode", "proto", "landing", "hy2", "tuic", "reality", "anytls", "sub", "cert")
        if k in d}
if keep:
    print(json.dumps(keep, ensure_ascii=False))
PY
)"
  fi

  cat > "$NODEF" <<EOF
{
  "uuid": "${uuid}",
  "tunnel_host": "${host}",
  "node_mode": "${mode_prev}",
  "hop_mode": "${hop_prev}",
  "hop_proto": "${hop_proto_prev}",
  "hop_addr": "${hop_addr_prev}",
  "hop_port": "${hop_port_prev}",
  "tunnel_proto": "${tproto_prev}",
  "path_xhttp": "${px}",
  "path_ws": "${pw}",
  "isp_pref": "${isp_prev}",
  "sub_token": "${sub_token}",
  "install_mode": "A",
  "proto": { "argo": true, "hy2": true, "tuic": true, "reality": false, "anytls": true },
  "landing": { "enabled": false, "uuid": "", "target": ["h3", "anytls"] },
  "hy2":     { "port": ${DEF_PORT_HY2}, "hop": "${DEF_HOP_RANGE}", "obfs": false, "up": 50, "down": 300 },
  "tuic":    { "port": ${DEF_PORT_TUIC}, "password": "", "cc": "bbr" },
  "reality": { "port": ${DEF_PORT_REALITY}, "sni": "${REALITY_SNI}", "short_id": "", "private_key": "", "public_key": "" },
  "anytls":  { "port": ${DEF_PORT_ANYTLS}, "password": "" },
  "sub":     { "port": ${DEF_PORT_SUB} },
  "cert":    { "sni": "${host}", "path": "${BASE}/cert" },
  "installed_at": "$(date -Iseconds)",
  "version": "${VERSION}"
}
EOF

  # 把重装前已有的扩展字段合回去（保持值不变）
  if [[ -n "$ext_json" ]] && has python3; then
    python3 - "$NODEF" "$ext_json" 2>/dev/null <<'PY'
import json, sys
p = sys.argv[1]
ext = json.loads(sys.argv[2])
with open(p) as f:
    d = json.load(f)
d.update(ext)
with open(p, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
PY
  fi
  chmod 600 "$NODEF"

  ok "UUID: ${uuid}"
  ok "XHTTP 路径: ${px}"
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
    ok "隧道服务已注册：${SVC_TUN}.service（协议 ${tproto_prev}）"
  else
    warn "未提供 Token，隧道服务暂不创建"
  fi

  write_xray_service
  ok "Xray 服务已注册：${SVC_XRAY}.service"

  # 订阅服务（仅监听 127.0.0.1）
  write_sub_server
  write_sub_service
  ok "订阅服务已注册：${SVC_SUB}.service（0.0.0.0:$(sub_port)，客户端直连）"

  # ---------- 直连协议（Hy2 / TUIC / AnyTLS）----------
  if proto_on hy2 || proto_on tuic || proto_on anytls; then
    step "直连协议（$(proto_label)）"
    if proto_on hy2 && port_in_use "$(hy2_port)" udp; then
      warn "UDP $(hy2_port) 已被占用，Hy2 可能起不来（菜单 14 改端口）"
    fi
    if proto_on tuic && port_in_use "$(tuic_port)" udp; then
      warn "UDP $(tuic_port) 已被占用，TUIC 可能起不来"
    fi
    if proto_on anytls && port_in_use "$(anytls_port)" tcp; then
      warn "TCP $(anytls_port) 已被占用，AnyTLS 可能起不来"
    fi
    if install_singbox && cert_gen && sb_sync; then
      ok "直连协议已就绪：$(proto_label)"
    else
      warn "直连协议未就绪，稍后执行：$(cmd_prefix) direct on all"
    fi
  fi

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
    # ---------- 出站预检（cloudflared 需要能出站访问 7844） ----------
    step "出站预检"
    if [[ -n "$(edge_dns)" ]]; then
      ok "边缘域名可解析"
    else
      warn "解析不了 region1/region2.v2.argotunnel.com，本机 DNS 可能有问题"
    fi
    local tcp_st; edge_tcp7844; tcp_st=$?
    case "$tcp_st" in
      0) ok "出站 TCP 7844 可达" ;;
      1) warn "出站 TCP 7844 不可达 —— http2 回退路径被封，隧道很可能起不来" ;;
      *) : ;;
    esac

    systemctl restart "$SVC_TUN"
    sleep 2
    if svc_active "$SVC_TUN"; then
      ok "隧道进程运行中"
      local nlive nreg pb
      nreg="$(tunnel_await 20)"; nlive="$(tunnel_live_proto)"; pb="$(tunnel_probe)"
      if [[ "${nreg:-0}" -gt 0 ]]; then
        ok "隧道已注册 ${nreg} 条到 Cloudflare（实际协议 ${nlive:-未知}）"
        [[ "$nlive" == "http2" ]] && warn "实际走 TCP/http2：UDP 7844 出不去，QUIC 用不上（功能正常，抗丢包差一档）"
      elif [[ "$pb" == ok:* ]]; then
        warn "日志暂无注册记录，但链路实测可用（HTTP ${pb#ok:}），继续即可"
      else
        warn "隧道尚未注册成功"
        tunnel_hints
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
      info "已有 $(wc -l < "$IPSF") 个 IP，跳过（菜单 12 可更新）"
    else
      read -rp "  现在导入优选 IP 并校验？约需 1-3 分钟（Y/n）: " yn2
      if [[ "${yn2,,}" != "n" ]]; then
        import_ips || printf '%s\n' "$DEFAULT_IPS" > "$IPSF"
      else
        printf '%s\n' "$DEFAULT_IPS" > "$IPSF"
        info "已写入默认 IP 列表（菜单 12 可重新导入）"
      fi
    fi
  else
    step "节点地址"
    ok "使用域名直连（$host），跳过优选 IP"
    info "如需改用优选 IP：菜单 11 → 6) 切换地址模式"
  fi

  # ---------- 收尾 ----------
  gen_sub >/dev/null 2>&1 || true
  install_cmd || true

  printf '\n'
  hr
  printf '%s安装完成%s\n' "$C_GRN$C_B" "$C_R"
  hr
  printf '  UUID        : %s\n' "$uuid"
  printf '  隧道域名    : %s\n' "${host:-（未填写）}"
  printf '  订阅地址    : %s\n' "$(sub_url 2>/dev/null || echo 未配置)"
  printf '  地址模式    : %s\n' "$mode_prev"
  printf '  Token       : %s\n' "$([[ -s "$TOKEN_FILE" ]] && echo 已配置 || echo 未配置)"
  printf '  XHTTP 路径  : %s\n' "$px"
  printf '  配置目录    : %s\n' "$BASE"
  printf '  Token 文件  : %s（600）\n' "$TOKEN_FILE"
  if [[ -x "${ARGOX_BIN:-$CMDBIN}" ]]; then
    printf '  管理命令    : %sargox%s（直接敲，或 argox check / argox port）\n' "$C_B" "$C_R"
  else
    printf '  管理命令    : bash %s\n' "$SELF_PATH"
  fi
  hr

  if [[ -z "$host" ]]; then
    warn "还需在 CF Dashboard 配置 Public Hostname，然后回到菜单 11 填域名"
  fi

  # 要放行的端口一次列全（云安全组只能手动配）
  port_firewall_hint

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
  printf '  4) 开机自启（Xray / 隧道 / 订阅 / sing-box）\n'
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
      # 原来叫「重启策略」，但 service 文件里本来就写了 Restart=always，
      # 这一步实际只是 enable（开机拉起）。改名并补上订阅 / sing-box 两个服务。
      local s cnt=0
      for s in "$SVC_XRAY" "$SVC_TUN" "$SVC_SUB" "$SVC_SB"; do
        svc_exists "$s" || { info "${s} 未创建，跳过"; continue; }
        if systemctl enable "$s" >/dev/null 2>&1; then
          ok "${s} 已设为开机自启"; cnt=$((cnt+1))
        else
          err "${s} 设置开机自启失败"
        fi
      done
      [[ $cnt -gt 0 ]] && info "崩溃自动拉起由 service 内的 Restart=always 负责，无需额外设置"
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

# 备份功能已移除（v2.8.0）：install 重装本身无损（uuid / sub_token / 端口 /
# proto / landing / Reality 密钥 / 优选 IP 全部通过 ext_json 合并保留），
# upgrade 也会把 node.json 存成 node.json.<时间戳>.bak，所以不再提供手动备份入口。

do_uninstall() {
  require_root
  installed || { warn "看起来没有安装"; }
  printf '\n  %s将会删除：%s\n' "$C_RED" "$C_R"
  printf '  · systemd 服务 argox-xray / argox-tunnel / argox-sub / argox-sb\n'
  printf '  · 二进制 /usr/local/bin/argox-xray、argox-sb\n'
  printf '  · 配置目录 /opt/argox（含 UUID/Token/日志/订阅/自签证书）\n'
  printf '  · nftables 表 inet argox_hop（Hy2 端口跳跃规则）\n'
  printf '  · /etc/argox/token.env\n'
  printf '  · /usr/local/bin/argox（命令入口）\n'
  printf '  · /etc/sysctl.d/99-argox.conf\n\n'
  printf '  %s不会动的：%s1panel、已有 xray.service、443 端口、cdnx 相关文件\n\n' "$C_GRN" "$C_R"
  local yn; read -rp "  确认卸载？(输入 yes 继续): " yn
  [[ "$yn" != "yes" ]] && { info "已取消"; return 0; }

  step "卸载"
  systemctl stop "$SVC_SB" 2>/dev/null
  systemctl stop "$SVC_SUB" 2>/dev/null
  systemctl stop "$SVC_TUN" 2>/dev/null
  systemctl stop "$SVC_XRAY" 2>/dev/null
  systemctl disable "$SVC_SB" 2>/dev/null
  systemctl disable "$SVC_SUB" 2>/dev/null
  systemctl disable "$SVC_TUN" 2>/dev/null
  systemctl disable "$SVC_XRAY" 2>/dev/null
  rm -f "/etc/systemd/system/${SVC_XRAY}.service" "/etc/systemd/system/${SVC_TUN}.service" \
        "/etc/systemd/system/${SVC_SUB}.service" "/etc/systemd/system/${SVC_SB}.service"
  systemctl daemon-reload

  has nft && nft delete table inet argox_hop 2>/dev/null || true

  rm -f "$XRAY_BIN"
  rm -f "$SB_BIN"
  rm -rf "$BASE"
  rm -rf "$TOKEN_DIR"
  rm -f /etc/sysctl.d/99-argox.conf
  rm -f /etc/logrotate.d/argox
  remove_cmd
  sysctl --system >/dev/null 2>&1 || true

  ok "已卸载"
  warn "cloudflared 二进制保留在 ${CFD_BIN}（可能被其他服务使用），如需删除：rm -f ${CFD_BIN}"
  warn "云安全组里为 Hy2/TUIC/AnyTLS 放行的 UDP/TCP 端口可以一并收回"
  warn "记得去 CF Dashboard 删除对应 Tunnel，否则会留下孤儿隧道"
}

# ==============================================================================
#  cloudflared 出站诊断（用户可见入口）
# ==============================================================================
do_diag() {
  require_root
  local act="${1:-}"

  # 指定协议：改配置 + 重建单元 + 重启
  case "$act" in
    auto|quic|http2)
      node_set tunnel_proto "$act"
      write_tunnel_service || { err "还没有 Token，无法创建隧道服务"; return 1; }
      systemctl daemon-reload
      systemctl restart "$SVC_TUN" 2>/dev/null
      sleep 2
      ok "隧道协议已设为 ${act}"
      info "等待注册（最多 20 秒）..."
      local nreg
      if nreg="$(tunnel_await 20)"; then
        printf '  注册连接 : %s 条\n' "$nreg"
        printf '  实际协议 : %s\n' "$(tunnel_live_proto)"
        [[ "$(tunnel_live_proto)" == "http2" && "$act" != "http2" ]] \
          && warn "已回退到 http2：UDP 7844 出不去（能用，抗丢包差一档）"
      else
        printf '  注册连接 : 0 条\n'
        err "20 秒内未注册成功"
        tunnel_hints
      fi
      return 0
      ;;
    ""|check|status) : ;;
    *) err "用法：diag [auto|quic|http2]"; return 1 ;;
  esac

  step "cloudflared 出站诊断"

  # 1) DNS
  local dns; dns="$(edge_dns)"
  if [[ -n "$dns" ]]; then ok "边缘域名可解析：${dns}"
  else err "解析不了 region1/region2.v2.argotunnel.com（本机 DNS 异常）"; fi

  # 2) 出站 TCP 7844
  local tcp; edge_tcp7844; tcp=$?
  case "$tcp" in
    0) ok "出站 TCP 7844 可达" ;;
    1) err "出站 TCP 7844 不可达（安全组 / 出站防火墙拦了）" ;;
    *) warn "缺 timeout 命令，跳过 TCP 探测（apt install coreutils）" ;;
  esac

  # 3) UDP 7844：只能间接判断
  local live; live="$(tunnel_live_proto)"
  if [[ "$live" == "quic" ]]; then
    ok "QUIC 正常（实际协议 quic，说明 UDP 7844 通）"
  elif [[ "$live" == "http2" ]]; then
    warn "实际协议 http2 → UDP 7844 出不去，已回退 TCP（能用，但抗丢包差一档）"
  fi

  # 4) 服务与注册
  if [[ ! -s "$TOKEN_FILE" ]]; then warn "还没有 Token，隧道未创建"; return 0; fi
  if svc_active "$SVC_TUN"; then ok "隧道进程运行中"; else err "隧道进程未运行：systemctl status ${SVC_TUN}"; fi

  local n cfg pb; n="$(tunnel_registered)"; cfg="$(node_tunnel_proto)"; pb="$(tunnel_probe)"
  if [[ "${n:-0}" -gt 0 ]]; then
    ok "已注册 ${n} 条连接（实际 ${live:-未知}，配置 ${cfg}）"
  else
    case "$pb" in
      ok:*)
        warn "日志窗口内暂无注册记录，但链路实测可用（HTTP ${pb#ok:}）—— 刚重启或日志轮转，可忽略"
        ;;
      origin:*)
        err "隧道已连上 CF，但回源失败（HTTP ${pb#origin:}）"
        info "检查 127.0.0.1:${DEF_PORT_XHTTP} 是否在听：systemctl status ${SVC_XRAY}"
        ;;
      nohost)
        warn "还没填隧道域名，无法实测链路（菜单 11 → 2）"
        ;;
      fail|noroute|*)
        err "没有任何注册记录：进程在跑，但连不上 CF"
        case "$pb" in
          noroute) info "实测返回 530/1033：隧道在线，但 Public Hostname 没指向本隧道" ;;
          fail)    info "实测连不上：本机 DNS 解析不到隧道域名，或 CF 边缘不可达" ;;
        esac
        tunnel_hints
        ;;
    esac
  fi

  printf '\n  切换协议：bash %s diag auto|quic|http2\n\n' "${0##*/}"
}

# ==============================================================================
#  自检 check（全只读，不修改任何东西）
#
#  检查项来自实际踩过的坑：
#   · path 带前导空格 → 全部节点不通（v1.1.x 事故）
#   · WS 链接 host 写成主域名 → WS 永远不通
#   · 订阅文件名与令牌不一致 → 404
#   · 服务 active 但端口没起 → 客户端全挂
# ==============================================================================
CK_FAIL=0
CK_WARN=0
CK_QUIET=0
ck_ok()   { [[ $CK_QUIET -eq 1 ]] || printf '  %s✓%s %s\n' "$C_GRN" "$C_R" "$*"; }
ck_warn() { CK_WARN=$((CK_WARN+1)); [[ $CK_QUIET -eq 1 ]] || printf '  %s!%s %s\n' "$C_YEL" "$C_R" "$*"; }
ck_err()  { CK_FAIL=$((CK_FAIL+1)); [[ $CK_QUIET -eq 1 ]] || printf '  %s✗%s %s\n' "$C_RED" "$C_R" "$*"; }

# 端口是否在监听
listen_on() { # $1=port $2=tcp|udp
  local -a f=(-lnt)
  [[ "${2:-tcp}" == "udp" ]] && f=(-lnu)
  ss "${f[@]}" -H "sport = :$1" 2>/dev/null | grep -q .
}

# 域名是否有解析记录
dns_has() { # $1=host
  if has getent; then getent hosts "$1" >/dev/null 2>&1
  elif has host;   then host -W 3 "$1" >/dev/null 2>&1
  else nslookup "$1" >/dev/null 2>&1
  fi
}

check_summary() {
  if [[ $CK_QUIET -eq 1 ]]; then
    [[ $CK_FAIL -eq 0 ]]
    return
  fi
  printf '\n'
  hr
  if [[ $CK_FAIL -eq 0 && $CK_WARN -eq 0 ]]; then
    ok "全部检查通过"
  elif [[ $CK_FAIL -eq 0 ]]; then
    printf '%s!%s %d 项警告，0 项失败\n' "$C_YEL" "$C_R" "$CK_WARN"
  else
    printf '%s✗%s %d 项失败，%d 项警告\n' "$C_RED" "$C_R" "$CK_FAIL" "$CK_WARN"
  fi
  hr
  [[ $CK_FAIL -eq 0 ]]
}

do_check() {
  require_root
  local quiet=0
  [[ "${1:-}" == "-q" ]] && quiet=1

  CK_FAIL=0; CK_WARN=0; CK_QUIET=$quiet
  [[ $quiet -eq 1 ]] || step "argox 自检 v${VERSION}（只读，不改任何东西）"

  if ! installed; then
    ck_err "尚未安装（缺 ${XRAY_BIN} 或 ${CONF}）"
    [[ $quiet -eq 1 ]] || printf '\n'
    check_summary
    return 1
  fi

  local uuid host px
  uuid="$(node_get uuid)"
  host="$(node_get tunnel_host)"
  px="$(node_get path_xhttp)"

  # ---------- 配置 ----------
  [[ $quiet -eq 1 ]] || printf '\n%s[配置]%s\n' "$C_B" "$C_R"

  if has jq; then
    jq empty "$NODEF" 2>/dev/null && ck_ok "node.json 可解析" || ck_err "node.json JSON 语法错误"
  elif has python3; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$NODEF" 2>/dev/null \
      && ck_ok "node.json 可解析" || ck_err "node.json JSON 语法错误"
  else
    ck_warn "缺 jq / python3，跳过 node.json 校验"
  fi

  # 首尾空白污染（最隐蔽的坑：链接看着正常，节点全不通）
  local dirty=""
  if has python3; then
    dirty="$(python3 - "$NODEF" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k, v in d.items():
    if isinstance(v, str) and v != v.strip():
        print('%s="%s"' % (k, v))
PY
)"
  fi
  if [[ -n "$dirty" ]]; then
    ck_err "字段含首尾空白字符（会让节点全部不通）："
    [[ $quiet -eq 1 ]] || printf '%s\n' "$dirty" | sed 's/^/      /'
  else
    ck_ok "字段无空白字符污染"
  fi

  if "$XRAY_BIN" run -test -c "$CONF" >/dev/null 2>&1; then
    ck_ok "config.json 语法通过"
  else
    ck_err "config.json 语法错误："
    [[ $quiet -eq 1 ]] || "$XRAY_BIN" run -test -c "$CONF" 2>&1 | tail -5 | sed 's/^/      /'
  fi

  local perm; perm="$(stat -c '%a' "$NODEF" 2>/dev/null || echo '')"
  [[ "$perm" == "600" ]] && ck_ok "node.json 权限 600" || ck_warn "node.json 权限 ${perm:-未知}（建议 600）"

  # ---------- 服务 ----------
  [[ $quiet -eq 1 ]] || printf '\n%s[服务]%s\n' "$C_B" "$C_R"
  local s
  for s in "$SVC_XRAY" "$SVC_TUN" "$SVC_SUB"; do
    if svc_active "$s"; then ck_ok "${s} 运行中"; else ck_err "${s} 未运行"; fi
  done
  systemctl is-enabled --quiet "$SVC_XRAY" 2>/dev/null \
    && ck_ok "Xray 开机自启已启用" || ck_warn "Xray 未设开机自启"

  # ---------- 端口 ----------
  [[ $quiet -eq 1 ]] || printf '\n%s[端口]%s\n' "$C_B" "$C_R"
  listen_on "$DEF_PORT_XHTTP" tcp \
    && ck_ok "${DEF_PORT_XHTTP}/tcp 在听（XHTTP 回源）" \
    || ck_err "${DEF_PORT_XHTTP}/tcp 没在听 → H3/H2 全部不可用"
  listen_on "$(sub_port)" tcp \
    && ck_ok "$(sub_port)/tcp 在听（订阅服务）" \
    || ck_err "$(sub_port)/tcp 没在听 → 订阅 404"

  # ---------- 订阅 ----------
  [[ $quiet -eq 1 ]] || printf '\n%s[订阅]%s\n' "$C_B" "$C_R"
  local stok; stok="$(node_get sub_token 2>/dev/null || true)"
  if [[ -z "$stok" ]]; then
    ck_err "sub_token 为空，订阅地址无法生成"
  else
    if [[ -f "${SUBPUB}/${stok}" ]]; then
      ck_ok "订阅文件与令牌一致"
    else
      ck_err "订阅文件缺失：${SUBPUB}/${stok}（执行 sub 重建）"
    fi
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      "http://127.0.0.1:$(sub_port)/${stok}" 2>/dev/null)"
    [[ "$code" == "200" ]] && ck_ok "订阅本地自测 HTTP 200" \
      || ck_err "订阅本地自测 HTTP ${code:-超时}（服务没起或文件不在）"

    # v2.8.0 多格式：缺文件只影响对应客户端，不算故障
    local miss=""
    [[ -f "${SUBPUB}/${stok}.yaml" ]] || miss="${miss} yaml"
    [[ -f "${SUBPUB}/${stok}.json" ]] || miss="${miss} json"
    if [[ -z "$miss" ]]; then
      ck_ok "订阅三格式齐备（base64 / yaml / json）"
    else
      ck_warn "缺格式：${miss# }（python3 不可用时属正常，其余客户端不受影响）"
    fi

    # UA 分流是否真的在跑：看响应的 Content-Type 最可靠。
    # 别拿 body 前 N 字节找 "proxies:" —— YAML 头两行注释就能占满采样窗口，
    # 会误报成"订阅服务还在跑旧代码"。
    local yct jct
    yct="$(curl -s -o /dev/null -w '%{content_type}' -A 'clash-verge/2.0' --max-time 5 \
      "http://127.0.0.1:$(sub_port)/${stok}" 2>/dev/null)"
    jct="$(curl -s -o /dev/null -w '%{content_type}' -A 'sing-box 1.12' --max-time 5 \
      "http://127.0.0.1:$(sub_port)/${stok}" 2>/dev/null)"
    if [[ "$yct" == *yaml* && "$jct" == *json* ]]; then
      ck_ok "UA 分流生效（Clash → YAML，sing-box → JSON）"
    elif [[ "$yct" == *yaml* || "$jct" == *json* ]]; then
      ck_warn "UA 分流只生效一半（yaml: ${yct:-空} / json: ${jct:-空}）→ 重启订阅服务"
    else
      ck_warn "UA 分流未生效（yaml: ${yct:-空} / json: ${jct:-空}）→ systemctl restart ${SVC_SUB}"
    fi
  fi

  # ---------- 节点链接 ----------
  [[ $quiet -eq 1 ]] || printf '\n%s[节点链接]%s\n' "$C_B" "$C_R"
  local links; links="$(build_links 2>/dev/null)"
  if [[ -z "$links" ]]; then
    ck_err "生成不出节点链接（缺 UUID 或隧道域名）"
  else
    local nlink; nlink="$(printf '%s\n' "$links" | grep -c .)"
    ck_ok "生成 ${nlink} 条链接（模式 $(node_mode)）"
    # 有 IP 却仍是 domain：这是「导入完订阅没变化」最常见的成因，直接点出来
    if [[ "$(node_mode)" != "ip" && -s "$IPSF" ]]; then
      local nip; nip="$(wc -l < "$IPSF" | tr -d ' ')"
      if [[ "${nip:-0}" -gt 0 ]]; then
        ck_warn "已存 ${nip} 个优选 IP 但模式是 domain（未启用）→ $(cmd_prefix) mode ip"
      fi
    fi
    # 自动更新地址：设过就说清 ips 无参会从哪拉，密码打码
    local iu; iu="$(node_get ips_url 2>/dev/null || true)"
    [[ -n "$iu" ]] && ck_ok "自动更新地址已设置：$(mask_url "$iu")"

    local bad=0 line sni hostarg pth exp_sni exp_host exp_path vip dtype dip
    vip="$(vps_ip)"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue

      # 直连协议（Hy2 / TUIC / AnyTLS）：格式与 vless 不同，单独校验地址
      if [[ "$line" == hysteria2://* || "$line" == tuic://* || "$line" == anytls://* ]]; then
        case "$line" in
          hysteria2://*) dtype="Hy2" ;;
          tuic://*)      dtype="TUIC" ;;
          *)             dtype="AnyTLS" ;;
        esac
        dip="$(printf '%s' "$line" | sed -n 's#^[a-z0-9]*://[^@]*@\([^:/]*\):.*#\1#p')"
        if [[ -n "$vip" && "$dip" == "$vip" ]]; then
          ck_ok "${dtype} 地址正确（${dip}）"
        else
          ck_err "${dtype} 地址 ${dip:-空} ≠ 公网 IP ${vip:-未知}"
          bad=1
        fi
        continue
      fi

      # Reality：直连 TCP，不走域名 / Host / path，只校验地址与伪装 sni
      if [[ "$line" == *"security=reality"* ]]; then
        dip="$(printf '%s' "$line" | sed -n 's#^vless://[^@]*@\([^:/]*\):.*#\1#p')"
        sni="$(printf '%s' "$line" | sed -n 's/.*[?&]sni=\([^&#]*\).*/\1/p')"
        local rsni; rsni="$(reality_sni)"
        if [[ -z "$vip" || "$dip" != "$vip" ]]; then
          ck_err "Reality 地址 ${dip:-空} ≠ 公网 IP ${vip:-未知}"; bad=1
        elif [[ "$sni" != "$rsni" ]]; then
          ck_err "Reality sni 不一致：${sni:-空} ≠ ${rsni}"; bad=1
        else
          ck_ok "Reality 地址正确（${dip}，伪装 ${sni}）"
        fi
        continue
      fi

      sni="$(printf '%s' "$line"     | sed -n 's/.*[?&]sni=\([^&#]*\).*/\1/p')"
      hostarg="$(printf '%s' "$line" | sed -n 's/.*[?&]host=\([^&#]*\).*/\1/p')"
      pth="$(printf '%s' "$line"     | sed -n 's/.*[?&]path=\([^&#]*\).*/\1/p')"
      exp_sni="$host"; exp_host="$host"; exp_path="$(urlenc "$px")"
      [[ "$sni"     == "$exp_sni"  ]] || { ck_err "sni 不一致：${sni} ≠ ${exp_sni}";  bad=1; }
      [[ "$hostarg" == "$exp_host" ]] || { ck_err "Host 不一致：${hostarg} ≠ ${exp_host}"; bad=1; }
      [[ "$pth"     == "$exp_path" ]] || { ck_err "path 不一致：${pth} ≠ ${exp_path}"; bad=1; }
    done <<< "$links"
    [[ $bad -eq 0 ]] && ck_ok "链接参数与服务端一致（sni / Host / path / 直连地址）"

    # 用 here-string 而不是管道：脚本开了 pipefail，grep -q 匹配即退出会让上游
    # 收到 SIGPIPE（141），pipefail 取到非零就把整句判成假——明明匹配上了也报失败。
    if grep -q '#argox-' <<< "$links"; then
      ck_warn "订阅里还有旧命名 argox-*（客户端需重新导入）"
    else
      ck_ok "节点名已是新命名（Argo-*）"
    fi
  fi

  # ---------- DNS ----------
  [[ $quiet -eq 1 ]] || printf '\n%s[DNS]%s\n' "$C_B" "$C_R"
  local h
  for h in "$host"; do
    [[ -z "$h" ]] && continue
    if dns_has "$h"; then ck_ok "${h} 有解析"; else ck_err "${h} 无解析（NXDOMAIN，客户端连不上）"; fi
  done

  # ---------- 隧道 ----------
  [[ $quiet -eq 1 ]] || printf '\n%s[隧道]%s\n' "$C_B" "$C_R"
  if [[ ! -s "$TOKEN_FILE" ]]; then
    ck_warn "未配置 Tunnel Token，隧道未启用"
  else
    local nreg live pb
    nreg="$(tunnel_registered)"; live="$(tunnel_live_proto)"; pb="$(tunnel_probe)"
    if [[ "${nreg:-0}" -gt 0 ]]; then
      ck_ok "已注册 ${nreg} 条连接（实际协议 ${live:-未知}）"
      [[ "$live" == "http2" ]] && ck_warn "回退到 http2：UDP 7844 出不去，H3 抗丢包优势用不上"
    else
      case "$pb" in
        ok:*)     ck_ok "链路实测可用（HTTP ${pb#ok:}），日志窗口内无注册记录属正常" ;;
        origin:*) ck_err "隧道连上 CF 但回源失败（HTTP ${pb#origin:}）→ 检查 127.0.0.1:${DEF_PORT_XHTTP}" ;;
        nohost)   ck_warn "未填隧道域名，无法实测链路" ;;
        *)        ck_err "没有任何注册记录：进程在跑但连不上 CF（运行 diag 看详情）" ;;
      esac
    fi
  fi

  # ---------- 落地 / 跳板 ----------
  local need_proxy=0
  [[ "$(node_hop_mode)" == "all" ]] && need_proxy=1
  landing_on && need_proxy=1
  if [[ $need_proxy -eq 1 ]]; then
    [[ $quiet -eq 1 ]] || printf '\n%s[本地代理]%s\n' "$C_B" "$C_R"
    local ha hp pr
    ha="$(node_hop_addr)"; hp="$(node_hop_port)"
    if timeout 5 bash -c ">/dev/tcp/${ha}/${hp}" 2>/dev/null; then
      pr="$(hop_probe || true)"
      [[ -n "$pr" ]] && ck_ok "代理 ${ha}:${hp} 可用（${pr}）" \
                     || ck_warn "代理端口开着但不通（协议可能选错，试试 http）"
    else
      ck_err "代理 ${ha}:${hp} 连不上 → 跳板 / 落地节点都会失效"
      local dp
      if dp="$(hop_detect_local)"; then
        printf '      %s本机 %s 端口在听，代理可能在这个端口：%s hop（菜单 13 → 3）改一下%s\n' \
          "$C_DIM" "$dp" "$(cmd_prefix)" "$C_R"
      else
        printf '      %s本机常见代理端口都没在听，先确认代理客户端是否启动%s\n' "$C_DIM" "$C_R"
      fi
    fi
  fi

  # 落地一致性：UUID 进了配置、订阅里有对应 -RH 节点
  if landing_on; then
    [[ $quiet -eq 1 ]] || printf '\n%s[住宅落地]%s\n' "$C_B" "$C_R"
    local lu want got has_xray_land=0
    local wt
    for wt in $(landing_targets); do
      case "$wt" in h3|h2|ws|reality) has_xray_land=1 ;; esac
    done
    lu="$(landing_uuid)"
    if [[ $has_xray_land -eq 1 ]]; then
      if [[ -z "$lu" ]]; then
        ck_err "落地已开启但 landing.uuid 为空（重开一次落地）"
      elif grep -q "$lu" "$CONF" 2>/dev/null; then
        ck_ok "落地 UUID 已写入 Xray 配置"
      else
        ck_err "落地已开启但 UUID 不在 config.json（重开一次落地）"
      fi
    fi
    # want 要排除「选了协议但协议没开」的入口，否则会误报不一致
    want=0
    for wt in $(landing_targets); do
      case "$wt" in
        reality) proto_on reality && want=$((want+1)) ;;
        anytls)  proto_on anytls  && want=$((want+1)) ;;
        *)       want=$((want+1)) ;;
      esac
    done
    got="$(build_links 2>/dev/null | grep -c -- '-RH$')"
    if [[ "${want:-0}" == "${got:-0}" ]]; then
      ck_ok "订阅落地节点 ${got} 条，与入口设置一致：$(landing_names)"
    else
      ck_err "订阅落地节点 ${got} 条 ≠ 入口设置 ${want} 条（重新生成订阅）"
    fi
  fi

  # ---------- 直连协议（Hy2 / TUIC）+ 证书 ----------
  if proto_on hy2 || proto_on tuic || proto_on anytls || sb_installed; then
    [[ $quiet -eq 1 ]] || printf '\n%s[直连协议]%s\n' "$C_B" "$C_R"

    if [[ -x "$SB_BIN" ]]; then
      ck_ok "sing-box 已安装（$("$SB_BIN" version 2>/dev/null | head -1 | awk '{print $3}')）"
    else
      ck_err "sing-box 未安装（direct on hy2 会自动装）"
    fi

    if proto_on hy2 || proto_on tuic || proto_on anytls; then
      if svc_active "$SVC_SB"; then
        ck_ok "${SVC_SB} 运行中（$(proto_label_sb)）"
      else
        ck_err "${SVC_SB} 未运行，但协议已开启（journalctl -u ${SVC_SB} 看原因）"
      fi

      if proto_on hy2; then
        if listen_on "$(hy2_port)" udp; then
          ck_ok "UDP $(hy2_port) 在听（Hy2）"
        else
          ck_err "UDP $(hy2_port) 没在听（Hy2 不可用）"
        fi
        local rng; rng="$(hy2_hop)"
        if has nft && nft list table inet argox_hop 2>/dev/null | grep -q "udp dport ${rng}"; then
          ck_ok "端口跳跃规则存在：UDP ${rng} → $(hy2_port)"
        else
          ck_warn "端口跳跃规则缺失（hy2 hop 重新应用；不影响连得上，只影响抗限速）"
        fi
      fi

      if proto_on tuic; then
        if listen_on "$(tuic_port)" udp; then
          ck_ok "UDP $(tuic_port) 在听（TUIC）"
        else
          ck_err "UDP $(tuic_port) 没在听（TUIC 不可用）"
        fi
      fi

      if proto_on anytls; then
        if listen_on "$(anytls_port)" tcp; then
          ck_ok "TCP $(anytls_port) 在听（AnyTLS，UDP 全灭时的出路）"
        else
          ck_err "TCP $(anytls_port) 没在听（AnyTLS 不可用）"
        fi
        # AnyTLS 落地是独立入站，端口不在听就说明 landing_on 之后没重建 sing-box
        if landing_on && landing_wants anytls && [[ -n "$(landing_uuid)" ]]; then
          if listen_on "$(anytls_rh_port)" tcp; then
            ck_ok "TCP $(anytls_rh_port) 在听（AnyTLS-RH 落地）"
          else
            ck_err "TCP $(anytls_rh_port) 没在听（AnyTLS 落地没生效，重开一次落地）"
          fi
        fi
      fi

      local dwant dgot
      dwant=0
      proto_on hy2    && dwant=$((dwant+1))
      proto_on tuic   && dwant=$((dwant+1))
      proto_on anytls && dwant=$((dwant+1))
      # 排除 -RH 落地节点：它们也是 anytls:// 开头，混进来会让数量对不上
      dgot="$(build_links 2>/dev/null | grep -E '^(hysteria2|tuic|anytls)://' | grep -vc -- '-RH$')"
      if [[ "$dwant" == "${dgot:-0}" ]]; then
        ck_ok "订阅直连节点 ${dgot} 条，与开关一致"
      else
        ck_err "订阅直连节点 ${dgot:-0} 条 ≠ 开关 ${dwant} 条（重新生成订阅）"
      fi
    fi

    if [[ -f "${CERTD}/cert.pem" ]]; then
      if openssl x509 -checkend 2592000 -noout -in "${CERTD}/cert.pem" >/dev/null 2>&1; then
        ck_ok "自签证书 30 天内不会过期"
      else
        ck_err "自签证书已过期或 30 天内过期（cert gen --force）"
      fi
    elif proto_on hy2 || proto_on tuic || proto_on anytls; then
      ck_err "协议已开启但证书不存在（cert gen）"
    fi
  fi

  # ---------- Reality（Xray 内核，不依赖 sing-box / 证书）----------
  if proto_on reality; then
    [[ $quiet -eq 1 ]] || printf '\n%s[Reality]%s\n' "$C_B" "$C_R"
    if listen_on "$(reality_port)" tcp; then
      ck_ok "TCP $(reality_port) 在听（Reality，伪装 $(reality_sni)）"
    else
      ck_err "TCP $(reality_port) 没在听（Reality 不可用）"
    fi
    if grep -q '"reality"' "$CONF" 2>/dev/null; then
      ck_ok "Reality 入站已写入 config.json"
    else
      ck_err "config.json 里没有 Reality 入站（重开一次 Reality）"
    fi
    if [[ -n "$(reality_pk)" && -n "$(reality_pub)" && -n "$(reality_sid)" ]]; then
      ck_ok "x25519 密钥对 + shortId 齐备"
    else
      ck_err "Reality 密钥缺失（重开一次 Reality 会自动生成）"
    fi
    # 伪装目标体检：Xray 对证书 TLS 记录有 8192 字节硬编码上限，超了握手直接失败
    # 且不打日志——不主动探测就会表现成「节点突然连不上」而查无实据
    local prc=0
    reality_probe_one "$(reality_sni)" 1 || prc=$?
    if [[ $prc -eq 1 ]]; then
      ck_err "伪装目标 $(reality_sni) 不可用：${PR_NOTE:-握手失败}（reality probe 看候选）"
    elif [[ $prc -eq 2 ]]; then
      ck_warn "伪装目标 $(reality_sni) 有风险：${PR_NOTE}"
    else
      ck_ok "伪装目标 $(reality_sni) 可用（证书 ${PR_REC} 字节，余量 $((REALITY_CERT_LIMIT - PR_REC))）"
    fi
    # 同上：here-string 避免 pipefail 把 SIGPIPE 当成失败。
    # 按 security=reality 判断比按节点名判断更准（改名也不会误报）。
    if grep -q 'security=reality' <<< "$(build_links 2>/dev/null)"; then
      ck_ok "订阅里有 ${NAME_REALITY} 节点"
    else
      ck_err "订阅里缺 ${NAME_REALITY} 节点（重新生成订阅）"
    fi
  fi

  [[ $quiet -eq 1 ]] || printf '\n'
  check_summary
}

# ==============================================================================
#  升级配置（对老版本：补字段 + 对齐单元 + 重建订阅，不动服务）
# ==============================================================================
do_upgrade() {
  require_root
  step "升级配置到 v${VERSION}（不动运行中的服务）"

  [[ -r "$NODEF" ]] || die "还没安装过（缺 ${NODEF}），请先执行 install"

  local bak; bak="${BACKD}/node.json.$(date +%Y%m%d-%H%M%S).bak"
  mkdir -p "$BACKD"
  cp -a "$NODEF" "$bak" && ok "已备份：${bak}"

  local MIG_HY2=0 MIG_RH=0 MIG_WS=0 MIG_HOP=0

  # 补齐新字段：已存在的绝不覆盖
  local added="-"
  if has python3; then
    added="$(python3 - "$NODEF" "$VERSION" "$DEF_PORT_HY2" "$DEF_HOP_RANGE" "$REALITY_SNI" "$DEF_PORT_SUB" 2>/dev/null <<'PY'
import json, sys
p, ver = sys.argv[1], sys.argv[2]
hp, hop = int(sys.argv[3]), sys.argv[4]
rsni = sys.argv[5]
sp = int(sys.argv[6])
with open(p) as f:
    d = json.load(f)
defaults = {
    "install_mode": "A",
    "ips_url": "",
    "proto": {"argo": True, "hy2": True, "tuic": True,
              "reality": False, "anytls": True},
    "landing": {"enabled": False, "uuid": "", "target": ["h3", "anytls"]},
    "hy2":     {"port": hp, "hop": hop, "obfs": False,
                "up": 50, "down": 300},
    "tuic":    {"port": 30001, "password": "", "cc": "bbr"},
    "reality": {"port": 8443, "sni": rsni, "short_id": "",
                "private_key": "", "public_key": ""},
    "anytls":  {"port": 8445, "password": ""},
    "sub":     {"port": sp},
    "cert":    {"sni": d.get("tunnel_host", ""), "path": "/opt/argox/cert"},
}
added = [k for k in defaults if k not in d]
for k in added:
    d[k] = defaults[k]

# reality 子字段补齐：老版本只有 port/sni/short_id，缺密钥对（阶段 4 新增）
r = d.get("reality")
if isinstance(r, dict):
    for k, dv in (("port", 8443), ("sni", rsni),
                  ("short_id", ""), ("private_key", ""), ("public_key", "")):
        if k not in r:
            r[k] = dv
            added.append("reality." + k)
    d["reality"] = r

# 旧默认段 20000-30000 与 RustDesk(21115-21119) / 其他服务冲突，自动迁移到新默认段。
# 只在「port 与 hop 都还是旧默认值」时动手，用户自己改过的一律不碰。
mig = "-"
h = d.get("hy2") or {}
if str(h.get("port")) == "20000" and str(h.get("hop")) == "20000-30000":
    h["port"] = hp
    h["hop"] = hop
    d["hy2"] = h
    mig = "%s|%s" % (hp, hop)

# 旧默认伪装目标迁移。条件收紧到「从未启用过 Reality」（无密钥、无 shortId）：
# 已经生成过密钥说明用过，改 SNI 会让客户端静默断连，一律不动只提示。
mig_sni = "-"
rv = d.get("reality") or {}
if str(rv.get("sni")) == "www.microsoft.com" and str(rv.get("port")) == "8443" \
        and not rv.get("private_key") and not rv.get("short_id"):
    rv["sni"] = rsni
    d["reality"] = rv
    mig_sni = rsni

# 落地默认入口迁移：纯默认态 ["h3","h2"] → ["h3","anytls"]。
# H2 与 H3 同走 CF，落地版重复度高；AnyTLS 是 TCP 兜底，更值得有家宽出口。
# 只认精确的默认数组，用户自己勾过的一律不动。
mig_land = "-"
ld = d.get("landing") or {}
if isinstance(ld.get("target"), list) and ld["target"] == ["h3", "h2"]:
    ld["target"] = ["h3", "anytls"]
    d["landing"] = ld
    mig_land = "h3 anytls"

d["version"] = ver
with open(p, "w") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print(("%s" % (",".join(added) if added else "-")) + ";" + mig + ";" + mig_sni + ";" + mig_land)
PY
)"
    local added_s="${added%%;*}" rest_s="${added#*;}"
    local mig="${rest_s%%;*}" rest2="${rest_s#*;}"
    local mig_sni="${rest2%%;*}" mig_land="${rest2#*;}"
    added="$added_s"
    if [[ "$added" == "-" ]]; then ok "字段已是最新，无需补齐"
    else ok "已补齐字段：${added}"; fi
    if [[ "$mig" != "-" ]]; then
      local m_port="${mig%%|*}" m_hop="${mig#*|}"
      ok "Hy2 已迁移：跳跃段 20000-30000 → ${m_hop}，监听口 20000 → ${m_port}"
      MIG_HY2=1
    elif [[ "$(hy2_hop)" == "20000-30000" ]]; then
      # 用户自己改过 port，只把段留着 → 不擅自改，给提示
      warn "Hy2 跳跃段仍是 20000-30000，可能和 RustDesk(21115-21119) 等端口冲突"
      info "要改运行：$(cmd_prefix) hy2 hop 23000-27000（监听口会自动跟到段首）"
    fi
    if [[ "$mig_land" != "-" ]]; then
      ok "落地默认入口已迁移：h3,h2 → ${mig_land}（H2 与 H3 同走 CF，重复；AnyTLS 是 TCP 兜底）"
      if landing_on; then
        info "落地已开启，正在应用新入口（会重启 Xray / sing-box）"
        landing_set_target "h3" "anytls" || warn "应用失败，手动跑：$(cmd_prefix) landing target h3,anytls"
      fi
    fi
    if [[ "$mig_sni" != "-" ]]; then
      ok "Reality 伪装目标已迁移：www.microsoft.com → ${mig_sni}"
      info "依据：微软证书链 5902 字节（余量仅 39%），且 Xray 作者不建议用微软做目标"
    elif [[ "$(reality_sni)" == "www.microsoft.com" ]]; then
      warn "Reality 伪装目标仍是 www.microsoft.com（已启用过，故未自动改）"
      info "换目标：$(cmd_prefix) reality sni www.lovelive-anime.jp（会先体检，客户端需重拉订阅）"
    fi
  else
    warn "缺 python3，跳过字段补齐"
  fi

  # hop_port 缺失：早期 node.json 没有这个字段，一直靠默认值兜底。
  # 默认值换过一次，缺字段的机器就突然报「代理连不上」——实际是探测端口错了，
  # 代理本身好好的。这里探测本机真实监听端口补上，探不到才写默认值。
  # 写完必须重建 Xray / sing-box，否则落地出口仍指着旧端口。
  if [[ -z "$(node_get hop_port 2>/dev/null)" ]]; then
    local dp
    if dp="$(hop_detect_local)"; then
      node_set hop_port "$dp"
      ok "hop_port 缺失，已按本机监听识别为 ${dp}"
    else
      node_set hop_port "$HOP_PORT_DEFAULT"
      warn "hop_port 缺失，按默认 ${HOP_PORT_DEFAULT} 写入"
      info "代理在别的端口就运行：$(cmd_prefix) hop（菜单 13 → 3）"
    fi
    if landing_on || [[ "$(node_hop_mode)" == "all" ]]; then
      local u1 p1 w1
      u1="$(node_get uuid)"; p1="$(node_get path_xhttp)"; w1="$(node_get path_ws)"
      if write_xray_config "$u1" "$p1" "$w1"; then
        systemctl restart "$SVC_XRAY" 2>/dev/null; sleep 1
        svc_active "$SVC_XRAY" && { ok "Xray 已按新代理端口重建"; MIG_HOP=1; }
      fi
      if landing_on && sb_sync; then
        ok "sing-box 已按新代理端口重建（落地出口生效）"; MIG_HOP=1
      fi
    fi
  fi

  write_xray_service
  [[ -s "$TOKEN_FILE" ]] && write_tunnel_service
  write_sub_server
  write_sub_service
  systemctl daemon-reload
  ok "systemd 单元已对齐当前脚本路径"
  install_cmd && ok "命令入口已就绪：argox（以后直接敲 argox 进菜单）"
  # 订阅服务的 Python 文件被重写了，但正在跑的进程仍是旧代码
  # （v2.8.0 的 UA 分流不重启就不会生效）；重启它不影响客户端连接
  if [[ -f "$PYSRV" ]] && systemctl is-active --quiet "$SVC_SUB" 2>/dev/null; then
    systemctl restart "$SVC_SUB" 2>/dev/null && ok "订阅服务已重载（新代码生效）"
  fi

  # v2.7.0 移除 WS 入站：老实例的 config.json 里还有 argo-ws（占着 8002），
  # upgrade 本身不重写 config.json，所以这里显式迁移一次，否则 8002 会一直留着。
  if [[ -f "$CONF" ]] && grep -q '"argo-ws"' "$CONF"; then
    local u0 px0 pw0
    u0="$(node_get uuid)"; px0="$(node_get path_xhttp)"; pw0="$(node_get path_ws)"
    if write_xray_config "$u0" "$px0" "$pw0"; then
      systemctl restart "$SVC_XRAY" 2>/dev/null; sleep 1
      if svc_active "$SVC_XRAY"; then
        ok "WS 入站已移除（8002 不再监听），Xray 配置已重写"
        MIG_WS=1
      else
        warn "Xray 重启失败，手动看：journalctl -u ${SVC_XRAY} -n 20"
      fi
    else
      warn "Xray 配置重写失败，WS 入站保留原样（不影响使用）"
    fi
  fi

  # 落地 AnyTLS 入站端口随版本变过（v2.6.2：主口 +1 → 主口 -1，8446 → 8444）。
  # 配置里的 listen_port 跟当前计算值不一致就重建 sing-box，否则客户端会连到一个
  # 已不存在的端口（check 会报「TCP 8444 没在听」）。
  if landing_on && proto_on anytls && landing_wants anytls && [[ -f "$SBCONF" ]]; then
    local cur_rh want_rh
    want_rh="$(anytls_rh_port)"
    cur_rh="$(grep -A6 '"tag": "anytls-rh-in"' "$SBCONF" 2>/dev/null \
             | sed -n 's/.*"listen_port": *\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [[ -n "$cur_rh" && "$cur_rh" != "$want_rh" ]]; then
      ok "AnyTLS 落地端口已变更：${cur_rh} → ${want_rh}（与主口 $(anytls_port) 连号，安全组少开一个口）"
      if sb_sync; then
        ok "sing-box 已按新端口重启（TCP ${want_rh}）"
        info "云安全组放行 TCP ${want_rh}；旧的 ${cur_rh} 可以删掉"
        MIG_RH=1
      else
        warn "sing-box 重建失败，端口仍是 ${cur_rh}"
        info "手动重应用：$(cmd_prefix) landing off && $(cmd_prefix) landing on"
      fi
    fi
  fi

  if gen_sub >/dev/null 2>&1; then
    local names="${NAME_H3} / ${NAME_H2}"
    proto_on hy2    && names="${names} / ${NAME_HY2}"
    proto_on tuic   && names="${names} / ${NAME_TUIC}"
    proto_on anytls && names="${names} / ${NAME_ANYTLS}"
    proto_on reality && names="${names} / ${NAME_REALITY}"
    ok "订阅已重建：${names}"
  else
    warn "订阅重建失败，运行 check 查看原因"
  fi

  printf '\n'
  if [[ $MIG_HY2 -eq 1 ]]; then
    # 迁移改了 Hy2 监听口，必须重启 sing-box 并重建 nft 跳跃规则
    if proto_on hy2; then
      sb_sync && ok "sing-box 已按新监听口重启（Hy2 UDP $(hy2_port)）"
    fi
    warn "Oracle 安全组：请删除旧的 UDP 20000-30000 规则，改为 UDP $(hy2_hop)"
    warn "本机 iptables 可能残留旧段放行规则，用 iptables -L INPUT -n 自查"
    if ! proto_on hy2; then
      info "Hy2 未开启，端口变更待下次 direct on hy2 时生效"
    fi
    printf '\n'
  elif [[ $MIG_RH -eq 1 || $MIG_WS -eq 1 || $MIG_HOP -eq 1 ]]; then
    if [[ $MIG_RH -eq 1 ]]; then info "AnyTLS-RH 端口已改变，客户端需重连并重导订阅"; fi
    if [[ $MIG_WS -eq 1 ]]; then info "WS 入站已移除；H2 节点不受影响（走同一个回源，只差 ALPN）"; fi
    if [[ $MIG_HOP -eq 1 ]]; then info "代理端口已修正，落地 / 跳板节点需重连一次"; fi
    info "服务已因配置结构变更重启过"
  else
    info "服务未重启，运行中的连接不受影响"
  fi
  if ! proto_on hy2 && ! proto_on tuic && ! proto_on anytls; then
    warn "直连协议全部关闭：Argo 走 CF，线路差时会全挂"
    info "开一条 TCP 兜底：$(cmd_prefix) direct on all（菜单 14）"
  else
    info "直连协议当前：$(proto_label)"
  fi
  printf '\n'
  info "订阅直连 VPS 的 TCP $(sub_port)，CF 面板只需保留一条路由（$(node_get tunnel_host) → 127.0.0.1:${DEF_PORT_XHTTP}）"
  info "多余的 ws / sub Public Hostname 及其 DNS 记录可以删掉"

  local su; su="$(sub_url 2>/dev/null || true)"
  if [[ -n "$su" ]]; then
    printf '\n  订阅地址：%s%s%s\n\n' "$C_B" "$su" "$C_R"
  fi

  port_firewall_hint
}

# ==============================================================================
#  出口跳板
# ==============================================================================
hop_show() {
  local mode proto addr port p mode_txt
  mode="$(node_hop_mode)"; proto="$(node_hop_proto)"
  addr="$(node_hop_addr)"; port="$(node_hop_port)"
  if [[ "$mode" == "all" ]]; then mode_txt="${C_YEL}全部走跳板${C_R}"; else mode_txt="关闭（VPS 原生出口）"; fi
  printf '  模式    : %s\n' "$mode_txt"
  printf '  代理    : %s  %s:%s\n' "$proto" "$addr" "$port"
  p="$(hop_probe || true)"
  if [[ -n "$p" ]]; then
    printf '  探测    : 可用（%s），出口 IP %s\n' "${p%% *}" "${p#* }"
  else
    printf '  探测    : %s不可达%s（代理未启动 / 端口不对）\n' "$C_YEL" "$C_R"
  fi
}

hop_edit_addr() {
  local a p
  a="$(node_hop_addr)"; p="$(node_hop_port)"
  read -rp "  代理地址（当前 ${a}）: " a
  [[ -n "$a" ]] && node_set hop_addr "$a"
  read -rp "  代理端口（当前 ${p}）: " p
  if [[ "$p" =~ ^[0-9]+$ ]]; then node_set hop_port "$p"; fi
  ok "代理已设为 $(node_hop_addr):$(node_hop_port)"
}

hop_set() { # $1=all|off  $2=可选协议 socks|http
  local mode="$1" proto="${2:-}" prev uuid px pw pr
  prev="$(node_hop_mode)"
  uuid="$(node_get uuid)"; px="$(node_get path_xhttp)"; pw="$(node_get path_ws)"
  if [[ -z "$uuid" || -z "$px" || -z "$pw" ]]; then
    err "缺少 uuid / 路径，先跑菜单 1 完成安装"
    return 1
  fi

  if [[ "$mode" == "all" ]]; then
    pr="$(hop_probe || true)"
    if [[ -z "$pr" ]]; then
      err "本地代理 $(node_hop_addr):$(node_hop_port) 不通，未切换"
      info "确认代理已启动；地址/端口不对就用菜单 13 → 3) 改代理地址"
      return 1
    fi
    [[ -z "$proto" ]] && proto="${pr%% *}"
    node_set hop_proto "$proto"
    ok "代理可用（${pr%% *}），出口 IP ${pr#* }"
  fi

  node_set hop_mode "$mode"
  if ! write_xray_config "$uuid" "$px" "$pw"; then
    node_set hop_mode "$prev"
    err "配置生成失败，已保持原状"
    return 1
  fi

  systemctl restart "$SVC_XRAY" 2>/dev/null
  sleep 2
  if svc_active "$SVC_XRAY"; then
    if [[ "$mode" == "all" ]]; then ok "已开启：全部流量经 $(node_hop_addr):$(node_hop_port) 出去"
    else ok "已关闭：流量从 VPS 本机出口出去"; fi
    info "客户端重新连一次节点生效（旧连接仍走原来的出口）"
  else
    err "Xray 启动失败，自动回滚"
    node_set hop_mode "$prev"
    write_xray_config "$uuid" "$px" "$pw" >/dev/null 2>&1 || true
    systemctl restart "$SVC_XRAY" 2>/dev/null
    journalctl -u "$SVC_XRAY" -n 20 --no-pager
    return 1
  fi
}

do_hop() {
  require_root
  installed || { err "尚未安装，先执行菜单 1"; return 1; }
  local act="${1:-}"

  case "$act" in
    on|all)   hop_set all "${2:-}"; return ;;
    off|none) hop_set off ; return ;;
    ""|status|menu) : ;;
    *) err "用法：hop [on|off] [socks|http]"; return 1 ;;
  esac

  while true; do
    printf '\n  出口跳板\n'
    hop_show
    printf '\n'
    printf '  1) 关闭（默认，流量从 VPS 原生 IP 出去）\n'
    printf '  2) 全部走跳板（目标站只看到代理的出口 IP）\n'
    printf '  3) 改代理地址 / 端口\n'
    printf '  0) 返回\n'
    local c; read -rp "  选择: " c
    case "$c" in
      1) hop_set off ;;
      2) hop_set all ;;
      3) hop_edit_addr ;;
      0|"") return 0 ;;
      *) warn "无效选项：${c:-<空>}" ;;
    esac
    printf '\n'
    read -rp "  按回车继续…" _ || true
  done
}

# ==============================================================================
#  住宅落地（菜单 15 / landing 子命令）
# ==============================================================================
landing_names() {
  local t out=""
  for t in h3 h2 ws anytls reality; do
    landing_wants "$t" || continue
    case "$t" in
      h3) out+="${NAME_H3}${NAME_RH} " ;;
      h2) out+="${NAME_H2}${NAME_RH} " ;;
      anytls) proto_on anytls && out+="${NAME_ANYTLS}${NAME_RH} " ;;
      reality) proto_on reality && out+="${NAME_REALITY}${NAME_RH} " ;;
    esac
  done
  printf '%s' "${out% }"
}

landing_show() {
  local on lu pr ha hp
  on="$(node_jget landing.enabled 2>/dev/null)"
  lu="$(landing_uuid)"
  ha="$(node_hop_addr)"; hp="$(node_hop_port)"
  if [[ "$on" == "true" ]]; then
    printf '  状态     : %s已开启%s\n' "$C_GRN" "$C_R"
    printf '  落地节点 : %s%s%s\n' "$C_B" "$(landing_names)" "$C_R"
  else
    printf '  状态     : 关闭（所有节点从 VPS 原生 IP 出去）\n'
    printf '  落地节点 : 未启用（开启后生成 %s）\n' "$(landing_names)"
  fi
  printf '  出口代理 : %s:%s（%s）\n' "$ha" "$hp" "$(landing_proto)"
  printf '  落地 UUID: %s\n' "${lu:-未生成}"
  if [[ "$on" == "true" ]] && landing_wants anytls && proto_on anytls; then
    printf '  AnyTLS-RH: TCP %s（sing-box 独立入站，与主入站分流）\n' "$(anytls_rh_port)"
  fi
  # 先探端口再探代理：代理不在时省掉 curl 的两个 8 秒超时
  if timeout 2 bash -c ">/dev/tcp/${ha}/${hp}" 2>/dev/null; then
    pr="$(hop_probe || true)"
    if [[ -n "$pr" ]]; then
      printf '  代理探测 : 可用（%s），出口 IP %s\n' "${pr%% *}" "${pr#* }"
    else
      printf '  代理探测 : %s端口开着但代理不通%s（换个协议试试 http）\n' "$C_YEL" "$C_R"
    fi
  else
    printf '  代理探测 : %s不可达%s（住宅代理没启动 / 端口不对）\n' "$C_YEL" "$C_R"
  fi
}

landing_set() { # $1=on|off
  local want="$1" prev lu uuid px pw pr
  prev="$(node_jget landing.enabled 2>/dev/null)"
  [[ -z "$prev" ]] && prev="false"
  uuid="$(node_get uuid)"; px="$(node_get path_xhttp)"; pw="$(node_get path_ws)"
  if [[ -z "$uuid" || -z "$px" || -z "$pw" ]]; then
    err "缺少 uuid / 路径，先跑菜单 1 完成安装"
    return 1
  fi

  if [[ "$want" == "on" ]]; then
    pr="$(hop_probe || true)"
    if [[ -z "$pr" ]]; then
      err "本地代理 $(node_hop_addr):$(node_hop_port) 不通，未开启"
      info "住宅代理没启动或端口变了；地址端口在菜单 13 → 3 里改"
      return 1
    fi
    lu="$(landing_uuid)"
    if [[ -z "$lu" ]]; then
      lu="$(gen_uuid)"
      node_jset landing.uuid "\"${lu}\""
    fi
    # 没单独指定出口协议时，用探测到的那个（代理可能只支持 socks 或 http 之一）
    if [[ -z "$(node_jget landing.proto 2>/dev/null)" ]]; then
      node_jset landing.proto "\"${pr%% *}\""
    fi
    node_jset landing.enabled true
    ok "代理可用（${pr%% *}），住宅出口 IP ${pr#* }"
    info "落地 UUID：${lu}"
  else
    node_jset landing.enabled false
  fi

  if ! write_xray_config "$uuid" "$px" "$pw"; then
    node_jset landing.enabled "${prev}"
    err "配置生成失败，已保持原状"
    return 1
  fi

  systemctl restart "$SVC_XRAY" 2>/dev/null
  sleep 2
  # AnyTLS 落地在 sing-box 侧（独立入站 + socks 出口），Xray 重写带不上，必须单独同步
  if proto_on anytls; then
    if write_sb_config; then
      systemctl restart "$SVC_SB" 2>/dev/null; sleep 1
    else
      warn "sing-box 配置生成失败（AnyTLS 落地可能没生效，运行 check 查看）"
    fi
  fi
  if svc_active "$SVC_XRAY"; then
    gen_sub >/dev/null 2>&1 || warn "订阅重建失败，运行 check 查看"
    if [[ "$want" == "on" ]]; then
      ok "已开启住宅落地"
      printf '  订阅新增：%s\n' "$(landing_names)"
    else
      ok "已关闭住宅落地，订阅回到纯原生出口"
    fi
    info "客户端重新拉订阅（旧的 -RH 节点记得删掉）"
  else
    err "Xray 启动失败，自动回滚"
    node_jset landing.enabled "${prev}"
    write_xray_config "$uuid" "$px" "$pw" >/dev/null 2>&1 || true
    systemctl restart "$SVC_XRAY" 2>/dev/null
    journalctl -u "$SVC_XRAY" -n 20 --no-pager
    return 1
  fi
}

landing_set_target() { # $@=h3 h2 ws anytls reality（支持逗号分隔）
  local t arr=() json="" i
  for t in $(printf '%s' "$*" | tr ',' ' '); do
    case "$t" in
      h3|h2|ws|anytls|reality) arr+=("$t") ;;
      *) err "未知入口：$t（只支持 h3 h2 ws anytls reality）"; return 1 ;;
    esac
  done
  [[ ${#arr[@]} -eq 0 ]] && { err "至少选一个入口（h3 h2 ws anytls reality）"; return 1; }
  json="["
  for (( i=0; i<${#arr[@]}; i++ )); do
    [[ $i -gt 0 ]] && json+=","
    json+="\"${arr[$i]}\""
  done
  json+="]"
  node_jset landing.target "$json"
  ok "落地入口：${arr[*]}"

  if landing_on; then
    local uuid px pw rc=0
    uuid="$(node_get uuid)"; px="$(node_get path_xhttp)"; pw="$(node_get path_ws)"
    if write_xray_config "$uuid" "$px" "$pw"; then
      systemctl restart "$SVC_XRAY" 2>/dev/null; sleep 1
    else
      err "Xray 配置生成失败，入口未改动"
      rc=1
    fi
    # AnyTLS 落地在 sing-box 侧，Xray 重写不会带上它，必须单独重建
    if proto_on anytls; then
      landing_wants anytls && fw_open tcp "$(anytls_rh_port)"
      if write_sb_config; then
        systemctl restart "$SVC_SB" 2>/dev/null; sleep 1
      else
        err "sing-box 配置生成失败（AnyTLS 落地可能没生效）"
        rc=1
      fi
    fi
    gen_sub >/dev/null 2>&1 || warn "订阅重建失败"
    [[ $rc -eq 0 ]] && ok "已生效，订阅：$(landing_names)"
    return $rc
  fi
}

landing_set_proto() { # $1=socks|http
  local p="$1"
  case "$p" in socks|http) : ;; *) err "只支持 socks / http"; return 1 ;; esac
  node_jset landing.proto "\"${p}\""
  ok "落地出口协议：${p}"
  if landing_on; then
    local uuid px pw
    uuid="$(node_get uuid)"; px="$(node_get path_xhttp)"; pw="$(node_get path_ws)"
    write_xray_config "$uuid" "$px" "$pw" && systemctl restart "$SVC_XRAY" 2>/dev/null
    info "客户端重连一次生效"
  fi
}

landing_pick_target() {
  local t ans cur a=()
  printf '\n  逐项确认（直接回车 = 保留当前）\n'
  for t in h3 h2 anytls reality; do
    if landing_wants "$t"; then cur="${C_GRN}是${C_R}"; else cur="${C_DIM}否${C_R}"; fi
    case "$t" in
      anytls)  proto_on anytls  || printf '  %s（AnyTLS 未开启，选了暂不生效）%s\n' "$C_YEL" "$C_R" ;;
      reality) proto_on reality || printf '  %s（Reality 未开启，选了暂不生效）%s\n' "$C_YEL" "$C_R" ;;
    esac
    read -rp "  $(printf '%-7s' "$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')") 落地？（当前 ${cur}，y/n/回车）: " ans
    case "${ans,,}" in
      y) a+=("$t") ;;
      n) : ;;
      *) landing_wants "$t" && a+=("$t") ;;
    esac
  done
  if [[ ${#a[@]} -eq 0 ]]; then
    warn "至少要保留一个入口，未改动"
    return 1
  fi
  landing_set_target "${a[@]}"
}

do_landing() {
  require_root
  installed || { err "尚未安装，先执行菜单 1"; return 1; }
  local act="${1:-}"

  case "$act" in
    on)      landing_set on;  return ;;
    off)     landing_set off; return ;;
    status)  landing_show;    return ;;
    target)  shift; landing_set_target "$@"; return ;;
    proto)   landing_set_proto "${2:-}"; return ;;
    ""|menu) : ;;
    *) err "用法：landing [on|off|status|target h3,h2,anytls,reality|proto socks|http]"; return 1 ;;
  esac

  while true; do
    printf '\n  住宅落地（本地 SOCKS / HTTP 代理）\n'
    landing_show
    printf '\n'
    printf '  1) 开启落地（订阅多出 -RH 节点）\n'
    printf '  2) 关闭落地\n'
    printf '  3) 选择作用入口（H3 / H2 / AnyTLS / Reality）\n'
    printf '  4) 出口协议（socks / http，当前 %s）\n' "$(landing_proto)"
    printf '  5) 改代理地址 / 端口（当前 %s:%s）\n' "$(node_hop_addr)" "$(node_hop_port)"
    printf '  0) 返回\n'
    local c; read -rp "  选择: " c
    case "$c" in
      1) landing_set on ;;
      2) landing_set off ;;
      3) landing_pick_target ;;
      4) read -rp "  协议（socks/http）: " lp; landing_set_proto "$lp" ;;
      5) hop_edit_addr ;;
      0|"") return 0 ;;
      *) warn "无效选项：${c:-<空>}" ;;
    esac
    printf '\n'
    read -rp "  按回车继续…" _ || true
  done
}

# 节点地址模式：domain=域名直连，ip=展开优选 IP。
# 单独做成子命令是因为它藏在「隧道配置」子菜单里 —— 刚导入完优选 IP 时
# 很难联想到还要去那儿切一下，订阅没变化就成了悬案。
do_mode() {
  require_root
  local m="${1:-}" cur n
  cur="$(node_mode)"
  n=0
  [[ -s "$IPSF" ]] && n="$(wc -l < "$IPSF" | tr -d ' ')"

  if [[ -z "$m" ]]; then
    printf '\n  当前地址模式：%s\n' "$cur"
    printf '  · domain  域名直连（客户端自行解析到最近的 CF 节点）\n'
    printf '  · ip      展开优选 IP（IP 列表 %s 个）\n' "${n:-0}"
    if [[ -s "$IPSF" ]]; then
      printf '\n  当前 IP：\n'
      head -8 "$IPSF" | sed 's/^/    /'
      [[ "${n:-0}" -gt 8 ]] && printf '    … 共 %s 个\n' "$n"
    fi
    printf '\n  切换：%s mode ip    /    %s mode domain\n\n' "$(cmd_prefix)" "$(cmd_prefix)"
    return 0
  fi

  case "$m" in
    domain|ip) ;;
    *) err "用法：$(cmd_prefix) mode [domain|ip]"; return 1 ;;
  esac

  if [[ "$m" == "ip" ]]; then
    if [[ ! -s "$IPSF" ]]; then
      err "IP 列表为空，先导入再切：$(cmd_prefix) ips"
      return 1
    fi
    info "ip 模式只影响 Argo-H3 / Argo-H2 / Argo-H3-RH 三条；Hy2、TUIC、AnyTLS、Reality 直连 VPS 公网 IP"
  fi

  if [[ "$m" == "$cur" ]]; then
    ok "地址模式已是 ${m}"
  else
    node_set node_mode "$m"
    ok "地址模式已设为 ${m}"
  fi

  gen_sub >/dev/null 2>&1 && ok "订阅已重建" || warn "订阅重建失败，跑 check 查看"
  show_nodes
}

do_tunnel_setup() {
  require_root
  local mode_v
  mode_v="$(node_mode)"
  printf '\n  隧道配置\n'
  printf '  1) 填写 / 更换 Tunnel Token\n'
  printf '  2) 设置 / 更换隧道域名（主入口，用于生成节点）\n'
  printf '  3) 测试主入口 + 订阅连通性\n'
  printf '  4) 节点地址模式（当前：%s）\n' "$mode_v"
  printf '  5) cloudflared 出站诊断（7844 通不通）\n'
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
      cf_paths "$h"
      show_nodes
      ;;
    3)
      local h; h="$(node_get tunnel_host)"
      [[ -z "$h" ]] && { err "先设置隧道域名"; return 1; }
      local r1 r2 u
      step "测试主入口 + 订阅"
      r1="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${h}/" 2>/dev/null || echo 000)"
      u="$(sub_url 2>/dev/null || true)"
      [[ -n "$u" ]] && r2="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u" 2>/dev/null || echo 000)"
      printf '  主入口  %-34s HTTP %s\n' "$h" "${r1:-—}"
      printf '  订阅    %-34s HTTP %s\n\n' "${u:-未配置}" "${r2:-—}"

      case "${r1:-000}" in
        000)     err "主入口不通：DNS 未解析 / 证书异常 / 隧道离线" ;;
        530|1033) err "主入口 HTTP ${r1}：CF 找不到该子域的路由（DNS 记录或 Public Hostname 缺失）" ;;
        502|503) err "主入口 HTTP ${r1}：CF 到了但回源失败（确认 127.0.0.1:${DEF_PORT_XHTTP} 在监听）" ;;
        *)       ok "主入口 HTTP ${r1}" ;;
      esac
      if [[ -n "${u:-}" ]]; then
        case "${r2:-000}" in
          200) ok "订阅可访问（HTTP 200，直连 $(sub_port)）" ;;
          000) err "订阅不通：云安全组未放行 TCP $(sub_port) / 防火墙拦截 / 服务没起" ;;
          *)   err "订阅 HTTP ${r2}（正常只有 200；服务日志看 journalctl -u ${SVC_SUB}）" ;;
        esac
      fi
      ;;
    4)
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
    5)
      do_diag
      ;;
    *) return 0 ;;
  esac
}

# ==============================================================================
#  菜单
# ==============================================================================
# ==============================================================================
#  直连协议（Hy2 / TUIC）：状态 / 开关 / 端口 / 跳跃段
# ==============================================================================
direct_show() {
  local sbv="未安装" svc="${C_DIM}未运行${C_R}"
  [[ -x "$SB_BIN" ]] && sbv="$("$SB_BIN" version 2>/dev/null | head -1 | sed 's/^sing-box version //')"
  svc_active "$SVC_SB" && svc="${C_GRN}运行中${C_R}"

  printf '\n  %s直连协议%s\n' "$C_B" "$C_R"
  printf '  sing-box  : %s\n' "$sbv"
  printf '  服务      : %s\n' "$svc"
  local p on port extra kind
  for p in hy2 tuic anytls; do
    proto_on "$p" && on="${C_GRN}开${C_R}" || on="${C_DIM}关${C_R}"
    case "$p" in
      hy2)    port="$(hy2_port)";    kind="UDP"; extra="  跳跃 $(hy2_hop)" ;;
      tuic)   port="$(tuic_port)";   kind="UDP"; extra="" ;;
      anytls) port="$(anytls_port)"; kind="TCP"; extra="  UDP 全灭时的出路" ;;
    esac
    printf '  %-9s : %s   %s %-6s%s\n' "$p" "$on" "$kind" "$port" "$extra"
  done
  # AnyTLS 落地：sing-box 的第二个入站，只有落地开了才有
  if proto_on anytls && landing_on && landing_wants anytls; then
    printf '  %-9s : %s   %s %-6s  落地家宽（独立入站）\n' \
      "anytls-rh" "${C_GRN}开${C_R}" "TCP" "$(anytls_rh_port)"
  fi
  # Reality 走 Xray 内核，与上面三个不同服务
  proto_on reality && on="${C_GRN}开${C_R}" || on="${C_DIM}关${C_R}"
  local rx; svc_active "$SVC_XRAY" && rx="${C_GRN}运行中${C_R}" || rx="${C_DIM}未运行${C_R}"
  printf '  %-9s : %s   %s %-6s  伪装 %s（Xray %s）\n' \
    "reality" "$on" "TCP" "$(reality_port)" "$(reality_sni)" "$rx"
  printf '  公网 IP   : %s\n' "$(vps_ip)"
  if [[ -f "${CERTD}/cert.pem" ]]; then
    local end left
    end="$(openssl x509 -noout -enddate -in "${CERTD}/cert.pem" 2>/dev/null | sed 's/^notAfter=//')"
    left=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    printf '  证书      : 剩 %s 天（Reality 不用证书）\n' "$left"
  else
    printf '  证书      : %s未生成%s（首次开启直连协议时自动生成）\n' "$C_YEL" "$C_R"
  fi
  printf '\n  云安全组需放行：UDP %s（Hy2 整段）、UDP %s（TUIC）、TCP %s（AnyTLS）' \
    "$(hy2_hop)" "$(tuic_port)" "$(anytls_port)"
  proto_on reality && printf '、TCP %s（Reality）' "$(reality_port)"
  proto_on anytls && landing_on && landing_wants anytls && printf '、TCP %s（AnyTLS-RH）' "$(anytls_rh_port)"
  printf '\n'
}

# 批量切换（on all / off all）：四个开关一次写完，配置只重建一次、服务只重启一次。
# 旧实现是 for 循环逐个调 direct_switch，代价是 sing-box 重启 3 次、nft 跳跃表
# 重建 3 次、ufw/iptables 全端口重复放行 3 轮、Xray 重启 1 次、订阅重建 4 次，
# 外加「证书已存在」刷 6 遍。中途某步失败还会留下半开半关的中间态。
direct_all() { # $1=on|off
  local act="$1" v=false rc=0 links nlink skip_r=0
  [[ "$act" == "on" ]] && v=true

  # 旧值留存，失败时整体回滚
  local o_hy2 o_tuic o_anytls o_reality
  o_hy2="$(proto_on hy2 && echo true || echo false)"
  o_tuic="$(proto_on tuic && echo true || echo false)"
  o_anytls="$(proto_on anytls && echo true || echo false)"
  o_reality="$(proto_on reality && echo true || echo false)"

  if [[ "$v" == "true" ]]; then
    step "批量开启直连协议（Hy2 + TUIC + AnyTLS + Reality）"
    install_singbox || return 1
    # Reality 走 Xray 内核，与 sing-box 三件套互不影响：密钥拿不到就只跳过它，
    # 别把 Hy2 / TUIC / AnyTLS 一起拖死（旧实现是逐个 try，单个失败不影响其他）
    reality_keys || { warn "Reality 密钥不可用，本次跳过 Reality（Hy2/TUIC/AnyTLS 照常开启）"; skip_r=1; }
    # 证书不在这里生成：交给 sb_sync 一次做完（否则会重复打印「证书已存在」）
  else
    step "批量关闭直连协议"
  fi

  node_jset proto.hy2     "$v" || { err "写入 node.json 失败"; return 1; }
  node_jset proto.tuic    "$v" || { err "写入 node.json 失败"; return 1; }
  node_jset proto.anytls  "$v" || { err "写入 node.json 失败"; return 1; }
  node_jset proto.reality "$([[ $skip_r -eq 1 ]] && echo false || echo "$v")" \
    || { err "写入 node.json 失败"; return 1; }

  # ---- sing-box 侧：Hy2 / TUIC / AnyTLS 一次重建（含证书、nft 跳跃、防火墙）----
  if ! sb_sync; then
    err "sing-box 重建失败，四个开关已整体回滚"
    node_jset proto.hy2     "${o_hy2:-false}"     >/dev/null 2>&1 || true
    node_jset proto.tuic    "${o_tuic:-false}"    >/dev/null 2>&1 || true
    node_jset proto.anytls  "${o_anytls:-false}"  >/dev/null 2>&1 || true
    node_jset proto.reality "${o_reality:-false}" >/dev/null 2>&1 || true
    sb_sync >/dev/null 2>&1 || true
    return 1
  fi

  # ---- Xray 侧：Reality 入站的增删（Reality 被跳过时无需动 Xray）----
  if [[ $skip_r -eq 1 ]]; then
    rc=1                                   # 部分成功：三个已开，Reality 未开
  elif ! reality_apply; then
    err "Xray 侧失败，reality 开关已回滚；sing-box 侧保持已生效"
    node_jset proto.reality "${o_reality:-false}" >/dev/null 2>&1 || true
    reality_apply >/dev/null 2>&1 || true
    rc=1
  fi

  gen_sub >/dev/null 2>&1 || warn "订阅重建失败，跑 check 查看"
  links="$(build_links 2>/dev/null)"
  nlink="$(grep -c . <<< "$links" 2>/dev/null || true)"

  printf '\n'
  if [[ "$v" == "true" ]]; then
    local rmark="✓" rcol="$C_GRN" rnote="伪装 $(reality_sni)"
    [[ $rc -ne 0 ]] && { rmark="✗"; rcol="$C_RED"; }   # reality 那行如实标红，不假报成功
    [[ $skip_r -eq 1 ]] && rnote="未开启（密钥不可用，已跳过）"
    printf '  %s✓%s %-9s %s %-6s %s\n' "$C_GRN" "$C_R" "$NAME_HY2"     "UDP" "$(hy2_port)"    "跳跃 $(hy2_hop)"
    printf '  %s✓%s %-9s %s %-6s %s\n' "$C_GRN" "$C_R" "$NAME_TUIC"    "UDP" "$(tuic_port)"   "备选"
    printf '  %s✓%s %-9s %s %-6s %s\n' "$C_GRN" "$C_R" "$NAME_ANYTLS"  "TCP" "$(anytls_port)" "UDP 全灭时的出路"
    printf '  %s%s%s %-9s %s %-6s %s\n' "$rcol" "$rmark" "$C_R" "$NAME_REALITY" "TCP" "$(reality_port)" "$rnote"
    info "配置只重建 1 轮：sing-box 重启 1 次、Xray 重启 1 次（原来各 3 次 / 6 次）"
    info "订阅已重建 ${nlink:-0} 条；客户端需重连一次才生效"
    info "云安全组放行 UDP $(hy2_hop) / UDP $(tuic_port) / TCP $(anytls_port) / TCP $(reality_port)"
  elif [[ $rc -eq 0 ]]; then
    ok "Hy2 / TUIC / AnyTLS / Reality 全部关闭（sing-box 已停止，nft 跳跃表已清空）"
  else
    warn "四个开关已置 false，但 Xray 侧重建失败，跑 check 确认 reality 入站是否已摘除"
  fi
  return $rc
}

direct_switch() { # $1=on|off  $2=hy2|tuic|anytls|reality|all
  local act="$1" name="$2" v=false
  case "$name" in
    hy2|tuic|anytls|reality) : ;;
    all)
      direct_all "$act"
      return $? ;;
    *) err "指定协议：hy2 / tuic / anytls / reality / all"; return 1 ;;
  esac
  [[ "$act" == "on" ]] && v=true

  # ---- Reality 走 Xray 内核：重写 config.json 并重启 argox-xray ----
  if [[ "$name" == "reality" ]]; then
    if [[ "$v" == "true" ]]; then
      reality_keys || return 1
    fi
    node_jset proto.reality "$v" || { err "写入 node.json 失败"; return 1; }
    if ! reality_apply; then
      node_jset proto.reality "$([[ "$v" == "true" ]] && echo false || echo true)" >/dev/null 2>&1 || true
      reality_apply >/dev/null 2>&1 || true
      err "Reality 操作失败，已回滚"
      return 1
    fi
    if [[ "$v" == "true" ]]; then
      ok "${NAME_REALITY} 已开启（TCP $(reality_port)，伪装 $(reality_sni)）"
      warn "云安全组放行 TCP $(reality_port)"
    else
      ok "${NAME_REALITY} 已关闭（TCP $(reality_port) 不再监听）"
    fi
    return 0
  fi

  if [[ "$v" == "true" ]]; then
    install_singbox || return 1
    # 证书由 sb_sync 内部生成，这里不再调 cert_gen，避免同一个流程打印两遍
  elif ! [[ -x "$SB_BIN" ]]; then
    info "${name} 本来就是关闭状态，无需操作"
    return 0
  fi

  node_jset "proto.${name}" "$v" || { err "写入 node.json 失败"; return 1; }

  if ! sb_sync; then
    if [[ "$v" == "true" ]]; then
      node_jset "proto.${name}" false >/dev/null 2>&1 || true
      sb_sync >/dev/null 2>&1 || true
      err "开启失败，已回滚"
    else
      err "关闭时出错，但开关已写入 false，可手动 systemctl stop ${SVC_SB}"
    fi
    return 1
  fi

  gen_sub >/dev/null 2>&1 || warn "订阅重建失败，跑 check 查看"
  if [[ "$v" == "true" ]]; then
    ok "${name} 已开启"
    case "$name" in
      hy2)    info "云安全组放行 UDP $(hy2_hop)（整段，不只是 $(hy2_port)）" ;;
      tuic)   info "云安全组放行 UDP $(tuic_port)" ;;
      anytls) info "云安全组放行 TCP $(anytls_port)" ;;
    esac
  else
    ok "${name} 已关闭"
  fi
}

direct_menu() {
  require_root
  local c r yn rh
  while true; do
    direct_show
    cat <<'EOF'

  1) 全部开启（Hy2 + TUIC + AnyTLS + Reality，推荐）*
  2) 开启 / 关闭 Hy2（UDP 主力）
  3) 开启 / 关闭 TUIC（UDP 备选）
  4) 开启 / 关闭 AnyTLS（TCP 兜底）
  5) 开启 / 关闭 Reality（Xray 内核，纯 Xray 客户端用）
  6) 改 Hy2 跳跃段
  7) 查看 / 重签证书
  8) 重启 sing-box
  9) Reality 伪装目标体检 / 换目标
  0) 返回
EOF
    read -rp "  选择: " c
    case "${c:-}" in
      1) direct_switch on all ;;
      2) if proto_on hy2; then direct_switch off hy2; else direct_switch on hy2; fi ;;
      3) if proto_on tuic; then direct_switch off tuic; else direct_switch on tuic; fi ;;
      4) if proto_on anytls; then direct_switch off anytls; else direct_switch on anytls; fi ;;
      5) if proto_on reality; then direct_switch off reality; else direct_switch on reality; fi ;;
      6) printf '\n  当前跳跃段：%s（监听 %s）\n' "$(hy2_hop)" "$(hy2_port)"
         read -rp "  新的跳跃段（回车保持不变）: " r
         if [[ -n "${r// /}" ]]; then
           hy2_hop_set "${r// /}"
         fi ;;
      7) cert_show; printf '\n'
         if [[ -f "${CERTD}/cert.pem" ]]; then
           read -rp "  重新生成证书？（y/N）: " yn
           if [[ "${yn,,}" == "y" ]]; then
             cert_gen --force && { if proto_on hy2 || proto_on tuic || proto_on anytls; then sb_sync; fi; }
           fi
         else
           cert_gen
         fi ;;
      8) if proto_on hy2 || proto_on tuic || proto_on anytls; then sb_sync; else warn "sing-box 侧协议都未开启"; fi ;;
      9) reality_probe; printf '\n'
         read -rp "  换成哪个？（留空则不改）: " rh
         if [[ -n "${rh// /}" ]]; then
           reality_sni_set "${rh// /}"
         fi ;;
      0|"") return 0 ;;
      *) warn "无效选项" ;;
    esac
    printf '\n'
    read -rp "  按回车继续…" _ || true
  done
}

do_direct() {
  require_root
  case "${1:-}" in
    ""|menu) direct_menu ;;
    status)  direct_show ;;
    on|off)  direct_switch "$1" "${2:-}" ;;
    *) err "用法：direct [status|on|off] <hy2|tuic|anytls|reality|all>"; return 1 ;;
  esac
}

# ==============================================================================
#  端口管理（v2.7.0）
#
#  所有端口都持久化在 node.json，改完要重建对应服务 + 重建订阅（客户端得重导）。
#  Oracle 安全组脚本改不了，只能提示。安装时也可用环境变量预指定：
#    SUB_PORT=9000 ANYTLS_PORT=9443 bash argox.sh install
# ==============================================================================
PORT_ITEMS="sub hy2 tuic anytls reality"

port_label() {
  case "$1" in
    sub)     printf '订阅服务' ;;
    hy2)     printf 'Hy2' ;;
    tuic)    printf 'TUIC' ;;
    anytls)  printf 'AnyTLS' ;;
    reality) printf 'Reality' ;;
    *)       printf '%s' "$1" ;;
  esac
}

port_kind() { # tcp | udp
  case "$1" in
    hy2|tuic) printf 'udp' ;;
    *)        printf 'tcp' ;;
  esac
}

port_cur() {
  case "$1" in
    sub)     sub_port ;;
    hy2)     hy2_port ;;
    tuic)    tuic_port ;;
    anytls)  anytls_port ;;
    reality) reality_port ;;
  esac
}

port_show() {
  printf '\n  %s端口%s（改完需重导订阅；云安全组要同步放行）\n' "$C_B" "$C_R"
  # 表头用硬编码空格：printf %-Ns 按字节算，中文表头跟 ASCII 数据行对不齐
  printf '  项目       协议 端口    说明\n'
  printf '  %-10s %-4s %-7s %s\n' "xhttp"      "TCP" "$DEF_PORT_XHTTP" "隧道回源，仅本机（不建议改）"
  printf '  %-10s %-4s %-7s %s\n' "sub"        "TCP" "$(sub_port)"     "订阅服务，公网直连"
  printf '  %-10s %-4s %-7s %s\n' "hy2"        "UDP" "$(hy2_port)"     "跳跃段 $(hy2_hop)"
  printf '  %-10s %-4s %-7s %s\n' "tuic"       "UDP" "$(tuic_port)"    ""
  printf '  %-10s %-4s %-7s %s\n' "anytls"     "TCP" "$(anytls_port)"  ""
  printf '  %-10s %-4s %-7s %s\n' "anytls-rh"  "TCP" "$(anytls_rh_port)" "落地口（跟随 anytls −1，不单独设）"
  printf '  %-10s %-4s %-7s %s\n' "reality"    "TCP" "$(reality_port)" "Xray 内核"
  printf '\n'
}

# 新端口能不能用：$1=项目（排除自己）$2=端口
port_check_free() {
  local me="$1" p="$2" it cur rng a b
  for it in $PORT_ITEMS; do
    [[ "$it" == "$me" ]] && continue
    cur="$(port_cur "$it")"
    [[ "$cur" == "$p" ]] && { err "端口 ${p} 已被 $(port_label "$it") 占用"; return 1; }
  done

  # AnyTLS 会按主口 −1 算出落地口，改别的协议时要避开它
  if [[ "$me" != "anytls" && "$(anytls_rh_port)" == "$p" ]]; then
    err "端口 ${p} 是 AnyTLS 落地口（$(anytls_port) − 1），换一个"; return 1
  fi

  # 落在 Hy2 跳跃段内的 UDP 端口会被 nft redirect 劫持到 Hy2
  rng="$(hy2_hop)"
  if [[ "$(port_kind "$me")" == "udp" && "$me" != "hy2" && "$rng" == *-* ]]; then
    a="${rng%%-*}"; b="${rng#*-}"
    if (( p >= a && p <= b )); then
      err "端口 ${p} 落在 Hy2 跳跃段 ${rng} 内，UDP 会被 nft 劫持到 Hy2"; return 1
    fi
  fi

  if port_in_use "$p" "$(port_kind "$me")" 2>/dev/null && [[ "$(port_cur "$me")" != "$p" ]]; then
    err "端口 ${p} 已被系统里其它进程占用（ss -lnup / -lntp 自查）"; return 1
  fi
  return 0
}

# 应用配置：sub 走订阅服务，hy2/tuic/anytls 走 sing-box，reality 走 Xray
port_apply() {
  local it="$1"
  case "$it" in
    sub)
      write_sub_server && write_sub_service || return 1
      systemctl daemon-reload
      systemctl restart "$SVC_SUB" 2>/dev/null
      sleep 1
      svc_active "$SVC_SUB" || { err "订阅服务起不来：journalctl -u ${SVC_SUB} -n 20"; return 1; }
      fw_open tcp "$(sub_port)"
      ;;
    hy2|tuic|anytls) sb_sync ;;
    reality)         reality_apply ;;
    *) return 1 ;;
  esac
}

port_set() { # $1=项目 $2=端口
  local it="$1" newp="${2:-}" oldp
  case "$it" in
    sub|hy2|tuic|anytls|reality) : ;;
    *) err "可改的项目：sub / hy2 / tuic / anytls / reality"; return 1 ;;
  esac
  [[ "$newp" =~ ^[0-9]+$ ]] || { err "端口必须是数字：${newp:-<空>}"; return 1; }
  (( newp >= 1024 && newp <= 65535 )) || { err "端口范围 1024-65535（1024 以下要 root 且易撞系统服务）"; return 1; }

  oldp="$(port_cur "$it")"
  if [[ "$oldp" == "$newp" ]]; then info "$(port_label "$it") 已经是 ${newp}，无需改动"; return 0; fi
  port_check_free "$it" "$newp" || return 1

  node_jset "${it}.port" "$newp" || { err "写入 node.json 失败"; return 1; }

  if ! port_apply "$it"; then
    err "应用失败，已回滚到 ${oldp}"
    node_jset "${it}.port" "$oldp" >/dev/null 2>&1 || true
    port_apply "$it" >/dev/null 2>&1 || true
    return 1
  fi

  gen_sub >/dev/null 2>&1 || warn "订阅重建失败，跑 check 查看"

  ok "$(port_label "$it") 端口 ${oldp} → ${newp}"
  printf '  云安全组：放行 %s %s（旧端口 %s 可删）\n' \
    "$(port_kind "$it" | tr '[:lower:]' '[:upper:]')" "$newp" "$oldp"
  if [[ "$it" == "anytls" ]]; then
    printf '  落地口自动跟随：TCP %s（一并放行）\n' "$(anytls_rh_port)"
  fi
  if [[ "$it" == "hy2" ]]; then
    printf '  跳跃段仍是 %s，nft 会重定向到新监听口 %s\n' "$(hy2_hop)" "$newp"
  fi
  info "客户端重新导入订阅才生效"
  return 0
}

port_menu() {
  require_root
  local c it p
  while true; do
    port_show
    cat <<'EOF'
  1) 改订阅端口     2) 改 Hy2      3) 改 TUIC
  4) 改 AnyTLS      5) 改 Reality  0) 返回
EOF
    read -rp "  选择: " c
    case "${c:-}" in
      1) it="sub" ;; 2) it="hy2" ;; 3) it="tuic" ;; 4) it="anytls" ;; 5) it="reality" ;;
      0|"") return 0 ;;
      *) warn "无效选项"; printf '\n'; continue ;;
    esac
    read -rp "  $(port_label "$it") 新端口（当前 $(port_cur "$it")）: " p
    [[ -z "${p// /}" ]] || port_set "$it" "${p// /}"
    printf '\n'
    read -rp "  按回车继续…" _ || true
  done
}

do_port() {
  require_root
  installed || { err "尚未安装，先执行菜单 1"; return 1; }
  case "${1:-}" in
    ""|menu)  port_menu ;;
    status|show|ls) port_show ;;
    *)        port_set "$1" "${2:-}" ;;
  esac
}

# 收尾提示：把要放行的端口一次列全。云安全组脚本改不了，只能人肉在控制台配。
port_firewall_hint() {
  local any=0
  printf '\n'
  step "云安全组（Oracle 控制台）需要放行"
  printf '  端口             协议 用途\n'
  if proto_on hy2; then
    printf '  %-16s %-4s %s\n' "$(hy2_hop)" "UDP" "Hy2 含端口跳跃（必须整段，不能只开 $(hy2_port)）"
    any=1
  fi
  if proto_on tuic; then
    printf '  %-16s %-4s %s\n' "$(tuic_port)" "UDP" "TUIC"
    any=1
  fi
  if proto_on anytls; then
    printf '  %-16s %-4s %s\n' "$(anytls_port)" "TCP" "AnyTLS"
    if landing_on && landing_wants anytls; then
      printf '  %-16s %-4s %s\n' "$(anytls_rh_port)" "TCP" "AnyTLS 落地（与上面连号，可合并放行 $(anytls_rh_port)-$(anytls_port)）"
    fi
    any=1
  fi
  if proto_on reality; then
    printf '  %-16s %-4s %s\n' "$(reality_port)" "TCP" "Reality"
    any=1
  fi
  printf '  %-16s %-4s %s\n' "$(sub_port)" "TCP" "订阅服务（客户端直连，不走隧道）"
  [[ $any -eq 0 ]] && printf '  （直连协议全关，只有订阅端口需要放行）\n'

  printf '\n'
  info "本机 iptables / ufw 脚本已自动放行，只剩云安全组要手动加"
  info "端口要改：$(cmd_prefix) port <sub|hy2|tuic|anytls|reality> <端口>"
  info "CF 隧道只需一条公共主机名：$(node_get tunnel_host) → http://127.0.0.1:${DEF_PORT_XHTTP}"
}

do_reality() {
  require_root
  case "${1:-status}" in
    probe|test)
      shift
      reality_probe "$@" ;;
    sni|set)
      [[ -z "${2:-}" ]] && { err "用法：reality sni www.example.com"; return 1; }
      reality_sni_set "${2:-}" ;;
    ""|status)
      local on sid
      proto_on reality && on="${C_GRN}已开启${C_R}" || on="${C_DIM}未开启${C_R}"
      [[ -n "$(reality_sid)" ]] && sid="已生成" || sid="${C_YEL}未生成${C_R}"
      printf '\n  %sReality%s（Xray 内核）\n' "$C_B" "$C_R"
      printf '  状态        : %s\n' "$on"
      printf '  监听        : TCP %s\n' "$(reality_port)"
      printf '  伪装目标    : %s\n' "$(reality_sni)"
      printf '  证书上限    : %s 字节（超了 Xray 直接拒绝握手）\n' "$REALITY_CERT_LIMIT"
      printf '  密钥        : %s\n' "$sid"
      printf '  shortId     : %s\n' "$(reality_sid)"
      printf '\n  %s体检当前目标：bash %s reality probe%s\n' "$C_DIM" "$APP" "$C_R"
      printf '  %s换目标：bash %s reality sni <域名>%s\n' "$C_DIM" "$APP" "$C_R" ;;
    *) err "用法：reality [status|probe [域名…]|sni <域名>]"; return 1 ;;
  esac
}

do_hy2() {
  require_root
  case "${1:-status}" in
    hop)
      local r="${2:-}"
      [[ -z "$r" ]] && { err "用法：hy2 hop 23000-27000"; return 1; }
      hy2_hop_set "$r" ;;
    ""|status) direct_show ;;
    *) err "用法：hy2 [status|hop 23000-27000]"; return 1 ;;
  esac
}

do_cert() {
  require_root
  case "${1:-show}" in
    gen)
      cert_gen "${2:-}" || return 1
      if proto_on hy2 || proto_on tuic || proto_on anytls; then sb_sync; fi
      ;;
    show|"") cert_show ;;
    *) err "用法：cert [show|gen [--force]]"; return 1 ;;
  esac
}

menu_header() {
  local st_x st_t host hop_l land_l
  if svc_active "$SVC_XRAY"; then st_x="${C_GRN}●运行${C_R}"; else st_x="${C_DIM}○停止${C_R}"; fi
  if [[ -s "$TOKEN_FILE" ]]; then
    if svc_active "$SVC_TUN"; then st_t="${C_GRN}●在线${C_R}"; else st_t="${C_YEL}○未运行${C_R}"; fi
  else
    st_t="${C_DIM}未配置${C_R}"
  fi
  host="$(node_get tunnel_host 2>/dev/null)"
  if [[ "$(node_hop_mode)" == "all" ]]; then hop_l="${C_YEL}全部${C_R}"; else hop_l="${C_DIM}关闭${C_R}"; fi
  if landing_on && [[ -n "$(landing_names)" ]]; then
    land_l="${C_GRN}$(landing_names)${C_R}"
  else
    land_l="${C_DIM}关闭${C_R}"
  fi
  printf '\n'
  printf '%s╔══════════════════════════════════════════════════╗%s\n' "$C_B$C_BLU" "$C_R"
  printf '%s║%s  argox  ·  Argo 隧道 + Xray(XHTTP) + sing-box  %s%-8s%s%s║%s\n' "$C_B$C_BLU" "$C_R$C_B" "$C_DIM" "v${VERSION}" "$C_R" "$C_B$C_BLU" "$C_R"
  printf '%s╚══════════════════════════════════════════════════╝%s\n' "$C_B$C_BLU" "$C_R"
  printf '  Xray %s   Tunnel %s   域名 %s\n' "$st_x" "$st_t" "${host:-${C_DIM}未设置${C_R}}"
  printf '  直连 %s   跳板 %s   落地 %s\n' "$(proto_label_short)" "$hop_l" "$land_l"
  printf '%s\n' "──────────────────────────────────────────────────"
}

menu_main() {
  while true; do
    menu_header
    cat <<'EOF'
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
EOF
    printf '\n    0) 退出\n'
    printf '%s\n' "──────────────────────────────────────────────────"
    printf '  %s左列＝常用动作，右列＝配置项%s\n' "$C_DIM" "$C_R"
    read -rp "  请选择: " choice
    case "${choice:-}" in
      1)  do_install ;;
      2)  do_start ;;
      3)  do_stop ;;
      4)  do_restart ;;
      5)  do_status ;;
      6)  do_logs ;;
      7)  do_update ;;
      8)  do_check ;;
      9)  do_change_uuid ;;
      10) do_upgrade ;;
      11) do_tunnel_setup ;;
      12) menu_ips ;;
      13) do_hop ;;
      14) do_direct ;;
      15) do_landing ;;
      16) show_nodes ;;
      17) do_port ;;
      18) do_sysopt ;;
      19) do_clean ;;
      20) do_uninstall ;;
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
  local B
  case "${1:-}" in
    install)   do_install ;;
    start)     do_start ;;
    stop)      do_stop ;;
    restart)   do_restart ;;
    status)    do_status ;;
    logs)      do_logs ;;
    update)    do_update ;;
    ips)       if [[ -n "${2:-}" ]]; then import_ips_url "${2:-}"
               elif [[ -n "$(node_get ips_url 2>/dev/null || true)" ]]; then import_ips_url
               else update_ips; fi ;;
    ips-url)   do_ips_url ;;
    mode)      do_mode "${2:-}" ;;
    nodes|show) show_nodes ;;
    links)     show_links ;;
    hop)       do_hop "${2:-}" "${3:-}" ;;
    landing)   shift; do_landing "$@" ;;
    direct)    do_direct "${2:-}" "${3:-}" ;;
    port)      do_port "${2:-}" "${3:-}" ;;
    reality)   shift; do_reality "$@" ;;
    hy2)       do_hy2 "${2:-}" "${3:-}" ;;
    cert)      do_cert "${2:-}" "${3:-}" ;;
    diag)      do_diag "${2:-}" ;;
    check)     do_check "${2:-}" ;;
    upgrade)   do_upgrade ;;
    sub)       gen_sub && cat "${SUBD}/argox.b64" ;;
    uninstall) do_uninstall ;;
    ""|menu)   require_root; menu_main ;;
    -h|--help|help)
      B="$(cmd_prefix)"
      cat <<EOF
argox v${VERSION} — Cloudflare Argo 隧道 + Xray 一键部署

用法：
  ${B}              进入交互菜单（推荐）
  ${B} install      直接部署
  ${B} status       查看状态
  ${B} nodes        打印订阅地址 + 二维码
  ${B} links        打印单节点链接
  ${B} sub          输出 Base64 订阅内容
  ${B} ips          从自动更新地址拉取（未设置时走 IP 源，菜单 12）
  ${B} ips <地址>    从测速结果导入（ftp(s)/http(s) 直链或本地文件路径，保序不重排）
  ${B} ips-url      设置自动更新地址（测速结果上传后的直链，设好 ips 无参即用它）
  ${B} mode         查看地址模式（domain 域名直连 / ip 优选 IP）
  ${B} mode ip      切到优选 IP 模式并重建订阅（只影响 Argo-H3/H2/H3-RH）
  ${B} mode domain  切回域名直连
  ${B} hop          出口跳板状态（菜单 13）
  ${B} hop on       全部流量走本地代理（自动探测 socks/http）
  ${B} hop off      关闭跳板，流量从 VPS 本机出口出去
  ${B} landing      住宅落地状态（菜单 15）
  ${B} landing on   给 -RH 节点挂住宅落地（需本地代理可用）
  ${B} landing off  关闭落地
  ${B} landing target h3,anytls,reality  选择落地作用入口
  ${B} landing proto socks|http  落地出口协议
  ${B} direct       直连协议状态（Hy2 / TUIC / AnyTLS / Reality，菜单 14）
  ${B} direct on all   一次开启 Hy2 + TUIC + AnyTLS + Reality（推荐）
  ${B} direct on hy2    开启 Hy2（自动装 sing-box + 自签证书）
  ${B} direct off tuic  关闭 TUIC
  ${B} port         端口一览（菜单 17）
  ${B} port sub 9000     改订阅端口（自动重建服务 + 订阅）
  ${B} port hy2 24000    改 Hy2 监听口（跳跃段另用 hy2 hop）
  ${B} port tuic 30001   改 TUIC 端口
  ${B} port anytls 8445  改 AnyTLS 端口（落地口自动跟随 −1）
  ${B} port reality 8443 改 Reality 端口
  ${B} reality       Reality 状态（伪装目标 / 端口 / 密钥）
  ${B} reality probe    体检当前伪装目标 + 内置候选（证书大小 / 握手 / 跳转）
  ${B} reality probe www.intel.com   只测指定域名，可一次给多个
  ${B} reality sni www.lovelive-anime.jp   换伪装目标（先体检，不合格拒绝写入）
  ${B} hy2 hop 23000-27000  改 Hy2 端口跳跃段（监听口自动跟随段首）
  ${B} cert         查看自签证书
  ${B} cert gen     重新生成证书（--force 强制）
  ${B} diag         cloudflared 出站诊断（DNS / TCP 7844 / 注册情况）
  ${B} diag http2   强制隧道走 TCP（UDP 7844 被封时用）
  ${B} diag auto    恢复自动选择（默认）
  ${B} check        自检：配置 / 端口 / 订阅 / 链接 / 隧道（只读）
  ${B} check -q     静默自检，只返回退出码（0=全通过）
  ${B} upgrade      补齐配置字段 + 对齐单元 + 重建订阅（不重启服务）
  ${B} uninstall    卸载

  curl -fsSL <地址> | bash     ← 不推荐，请先 curl -o 下来看一眼
EOF
      ;;
    *) err "未知命令：$1（用 --help 查看）"; exit 1 ;;
  esac
}

# ==============================================================================
#  命令入口
#  装一个 /usr/local/bin/argox 的壳，内容是 exec bash <脚本本体> "$@"。
#  这样装完只需敲 argox（或 argox check / argox port sub 9000），不用记路径。
#  用壳而不是副本：脚本更新后命令自动跟着新，不会出现两份代码不一致。
#  失败一律静默降级 —— 命令入口只是便利，不影响任何功能。
# ==============================================================================

# 提示里该显示哪个命令：装了入口显示 argox，没装则回退到 bash <脚本>
cmd_prefix() {
  if [[ -x "${ARGOX_BIN:-$CMDBIN}" ]]; then
    printf 'argox'
  else
    printf 'bash %s' "${0:-argox.sh}"
  fi
}

install_cmd() {
  local src="${1:-${BASH_SOURCE[0]:-$0}}"
  case "$src" in
    /dev/fd/*|/proc/self/fd/*|/dev/stdin|-) return 1 ;;
  esac
  [[ -f "$src" ]] || return 1

  local tgt="${ARGOX_DST:-$SELF_PATH}"
  local bin="${ARGOX_BIN:-$CMDBIN}"

  # 脚本本体放在别处时（手动下载到 /tmp 之类）先落到固定位置，
  # 否则命令入口指向一个随时会被清理的路径。
  if [[ "$src" != "$tgt" ]]; then
    if ! install -m 0755 "$src" "$tgt" 2>/dev/null; then
      warn "无法写入 ${tgt}，命令入口未安装"
      return 1
    fi
  fi

  local tmp; tmp="$(mktemp)" || return 1
  {
    printf '#!/bin/sh\n'
    printf '# argox 命令入口（由 argox.sh 自动生成，请勿手工编辑）\n'
    printf 'exec bash "%s" "$@"\n' "$tgt"
  } > "$tmp" || { rm -f "$tmp"; return 1; }

  chmod 0755 "$tmp" 2>/dev/null
  mkdir -p "$(dirname "$bin")" 2>/dev/null || { rm -f "$tmp"; return 1; }
  if mv -f "$tmp" "$bin" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  warn "命令入口写入失败（${bin}），仍可用 bash ${tgt}"
  return 1
}

remove_cmd() {
  local bin="${ARGOX_BIN:-$CMDBIN}"
  [[ -f "$bin" ]] || return 0
  grep -q 'argox 命令入口' "$bin" 2>/dev/null || return 0   # 不是我们生成的，不碰
  rm -f "$bin" 2>/dev/null
}

# ==============================================================================
#  自落地
#  用 bash <(curl ...) 运行时 $0 是 /dev/fd/NN（一次性管道），脚本里所有
#  「bash $0 xxx」提示都会指向失效路径，重跑也没有本地副本。这里把自己存成
#  $SELF_PATH 再重新执行一次，之后的 $0 就是真实文件。
#  本地副本版本与当前不一致时不复用它，重新取一份，避免跑到旧版。
#  落地失败不影响任何功能，只是提示里的路径不准。
# ==============================================================================
self_relocate() {
  local src="${BASH_SOURCE[0]:-$0}"
  case "$src" in
    /dev/fd/*|/proc/self/fd/*|/dev/stdin|/dev/null|-) ;;
    *) return 0 ;;                     # 正常文件运行，不用管
  esac
  [[ -n "${ARGOX_RELOCATED:-}" ]] && return 0
  [[ ${EUID:-$(id -u)} -eq 0 ]] || return 0   # 非 root 落地没意义，交给 require_root 报错

  local dst="${ARGOX_DST:-$SELF_PATH}" have=""
  [[ -s "$dst" ]] && have="$(sed -n 's/^VERSION="\([^"]*\)".*/\1/p' "$dst" 2>/dev/null | head -1)"
  if [[ -n "$have" && "$have" == "$VERSION" ]]; then
    export ARGOX_RELOCATED=1
    ARGOX_DST="$dst" install_cmd "$dst" >/dev/null 2>&1 || true
    exec bash "$dst" "$@"
  fi

  if curl -fsSL --max-time 20 "$RAW_URL" -o "$dst" 2>/dev/null && [[ -s "$dst" ]] \
     && grep -q '^APP="argox"' "$dst" 2>/dev/null; then
    chmod 755 "$dst" 2>/dev/null || true
    export ARGOX_RELOCATED=1
    ARGOX_DST="$dst" install_cmd "$dst" >/dev/null 2>&1 || true   # 顺手装好 argox 命令
    exec bash "$dst" "$@"
  fi

  warn "自身落地失败（网络或权限），本次用临时副本运行：提示里的 bash $0 路径不可用"
  [[ -n "$have" ]] && info "本地副本 ${dst} 是 v${have}，当前是 v${VERSION}，建议手动更新"
}

self_relocate "$@"
main "$@"

