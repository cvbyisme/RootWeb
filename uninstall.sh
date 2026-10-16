#!/system/bin/sh
# 卸载 RootWeb 模块时清理运行期文件与进程
BB=/data/adb/ap/bin/busybox
[ -x "$BB" ] || BB=busybox

RWDIR=/data/adb/rootwebui
PORT=8099

if [ -s "$RWDIR/httpd.pid" ]; then
  for _p in $("$BB" cat "$RWDIR/httpd.pid"); do
    "$BB" kill "$_p" 2>/dev/null
  done
fi

# 兜底：按命令行匹配（busybox ps 用默认输出，PID 在第一列）
for _round in 1 2 3; do
  _n=0
  _pids=$("$BB" ps -A 2>/dev/null | "$BB" grep "httpd.*$PORT" | "$BB" grep -v grep | "$BB" awk '{print $1}')
  for _p in $_pids; do
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    "$BB" kill "$_p" 2>/dev/null && _n=$((_n + 1))
  done
  [ "$_n" = "0" ] && break
  "$BB" sleep 1
done

"$BB" rm -rf "$RWDIR" 2>/dev/null