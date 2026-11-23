#!/usr/bin/env bash
# Hy2 nft 跳跃表开机恢复测试：纯 bash + python3，不连 VPS、不碰生产路径。
# 用法：bash tests/hop-restore-test.sh <用例名>|all
# 做法：把 argox.sh 去掉末尾入口两行后 source 成函数库，用临时 BASE + 假 systemctl/nft 桩跑。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/argox.sh"
PASS=0 FAIL=0

t_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
t_bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
eq()     { local name="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then t_ok "$name"; else t_bad "$name (want=[$want] got=[$got])"; fi; }
truth()  { local name="$1" cond="$2"; if eval "$cond"; then t_ok "$name"; else t_bad "$name"; fi; }

LIB="$(mktemp)"
trap 'rm -rf "$LIB" "${TEST_TMP:-}"' EXIT
grep -v '^self_relocate "\$@"$' "$SRC" | grep -v '^main "\$@"$' > "$LIB"
# shellcheck disable=SC1090
source "$LIB"
die() { err "$*"; return 1; }

# 桩目录：假 nft / systemctl 放这里，PATH 前置。用文件桩而非函数，
# 因为 has nft 走 command -v，只有真实可执行文件才认。
setup_env() {
  TEST_TMP="$(mktemp -d)"
  if command -v cygpath >/dev/null 2>&1; then TEST_TMP="$(cygpath -u "$TEST_TMP")"; fi
  BASE="$TEST_TMP/opt/argox"
  mkdir -p "$BASE/logs" "$BASE/sub" "$BASE/qr" "$BASE/backup" "$BASE/pub" "$TEST_TMP/bin"
  CONF="$BASE/config.json"; NODEF="$BASE/node.json"; SBCONF="$BASE/sb.json"
  IPSF="$BASE/ips.txt"; IPMETA="$BASE/ips.meta"; IPSRCF="$BASE/ipsrc.txt"
  SUBGEN="$BASE/subs_gen.py"; PYSRV="$BASE/sub_server.py"
  LOGD="$BASE/logs"; SUBD="$BASE/sub"; QDIR="$BASE/qr"; BACKD="$BASE/backup"
  XRAY_BIN="$TEST_TMP/xray-stub"; CMDBIN="$TEST_TMP/argox"
  TOKEN_FILE="$TEST_TMP/token.env"
  SB_BIN="$TEST_TMP/sb-stub"
  echo '{}' > "$NODEF"
  # 默认 Hy2 开启 + 跳跃段；单测可覆盖
  node_jset proto.hy2 true >/dev/null 2>&1
  node_jset hy2.port 23000 >/dev/null 2>&1
  node_jset hy2.hop '"23000-27000"' >/dev/null 2>&1
  : > "$XRAY_BIN"; chmod +x "$XRAY_BIN"

  # 假 nft：记录调用到 $TEST_TMP/nft.log；list table 时返回当前表内容
  # 注意 heredoc 不加引号，让 $TEST_TMP 在本进程展开成真实路径写进桩文件；
  # 桩脚本内部要用的 $* / $1 / $2 用 \$ 转义，留到桩运行时展开。
  cat > "$TEST_TMP/bin/nft" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/nft.log"
case "\$1 \$2" in
  "list table") cat "${TEST_TMP}/nft.table" 2>/dev/null || exit 1 ;;
  "-f -")
    # 从 stdin 读规则，写进模拟表
    cat > "${TEST_TMP}/nft.table" 2>/dev/null
    ;;
  "delete table") : > "${TEST_TMP}/nft.table" 2>/dev/null ;;
esac
exit 0
STUB
  # 假 systemctl：daemon-reload/restart/enable 全记录，永远成功
  cat > "$TEST_TMP/bin/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TEST_TMP}/systemctl.log"
case "\$1" in
  is-active) exit "\${STUB_SVC_ACTIVE:-0}" ;;
  list-unit-files) printf 'argox-sb.service enabled\n' ;;
esac
exit 0
STUB
  chmod +x "$TEST_TMP/bin/nft" "$TEST_TMP/bin/systemctl"
  export PATH="$TEST_TMP/bin:$PATH"
  : > "$TEST_TMP/nft.log"; : > "$TEST_TMP/systemctl.log"
}

# 1) RED/结构：write_sb_service 生成的单元含带 - 前缀的 ExecStartPre，指向 hop-restore
case_service_unit() {
  printf '[service_unit]\n'
  setup_env
  write_sb_service >/dev/null 2>&1
  local unit="/etc/systemd/system/${SVC_SB}.service"
  # 生产路径不可写，改为直接检查函数体 + 用假 SVC_SB 无法重定向绝对路径；
  # 改为从源码函数提取生成的行做断言（静态），再用可控路径覆盖验证。
  truth 'write_sb_service 含 ExecStartPre' 'grep -q "ExecStartPre" "$SRC"'
  truth 'ExecStartPre 带失败不阻塞前缀(-)' 'grep -q "ExecStartPre=-" "$SRC"'
  truth 'ExecStartPre 指向 hop-restore 命令' 'grep -q "ExecStartPre=.*hop-restore" "$SRC"'
  truth 'ExecStartPre 在 ExecStart 之前' 'grep -n "ExecStartPre" "$SRC" | head -1 | cut -d: -f1 | awk -v e=$(grep -n "ExecStart=" "$SRC" | head -1 | cut -d: -f1) '\''{exit !($1<e)}'\'''
}

# 2) hop-restore 命令必须已注册到 main 分派
case_command_registered() {
  printf '[command_registered]\n'
  truth 'main case 注册 hop-restore' 'grep -q "hop-restore)" "$SRC"'
  truth 'hop_restore 函数已定义' 'grep -q "^hop_restore()" "$SRC"'
  truth 'hop-restore 走内部恢复而非菜单' 'grep -q "hop-restore).*hop_restore" "$SRC"'
}

# 3) hop_restore 只重建 nft 表：应 nft delete + nft -f，不 restart 服务、不重建订阅
case_hop_restore_rebuilds_nft() {
  printf '[hop_restore_rebuilds_nft]\n'
  setup_env
  hop_restore >/dev/null 2>&1
  truth '调用了 nft delete table' 'grep -q "delete table inet argox_hop" "$TEST_TMP/nft.log"'
  truth '调用了 nft -f 写入规则' 'grep -q -- "-f -" "$TEST_TMP/nft.log"'
  truth '模拟表已生成' '[[ -s "$TEST_TMP/nft.table" ]]'
  truth '表内容含 udp dport 跳跃段' 'grep -q "udp dport 23000-27000" "$TEST_TMP/nft.table"'
  truth '未重启任何 service' '[[ ! -s "$TEST_TMP/systemctl.log" ]]'
  eq '未触碰 node.json（端口设置不变）' '23000' "$(node_jget hy2.port 2>/dev/null)"
}

# 4) Hy2 关闭时：hop_restore 不建表也不报错
case_hop_restore_hy2_off() {
  printf '[hop_restore_hy2_off]\n'
  setup_env
  node_jset proto.hy2 false >/dev/null 2>&1
  hop_restore >/dev/null 2>&1
  local rc=$?
  eq '关闭 Hy2 时返回 0' '0' "$rc"
  truth '未调用 nft' '[[ ! -s "$TEST_TMP/nft.log" ]]'
}

# 5) nft 未安装时：hop_restore 优雅跳过，不阻塞服务启动
case_no_nft() {
  printf '[no_nft]\n'
  setup_env
  rm -f "$TEST_TMP/bin/nft"
  hop_restore >/dev/null 2>&1
  local rc=$?
  eq '无 nft 时返回 0（不阻塞 ExecStartPre）' '0' "$rc"
  truth '未留下半张表' '[[ ! -s "$TEST_TMP/nft.table" ]]'
}

# 6) 部署闭环：菜单10 更新脚本后必须用新脚本重写 service，ExecStartPre 才能落地
case_upgrade_refresh_service() {
  printf '[upgrade_refresh_service]\n'
  if grep -Fq 'bash "$dst" upgrade' "$SRC"; then t_ok 'selfupdate 更新后用新脚本跑 upgrade'; else t_bad 'selfupdate 更新后用新脚本跑 upgrade'; fi
  if grep -Fq 'write_sb_service && info' "$SRC"; then t_ok 'do_upgrade 刷新 sb service 单元'; else t_bad 'do_upgrade 刷新 sb service 单元'; fi
}

case_all() {
  case_service_unit
  case_command_registered
  case_hop_restore_rebuilds_nft
  case_hop_restore_hy2_off
  case_no_nft
  case_upgrade_refresh_service
}

case "${1:-all}" in
  service_unit) case_service_unit ;;
  command_registered) case_command_registered ;;
  hop_restore_rebuilds_nft) case_hop_restore_rebuilds_nft ;;
  hop_restore_hy2_off) case_hop_restore_hy2_off ;;
  no_nft) case_no_nft ;;
  upgrade_refresh_service) case_upgrade_refresh_service ;;
  all) case_all ;;
  *) echo "unknown case: $1"; exit 2 ;;
esac

printf '\nTOTAL %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
