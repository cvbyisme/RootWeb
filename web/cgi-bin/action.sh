#!/system/bin/sh
# POST|GET /cgi-bin/action.sh?id=<模块id>  —— 执行模块的 action.sh
#
# 实现要点（踩坑记录）：
#  1. 不能走 `apd module action`：设备无 APatch 管理器 App 时会阻塞卡死。
#  2. 不能放在后台子 shell `( ... ) &` 里执行：CGI 父进程结束后子进程被孤儿化，
#     binder 会话丢失 → 模块脚本里的 am/cmd 会报
#     "cmd: Failure calling service activity: Failed transaction"。
#     必须【前台】执行（用 bb timeout 兜底防卡死，CGI 会阻塞等待结果）。
#  3. 需补 PATH，否则模块脚本里的裸 am/getprop/pm 可能找不到。
. "$(dirname "$0")/_lib.sh"

rw_check_auth; _auth=$?
if [ "$_auth" != "0" ]; then
  json_header
  printf '{"ok":false,"error":"%s"}\n' "$([ "$_auth" = "2" ] && echo 'token not configured' || echo unauthorised)"
  exit 0
fi

_id=$(printf '%s' "$QUERY_STRING" | bb awk -F'&' '{
  for(i=1;i<=NF;i++){ if($i ~ /^id=/){ sub(/^id=/,"",$i); print $i; exit } }
}')
_id=$(printf '%s' "$_id" | bb sed 's/%2F/\//g;s/%20/ /g;s/%2E/./g;s/%2D/-/g;s/%5F/_/g')

is_mod_id "$_id" || { json_header; printf '{"ok":false,"error":"bad id"}\n'; exit 0; }

json_header

_dir="$RW_MODULES/$_id"
if [ ! -f "$_dir/action.sh" ]; then
  printf '{"ok":false,"error":"no action.sh"}\n'; exit 0
fi

export PATH="/system/bin:/system/xbin:/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH"

# 前台执行，最多 20s（超时由 bb timeout 终止）。必须前台，见文件头说明 2。
_out=$(cd "$_dir" && bb timeout 20 sh action.sh 2>&1)
_rc=$?
if [ "$_rc" -eq 124 ] || [ "$_rc" -eq 137 ]; then
  _timedout=true
else
  _timedout=false
fi

printf '{"ok":true,"id":"%s","timeout":%s,"rc":%s,"output":"%s"}\n' \
  "$(jstr "$_id")" "$_timedout" "$_rc" "$(jstr "$_out")"