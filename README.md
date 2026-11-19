# dsh-pc-guard

A tiny [DeepSeek Harness](https://github.com/deepseek-ai) (DSH) plugin for Windows that gives the agent a
`pc_guard` tool:

| action | what it does |
| --- | --- |
| `lock` | Locks the current Windows workstation and turns the display off. Background programs keep running; the machine never sleeps, shuts down, or restarts. Unlocking returns to the exact same desktop. |
| `status` | Samples total CPU usage, the current idle time, battery percentage and whether the machine is on AC power, so the agent can decide whether the machine is too busy — or too low on battery — for heavy OCR / video / agent work. |
| `ui` | Opens the PC Guard panel — the small window with the live CPU readout, one-click lock and the automatic guard. If it is already open, it is brought to the front instead of opening a second copy. |
| `shortcut` | Puts a **锁屏管家** shortcut on the desktop that opens the same panel, so the feature is one double-click away when you are not talking to the agent. The shortcut launches through a generated `launch.vbs` (wscript), so Windows never shows a PowerShell console window — and closing that console can no longer take the panel down with it. |

The repository also ships the standalone `assets/PcGuard.ps1` script it is built on: a small WinForms
window with a live CPU readout, a one-click lock button, an automatic CPU guard (suspend OCR / agent
processes above a threshold, resume after the load drops), a low-battery guard, and a "keep the display off while locked" loop.

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
pc_guard { action: "lock" }
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

## Safety

`action: "lock"` locks the machine immediately, including the session you are talking to the agent from.
Do not bind it to a hotkey you cannot undo.

## License

MIT — see [LICENSE](./LICENSE).

---

## 中文说明

这是一个 Windows 专用的 DeepSeek Harness 插件，把「一键锁屏 + CPU 守护」包装成 `pc_guard` 工具：

- `lock`：调用 `user32!LockWorkStation` 锁定工作站并关屏，后台程序全部保留，不休眠、不关机；
- `status`：返回当前 CPU 占用、空闲秒数与电池状态（电量、是否接电源）；
- `ui`：打开 锁屏管家小窗（实时 CPU、一键锁屏、自动守护）；已开着就拉到前台；
- `shortcut`：在桌面生成「锁屏管家」快捷方式，双击即可打开同一个小窗。快捷方式实际指向 `assets/launch.vbs`（由 wscript 启动），所以**不会再弹出 PowerShell 黑框**，也就不会出现「关掉黑框把管家一起关掉」的问题。

附带的 `assets/PcGuard.ps1` 也可以脱离 DSH 单独运行，带一个小窗口：实时 CPU、一键锁屏、CPU 超阈值
自动暂停 OCR / 进程、锁屏后压制自动亮屏，以及**低电量保护**：

- 仅当「未接电源 + 有 OCR / agent 后台任务」时生效；
- 电量降到 20%（可调 `-LowBatteryPct`）时自动暂停所有后台任务，并把电源计划切到「节能」，省电优先；
- 插上电源或电量回升到 25%（可调 `-LowBatteryResumePct`）后自动恢复任务与原来的电源计划；
- 界面里第五个复选框可以随时关掉它，关掉时若正因低电量暂停会立即恢复。

**界面**采用 DeepSeek 蓝主题自绘（圆角卡片、胶囊开关、去掉了系统默认按钮外观），不再使用 WinForms 原生控件：

- CPU 大号数字配阈值渐变进度条（蓝 → 橙 → 红）；
- 「状态」单独一行大字加粗，下面是独立的电池行，左侧图标随电量填充；
- 五个胶囊开关：CPU 守护、含 DSH、压制亮屏、空闲自动锁屏、低电量保护；
- 命中进程列表 + 自定义进程输入框；
- 一键锁屏 / 立即暂停 / 恢复 三个按钮。

**命中进程**会自动识别 OCR 与 DSH 进程；其它程序（如 `ffmpeg`、`chrome`）可以把进程名输入到
输入框点「添加」，名单保存在 `assets/pc-guard.custom.txt`，按「进程名包含该字符串」匹配，重启后仍在。

安装：用 `plugin_manager` 的 `install_bundle` 指向本目录绝对路径即可。
