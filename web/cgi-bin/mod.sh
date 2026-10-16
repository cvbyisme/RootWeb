#!/system/bin/sh
# POST /cgi-bin/mod.sh?id=<模块id>&action=<enable|disable|uninstall|undo|action|purge>
# 优先走 apd 官方子命令；purge 为直删目录（危险，需二次确认）
. "$(dirname "$0")/_lib.sh"

rw_check_auth; _auth=$?
if [ "$_auth" != "0" ]; then
  json_header
  printf '{"ok":false,"error":"%s"}\n' "$([ "$_auth" = "2" ] && echo 'token not configured' || echo unauthorised)"
  exit 0
fi

# 解析 query
_param() {
  printf '%s' "$QUERY_STRING" | bb awk -F'&' -v k="$1" '{
    for(i=1;i<=NF;i++){ if($i ~ ("^"k"=")){ sub("^"k"=","",$i); print $i; exit } }
  }'
}
_id=$(_param id)
_act=$(_param action)

# urldecode（只处理常见转义）
_id=$(printf '%s' "$_id" | bb sed 's/%2F/\//g;s/%20/ /g;s/%2E/./g;s/%2D/-/g;s/%5F/_/g')
_act=$(printf '%s' "$_act" | bb sed 's/%2F/\//g')

is_mod_id "$_id" || { json_header; printf '{"ok":false,"error":"bad id"}\n'; exit 0; }

case "$_act" in
  enable|disable|uninstall|undo-uninstall|action|purge) ;;
  *) json_header; printf '{"ok":false,"error":"bad action"}\n'; exit 0 ;;
esac

_dir="$RW_MODULES/$_id"
if [ "$_act" != "purge" ] && [ ! -d "$_dir" ]; then
  json_header; printf '{"ok":false,"error":"module not found"}\n'; exit 0
fi

# purge：直接删目录（等价于 apd 卸载后立即清理）
if [ "$_act" = "purge" ]; then
  if bb rm -rf "$_dir" 2>/dev/null; then
    json_header; printf '{"ok":true,"action":"purge","id":"%s","needsReboot":false,"note":"目录已删除"}\n' "$(jstr "$_id")"
  else
    json_header; printf '{"ok":false,"error":"purge failed"}\n'
  fi
  exit 0
fi

# 其余：调 apd
_out=$("$RW_APD" module "$_act" "$_id" 2>&1)
_rc=$?

_needs_reboot=true
case "$_act" in
  enable|disable) _needs_reboot=false ;;
esac

json_header
if [ "$_rc" = "0" ]; then
  printf '{"ok":true,"id":"%s","action":"%s","needsReboot":%s,"output":"%s"}\n' \
    "$(jstr "$_id")" "$(jstr "$_act")" "$_needs_reboot" "$(jstr "$_out")"
else
  printf '{"ok":false,"id":"%s","action":"%s","output":"%s","error":"apd 返回 %s"}\n' \
    "$(jstr "$_id")" "$(jstr "$_act")" "$(jstr "$_out")" "$_rc"
fi