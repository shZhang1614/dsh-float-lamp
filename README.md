# dsh-float-lamp

悬浮任务状态灯：独立于 DeepSeek Harness 窗口的置顶小灯，实时显示任务状态；鼠标悬停显示正在运行的任务信息。

A floating, always-on-top status lamp that lives **outside** the DeepSeek Harness window: 🟢 running, 🟠 needs approval, 🔵 needs your input, ⚪ idle, dark-grey host offline. Hover the lamp to list running tasks. Windows only (PowerShell WinForms).

## 灯色含义

| 灯色 | 含义 | 判定 |
|------|------|------|
| 🟢 绿 | 运行中 | 有会话 `turn/start` 未闭合 |
| 🟠 橙 | 待你授权 | 有 `approval/asked` 未 `approval/decided` |
| 🔵 蓝 | 待你交互 | `ask_user_question` / `exit_plan_mode` 调用挂起 |
| ⚪ 灰 | 空闲 | 无活动轮次 |
| ⚫ 暗灰「宿主离线」 | DSH 未运行 | state.json 超过 15 秒未更新，或标记 hostDown |

- 多会话聚合优先级：橙 > 蓝 > 绿 > 灰；灯上显示当前状态与计数。
- 无脉冲动画（不闪烁）。
- **悬停卡片**：鼠标移到灯上约 0.3 秒，灯左侧弹出深色卡片，逐行列出每个会话：
  `[状态] 最近一条用户消息（正在: 工具名）`；移开自动消失，拖动灯时隐藏。
- 离线超过 60 秒灯自动退出（宿主重启后会重新拉起）。

## 原理

- `lib/index.js`（宿主插件）：
  - **权威路径**：每 800ms 轮询 `ctx.sessions.list()`，对每个会话从游标起增量折叠
    `session.log` 里的 `turn/start|end`、`approval/asked|decided`、`tool/call|result`、
    `user/message`（悬停标题），按 `seq` 去重。
  - **快速路径**：同时订阅 `session/created` / `session/event` 与 `internal/dispatch`（global），
    事件到达即时更新（双投递由 seq 去重兜底）。
  - 聚合结果原子写入 `~/.dsh/float-lamp/state.json`（5 秒心跳 + 事件即时更新），
    并自动拉起灯进程（单实例：`lamp.pid` + 子进程存活检查）。
  - **自禁用检测**：心跳时读取 `~/.dsh/profiles/<profile>/cordis.patch.yml`，
    若本插件被标记 `disabled: true`，立即写 hostDown 并杀掉灯（约 5 秒内熄灭）；
    重新开启则重新拉起灯。
  - `apply()` 返回清理函数（cordis fiber disposable）。⚠️ 不要在 apply 里访问
    `ctx.dispose`——Context 没有该成员，代理会抛错并使 fiber 进入错误态（所有监听被摘除）。
- `widget/lamp.ps1`（独立灯窗）：PowerShell WinForms，置顶无边框圆角卡片（184×96），
  400ms 轮询 state.json。左键拖动（位置记忆到 `pos.json`），右键菜单：置顶开关 / 退出。
  互斥锁 + `lamp.pid` 保证单实例；仅在状态文本变化时重绘。

## 安装 / Install

```sh
dsh plugin --profile desktop add github:shZhang1614/dsh-float-lamp
```

然后重启 DeepSeek Harness 应用；插件加载后会自动拉起灯窗（无需手动运行任何脚本）。

<details>
<summary>手动安装（不经过 dsh plugin 命令）</summary>

1. 把源码放到任意目录，例如 `~/dsh-plugins/dsh-float-lamp`。
2. 在 profile 的 `~/.dsh/profiles/<profile>/package.json` 中：
   - dependencies 加 `"dsh-float-lamp": "link:<源码目录的绝对路径，正斜杠>"`
   - `dsh.profile.bundles` 数组追加 `"dsh-float-lamp"`
3. 重启 DeepSeek Harness 应用。
</details>

## 开关插件

- 在 dshmarket 里开关：会改写 profile 的 bundles 与 `cordis.patch.yml`（`disabled: true`）。
- 插件处于加载状态时，开关约 5 秒内实时生效（关闭→灯自动熄灭）。
- 关闭后下次重启不再加载插件；重新开启后需**重启应用**才会再次加载并亮灯。

## 手动操作

- 手动启动灯：`powershell -NoProfile -ExecutionPolicy Bypass -File widget\lamp.ps1`
- 禁止插件自动拉起灯：环境变量 `DSH_FLOAT_LAMP_NO_WIDGET=1`
- 单独运行灯（无宿主）：灯显示「宿主离线」，60 秒后自动退出，属正常。
- 悬停卡片自动弹出测试：环境变量 `DSH_LAMP_TEST_TIP=1`（启动后首个 tick 直接弹卡片）。

## 文件一览（运行时目录 `~/.dsh/float-lamp/`）

| 文件 | 作用 |
|------|------|
| `state.json` | 聚合状态（state、counts、tasks、updatedAt、pid、hostDown） |
| `pos.json` | 灯窗位置记忆 |
| `lamp.pid` | 灯进程 pid（单实例检查） |
| `debug.log` | 插件诊断日志（加载、订阅、轮询错误、spawn） |

## 注意 / 已知坑

- `widget/lamp.ps1` 必须保存为 **UTF-8 带 BOM**，否则 PowerShell 5.1 按 GBK 解析中文报错。
- 拉起灯不能用 `detached: true`（powershell 会立即退出）；用 `stdio:'ignore' + windowsHide + unref`。
- WinForms `ToolTip` 在无边框置顶窗上不会弹出，悬停卡片是自绘的 `LampTipForm`
  （`Add-Type` 需 `-ReferencedAssemblies System.Windows.Forms`）。
- PowerShell 5.1（.NET Framework）没有 `[System.Drawing.Point]::From`，右键菜单要用
  `$menu.Show($form, $e.X, $e.Y)` 重载，否则右键弹未处理异常错误框。
- 应用内「重启」若被活跃会话阻塞，会出现新宿主反复启动失败的循环；等当前任务结束或从托盘完全退出后重开。

## 卸载

在 dshmarket 关闭（或从 profile package.json 移除 dependency 与 bundles 条目），
删除 `node_modules\dsh-float-lamp` junction 与源码目录，重启应用。

## 测试

- `node test/fold-test.mjs` — 状态机 17 项断言（四态、优先级、多会话、重放播种、harness 噪音过滤）。
- 假 ctx 冒烟：apply 返回清理函数、poll 折叠事件、cleanup 写 hostDown。
