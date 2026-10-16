#!/system/bin/sh
# GET /cgi-bin/state.sh —— 设备信息 + 模块列表
# 数据源：apd module list（原生 JSON，字段最全）→ 失败回退扫 /data/adb/modules
. "$(dirname "$0")/_lib.sh"

rw_check_auth
_auth=$?
if [ "$_auth" = "2" ]; then
  json_header
  printf '{"ok":false,"error":"token not configured"}\n'
  exit 0
elif [ "$_auth" != "0" ]; then
  json_header
  printf '{"ok":false,"error":"unauthorised"}\n'
  exit 0
fi

json_header
rw_set_cookie_if_query

# ---------- 设备信息 ----------
_model=$(sysprop ro.product.model)
_rel=$(sysprop ro.build.version.release)
_abi=$(sysprop ro.product.cpu.abi)
_sdk=$(sysprop ro.build.version.sdk)
_uid=$(bb id -u 2>/dev/null)
_apd_ver=$("$RW_APD" --version 2>/dev/null | bb head -1)
_uptime=$(bb cut -d. -f1 /proc/uptime 2>/dev/null | bb tr -d '\r\n')
_cnt=$(bb ls -1 "$RW_MODULES" 2>/dev/null | bb wc -l | bb tr -d ' \r\n')

printf '{\n'
printf '  "ok": true,\n'
printf '  "device": {\n'
printf '    "model": "%s",\n' "$(jstr "$_model")"
printf '    "android": "%s",\n' "$(jstr "$_rel")"
printf '    "sdk": "%s",\n' "$(jstr "$_sdk")"
printf '    "abi": "%s",\n' "$(jstr "$_abi")"
printf '    "uid": "%s",\n' "$(jstr "$_uid")"
printf '    "apdVersion": "%s",\n' "$(jstr "$_apd_ver")"
printf '    "uptime": %s\n' "${_uptime:-0}"
printf '  },\n'
printf '  "modulesDir": "%s",\n' "$(jstr "$RW_MODULES")"
printf '  "count": %s,\n' "${_cnt:-0}"

# ---------- 模块列表 ----------
_json=$("$RW_APD" module list 2>/dev/null)

if [ -n "$_json" ]; then
  # apd 输出已是合法 JSON 数组，原样内嵌
  printf '  "source": "apd",\n'
  printf '  "modules": %s\n' "$_json"
else
  # 回退：扫目录拼 JSON
  printf '  "source": "fs",\n'
  printf '  "modules": [\n'
  _first=1
  for _d in "$RW_MODULES"/*; do
    [ -d "$_d" ] || continue
    _id=$(bb basename "$_d")
    is_mod_id "$_id" || continue
    _p="$_d/module.prop"
    _name=$(prop_get "$_p" name); [ -n "$_name" ] || _name="$_id"
    _ver=$(prop_get "$_p" version)
    _auth=$(prop_get "$_p" author)
    _desc=$(prop_get "$_p" description)
    _en=true;  [ -e "$_d/disable" ] && _en=false
    _rm=true;  [ -e "$_d/remove" ] && _rm=false
    _web=false; [ -e "$_d/webroot/index.html" ] && _web=true
    _act=false; [ -e "$_d/action.sh" ] && _act=true
    [ "$_first" = "1" ] || printf ',\n'
    _first=0
    printf '    {"id":"%s","name":"%s","version":"%s","author":"%s","description":"%s","enabled":"%s","remove":"%s","action":"%s","web":"%s"}' \
      "$(jstr "$_id")" "$(jstr "$_name")" "$(jstr "$_ver")" "$(jstr "$_auth")" \
      "$(jstr "$_desc")" "$_en" "$_rm" "$_act" "$_web"
  done
  printf '\n  ]\n'
fi

printf '}\n'