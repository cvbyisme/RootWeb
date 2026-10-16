#!/system/bin/sh
# 安装时执行：修正权限（apd/Magisk 解包后文件常是 644）
# MODPATH 由安装器注入，指向模块被展开的目录

[ -n "$MODPATH" ] || MODPATH="${0%/*}"

chmod 755 "$MODPATH" 2>/dev/null
chmod 755 "$MODPATH/service.sh" 2>/dev/null
chmod 755 "$MODPATH/uninstall.sh" 2>/dev/null
chmod 755 "$MODPATH/customize.sh" 2>/dev/null
for f in "$MODPATH"/web/cgi-bin/*.sh; do
  [ -f "$f" ] && chmod 755 "$f" 2>/dev/null
done
find "$MODPATH" -type d -exec chmod 755 {} + 2>/dev/null
find "$MODPATH" -type f ! -name '*.sh' -exec chmod 644 {} + 2>/dev/null

ui_print() { echo "$@"; }
ui_print "RootWeb 权限已修正"

# SELinux 上下文（部分环境需要，失败不影响）
chcon -R u:object_r:system_file:s0 "$MODPATH" 2>/dev/null