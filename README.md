# dsh-pc-guard

A tiny [DeepSeek Harness](https://github.com/deepseek-ai) (DSH) plugin for Windows that gives the agent a
`pc_guard` tool:

| action | what it does |
| --- | --- |
| `lock` | Locks the current Windows workstation and turns the display off. Background programs keep running; the machine never sleeps, shuts down, or restarts. Unlocking returns to the exact same desktop. |
| `status` | Samples total CPU usage and the current idle time, so the agent can decide whether the machine is too busy for heavy OCR / video / agent work. |

The repository also ships the standalone `assets/PcGuard.ps1` script it is built on: a small WinForms
window with a live CPU readout, a one-click lock button, an automatic CPU guard (suspend OCR / agent
processes above a threshold, resume after the load drops), and a "keep the display off while locked" loop.

## Why

Locking a workstation from an agent chat sounds trivial, but the naive options all have side effects:
`shutdown /l` closes background work, sleep breaks long jobs, and third-party lock utilities request
administrator rights. This plugin only calls `user32!LockWorkStation`, the exact same API `Win+L` uses,
so nothing else on the machine is touched.

## Install

DSH installs plugin bundles from a local package directory:

```text
plugin_manager { action: "install_bundle", target: "<absolute path to this directory>" }
```

Or keep it in a profile as a linked checkout during development.

Once installed, ask the agent to lock the screen, or call the tool directly:

```text
pc_guard { action: "lock" }
pc_guard { action: "status" }
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
-ForceResumeMin 30 -NoWakeIdleSec 120 -AutoLockMin 10`.

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
- `status`：返回当前 CPU 占用与空闲秒数。

附带的 `assets/PcGuard.ps1` 也可以脱离 DSH 单独运行，带一个小窗口：实时 CPU、一键锁屏、CPU 超阈值
自动暂停 OCR / 进程、锁屏后压制自动亮屏。

安装：用 `plugin_manager` 的 `install_bundle` 指向本目录绝对路径即可。
