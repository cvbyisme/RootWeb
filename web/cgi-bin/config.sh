#!/system/bin/sh
# /cgi-bin/config.sh —— 读写动态配置
#
# GET  ?token=xxx
#       → 返回当前配置（含 token 掩码、服务运行信息）
#
# POST ?token=xxx&action=set&key=port&value=9090
#       → 修改单项配置
# POST ?token=xxx&action=token          → 重新生成随机 token（立即生效）
# POST ?token=xxx&action=token&value=X  → 设置指定 token
# POST ?token=xxx&action=restart        → 重启 httpd 服务（使 port/host 生效）
#
. "$(dirname "$0")/_lib.sh"

rw_check_auth; _auth=$?
if [ "$_auth" != "0" ]; then
  json_header
  printf '{"ok":false,"error":"%s"}\n' "$([ "$_auth" = "2" ] && echo 'token not configured' || echo unauthorised)"
  exit 0
fi

_param() {
  printf '%s' "$QUERY_STRING" | bb awk -F'&' -v k="$1" '{
    for(i=1;i<=NF;i++){ if($i ~ ("^"k"=")){ sub("^"k"=","",$i); print $i; exit } }
  }'
}
_udec() {
  # 用 printf 的八进制转义解码，避开 awk strtonum（busybox 没有）
  printf '%s' "$1" | bb sed 's/+/ /g' | bb awk '{
    s=$0; out=""; n=length(s);
    for(i=1;i<=n;i++){
      c=substr(s,i,1);
      if(c=="%" && i+2<=n){
        h=tolower(substr(s,i+1,2));
        v=index("0123456789abcdef", substr(h,1,1))-1;
        w=index("0123456789abcdef", substr(h,2,1))-1;
        if(v>=0 && w>=0){ out=out sprintf("%c", v*16+w); i+=2 }
        else out=out c;
      } else out=out c;
    }
    printf "%s", out;
  }'
}

# 参数解析必须在输出 header 之前完成（否则 die_json 无法正常报错）
_action=$(_param action)
_key=$(_param key)
_value=$(_udec "$(_param value)")

# ---------- token 掩码工具 ----------
_mask() {
  _t="$1"
  [ -n "$_t" ] || { printf ''; return; }
  _len=${#_t}
  if [ "$_len" -le 8 ]; then
    printf '%s' "$_t"
  else
    printf '%s…%s' "$(printf '%s' "$_t" | bb cut -c1-4)" "$(printf '%s' "$_t" | bb cut -c$((_len-3))-$_len)"
  fi
}

_cur_token=$(bb cat "$RW_TOKEN_FILE" 2>/dev/null | bb tr -d '\r\n')

json_header

case "$_action" in
  # ---------------- 读取 ----------------
  ""|get)
    printf '{\n'
    printf '  "ok": true,\n'
    printf '  "config": %s,\n' "$(rw_config_json)"
    printf '  "token": "%s",\n' "$(jstr "$(_mask "$_cur_token")")"
    printf '  "tokenLength": %s,\n' "${#_cur_token}"
    printf '  "configFile": "%s",\n' "$(jstr "$RW_CONFIG")"
    printf '  "tokenFile": "%s",\n' "$(jstr "$RW_TOKEN_FILE")"
    printf '  "running": %s\n' "$(is_running && echo true || echo false)"
    printf '}\n'
    ;;

  # ---------------- 修改单项 ----------------
  set)
    case "$_key" in
      port)
        case "$_value" in
          ''|*[!0-9]*) die_json "端口必须是数字" ;;
        esac
        if [ "$_value" -lt 1 ] 2>/dev/null || [ "$_value" -gt 65535 ] 2>/dev/null; then
          die_json "端口范围 1-65535"
        fi
        rw_set_config port "$_value"
        printf '{"ok":true,"key":"port","value":%s,"applied":false,"note":"需重启服务生效"}\n' "$_value"
        ;;
      host)
        case "$_value" in
          ''|*[!0-9A-Za-z.:\[\]-]*) die_json "host 含非法字符" ;;
        esac
        rw_set_config host "$_value"
        printf '{"ok":true,"key":"host","value":"%s","applied":false,"note":"需重启服务生效"}\n' "$(jstr "$_value")"
        ;;
      max_upload)
        case "$_value" in
          ''|*[!0-9]*) die_json "max_upload 必须是数字（字节）" ;;
        esac
        rw_set_config max_upload "$_value"
        printf '{"ok":true,"key":"maxUpload","value":%s,"applied":true}\n' "$_value"
        ;;
      notify)
        case "$_value" in
          true|1)  rw_set_config notify 1; _v=true ;;
          false|0) rw_set_config notify 0; _v=false ;;
          *) die_json "notify 取值 true/false" ;;
        esac
        printf '{"ok":true,"key":"notify","value":%s,"applied":false,"note":"下次开机生效"}\n' "$_v"
        ;;
      auto_open)
        case "$_value" in
          true|1)  rw_set_config auto_open 1; _v=true ;;
          false|0) rw_set_config auto_open 0; _v=false ;;
          *) die_json "auto_open 取值 true/false" ;;
        esac
        printf '{"ok":true,"key":"autoOpen","value":%s,"applied":false,"note":"下次开机生效"}\n' "$_v"
        ;;
      *) die_json "不支持的配置项：$_key" ;;
    esac
    ;;

  # ---------------- 改 token ----------------
  token)
    if [ -n "$_value" ]; then
      case "$_value" in
        *[!A-Za-z0-9._-]*) die_json "token 只能含字母/数字/._-" ;;
      esac
      [ "${#_value}" -ge 8 ] || die_json "token 至少 8 位"
      _new="$_value"
    else
      _new=$(bb head -c 16 /dev/urandom | bb md5sum | bb cut -d' ' -f1)
    fi
    printf '%s' "$_new" > "$RW_TOKEN_FILE"
    bb chmod 600 "$RW_TOKEN_FILE" 2>/dev/null
    # 同步更新 /sdcard 地址文件
    _dump="/sdcard/RootWeb-地址.txt"
    printf 'http://%s:%s/?token=%s\n' "$RW_HOST" "$RW_PORT" "$_new" > "$_dump" 2>/dev/null
    bb chmod 644 "$_dump" 2>/dev/null
    printf '{"ok":true,"key":"token","token":"%s","applied":true,"note":"旧 token 立即失效，请重新访问"}\n' "$(jstr "$_new")"
    ;;

  # ---------------- 重启服务 ----------------
  restart)
    # CGI 路径：<moddir>/web/cgi-bin/config.sh → 模块根 = 上三级
    _selfdir=$(dirname "$0")
    _moddir=$(cd "$_selfdir/../.." 2>/dev/null && pwd)
    [ -n "$_moddir" ] || _moddir="/data/adb/modules/rootwebui"
    # 兼容 modules_update 落点
    if [ ! -f "$_moddir/service.sh" ] && [ -f "/data/adb/modules_update/rootwebui/service.sh" ]; then
      _moddir="/data/adb/modules_update/rootwebui"
    fi
    _logf="$RW_HOME/restart.log"
    # 写一个脱离 CGI 生命周期的重启脚本：等本请求回包后再执行
    _rs="$RW_TMP/restart.$$.sh"
    {
      printf '#!/system/bin/sh\n'
      printf 'sleep 1\n'
      printf 'exec "%s" >>"%s" 2>&1\n' "$_moddir/service.sh" "$_logf"
    } > "$_rs"
    bb chmod 755 "$_rs" 2>/dev/null
    # setsid 使其脱离 httpd 的进程组，nohup 防挂断
    bb nohup "$RW_BUSYBOX" setsid "$_rs" >/dev/null 2>&1 &
    printf '{"ok":true,"action":"restart","note":"服务正在重启，约 5 秒后可用，若端口已改请访问新端口","moddir":"%s"}\n' "$(jstr "$_moddir")"
    ;;

  *) die_json "未知 action：$_action" ;;
esac