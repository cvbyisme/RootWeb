#!/system/bin/sh
# /cgi-bin/su.sh —— Root 权限管理（APatch 超级用户列表）
#
# 数据源：/data/adb/ap/package_config（CSV，表头 pkg,exclude,allow,uid,to_uid,sctx）
#   allow   = 1 表示已授权 root，0 表示拒绝
#   exclude = 1 表示排除（denylist）
#
# GET  ?token=xxx
#       → 返回授权列表（含应用名/图标/uid，用 pm 补全）
# POST ?token=xxx&action=grant&pkg=com.xxx     → 授权（allow=1）
# POST ?token=xxx&action=revoke&pkg=com.xxx    → 撤销（allow=0）
# POST ?token=xxx&action=exclude&pkg=com.xxx   → 加入排除
# POST ?token=xxx&action=unextrude...          （exclude=0，撤销排除）
# 写操作默认在改动后重启 apd（apd2sync 参数可强制）
#
. "$(dirname "$0")/_lib.sh"

RW_PKGCFG="${RW_PKGCFG:-/data/adb/ap/package_config}"

rw_check_auth; _auth=$?
if [ "$_auth" = "2" ]; then
  json_header
  printf '{"ok":false,"error":"token not configured"}\n'
  exit 0
elif [ "$_auth" != "0" ]; then
  json_header
  printf '{"ok":false,"error":"unauthorised"}\n'
  exit 0
fi

_param() {
  printf '%s' "$QUERY_STRING" | bb awk -F'&' -v k="$1" '{
    for(i=1;i<=NF;i++){ if($i ~ ("^"k"=")){ sub("^"k"=","",$i); print $i; exit } }
  }'
}

_action=$(_param action)
_pkg=$(_param pkg)
_restart=$(_param restart)   # 默认 1（改后重启 apd）

# 包名合法性校验（防注入/路径穿越）
is_pkg() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# 用 pm 查应用名（可能因权限/未安装返回空）
app_label() {
  _p="$1"
  _l=""                                 # 标签
  # pm list packages 里找不到说明可能已卸载，仍显示包名
  if command -v /system/bin/pm >/dev/null 2>&1; then
    _l=$(/system/bin/pm list packages -U 2>/dev/null | bb grep "package:$_p" | bb head -1)
  fi
  # 尝试读 label：直接读 /data/system/packages.xml 太重，用 dumpsys 兜底
  printf '%s' "$_l"
}

# 读某包名在 package_config 中的整行（返回 pkg,exclude,allow,uid,to_uid,sctx）
row_of() {
  _p="$1"
  bb grep "^$_p," "$RW_PKGCFG" 2>/dev/null | bb head -1
}

# 写回 package_config：把某包的 allow 字段设为 $2（1/0）
set_allow() {
  _p="$1"; _a="$2"
  [ -f "$RW_PKGCFG" ] || { printf 'no-config'; return 1; }
  if row_of "$_p" | bb grep -q .; then
    # 已存在 → 改第 3 列（allow）
    bb awk -F, -v p="$_p" -v a="$_a" '
      NR==1{print; next}
      $1==p{ $3=a; OFS=","; print; next }
      {print}
    ' OFS=, "$RW_PKGCFG" > "$RW_PKGCFG.tmp" && bb mv "$RW_PKGCFG.tmp" "$RW_PKGCFG"
    bb chmod 600 "$RW_PKGCFG" 2>/dev/null
    printf 'updated'
  else
    # 新应用 → 追加一行（uid 未知先填 0，sctx 用 magisk）
    printf '%s,0,%s,0,0,u:r:magisk:s0\n' "$_p" "$_a" >> "$RW_PKGCFG"
    bb chmod 600 "$RW_PKGCFG" 2>/dev/null
    printf 'appended'
  fi
}

# 重启 apd（让授权改动生效）。apd 是核心守护进程，kill 后不一定自动 respawn，
# 故 kill 后主动用 uid-listener 重新拉起（需 setsid 脱离当前 CGI 生命周期）。
restart_apd() {
  _pid=$(bb pidof apd 2>/dev/null | bb awk '{print $1}')
  [ -n "$_pid" ] && bb kill "$_pid" 2>/dev/null
  sleep 1
  # 用 setsid + nohup 脱离 httpd 进程组重新拉起 uid-listener（apd 的守护模式）
  if [ -x "$RW_APD" ]; then
    bb nohup "$RW_BUSYBOX" setsid "$RW_APD" uid-listener >>"$RW_HOME/apd-restart.log" 2>&1 &
    sleep 1
  fi
  bb pidof apd 2>/dev/null | bb grep -q . && return 0 || return 1
}

json_header
rw_set_cookie_if_query

case "$_action" in
  # ---------------- 读取列表 ----------------
  ""|list)
    printf '{\n  "ok": true,\n  "configFile": "%s",\n' "$(jstr "$RW_PKGCFG")"
    printf '  "apps": [\n'
    _first=1
    if [ -f "$RW_PKGCFG" ]; then
      while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        # 跳过表头
        case "$_line" in pkg,exclude,allow,*) continue ;; esac
        _p=${_line%%,*}
        _rest=${_line#*,}      # exclude,allow,uid,to_uid,sctx
        _excl=${_rest%%,*}; _rest=${_rest#*,}
        _allow=${_rest%%,*}; _rest=${_rest#*,}
        _uid=${_rest%%,*}; _rest=${_rest#*,}
        _to_uid=${_rest%%,*}
        # sctx 是最后一个逗号后的整段
        _sctx=${_line##*,}
        # 校验包名
        is_pkg "$_p" || continue
        # 补应用名
        _label=$(app_label "$_p")
        # 尝试从 pm 拿真实 uid
        _real_uid=$(/system/bin/pm list packages -U 2>/dev/null | bb grep "^package:$_p uid:" | bb sed 's/.*uid://' | bb tr -d ' ')
        [ -n "$_real_uid" ] || _real_uid="$_uid"
        [ "$_first" = "1" ] || printf ',\n'
        _first=0
        printf '    {"pkg":"%s","label":"%s","exclude":%s,"allow":%s,"uid":%s,"toUid":%s,"sctx":"%s"}' \
          "$(jstr "$_p")" "$(jstr "$_label")" \
          "$([ "$_excl" = "1" ] && echo true || echo false)" \
          "$([ "$_allow" = "1" ] && echo true || echo false)" \
          "$_real_uid" "$_to_uid" "$(jstr "$_sctx")"
      done < "$RW_PKGCFG"
    fi
    printf '\n  ]\n}\n'
    ;;

  # ---------------- 授权 ----------------
  grant)
    is_pkg "$_pkg" || { printf '{"ok":false,"error":"非法包名"}\n'; exit 0; }
    _r=$(set_allow "$_pkg" 1)
    _did_restart=false
    if [ "$_restart" != "0" ]; then
      restart_apd && _did_restart=true
    fi
    printf '{"ok":true,"action":"grant","pkg":"%s","op":"%s","restarted":%s}\n' \
      "$(jstr "$_pkg")" "$(jstr "$_r")" "$_did_restart"
    ;;

  # ---------------- 撤销 ----------------
  revoke)
    is_pkg "$_pkg" || { printf '{"ok":false,"error":"非法包名"}\n'; exit 0; }
    _r=$(set_allow "$_pkg" 0)
    _did_restart=false
    if [ "$_restart" != "0" ]; then
      restart_apd && _did_restart=true
    fi
    printf '{"ok":true,"action":"revoke","pkg":"%s","op":"%s","restarted":%s}\n' \
      "$(jstr "$_pkg")" "$(jstr "$_r")" "$_did_restart"
    ;;

  *)
    printf '{"ok":false,"error":"未知 action：%s"}\n' "$(jstr "$_action")"
    ;;
esac
