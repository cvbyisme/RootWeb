# RootWeb

在**系统浏览器**里管理 root 模块（Magisk / KernelSU / APatch）。

不依赖任何 App —— 本模块自带一个 busybox httpd + CGI 后端，开机自启。

## 安装

用 APatch / Magisk / KernelSU 管理器刷入 `RootWeb-vX.Y.Z.zip`，重启。

## 使用

重启后系统会弹通知，里面有完整地址：

```
http://127.0.0.1:8099/?token=<你的 token>
```

首次访问 URL 里带上 `?token=`，页面会把 token 存进浏览器 localStorage，之后直接开 `http://127.0.0.1:8099/` 即可。

token 存在 `/data/adb/rootwebui/token`（权限 600），可随时 `cat` 查看。

## 功能

| 功能 | 说明 |
|---|---|
| 模块列表 | 走 `apd module list`，含名称/版本/作者/描述/状态 |
| 启用 / 禁用 | 调 `apd module enable/disable`，重启后生效 |
| 卸载 | 调 `apd module uninstall`（打 remove 标记，重启清理） |
| 撤销卸载 | 调 `apd module undo-uninstall` |
| 执行 Action | 调 `apd module action` |
| 上传安装 | 优先 `apd module install`；失败回退手工解包 + 修 SELinux 上下文 |
| 彻底删除 (purge) | 直接删模块目录，**不可恢复**，仅 API 提供 |
| 搜索 | 按名称 / id / 描述 / 作者过滤 |
| 详情 | 查看模块全部原始字段 |
| **动态设置** | 点「设置」按钮改端口 / 地址 / 上传上限 / 开机通知 / 自动打开 / token |

## 动态配置

点右上角**设置**按钮可在网页里直接改：

| 配置项 | 生效方式 | 说明 |
|---|---|---|
| `port` | **需重启服务** | 监听端口，1-65535，默认 8099 |
| `host` | **需重启服务** | 监听地址，默认 `127.0.0.1`。改成 `0.0.0.0` 会对外网开放，⚠️ 危险 |
| `max_upload` | 立即生效 | 上传体积上限（字节），默认 268435456 (256MB) |
| `notify` | 下次开机生效 | 开机是否弹通知提示访问地址 |
| `auto_open` | 下次开机生效 | 开机是否自动打开浏览器跳转 |
| `token` | **立即生效** | 可重新随机生成，或自定义（≥8 位，仅 `A-Za-z0-9._-`） |

- 配置存 `/data/adb/rootwebui/config.conf`（`key=value` 纯文本，权限 600），也可手动编辑。
- 改端口/地址后点「重启服务」即可（无需重启手机）；改 token 后旧链接立即失效，页面会自动更新 URL。
- 所有改动都会同步更新 `/sdcard/RootWeb-地址.txt`。

## 安全设计

- **只监听 `127.0.0.1:8099`**，不对外网开放，不做端口转发。
- **token 鉴权**：`X-Token` 头 / `?token=` / cookie 三种方式，任一匹配即可。
- token 文件权限 600，位于 `/data/adb/rootwebui/`（700）。
- 模块 id 严格校验（`[A-Za-z0-9._-]+`），防路径穿越。
- 上传体积上限 256MB（可在设置里改）。

## 目录结构

```
/data/adb/modules/rootwebui/
├── module.prop
├── service.sh          # 开机自启 httpd
├── uninstall.sh        # 卸载时停服务 + 清理
├── customize.sh        # 安装时修权限
└── web/
    ├── index.html      # 前端（单文件，含设置面板）
    └── cgi-bin/        # CGI 后端
        ├── _lib.sh     # 公共库（鉴权/配置/JSON/工具）
        ├── state.sh    # GET  状态 + 模块列表
        ├── config.sh   # GET/POST 读改动态配置（端口/token 等）
        ├── mod.sh      # POST 启停/卸载/撤销
        ├── install.sh  # POST 上传安装
        ├── action.sh   # POST 执行 Action
        └── reboot.sh   # POST 重启设备

/data/adb/rootwebui/    # 运行期数据
├── token               # 鉴权 token（600）
├── config.conf         # 动态配置 key=value（600）
├── access.log          # 日志
├── httpd.pid
└── tmp/                # 上传临时目录
```

## 环境要求

- APatch（apd）或 Magisk / KernelSU（提供 `/data/adb/modules`）
- busybox（APatch 自带 `/data/adb/ap/bin/busybox`；否则回退系统 `toybox`）
- 需要 busybox 的 `httpd` 编译时**启用了 CGI**（APatch 自带的支持）

## 已知限制

- 模块列表依赖 `apd module list` 的 JSON 输出；不可用时回退扫目录（字段较少）。
- 浏览器可能缓存 `index.html`，界面更新后请强制刷新或加 `?v=<时间戳>`。
- 仅在 Android 16 / APatch 115051 上实测通过。

## 许可

GPL-3.0
