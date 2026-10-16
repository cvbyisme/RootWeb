#!/system/bin/sh
# RootWeb 公共库 —— 被各 CGI 脚本 source
# 目标环境：Android + APatch(apd) + busybox(toybox 兜底)
# 所有函数只用 POSIX sh 语法，不依赖 bash。

# ---------- 常量 ----------
RW_HOME="${RW_HOME:-/data/adb/rootwebui}"     # 运行期目录（token / tmp / 日志）
RW_MODULES="${RW_MODULES:-/data/adb/modules}"
RW_APD="${RW_APD:-/data/adb/apd}"
RW_BUSYBOX="${RW_BUSYBOX:-/data/adb/ap/bin/busybox}"
RW_TOKEN_FILE="${RW_TOKEN_FILE:-/data/adb/rootwebui/token}"
RW_TMP="${RW_TMP:-/data/adb/rootwebui/tmp}"
RW_CONFIG="${RW_CONFIG:-/data/adb/rootwebui/config.conf}"   # 动态配置

# 配置默认值
RW_MAX_UPLOAD="${RW_MAX_UPLOAD:-268435456}"   # 256MB 上限
RW_PORT="${RW_PORT:-8099}"
RW_HOST="${RW_HOST:-127.0.0.1}"
RW_NOTIFY="${RW_NOTIFY:-1}"                   # 开机是否发通知
RW_AUTO_OPEN="${RW_AUTO_OPEN:-0}"             # 开机是否自动打开浏览器

# busybox 优先，没有就退回系统命令
if [ -x "$RW_BUSYBOX" ]; then
  bb() { "$RW_BUSYBOX" "$@"; }
else
  bb() { command "$@"; }
fi

# ---------- 动态配置 ----------
# config.conf 是 key=value 纯文本，可被前端 / CLI 随时修改。
# 每次 CGI 调用都重新读取 → 改了就生效（端口/host 除外，需重启服务）。
rw_load_config() {
  [ -f "$RW_CONFIG" ] || return 0
  _line=""
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    _k=${_line%%=*}
    _v=${_line#*=}
    # 去掉首尾空白
    _k=$(printf '%s' "$_k" | bb sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _v=$(printf '%s' "$_v" | bb sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
    case "$_k" in
      port)        case "$_v" in ''|*[!0-9]*) ;; *) RW_PORT="$_v" ;; esac ;;
      host)        [ -n "$_v" ] && RW_HOST="$_v" ;;
      max_upload)  case "$_v" in ''|*[!0-9]*) ;; *) RW_MAX_UPLOAD="$_v" ;; esac ;;
      notify)      RW_NOTIFY="$_v" ;;
      auto_open)   RW_AUTO_OPEN="$_v" ;;
    esac
  done < "$RW_CONFIG"
}
rw_load_config

# 写配置（幂等覆盖单个 key）
rw_set_config() {
  _k="$1"; _v="$2"
  [ -f "$RW_CONFIG" ] || : > "$RW_CONFIG"
  if bb grep -q "^${_k}=" "$RW_CONFIG" 2>/dev/null; then
    _tmp="$RW_CONFIG.tmp.$$"
    bb sed "s|^${_k}=.*|${_k}=${_v}|" "$RW_CONFIG" > "$_tmp" && bb mv "$_tmp" "$RW_CONFIG"
  else
    printf '%s=%s\n' "$_k" "$_v" >> "$RW_CONFIG"
  fi
  bb chmod 600 "$RW_CONFIG" 2>/dev/null
}

# 输出全部配置的 JSON 片段（不含 token，token 单独处理）
rw_config_json() {
  printf '{"port":%s,"host":"%s","maxUpload":%s,"notify":%s,"autoOpen":%s}' \
    "${RW_PORT:-0}" "$(jstr "$RW_HOST")" "${RW_MAX_UPLOAD:-0}" \
    "$([ "$RW_NOTIFY" = "0" ] && echo false || echo true)" \
    "$([ "$RW_AUTO_OPEN" = "1" ] && echo true || echo false)"
}

# ---------- 输出 ----------
# 注意：必须在任何输出之前调用
RW_HEADER_SENT=""
json_header() {
  [ -n "$RW_HEADER_SENT" ] && return 0
  RW_HEADER_SENT=1
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf 'X-Content-Type-Options: nosniff\r\n'
  printf '\r\n'
}

html_header() {
  [ -n "$RW_HEADER_SENT" ] && return 0
  RW_HEADER_SENT=1
  printf 'Content-Type: text/html; charset=utf-8\r\n'
  printf '\r\n'
}

text_header() {
  [ -n "$RW_HEADER_SENT" ] && return 0
  RW_HEADER_SENT=1
  printf 'Content-Type: text/plain; charset=utf-8\r\n'
  printf '\r\n'
}

# JSON 字符串转义（用于拼手写 JSON）
jstr() {
  printf '%s' "$1" | bb sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
    | bb awk 'BEGIN{ORS=""} {if(NR>1)printf "\\n"; printf "%s", $0}'
}

# 输出错误并退出
die_json() {
  json_header
  printf '{"ok":false,"error":"%s"}\n' "$(jstr "$1")"
  exit 0
}

# 服务是否在跑（按模块 web 目录判断，端口变更后仍准确）
is_running() {
  [ -n "$(bb ps -A 2>/dev/null | bb grep 'busybox httpd' | bb grep 'rootwebui' | bb grep -v grep)" ]
}

# ---------- 鉴权 ----------
# 从 query / cookie / header 中找 token，与文件比对
rw_check_auth() {
  _expect=$(bb cat "$RW_TOKEN_FILE" 2>/dev/null | bb tr -d '\r\n')
  [ -n "$_expect" ] || return 2   # token 都不存在 → 配置错误

  # CGI 环境下 QUERY_STRING 有 query；HTTP_COOKIE 有 cookie
  _given=""
  # 1) X-Token 头
  if [ -n "$HTTP_X_TOKEN" ]; then
    _given="$HTTP_X_TOKEN"
  fi
  # 2) query ?token=
  if [ -z "$_given" ] && [ -n "$QUERY_STRING" ]; then
    _given=$(printf '%s' "$QUERY_STRING" | bb awk -F'&' '{
      for(i=1;i<=NF;i++){ if($i ~ /^token=/){ sub(/^token=/,"",$i); print $i; exit } }
    }')
    _given=$(bb printf '%s' "$_given" | bb sed 's/%2F/\//g;s/%2B/+/g;s/%3D/=/g')
  fi
  # 3) cookie rwui_token=
  if [ -z "$_given" ] && [ -n "$HTTP_COOKIE" ]; then
    _given=$(printf '%s' "$HTTP_COOKIE" | bb awk -F'; *' '{
      for(i=1;i<=NF;i++){ if($i ~ /^rwui_token=/){ sub(/^rwui_token=/,"",$i); print $i; exit } }
    }')
  fi

  [ "$_given" = "$_expect" ]
}

# 校验通过时：若 token 来自 query，顺便发 Set-Cookie，之后同源请求免 token
rw_set_cookie_if_query() {
  _expect=$(bb cat "$RW_TOKEN_FILE" 2>/dev/null | bb tr -d '\r\n')
  case "$QUERY_STRING" in
    *"token=$_expect"*)
      printf 'Set-Cookie: rwui_token=%s; Path=/; SameSite=Strict; HttpOnly\r\n' "$_expect"
      ;;
  esac
}

# ---------- 工具 ----------
# 校验模块 id 合法（防路径穿越）
is_mod_id() {
  case "$1" in
    ''|.|..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# URL 解码
urldecode() {
  printf '%s' "$1" | bb sed 's/+/ /g' | bb awk '{
    s=$0; out=""; n=length(s);
    for(i=1;i<=n;i++){
      c=substr(s,i,1);
      if(c=="%" && i+2<=n){
        h=substr(s,i+1,2);
        cmd="printf \"\\x" h "\"";
        cmd | getline ch; close(cmd);
        out=out ch; i+=2;
      } else out=out c;
    }
    printf "%s", out;
  }'
}

# 读取 POST body 到文件（按 CONTENT_LENGTH）
read_body_to() {
  _dest="$1"
  _len="${CONTENT_LENGTH:-0}"
  if [ "$_len" -gt "$RW_MAX_UPLOAD" ] 2>/dev/null; then
    return 1
  fi
  bb dd bs=4096 count=$(( _len / 4096 + 2 )) 2>/dev/null | bb dd bs=1 count="$_len" 2>/dev/null > "$_dest"
  [ "$(bb wc -c < "$_dest" 2>/dev/null | bb tr -d ' ')" = "$_len" ]
}

# 指定文件里的字段
prop_get() {
  _f="$1"; _k="$2"
  bb grep -m1 "^${_k}=" "$_f" 2>/dev/null | bb sed "s/^${_k}=//" | bb tr -d '\r'
}

# 读系统属性（busybox 常缺 getprop，优先系统工具）
sysprop() {
  if [ -x /system/bin/getprop ]; then
    /system/bin/getprop "$1" 2>/dev/null
  else
    bb getprop "$1" 2>/dev/null
  fi
}

# 按命令行关键字找 PID
# 注意：busybox ps 不支持 -o PID,ARGS，只能用默认输出（PID 在第一列）
#       系统 ps 的 ARGS 可能被截断，故优先 busybox ps
find_pids() {
  _pat="$1"
  if bb ps -A >/dev/null 2>&1; then
    bb ps -A 2>/dev/null | bb grep "$_pat" | bb grep -v -e grep -e find_pids | bb awk '{print $1}'
  else
    /system/bin/ps -A -o PID,ARGS 2>/dev/null | bb grep "$_pat" | bb grep -v grep | bb awk '{print $1}'
  fi
}

# 杀掉匹配的进程（返回杀掉的个数）
kill_matching() {
  _n=0
  for _p in $(find_pids "$1"); do
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    bb kill "$_p" 2>/dev/null && _n=$((_n + 1))
  done
  printf '%s' "$_n"
}

# 秒 → 人类可读
human_kb() {
  _kb="$1"
  [ -z "$_kb" ] && { printf '?'; return; }
  if [ "$_kb" -ge 1024 ] 2>/dev/null; then
    printf '%s.%s MB' $((_kb / 1024)) $(( (_kb % 1024) * 10 / 1024 ))
  else
    printf '%s KB' "$_kb"
  fi
}

mkdir -p "$RW_HOME" "$RW_TMP" 2>/dev/null
