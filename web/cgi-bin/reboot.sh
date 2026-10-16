#!/system/bin/sh
# POST /cgi-bin/reboot.sh  —— 重启设备（危险操作，前端需二次确认）
. "$(dirname "$0")/_lib.sh"

rw_check_auth; _auth=$?
if [ "$_auth" != "0" ]; then
  json_header
  printf '{"ok":false,"error":"%s"}\n' "$([ "$_auth" = "2" ] && echo 'token not configured' || echo unauthorised)"
  exit 0
fi

json_header
printf '{"ok":true,"note":"reboot scheduled"}\n'
# 稍延迟，确保响应先发出去
(bb sleep 1; bb reboot) >/dev/null 2>&1 &