# dsh-pc-guard

A tiny [DeepSeek Harness](https://github.com/deepseek-ai) (DSH) plugin for Windows that gives the agent a
`pc_guard` tool:

| action | what it does |
| --- | --- |
| `lock` | Locks the current Windows workstation and turns the display off. Background programs keep running; the machine never sleeps, shuts down, or restarts. Unlocking returns to the exact same desktop. |
| `sleep` | Turns the **display** off and nothing else: the session stays unlocked, so background jobs and other plugins (a WeChat upload, for instance) keep working. Touching the keyboard or mouse brings the picture straight back, no password. |
| `wake` | Turns the display back on **without** unlocking, and reports whether the session was merely dimmed or genuinely locked — so an agent knows whether it may proceed or has to ask you to type your password. |
| `status` | Samples total CPU usage, the current idle time, battery percentage and whether the machine is on AC power, plus the real lock state (`locked`) and whether a send lease is active (`sendLease`), so the agent can decide whether the machine is too busy — or too low on battery — for heavy OCR / video / agent work. |
| `ui` | Opens the PC Guard panel — the small window with the live CPU readout, one-click lock and the automatic guard. If it is already open, it is brought to the front instead of opening a second copy. |
| `shortcut` | Puts a **锁屏管家** shortcut on the desktop that opens the same panel, so the feature is one double-click away when you are not talking to the agent. The shortcut launches through a generated `launch.vbs` (wscript), so Windows never shows a PowerShell console window — and closing that console can no longer take the panel down with it. |

The repository also ships the standalone `assets/PcGuard.ps1` script it is built on: a small WinForms
window with a live CPU readout, a one-click lock button, an explicit **display-off** button, an automatic CPU guard (suspend OCR / agent
processes above a threshold, resume after the load drops), a low-battery guard, and a "keep the display off while locked" loop.

**Display-off is not lock.** The idle action turns the display off and leaves the session unlocked, so
whatever runs in the background keeps running. `LockWorkStation` only happens when you press the lock
button or call the `lock` action. This distinction matters once an agent is expected to push a file
while you are away from the desk.

**Send lease.** Before an agent starts something that needs the screen to stay on (uploading a file
over WeChat, for example), it writes one line of JSON to `%TEMP%\dsh-wechat-send.lease`:

```json
{"pid":4196,"expires":1795521048071,"note":"wechat send-file"}
```

While that file exists and its `expires` (Unix milliseconds) is still in the future, the guard will not
blank the display, will not lock, will not re-blank, and holds `SetThreadExecutionState` so Windows does
not blank it either. An expired file is deleted the next time the guard looks at it, so a crashed sender
can never keep your screen awake forever.

## Why

Locking a workstation from an agent chat sounds trivial, but the naive options all have side effects:
`shutdown /l` closes background work, sleep breaks long jobs, and third-party lock utilities request
administrator rights. This plugin only calls `user32!LockWorkStation`, the exact same API `Win+L` uses,
so nothing else on the machine is touched.

## Install

Clone the repository, then point DSH at the checkout:

```bash
git clone https://github.com/NCT-Ant/dsh-pc-guard.git
```

DSH installs plugin bundles from a local package directory:

```text
plugin_manager { action: "install_bundle", target: "<absolute path to this directory>" }
```

Or keep it in a profile as a linked checkout during development.

Once installed, ask the agent to lock the screen, open the panel, or leave a desktop icon, or call the tool directly:

```text
pc_guard { action: "lock" }      # lock + display off (needs the password to come back)
pc_guard { action: "sleep" }     # display off only, session stays unlocked
pc_guard { action: "wake" }      # display on, reports whether it is actually locked
pc_guard { action: "status" }
pc_guard { action: "ui" }        # open the PC Guard panel
pc_guard { action: "shortcut" }  # put a 锁屏管家 icon on the desktop
```

## Standalone script

`assets/PcGuard.ps1` runs on its own, without DSH:

```powershell
# window with CPU readout, lock button and automatic guard
powershell -NoProfile -ExecutionPolicy Bypass -File assets/PcGuard.ps1

# command line
powershell -NoProfile -ExecutionPolicy Bypass -File assets/PcGuard.ps1 -Action lock
powershell -NoProfile -ExecutionPolicy Bypass -File assets/PcGuard.ps1 -Action status
powershell -NoProfile -ExecutionPolicy Bypass -File assets/PcGuard.ps1 -Headless   # no window
```

Parameters: `-CpuPause 90 -CpuResume 40 -ResumeHoldMin 5 -IntervalSec 3 -PauseStreak 3
-ForceResumeMin 30 -NoWakeIdleSec 120 -AutoLockMin 10 -LowBatteryPct 20 -LowBatteryResumePct 25`.

## Panel

The panel is drawn with a custom theme inspired by the DeepSeek blue — rounded cards, pill toggles and no
native Windows chrome — instead of stock WinForms controls:

- live CPU readout with a threshold-aware bar (blue → amber → red),
- the guard state as one large line, plus a dedicated battery row whose icon fills up as the charge drops,
- five toggles: CPU guard, include DSH, keep the screen off, idle auto-lock, low-battery guard,
- the list of matching processes and a custom-name entry field,
- one-click lock, pause-now and resume buttons.

`命中进程` picks up OCR and DSH processes automatically. Anything else can be added by typing its name
(for example `ffmpeg` or `chrome`) into the field and pressing **添加**; entries persist in
`assets/pc-guard.custom.txt` and are matched case-insensitively as a substring of the process name.

## Requirements and limits

- **Windows only.** The tool returns an error on other platforms.
- Windows PowerShell 5.1 or PowerShell 7 (`powershell.exe` must be on `PATH`).
- No administrator rights are required. Device-wake disabling (`powercfg /devicedisablewake`) does need
  an elevated shell and is intentionally **not** performed by this plugin.
- The automatic guard suspends processes with `NtSuspendProcess`. Suspended processes resume on window
  close, on manual resume, or after `-ForceResumeMin` minutes as a safety net.
- The "keep the display off" loop only re-sends `SC_MONITORPOWER`; a display driver that ignores the
  broadcast is out of scope.
- The panel never blocks its own UI thread: the screen-off broadcast runs through
  `SendMessageTimeout` (400 ms cap) or plain `PostMessage`, and the CPU counter is sampled on a
  background thread. Before this, a single unresponsive window — common right after the session locks
  — could freeze the whole panel until Windows offered to kill it.

## Why the panel used to hang after the screen went off

`SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2)` blocks until **every** top-level
window acknowledges the message, and it has no timeout. The "keep the display off" loop re-sent that
broadcast every 10 seconds while the session was locked, so one stuck window (explorer after wake,
an installer, a hung game launcher) froze the message loop for good — the window looked dead and
Windows eventually offered "PowerShell is not responding". `PerformanceCounter.NextValue()` on the UI
thread made it worse: it can stall for seconds right after the machine resumes from sleep.

The fix is three small things: broadcast with a timeout (or asynchronously), sample CPU on a
background thread, and activate an existing panel with `ShowWindowAsync` instead of the synchronous
`ShowWindow`.

## Why the screen could start flickering while you were using the PC

The "keep the display off" loop asked a flag (`$script:locked`) whether the session was locked, and
that flag was set from a `SessionSwitch` handler registered with `Register-ObjectEvent`. A PowerShell
event `-Action` block runs in its own scope, so `$script:locked = $false` on unlock wrote to the event
handler's scope, not the script's. Once the guard had locked the screen **once**, the flag stayed
`true` for the rest of the process lifetime — and the retry loop then kept re-sending
`SC_MONITORPOWER` every 10 seconds whenever the idle counter passed 120 seconds. Two minutes of not
touching the keyboard (watching a video, reading a document) was enough to get the display turned off
over and over: the screen blinks, then comes back, then goes dark again.

The flag is gone. The guard now asks Windows which desktop is currently receiving input
(`OpenInputDesktop` → `GetUserObjectInformation`, looking for `Winlogon` / `LockApp`), so unlocking
clears the state automatically. On top of that, a failed idle-time read (`-1`) no longer counts as
"idle", and two screen-off broadcasts are always at least 25 seconds apart.


## Safety

`action: "lock"` locks the machine immediately, including the session you are talking to the agent from.
Do not bind it to a hotkey you cannot undo.

## License

MIT — see [LICENSE](./LICENSE).

---

## 中文说明

这是一个 Windows 专用的 DeepSeek Harness 插件，把「一键锁屏 + CPU 守护」包装成 `pc_guard` 工具：

- `lock`：调用 `user32!LockWorkStation` 锁定工作站并关屏，后台程序全部保留，不休眠、不关机；
- `sleep`：**只熄屏**，不锁会话 —— 后台任务、别的插件（比如微信上传）照常跑，碰一下键鼠画面就回来，不用输密码；
- `wake`：把屏幕点亮但**不解锁**，并如实回报当前是真锁着还是只是熄屏，agent 据此决定继续干还是等你输密码；
- `status`：返回当前 CPU 占用、空闲秒数、电池状态（电量、是否接电源），以及真实的锁定状态 `locked` 与发送租约 `sendLease`；
- `ui`：打开 锁屏管家小窗（实时 CPU、一键锁屏、自动守护）；已开着就拉到前台；
- `shortcut`：在桌面生成「锁屏管家」快捷方式，双击即可打开同一个小窗。快捷方式实际指向 `assets/launch.vbs`（由 wscript 启动），所以**不会再弹出 PowerShell 黑框**，也就不会出现「关掉黑框把管家一起关掉」的问题。

**熄屏 ≠ 锁屏。** 空闲动作默认只熄屏，保持会话解锁，后台该跑什么还跑什么；只有按「一键锁屏」
按钮或调用 `lock` 才会 `LockWorkStation`。这个区分在「人离开、agent 还要发文件」的场景里是刚需。

**发送租约。** agent 在需要屏幕保持亮着的操作前（例如微信发文件），往
`%TEMP%\dsh-wechat-send.lease` 写一行 JSON：

```json
{"pid":4196,"expires":1795521048071,"note":"wechat send-file"}
```

文件存在且 `expires`（Unix 毫秒）未到期期间，管家不熄屏、不锁屏、不重复关屏，并用
`SetThreadExecutionState` 顶住系统的空闲熄屏。到期的残租约会被顺手删掉，发送方崩了也不会让屏幕永远亮着。

附带的 `assets/PcGuard.ps1` 也可以脱离 DSH 单独运行，带一个小窗口：实时 CPU、一键锁屏、CPU 超阈值
自动暂停 OCR / 进程、锁屏后压制自动亮屏，以及**低电量保护**：

- 仅当「未接电源 + 有 OCR / agent 后台任务」时生效；
- 电量降到 20%（可调 `-LowBatteryPct`）时自动暂停所有后台任务，并把电源计划切到「节能」，省电优先；
- 插上电源或电量回升到 25%（可调 `-LowBatteryResumePct`）后自动恢复任务与原来的电源计划；
- 界面里第五个复选框可以随时关掉它，关掉时若正因低电量暂停会立即恢复。

**界面**采用 DeepSeek 蓝主题自绘（圆角卡片、胶囊开关、去掉了系统默认按钮外观），不再使用 WinForms 原生控件：

- CPU 大号数字配阈值渐变进度条（蓝 → 橙 → 红）；
- 「状态」单独一行大字加粗，下面是独立的电池行，左侧图标随电量填充；
- 五个胶囊开关：CPU 守护、含 DSH、压制亮屏、空闲自动熄屏、低电量保护；
- 命中进程列表 + 自定义进程输入框；
- 一键锁屏 / 熄屏（可继续收发） / 立即暂停 / 恢复 四个按钮；
- 底部一行提示写清楚：熄屏不锁会话、锁屏要输密码。

**命中进程**会自动识别 OCR 与 DSH 进程；其它程序（如 `ffmpeg`、`chrome`）可以把进程名输入到
输入框点「添加」，名单保存在 `assets/pc-guard.custom.txt`，按「进程名包含该字符串」匹配，重启后仍在。

**为什么以前息屏一段时间后点它就没响应**：关屏用的是
`SendMessage(HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2)`，它会同步等待**每一个**顶层窗口
应答，而且没有超时；锁屏期间这个广播每 10 秒重发一次，只要有一个窗口卡住（唤醒后的 explorer、
安装程序、挂住的启动器都算），消息循环就再也回不来，于是 Windows 弹出「PowerShell 未响应」。
另外 `PerformanceCounter.NextValue()` 在系统刚从睡眠恢复时可能卡好几秒，而它当时跑在界面线程上。

现在改成三处：广播关屏走 `SendMessageTimeout`（400ms 上限）或纯异步 `PostMessage`、CPU 采样搬到
后台线程、激活已有窗口用 `ShowWindowAsync`。界面线程不再做任何可能无限等待的事。

**为什么用着用着屏幕会自己反复熄灭**：以前「锁屏后压制亮屏」靠一个 `$script:locked` 变量判断
是否还锁着屏，而这个变量是在 `Register-ObjectEvent` 的 `SessionSwitch` 事件里改的。PowerShell 的
事件 `-Action` 有独立作用域，解锁时那句 `$script:locked = $false` 根本写不回主脚本 —— 于是只要
锁过一次屏，这个标志在剩下的进程生命周期里永远是 `true`，重发关屏的逻辑就变成「只要闲置超过
120 秒就每 10 秒关一次屏」。你只是两分钟没碰键鼠（看视频、读文档），屏幕就会黑一下、亮一下、
再黑一下。

现在不靠标志了：直接用 `OpenInputDesktop` + `GetUserObjectInformation` 问 Windows 当前输入桌面
是不是 `Winlogon` / `LockApp`，解锁后状态自动复位。另外 `GetLastInputInfo` 失败（返回 -1）不再
被当成「该关屏」，两次关屏广播至少间隔 25 秒。

安装：用 `plugin_manager` 的 `install_bundle` 指向本目录绝对路径即可。
