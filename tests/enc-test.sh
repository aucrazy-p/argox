#!/usr/bin/env bash
# Vless-XHTTP-enc 测试：纯 bash + python3，不连 VPS、不碰生产路径。
# 用法：bash tests/enc-test.sh <用例名>|all
# 做法：把 argox.sh 去掉末尾入口两行后 source 成函数库，用临时 BASE + 假 XRAY_BIN 桩跑。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/argox.sh"
PASS=0 FAIL=0

# ---- 断言（用 t_ 前缀，避免被 argox.sh 自带的 ok/err 覆盖）----
t_ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
t_bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
eq()   { local name="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then t_ok "$name"; else t_bad "$name (want=[$want] got=[$got])"; fi; }
truth() { local name="$1" cond="$2"; if eval "$cond"; then t_ok "$name"; else t_bad "$name"; fi; }

# ---- 加载函数库（剥离入口两行，避免 self_relocate/main 执行）----
LIB="$(mktemp)"
trap 'rm -rf "$LIB" "${TEST_TMP:-}"' EXIT
grep -v '^self_relocate "\$@"$' "$SRC" | grep -v '^main "\$@"$' > "$LIB"
# shellcheck disable=SC1090
source "$LIB"
# argox.sh 定义了 die() 会 exit，测试里改为返回，避免单个断言中断整组
die() { err "$*"; return 1; }

# ---- 临时环境 ----
setup_env() {
  TEST_TMP="$(mktemp -d)"
  # 转成 POSIX 路径：mktemp -d 在 Git Bash 下返回 Windows 盘符路径，
  # 写进 JSON 配置会产生非法反斜杠转义；用 cygpath -u 转回 /tmp/...
  if command -v cygpath >/dev/null 2>&1; then TEST_TMP="$(cygpath -u "$TEST_TMP")"; fi
  BASE="$TEST_TMP/opt/argox"
  mkdir -p "$BASE/logs" "$BASE/sub" "$BASE/qr" "$BASE/backup" "$BASE/pub"
  CONF="$BASE/config.json"
  NODEF="$BASE/node.json"
  IPSF="$BASE/ips.txt"
  IPMETA="$BASE/ips.meta"
  IPSRCF="$BASE/ipsrc.txt"
  SBCONF="$BASE/sb.json"
  SUBGEN="$BASE/subs_gen.py"
  PYSRV="$BASE/sub_server.py"
  LOGD="$BASE/logs"
  SUBD="$BASE/sub"
  QDIR="$BASE/qr"
  BACKD="$BASE/backup"
  SUBPUB="$BASE/pub"
  : > "$IPSF"
  XRAY_BIN="$TEST_TMP/xray-stub"
  CMDBIN="$TEST_TMP/argox"
  TOKEN_FILE="$TEST_TMP/token.env"
  echo '{}' > "$NODEF"

  # 假 Xray：version / vlessenc / run -test -c
  cat > "$XRAY_BIN" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo "Xray ${STUB_XRAY_VER:-25.9.5}" ;;
  vlessenc)
    if [[ "${STUB_ENC_FORMAT:-labeled}" == "labeled" ]]; then
      echo "Decryption string:"
      echo "mlkem768x25519plus.native.600s.100-111-1111.75-0-111.50-0-3333.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
      echo "Encryption string:"
      echo "mlkem768x25519plus.native.0rtt.100-111-1111.75-0-111.50-0-3333.CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC.DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
    elif [[ "${STUB_ENC_FORMAT}" == "inline" ]]; then
      echo "Decryption: mlkem768x25519plus.native.600s.100-111-1111.75-0-111.50-0-3333.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
      echo "Encryption: mlkem768x25519plus.native.0rtt.100-111-1111.75-0-111.50-0-3333.CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC.DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
    elif [[ "${STUB_ENC_FORMAT}" == "json" ]]; then
      # 真实 xray vlessenc 可能的 JSON 输出：串后紧跟 ",  —— 曾导致写入失败
      echo '{'
      echo '  "decryption": "mlkem768x25519plus.native.600s.100-111-1111.75-0-111.50-0-3333.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",'
      echo '  "encryption": "mlkem768x25519plus.native.0rtt.100-111-1111.75-0-111.50-0-3333.CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC.DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"'
      echo '}'
    else
      echo "mlkem768x25519plus.native.600s.100-111-1111.75-0-111.50-0-3333.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
      echo "mlkem768x25519plus.native.0rtt.100-111-1111.75-0-111.50-0-3333.CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC.DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
    fi
    ;;
  run) exit 0 ;;
esac
STUB
  chmod +x "$XRAY_BIN"
}

# =====================================================================
case_version() {
  printf '[version]\n'
  truth 'VERSION=2.12.0' 'grep -q "^VERSION=\"2.12.0\"" "$SRC"'
  truth 'ENC_MIN_XRAY defined' 'grep -q "^ENC_MIN_XRAY=\"25.9.5\"" "$SRC"'
}

case_enc_keys_labeled() {
  printf '[enc_keys_labeled]\n'
  setup_env
  ENC_CHANGED=0
  enc_keys; local rc=$?
  eq 'enc_keys returns 0' 0 "$rc"
  truth 'decryption set & prefixed' '[[ "$(node_jget enc.decryption)" == mlkem768x25519plus.* ]]'
  truth 'encryption set & prefixed' '[[ "$(node_jget enc.encryption)" == mlkem768x25519plus.* ]]'
  truth 'dec and enc differ' '[[ "$(node_jget enc.decryption)" != "$(node_jget enc.encryption)" ]]'
  eq 'ENC_CHANGED on first gen' 1 "$ENC_CHANGED"
  local d1; d1="$(node_jget enc.decryption)"
  ENC_CHANGED=0
  enc_keys
  eq 'ENC_CHANGED clear on reuse' 0 "$ENC_CHANGED"
  eq 'key stable on reuse' "$d1" "$(node_jget enc.decryption)"
}

case_enc_keys_plain() {
  printf '[enc_keys_plain]\n'
  # 无标签裸串
  setup_env
  export STUB_ENC_FORMAT=plain
  ENC_CHANGED=0
  enc_keys; local rc=$?
  eq 'plain-format enc_keys returns 0' 0 "$rc"
  truth 'plain-format decryption prefixed' '[[ "$(node_jget enc.decryption)" == mlkem768x25519plus.* ]]'
  truth 'plain-format encryption prefixed' '[[ "$(node_jget enc.encryption)" == mlkem768x25519plus.* ]]'
  truth 'plain-format dec!=enc' '[[ "$(node_jget enc.decryption)" != "$(node_jget enc.encryption)" ]]'
  # 同行标签格式（Decryption: <串>）
  setup_env
  export STUB_ENC_FORMAT=inline
  ENC_CHANGED=0
  enc_keys; rc=$?
  eq 'inline-format enc_keys returns 0' 0 "$rc"
  truth 'inline-format decryption correct (A key)' '[[ "$(node_jget enc.decryption)" == *AAAAAAAA* ]]'
  truth 'inline-format encryption correct (C key)' '[[ "$(node_jget enc.encryption)" == *CCCCCCCC* ]]'
}

case_enc_keys_json() {
  printf '[enc_keys_json]\n'
  # JSON 输出：串尾带 ", 不能污染密钥，必须剥掉后再落盘
  setup_env
  export STUB_ENC_FORMAT=json
  ENC_CHANGED=0
  enc_keys; local rc=$?
  eq 'json-format enc_keys returns 0' 0 "$rc"
  local d e
  d="$(node_jget enc.decryption)"; e="$(node_jget enc.encryption)"
  truth 'json-format decryption is clean A' '[[ "$d" == *AAAAAAAA* && "$d" != *\"* && "$d" != *,* ]]'
  truth 'json-format encryption is clean C' '[[ "$e" == *CCCCCCCC* && "$e" != *\"* && "$e" != *,* ]]'
  truth 'json-format dec!=enc' '[[ "$(node_jget enc.decryption)" != "$(node_jget enc.encryption)" ]]'
}

case_enc_keys_fail() {
  printf '[enc_keys_fail]\n'
  # 版本不足： refusal
  setup_env
  export STUB_XRAY_VER=25.8.0
  ENC_CHANGED=0
  local out; out="$(enc_keys 2>&1)"; local rc=$?
  truth 'low version fails' '[[ $rc -ne 0 ]]'
  truth 'low version hints argox update' '[[ "$out" == *"argox update"* ]]'
  truth 'low version wrote no key' '[[ -z "$(node_jget enc.decryption)" && -z "$(node_jget enc.encryption)" ]]'
  # 解析失败：桩只输出一行
  setup_env
  cat > "$XRAY_BIN" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo "Xray 25.9.5" ;;
  vlessenc) echo "mlkem768x25519plus.native.600s.AAAA.BBBB" ;;
  run) exit 0 ;;
esac
STUB
  chmod +x "$XRAY_BIN"
  ENC_CHANGED=0
  enc_keys >/dev/null 2>&1; rc=$?
  truth 'bad parse fails' '[[ $rc -ne 0 ]]'
  truth 'bad parse wrote no half key' '[[ -z "$(node_jget enc.decryption)" && -z "$(node_jget enc.encryption)" ]]'
}

case_xhttp_decryption() {
  printf '[xhttp_decryption]\n'
  setup_env
  # 先生成密钥，再写配置
  ENC_CHANGED=0
  enc_keys >/dev/null 2>&1
  local dec; dec="$(node_jget enc.decryption)"
  write_xray_config 'uuid-test' '/p' '/w' >/dev/null 2>&1; local rc=$?
  eq 'write_xray_config returns 0' 0 "$rc"
  local got
  got="$(cd "$BASE" && python3 -c 'import json;d=json.load(open("config.json"));print(next(i["settings"]["decryption"] for i in d["inbounds"] if i["tag"]=="argo-xhttp"))' 2>/dev/null)"
  eq 'argo-xhttp decryption == enc key' "$dec" "$got"
  truth 'no decryption:none in argo-xhttp' '[[ "$got" != "none" ]]'
  local rdec; rdec="$(cd "$BASE" && python3 -c 'import json;d=json.load(open("config.json"));print([i for i in d["inbounds"] if i["tag"]=="reality"][0]["settings"]["decryption"] if any(i["tag"]=="reality" for i in d["inbounds"]) else "ABSENT")' 2>/dev/null)"
  truth 'reality inbound stays none/absent' '[[ "$rdec" == "none" || "$rdec" == "ABSENT" ]]'

  # 清空密钥后必须失败，且不写成明文 none
  node_jset enc.decryption '""' >/dev/null 2>&1
  write_xray_config 'uuid-test' '/p' '/w' >/dev/null 2>&1; rc=$?
  truth 'empty decryption fails' '[[ $rc -ne 0 ]]'
  got="$(cd "$BASE" && python3 -c 'import json;d=json.load(open("config.json"));print(next(i["settings"]["decryption"] for i in d["inbounds"] if i["tag"]=="argo-xhttp"))' 2>/dev/null)"
  truth 'no plaintext none written on failure' '[[ "$got" != "none" ]]'
}

setup_links_env() {
  setup_env
  ENC_CHANGED=0
  enc_keys >/dev/null 2>&1
  node_set uuid '11111111-2222-3333-4444-555555555555'
  node_set tunnel_host 'argo.example.com'
  node_set path_xhttp '/secret'
  node_jset 'proto.argo' 'true' >/dev/null 2>&1
  node_jset 'landing.enabled' 'false' >/dev/null 2>&1
  : > "$IPSF"
}

case_links_encryption() {
  printf '[links_encryption]\n'
  setup_links_env
  local enc; enc="$(node_jget enc.encryption)"
  local links; links="$(build_links 2>/dev/null)"
  truth 'links non-empty' '[[ -n "$links" ]]'
  local xh; xh="$(printf '%s\n' "$links" | grep 'type=xhttp' || true)"
  truth 'has xhttp links' '[[ -n "$xh" ]]'
  truth 'all xhttp carry enc encryption' '[[ $(printf "%s\n" "$xh" | grep -c "encryption=$enc") -eq $(printf "%s\n" "$xh" | grep -c .) ]]'
  truth 'no encryption=none in xhttp' '! grep -q "encryption=none" <<< "$xh"'
  truth 'no flow in xhttp' '! grep -q "flow=" <<< "$xh"'
  # 落地 -RH 的 h3/h2 同样带 enc
  node_jset 'landing.enabled' 'true' >/dev/null 2>&1
  node_jset 'landing.uuid' '"99999999-8888-7777-6666-555555555555"' >/dev/null 2>&1
  node_jset 'landing.target' '["h3","h2"]' >/dev/null 2>&1
  local rh; rh="$(build_links 2>/dev/null | grep '\-RH' || true)"
  truth 'RH links present' '[[ -n "$rh" ]]'
  local rhx; rhx="$(printf '%s\n' "$rh" | grep 'type=xhttp' || true)"
  truth 'RH xhttp carries enc encryption' '[[ -n "$rhx" ]] && [[ $(printf "%s\n" "$rhx" | grep -c "encryption=$enc") -eq $(printf "%s\n" "$rhx" | grep -c .) ]]'
}

case_clash_encryption() {
  printf '[clash_encryption]\n'
  setup_env
  local enc; enc="$(node_jget enc.encryption 2>/dev/null)"
  [[ -z "$enc" ]] && { ENC_CHANGED=0; enc_keys >/dev/null 2>&1; enc="$(node_jget enc.encryption)"; }
  local link="vless://uuid-test@argo.example.com:443?encryption=${enc}&security=tls&sni=argo.example.com&fp=chrome&alpn=h3&type=xhttp&path=%2Fp&host=argo.example.com&mode=auto#Argo-H3"
  printf '%s\n' "$link" > "$BASE/links.txt"
  write_subs_gen
  (cd "$BASE" && python3 subs_gen.py links.txt out.yaml out.json >/dev/null 2>&1)
  truth 'clash yaml generated' '[[ -s "$BASE/out.yaml" ]]'
  truth 'clash has encryption field' 'grep -q "encryption: *\"$enc\"" "$BASE/out.yaml"'
  truth 'singbox skips xhttp (no json or no node)' '[[ ! -s "$BASE/out.json" ]] || ! grep -q "Argo-H3" "$BASE/out.json"'
  # none 值不应输出 encryption 字段
  printf '%s\n' "vless://uuid-test@argo.example.com:443?encryption=none&security=tls&sni=argo.example.com&fp=chrome&alpn=h2&type=xhttp&path=%2Fp&host=argo.example.com&mode=auto#Argo-H2" > "$BASE/links.txt"
  (cd "$BASE" && python3 subs_gen.py links.txt out2.yaml out2.json >/dev/null 2>&1)
  truth 'out2.yaml has node (not empty)' 'grep -q "Argo-H2" "$BASE/out2.yaml"'
  truth 'encryption=none not emitted as field' '! grep -q "encryption:" "$BASE/out2.yaml"'
}

case_cmd_surface() {
  printf '[cmd_surface]\n'
  truth 'main case has enc branch' 'grep -qE "^[[:space:]]+enc\)" "$SRC"'
  truth 'help mentions enc regen' 'grep -q "enc regen" "$SRC"'
  truth 'no enc on/off switch' '! grep -qE "enc (on|off)" "$SRC"'
  truth 'no clash_view field' '! grep -q "clash_view" "$SRC"'
  truth 'no ARGOX_ENC_CLASH' '! grep -q "ARGOX_ENC_CLASH" "$SRC"'
  truth 'enc_show defined' 'grep -q "^enc_show()" "$SRC"'
  truth 'enc_regen defined' 'grep -q "^enc_regen()" "$SRC"'
  # 修复1：enc case 用显式 if，不用 && ||（避免 regen 失败被 enc_show 吞）
  truth 'enc case uses explicit if' 'grep -q "enc)       shift; if \[\[" "$SRC"'
  truth 'enc case no && || trap' '! grep -q "enc)       shift; \[\[.*&& enc_regen || enc_show" "$SRC"'
  # 修复2：regen 备份旧密钥（失败可回滚）
  truth 'regen backs up old keys' 'grep -q "old_d=\\\"\\\$(node_jget enc.decryption" "$SRC" && grep -q "已恢复旧密钥" "$SRC"'
}

case_migration_wiring() {
  printf '[migration_wiring]\n'
  # 安装：heredoc 有 enc 空对象；install_xray 后有 enc_keys 调用；配置写入前
  truth 'install heredoc has enc object' 'grep -q "\"enc\".*\"decryption\": \"\".*\"encryption\": \"\"" "$SRC"'
  truth 'install calls enc_keys after install_xray' 'grep -q "install_xray || die \"Xray 安装失败\"" "$SRC" && grep -q "enc_keys || die" "$SRC"'
  # 升级：Python defaults 有 enc；enc_keys 在 write_xray_config 前；ENC_CHANGED 用于重启
  truth 'upgrade defaults has enc' 'grep -q "\"enc\": *{\"decryption\": *\"\", *\"encryption\": *\"\"}" "$SRC"'
  truth 'upgrade checks ENC_CHANGED' 'grep -q "ENC_CHANGED" "$SRC"'
  truth 'upgrade has MIG_ENC reflag' 'grep -q "MIG_ENC" "$SRC"'
  truth 'upgrade hints resubscribe' 'grep -q "所有客户端需重新拉取订阅" "$SRC"'
  # 修复3：重启失败标志 + 跳过订阅重建
  truth 'restart failure flag defined' 'grep -q "ENC_RESTART_FAIL=0" "$SRC"'
  truth 'restart failure skips gen_sub' 'grep -q "已跳过订阅重建" "$SRC"'
  # 修复4：MIG_ENC 提示独立于 elif 链
  truth 'MIG_ENC hint independent of elif' 'grep -q "enc 的订阅失效提示独立输出" "$SRC"'
}

case_migration_idempotent() {
  printf '[migration_idempotent]\n'
  setup_env
  # 模拟老机器：node.json 有其它字段但无 enc（Python defaults 会补，这里直接给空 enc）
  node_jset 'proto.argo' 'true' >/dev/null 2>&1
  node_jset 'enc' '{"decryption":"","encryption":""}' >/dev/null 2>&1

  ENC_CHANGED=0
  enc_keys >/dev/null 2>&1
  local d1 e1; d1="$(node_jget enc.decryption)"; e1="$(node_jget enc.encryption)"
  eq 'first pass marks changed' 1 "$ENC_CHANGED"
  truth 'first pass generated keys' '[[ -n "$d1" && -n "$e1" ]]'

  # 第二次：模拟 upgrade 幂等路径
  ENC_CHANGED=0
  enc_keys >/dev/null 2>&1
  eq 'second pass not changed' 0 "$ENC_CHANGED"
  eq 'second pass keeps decryption' "$d1" "$(node_jget enc.decryption)"
  eq 'second pass keeps encryption' "$e1" "$(node_jget enc.encryption)"
  # ENC_CHANGED=0 ⇒ upgrade 不会进入重启分支
  truth 'no restart when not changed' '[[ $ENC_CHANGED -eq 0 ]]'
}

case_check_consistency() {
  printf '[check_consistency]\n'
  setup_env
  ENC_CHANGED=0
  enc_keys >/dev/null 2>&1
  node_set uuid 'u'; node_set tunnel_host 'h'; node_set path_xhttp '/p'
  write_xray_config 'u' '/p' '/w' >/dev/null 2>&1

  # 一致：enc_check 不产生 ck_err
  CK_FAIL=0; CK_WARN=0; CK_QUIET=1
  enc_check
  eq 'consistent: no enc error' 0 "$CK_FAIL"

  # 不一致：config 的 decryption 被改成 none → ck_err
  (cd "$BASE" && python3 -c 'import json;d=json.load(open("config.json"));[i["settings"].__setitem__("decryption","none") for i in d["inbounds"] if i["tag"]=="argo-xhttp"];json.dump(d,open("config.json","w"))')
  CK_FAIL=0; CK_WARN=0
  enc_check
  truth 'mismatch decryption flagged' '[[ $CK_FAIL -gt 0 ]]'

  # 链接 encryption 不一致：构造带错误加密串的链接
  CK_FAIL=0; CK_WARN=0
  enc_link_check 'vless://u@h:443?encryption=WRONG&type=xhttp#x'
  truth 'mismatch link encryption flagged' '[[ $CK_FAIL -gt 0 ]]'
  CK_FAIL=0
  local enc; enc="$(node_jget enc.encryption)"
  enc_link_check "vless://u@h:443?encryption=$enc&type=xhttp#x"
  eq 'matching link encryption ok' 0 "$CK_FAIL"
  # 非 xhttp 链接（Reality 的 encryption=none）不应被误报
  CK_FAIL=0
  enc_link_check 'vless://u@h:443?encryption=none&security=reality&type=tcp#x'
  eq 'reality none not flagged' 0 "$CK_FAIL"
}

case_all() {
  # 每个用例在独立子进程跑，避免 setup_env 的全局状态（BASE/NODEF/TEST_TMP/CK_*）互相污染。
  local total_p=0 total_f=0 c line raw rc p f
  for c in version enc_keys_labeled enc_keys_plain enc_keys_json enc_keys_fail xhttp_decryption links_encryption clash_encryption cmd_surface migration_wiring migration_idempotent check_consistency; do
    raw="$(bash "$0" "$c" 2>&1)"; rc=$?
    line="$(printf '%s\n' "$raw" | grep -v 'safe-delete' | tail -1)"
    if [[ $rc -ne 0 ]] || [[ ! "$line" =~ ^===\ [0-9]+\ passed,\ [0-9]+\ failed\ ===$ ]]; then
      printf '%-22s CRASH/NO-SUMMARY (rc=%s, last=[%s])\n' "$c" "$rc" "$line"
      total_f=$((total_f + 1)); continue
    fi
    printf '%-22s %s\n' "$c" "$line"
    p="$(printf '%s' "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')"
    f="$(printf '%s' "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')"
    total_p=$((total_p + ${p:-0})); total_f=$((total_f + ${f:-0}))
  done
  printf '\n=== TOTAL %d passed, %d failed ===\n' "$total_p" "$total_f"
  [[ $total_f -eq 0 ]]
}

main_case="${1:-all}"
case "$main_case" in
  all) case_all ;;
  version) case_version ;;
  xhttp_decryption) case_xhttp_decryption ;;
  links_encryption) case_links_encryption ;;
  clash_encryption) case_clash_encryption ;;
  cmd_surface) case_cmd_surface ;;
  migration_wiring) case_migration_wiring ;;
  migration_idempotent) case_migration_idempotent ;;
  check_consistency) case_check_consistency ;;
  enc_keys_labeled) case_enc_keys_labeled ;;
  enc_keys_plain) case_enc_keys_plain ;;
  enc_keys_json) case_enc_keys_json ;;
  enc_keys_fail) case_enc_keys_fail ;;
  *) echo "unknown case: $main_case" >&2; exit 2 ;;
esac
CASE_RC=$?

if [[ "$main_case" == "all" ]]; then
  # case_all 已汇总并自行判定退出码，父进程不重复打印计数
  exit "$CASE_RC"
fi
printf '\n=== %d passed, %d failed ===\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
