#!/system/bin/sh
# POST /cgi-bin/install.sh?name=xxx.zip  —— 接收模块 zip 并安装
# 优先 apd module install（官方安装器，处理 SELinux/权限/脚本）；失败则回退手工安装
. "$(dirname "$0")/_lib.sh"

rw_check_auth; _auth=$?
if [ "$_auth" != "0" ]; then
  json_header
  printf '{"ok":false,"error":"%s"}\n' "$([ "$_auth" = "2" ] && echo 'token not configured' || echo unauthorised)"
  exit 0
fi

_len="${CONTENT_LENGTH:-0}"
if [ "$_len" -le 0 ] 2>/dev/null; then
  json_header; printf '{"ok":false,"error":"empty body"}\n'; exit 0
fi
if [ "$_len" -gt "$RW_MAX_UPLOAD" ] 2>/dev/null; then
  json_header; printf '{"ok":false,"error":"file too large (max %s bytes)"}\n' "$RW_MAX_UPLOAD"; exit 0
fi

# 保存上传
_name=$(printf '%s' "$QUERY_STRING" | bb awk -F'&' '{
  for(i=1;i<=NF;i++){ if($i ~ /^name=/){ sub(/^name=/,"",$i); print $i; exit } }
}')
_name=$(printf '%s' "$_name" | bb sed 's/%[0-9A-Fa-f][0-9A-Fa-f]/_/g;s/[^A-Za-z0-9._-]/_/g')
[ -n "$_name" ] || _name="upload.zip"

_zip="$RW_TMP/$(bb date +%s)-$_name"
if ! read_body_to "$_zip"; then
  bb rm -f "$_zip" 2>/dev/null
  json_header; printf '{"ok":false,"error":"body read failed (len=%s)"}\n' "$_len"; exit 0
fi

# 校验是不是合法 zip
if ! bb unzip -l "$_zip" >/dev/null 2>&1; then
  bb rm -f "$_zip" 2>/dev/null
  json_header; printf '{"ok":false,"error":"not a valid zip"}\n'; exit 0
fi

json_header

# ---- 优先 apd 官方安装 ----
if [ -x "$RW_APD" ]; then
  _out=$("$RW_APD" module install "$_zip" 2>&1)
  _rc=$?
  if [ "$_rc" = "0" ]; then
    bb rm -f "$_zip" 2>/dev/null
    printf '{"ok":true,"method":"apd","needsReboot":true,"output":"%s"}\n' "$(jstr "$_out")"
    exit 0
  fi
  # apd 失败 → 记录并从手工路径再试
  _apd_err="$_out"
fi

# ---- 回退：手工安装 ----
_work="$RW_TMP/i-$$"
bb rm -rf "$_work" 2>/dev/null
bb mkdir -p "$_work"

if ! bb unzip -o "$_zip" -d "$_work" >/dev/null 2>&1; then
  bb rm -rf "$_work" "$_zip" 2>/dev/null
  printf '{"ok":false,"error":"unzip failed"}\n'; exit 0
fi

# 定位 module.prop 所在目录（zip 根或单层子目录）
_root=""
[ -f "$_work/module.prop" ] && _root="$_work"
if [ -z "$_root" ]; then
  for _sub in "$_work"/*/; do
    [ -f "${_sub}module.prop" ] && { _root="${_sub%/}"; break; }
  done
fi
if [ -z "$_root" ]; then
  bb rm -rf "$_work" "$_zip" 2>/dev/null
  printf '{"ok":false,"error":"no module.prop in zip","apdError":"%s"}\n' "$(jstr "${_apd_err:-}")"; exit 0
fi

_id=$(prop_get "$_root/module.prop" id)
is_mod_id "$_id" || {
  bb rm -rf "$_work" "$_zip" 2>/dev/null
  printf '{"ok":false,"error":"invalid module id in module.prop"}\n'; exit 0
}

# 跑自定义安装脚本（尽力而为）
_log=""
if [ -f "$_root/customize.sh" ]; then
  _log=$(cd "$_root" && MODPATH="$_root" MODID="$_id" API="$(sysprop ro.build.version.sdk)" \
    sh customize.sh 2>&1)
fi

# 落盘
_target="$RW_MODULES/$_id"
bb rm -rf "$_target" 2>/dev/null
if ! bb mv "$_root" "$_target" 2>/dev/null; then
  bb rm -rf "$_work" "$_zip" 2>/dev/null
  printf '{"ok":false,"error":"move failed"}\n'; exit 0
fi

# 权限 + SELinux 上下文（关键：不设 system_file 开机脚本会被拒）
# 注意：find -exec 里不能用 shell 函数 bb，必须写 busybox 绝对路径
bb chmod 755 "$_target" 2>/dev/null
bb find "$_target" -type d -exec "$RW_BUSYBOX" chmod 755 {} + 2>/dev/null
bb find "$_target" -type f -name '*.sh' -exec "$RW_BUSYBOX" chmod 755 {} + 2>/dev/null
bb find "$_target" -type f ! -name '*.sh' ! -name '*.prop' -exec "$RW_BUSYBOX" chmod 644 {} + 2>/dev/null
_chcon=$(bb chcon -R u:object_r:system_file:s0 "$_target" 2>&1)

bb rm -rf "$_work" "$_zip" 2>/dev/null

printf '{"ok":true,"method":"manual","id":"%s","needsReboot":true,"chcon":"%s","customize":"%s","apdError":"%s"}\n' \
  "$(jstr "$_id")" "$(jstr "${_chcon:-ok}")" "$(jstr "$_log")" "$(jstr "${_apd_err:-}")"