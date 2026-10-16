#!/system/bin/sh
# RootWeb 开机自启：等开机稳定后拉起 busybox httpd（CGI 模式）
# 由 APatch/Magisk 在 late_start 阶段以 root 执行
# 注意：本脚本必须可执行（chmod 755）；apd 安装后可能不带执行位，故顶部先自修复

MODDIR=${0%/*}
RWDIR=/data/adb/rootwebui
BB=/data/adb/ap/bin/busybox
[ -x "$BB" ] || BB=busybox

PORT=8099
HOST=127.0.0.1
LOG="$RWDIR/access.log"
CONF="$RWDIR/config.conf"
NOTIFY=1
AUTO_OPEN=0

# ---- 读动态配置（config.conf）----
if [ -f "$CONF" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    _k=${_line%%=*}; _v=${_line#*=}
    _k=$(printf '%s' "$_k" | "$BB" sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _v=$(printf '%s' "$_v" | "$BB" sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
    case "$_k" in
      port)      case "$_v" in ''|*[!0-9]*) ;; *) PORT="$_v" ;; esac ;;
      host)      [ -n "$_v" ] && HOST="$_v" ;;
      notify)    NOTIFY="$_v" ;;
      auto_open) AUTO_OPEN="$_v" ;;
    esac
  done < "$CONF"
fi

# ---- 进程管理（busybox ps 不支持 -o PID,ARGS，用默认输出）----
find_pids() {
  "$BB" ps -A 2>/dev/null | "$BB" grep "$1" | "$BB" grep -v -e grep -e find_pids | "$BB" awk '{print $1}'
}
kill_matching() {
  _n=0
  for _p in $(find_pids "$1"); do
    case "$_p" in ''|*[!0-9]*) continue ;; esac
    "$BB" kill "$_p" 2>/dev/null && _n=$((_n + 1))
  done
  printf '%s' "$_n"
}

# 自修复权限（apd 解包后常丢失执行位）
chmod 755 "$MODDIR/service.sh" 2>/dev/null
chmod 755 "$MODDIR"/web/cgi-bin/*.sh 2>/dev/null

# 等系统起来（最多 90s）
_i=0
while [ "$_i" -lt 90 ]; do
  [ "$("$BB" getprop sys.boot_completed 2>/dev/null || /system/bin/getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
  "$BB" sleep 1
  _i=$((_i + 1))
done
"$BB" sleep 5

# 准备运行目录 + token
"$BB" mkdir -p "$RWDIR/tmp" 2>/dev/null
"$BB" chmod 700 "$RWDIR" 2>/dev/null
if [ ! -s "$RWDIR/token" ]; then
  "$BB" head -c 16 /dev/urandom | "$BB" md5sum | "$BB" cut -d' ' -f1 > "$RWDIR/token"
fi
"$BB" chmod 600 "$RWDIR/token" 2>/dev/null

# 停掉可能存在的旧实例（靠命令行关键字匹配）
for _round in 1 2 3; do
  _killed=$(kill_matching "busybox httpd")
  [ "$_killed" = "0" ] && break
  "$BB" sleep 1
done
"$BB" sleep 1

# 起 httpd（-h 指定 web 根；CGI 目录固定为 <root>/cgi-bin）
"$BB" httpd -f -p "$HOST:$PORT" -h "$MODDIR/web" >> "$LOG" 2>&1 &
_HTTPD_PID=$!

"$BB" sleep 1
_TOKEN=$("$BB" cat "$RWDIR/token" 2>/dev/null)
printf '%s\n' "$_HTTPD_PID" > "$RWDIR/httpd.pid"
{
  echo "---- $(date 2>/dev/null || echo boot) ----"
  if [ -d "/proc/$_HTTPD_PID" ]; then
    echo "[RootWeb] OK  http://$HOST:$PORT/?token=$_TOKEN"
  else
    echo "[RootWeb] FAILED to start (pid $_HTTPD_PID)"
  fi
} >> "$LOG"

# 只有真正跑起来才做后续
[ -d "/proc/$_HTTPD_PID" ] || exit 0

# 把访问地址写到 /sdcard 根目录，方便查看
_dump="/sdcard/RootWeb-地址.txt"
printf 'http://%s:%s/?token=%s\n' "$HOST" "$PORT" "$_TOKEN" > "$_dump" 2>/dev/null && \
  "$BB" chmod 644 "$_dump" 2>/dev/null

# 系统通知（可关）
if [ "$NOTIFY" != "0" ]; then
  /system/bin/cmd notification post -t "RootWeb 已启动" rwui_boot \
    "浏览器打开 http://$HOST:$PORT/?token=$_TOKEN" 2>/dev/null || true
fi

# 自动打开浏览器（默认关）
if [ "$AUTO_OPEN" = "1" ]; then
  /system/bin/am start -a android.intent.action.VIEW \
    -d "http://$HOST:$PORT/?token=$_TOKEN" >/dev/null 2>&1 || true
fi