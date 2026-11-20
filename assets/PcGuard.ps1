<#
  PcGuard.ps1  --  一键锁屏 + CPU 守护 + 锁屏后压制自动亮屏
  用法：
    启动小窗      powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File PcGuard.ps1
    自检          powershell -NoProfile -ExecutionPolicy Bypass -File PcGuard.ps1 -SelfTest
    无界面守护    powershell -NoProfile -ExecutionPolicy Bypass -File PcGuard.ps1 -Headless

  规则（可在界面里调）：
    CPU >= 90% 连续 9 秒  -> 暂停目标进程
    CPU <  40% 连续 5 分钟 -> 恢复
    暂停超过 30 分钟       -> 强制恢复（安全兜底）
#>
[CmdletBinding()]
param(
    [double]$CpuPause = 90,
    [double]$CpuResume = 40,
    [int]$ResumeHoldMin = 5,
    [int]$IntervalSec = 3,
    [int]$PauseStreak = 3,
    [int]$ForceResumeMin = 30,
    [int]$NoWakeIdleSec = 120,
    [int]$AutoLockMin = 10,
    [int]$LowBatteryPct = 20,
    [int]$LowBatteryResumePct = 25,
    [ValidateSet('ui', 'lock', 'status', 'shortcut')]
    [string]$Action = 'ui',
    [switch]$Headless,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:Root) { $script:Root = (Get-Location).Path }
$script:LogPath = Join-Path $script:Root 'pc-guard.log'

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    if ($Headless -or $SelfTest) { Write-Host $line }
}

# ---------- Win32 ----------
if (-not ('PcGuard.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
namespace PcGuard {
  public static class Native {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr hProcess);
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr hProcess);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool LockWorkStation();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    // 广播关屏必须带超时：HWND_BROADCAST 的 SendMessage 会同步等待每一个顶层窗口，
    // 只要有一个窗口卡住（锁屏后很常见），调用线程就永远回不来 —— 界面随即变成"未响应"。
    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    // 判断当前输入桌面是不是锁屏桌面（Winlogon / LockApp）。
    // 比"自己记一个我锁过屏"的标志可靠：解锁后输入桌面变回 Default，状态自动复位。
    // 之前用 SessionSwitch 事件里的 $script:locked 做判断，事件 Action 有独立作用域，
    // 解锁时那次赋值写不到主脚本里，于是一旦锁过屏就永远认为"还在锁屏"，
    // 用户正常用着（只是两分钟没碰键鼠）屏幕就被每 10 秒关一次 —— 就是那次黑屏闪烁。
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool CloseDesktop(IntPtr hDesktop);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern bool GetUserObjectInformation(IntPtr hObj, int nIndex, System.Text.StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);
    public static bool IsLockedDesktop() {
      const uint DESKTOP_READOBJECTS = 0x0001;
      const int UOI_NAME = 2;
      IntPtr h = OpenInputDesktop(0, false, DESKTOP_READOBJECTS);
      if (h == IntPtr.Zero) { return true; }
      try {
        var sb = new System.Text.StringBuilder(256);
        int need;
        if (!GetUserObjectInformation(h, UOI_NAME, sb, 512, out need)) { return true; }
        string name = sb.ToString();
        return name.IndexOf("Winlogon", StringComparison.OrdinalIgnoreCase) >= 0
            || name.IndexOf("LockApp", StringComparison.OrdinalIgnoreCase) >= 0;
      } catch { return true; }
      finally { CloseDesktop(h); }
    }

    [DllImport("kernel32.dll")] public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS lpSystemPowerStatus);
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS {
      public byte ACLineStatus;
      public byte BatteryFlag;
      public byte BatteryLifePercent;
      public byte SystemStatusFlag;
      public int BatteryLifeTime;
      public int BatteryFullLifeTime;
    }
  }

  // CPU 采样放到后台线程：PerformanceCounter 在系统刚从睡眠/息屏恢复时可能卡住好几秒，
  // 如果它在 UI 线程上跑，整个窗口就会假死。这里只留一个原子读的数字给界面。
  public static class CpuSampler {
    private static Thread _thread;
    private static volatile bool _started;
    private static int _centi = -1;   // cpu*100；-1 = 还没采到，-2 = 当前不可用
    private static string _error = "";

    public static void Start() {
      if (_started) return;
      _started = true;
      try {
        _thread = new Thread(Loop);
        _thread.IsBackground = true;
        _thread.Priority = ThreadPriority.BelowNormal;
        _thread.Name = "PcGuardCpu";
        _thread.Start();
      } catch (Exception ex) { _centi = -2; _error = ex.Message; }
    }

    private static void Loop() {
      while (true) {
        System.Diagnostics.PerformanceCounter pc = null;
        try {
          pc = new System.Diagnostics.PerformanceCounter("Processor", "% Processor Time", "_Total");
          pc.NextValue();
        } catch (Exception ex) {
          _error = ex.Message;
          _centi = -2;
          pc = null;
        }
        if (pc != null) {
          try { pc.NextValue(); } catch { }      // 第一次读数是 0，先预热
          Thread.Sleep(250);
          while (true) {
            try {
              float v = pc.NextValue();
              if (v < 0f) v = 0f;
              if (v > 100f) v = 100f;
              _centi = (int)Math.Round(v * 100.0);
            } catch (Exception ex) {
              _error = ex.Message;
              _centi = -2;
              break;
            }
            Thread.Sleep(700);
          }
          try { pc.Dispose(); } catch { }
        }
        Thread.Sleep(5000);   // 计数器坏了就重建，别让线程退出
      }
    }

    public static double Cpu {
      get {
        int c = _centi;
        if (c < 0) return -1.0;
        return c / 100.0;
      }
    }
    public static bool Ready { get { return _centi >= 0; } }
    public static string Error { get { return _error == null ? "" : _error; } }
  }
}
'@
}
$SCRIPT:SUSPEND_RESUME = 0x0800
$SCRIPT:WM_SYSCOMMAND = 0x0112
$SCRIPT:SC_MONITORPOWER = 0xF170
$SCRIPT:HWND_BROADCAST = [IntPtr]0xFFFF

# ---------- 状态 ----------
$script:pausedIds   = @()
$script:pausedAt    = $null
$script:lowSince    = $null
$script:highStreak  = 0
$script:locked      = $false
$script:lastMonitorOff = $null
$script:autoGuard   = $true
$script:includeDsh  = $false
$script:noWake      = $true
$script:autoLock    = $true
$script:autoLockMin = $AutoLockMin
$script:lastLockAt  = [datetime]::MinValue
$script:lastCpu     = 0
$script:extraNames  = @()
try {
    $customFile = Join-Path $script:Root 'pc-guard.custom.txt'
    if (Test-Path -LiteralPath $customFile) {
        $script:extraNames = @((Get-Content -LiteralPath $customFile -Encoding UTF8) |
            ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
} catch { }
$script:pauseReason = ''
$script:lowBattery  = $true
$script:battery     = $null
$script:saverOn     = $false
$script:prevScheme  = $null
$SCRIPT:SAVER_GUID  = 'a1841308-3541-4fab-bc81-f71556f20b4a'

$script:cpuCounter = $null
try {
    $script:cpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
    [void]$script:cpuCounter.NextValue()
} catch { Write-Log "PerformanceCounter 不可用，改用 CIM: $($_.Exception.Message)" }

function Get-CpuPercent {
    $v = [PcGuard.CpuSampler]::Cpu
    if ($v -ge 0) { return [math]::Round($v, 1) }
    # 界面线程上绝不同步采样：采样器不可用时就沿用上一次的读数，宁可显示旧值也别假死。
    if ($Action -eq 'ui') { return [double]$script:lastCpu }
    if ($script:cpuCounter) {
        try { return [math]::Round([double]$script:cpuCounter.NextValue(), 1) } catch { }
    }
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 5 -ErrorAction Stop
        return [double]$p.PercentProcessorTime
    } catch { return -1 }
}

function Get-IdleSeconds {
    $lii = New-Object PcGuard.Native+LASTINPUTINFO
    $lii.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($lii)
    if ([PcGuard.Native]::GetLastInputInfo([ref]$lii)) {
        $now = [Environment]::TickCount
        $delta = [int64]($now - [int64]$lii.dwTime)
        if ($delta -lt 0) { $delta += 4294967296 }
        return [math]::Round($delta / 1000.0, 1)
    }
    return -1
}

function Get-BatteryInfo {
    $sps = New-Object PcGuard.Native+SYSTEM_POWER_STATUS
    try {
        if ([PcGuard.Native]::GetSystemPowerStatus([ref]$sps)) {
            $pct = [int]$sps.BatteryLifePercent
            $noBattery = (($sps.BatteryFlag -band 0x80) -ne 0) -or ($pct -gt 100)
            if ($pct -gt 100) { $pct = -1 }
            return [pscustomobject]@{
                HasBattery = (-not $noBattery)
                Percent    = $pct
                OnAC       = ($sps.ACLineStatus -eq 1)
            }
        }
    } catch { }
    return [pscustomobject]@{ HasBattery = $false; Percent = -1; OnAC = $true }
}

function Get-ActiveScheme {
    try {
        $out = & powercfg /getactivescheme 2>$null | Out-String
        if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            return $matches[1]
        }
    } catch { }
    return $null
}

function Set-PowerSaver {
    param([switch]$On)
    try {
        if ($On) {
            if ($script:saverOn) { return }
            $cur = Get-ActiveScheme
            if ($cur -and $cur -ne $SCRIPT:SAVER_GUID) { $script:prevScheme = $cur }
            & powercfg /setactive $SCRIPT:SAVER_GUID | Out-Null
            $script:saverOn = $true
            Write-Log '已切换到节能电源计划（低电量模式）'
        } else {
            if (-not $script:saverOn) { return }
            if ($script:prevScheme) { & powercfg /setactive $script:prevScheme | Out-Null }
            $script:saverOn = $false
            $script:prevScheme = $null
            Write-Log '已恢复原来的电源计划'
        }
    } catch { Write-Log "切换电源计划失败：$($_.Exception.Message)" }
}

function Invoke-BatteryTick {
    if (-not $script:lowBattery) { return }
    $b = Get-BatteryInfo
    $script:battery = $b
    if (-not $b.HasBattery) { return }

    $low = (-not $b.OnAC) -and ($b.Percent -ge 0) -and ($b.Percent -le $LowBatteryPct)
    if ($low) {
        if ($script:pausedIds.Count -eq 0) {
            $targets = @(Get-TargetProcesses -IncludeDsh:$script:includeDsh)
            if ($targets.Count -gt 0) {
                Pause-All ('电池 {0}% 低于 {1}%，且未接电源' -f $b.Percent, $LowBatteryPct) 'battery'
                Set-PowerSaver -On
            }
        } else {
            Set-PowerSaver -On
        }
    } else {
        if ($script:saverOn) { Set-PowerSaver }
        if ($script:pauseReason -eq 'battery' -and ($b.OnAC -or $b.Percent -ge $LowBatteryResumePct -or $b.Percent -lt 0)) {
            Resume-All ('已接电源或电量回升到 {0}%' -f $b.Percent)
        }
    }
}

function Close-Monitor {
    # 带超时的广播：400 毫秒内没人应答就改发异步消息，绝不让主线程被别人的窗口拖住。
    $res = [IntPtr]::Zero
    try {
        $ok = [PcGuard.Native]::SendMessageTimeout($SCRIPT:HWND_BROADCAST, $SCRIPT:WM_SYSCOMMAND,
                [IntPtr]$SCRIPT:SC_MONITORPOWER, [IntPtr]2, 0x0002, 400, [ref]$res)
        if ($ok -eq [IntPtr]::Zero) {
            [void][PcGuard.Native]::PostMessage($SCRIPT:HWND_BROADCAST, $SCRIPT:WM_SYSCOMMAND,
                [IntPtr]$SCRIPT:SC_MONITORPOWER, [IntPtr]2)
        }
    } catch {
        try {
            [void][PcGuard.Native]::PostMessage($SCRIPT:HWND_BROADCAST, $SCRIPT:WM_SYSCOMMAND,
                [IntPtr]$SCRIPT:SC_MONITORPOWER, [IntPtr]2)
        } catch { }
    }
}

function Close-MonitorAsync {
    # 纯异步投递，立即返回：定时补发关屏时不该因为别人的窗口慢而让界面卡顿
    try {
        [void][PcGuard.Native]::PostMessage($SCRIPT:HWND_BROADCAST, $SCRIPT:WM_SYSCOMMAND,
            [IntPtr]$SCRIPT:SC_MONITORPOWER, [IntPtr]2)
    } catch { }
}

function Lock-Screen {
    $script:locked = $true
    [void][PcGuard.Native]::LockWorkStation()
    Write-Log '已锁屏（后台程序保持运行，不休眠）'
    # 不再 Start-Sleep 等锁屏动画：关屏本身带超时，锁屏期间 noWake 还会继续补发。
    Close-Monitor
}

# ---------- 进程选择 ----------
$script:OcrPattern = 'ocr|paddle|rapidocr|easyocr|ppocr|tesseract|cnocr|image.?recogni'

function Get-TargetProcesses {
    param([switch]$IncludeDsh)
    $result = New-Object System.Collections.ArrayList
    # 基础目标 + 用户自定义进程名，一起交给 CIM 过滤，避免逐个进程枚举
    $wqlNames = @("Name='python.exe'", "Name='pythonw.exe'", "Name='tesseract.exe'", "Name='DeepSeek Harness.exe'")
    foreach ($n in $script:extraNames) {
        $safe = ([string]$n) -replace "'", "''"
        if ($safe) { $wqlNames += ("Name LIKE '%{0}%'" -f $safe) }
    }
    $filter = ($wqlNames -join ' OR ')
    $procs = @()
    try { $procs = Get-CimInstance Win32_Process -Filter $filter -OperationTimeoutSec 8 -ErrorAction Stop } catch { }
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $PID) { continue }
        $cl = ''
        if ($p.CommandLine) { $cl = [string]$p.CommandLine }
        $name = [string]$p.Name
        $entry = $null
        if ($name -eq 'DeepSeek Harness.exe') {
            if (-not $IncludeDsh) { continue }
            $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            if ($gp -and $gp.MainWindowTitle -ne '') { continue }   # 会话界面进程不暂停，避免白屏
            $entry = [pscustomobject]@{ Id = $p.ProcessId; Name = 'DSH'; Kind = 'DSH'; Cmd = 'DeepSeek Harness' }
        }
        elseif ($name -eq 'tesseract.exe' -or $cl -match $script:OcrPattern) {
            $entry = [pscustomobject]@{ Id = $p.ProcessId; Name = $name; Kind = 'OCR'; Cmd = $cl }
        }
        elseif ($script:extraNames.Count -gt 0) {
            $hit = $false
            foreach ($n in $script:extraNames) { if ($name -like "*$n*") { $hit = $true; break } }
            if ($hit) { $entry = [pscustomobject]@{ Id = $p.ProcessId; Name = $name; Kind = '自定义'; Cmd = $cl } }
        }
        if ($entry) { [void]$result.Add($entry) }
    }
    return $result
}

function Suspend-Pid {
    param([int]$ProcId)
    $h = [PcGuard.Native]::OpenProcess($SCRIPT:SUSPEND_RESUME, $false, $ProcId)
    if ($h -eq [IntPtr]::Zero) { return $false }
    try { return ([PcGuard.Native]::NtSuspendProcess($h) -eq 0) }
    finally { [void][PcGuard.Native]::CloseHandle($h) }
}

function Resume-Pid {
    param([int]$ProcId)
    $h = [PcGuard.Native]::OpenProcess($SCRIPT:SUSPEND_RESUME, $false, $ProcId)
    if ($h -eq [IntPtr]::Zero) { return $false }
    try { return ([PcGuard.Native]::NtResumeProcess($h) -eq 0) }
    finally { [void][PcGuard.Native]::CloseHandle($h) }
}

function Pause-All {
    param([string]$Reason, [string]$Kind = 'cpu')
    if ($script:pausedIds.Count -gt 0) { return }
    $targets = @(Get-TargetProcesses -IncludeDsh:$script:includeDsh)
    if ($targets.Count -eq 0) {
        Write-Log "触发暂停（$Reason），但没有匹配到目标进程"
        return
    }
    $ok = New-Object System.Collections.ArrayList
    foreach ($t in $targets) {
        if (Suspend-Pid -ProcId $t.Id) { [void]$ok.Add($t.Id) }
    }
    if ($ok.Count -gt 0) {
        $script:pausedIds = @($ok)
        $script:pausedAt = Get-Date
        $script:lowSince = $null
        $script:pauseReason = $Kind
        Write-Log ("已暂停 {0} 个进程（{1}）：{2}" -f $ok.Count, $Reason, ($ok -join ','))
    } else {
        Write-Log "暂停失败（$Reason），可能是权限不足"
    }
}

function Resume-All {
    param([string]$Reason)
    if ($script:pausedIds.Count -eq 0) { return }
    $n = 0
    foreach ($id in $script:pausedIds) {
        if (Resume-Pid -ProcId $id) { $n++ }
    }
    Write-Log ("已恢复 {0}/{1} 个进程（{2}）" -f $n, $script:pausedIds.Count, $Reason)
    $script:pausedIds = @()
    $script:pausedAt = $null
    $script:lowSince = $null
    $script:highStreak = 0
    $script:pauseReason = ''
}

function Update-State {
    $cpu = Get-CpuPercent
    if ($cpu -lt 0) { return $script:lastCpu }
    $script:lastCpu = $cpu

    if ($script:pausedIds.Count -gt 0) {
        # 低电量引起的暂停只由电池状态解除，不套用 CPU 的 30 分钟强制恢复，否则会继续耗电
        if ($script:pauseReason -eq 'battery') { return $cpu }
        if ($script:pausedAt -and ((Get-Date) - $script:pausedAt).TotalMinutes -ge $ForceResumeMin) {
            Resume-All "暂停超过 $ForceResumeMin 分钟，强制恢复"
            return $cpu
        }
        if ($cpu -lt $CpuResume) {
            if ($null -eq $script:lowSince) { $script:lowSince = Get-Date }
            if (((Get-Date) - $script:lowSince).TotalMinutes -ge $ResumeHoldMin) {
                Resume-All "CPU 低于 $CpuResume% 且持续 $ResumeHoldMin 分钟"
            }
        } else {
            $script:lowSince = $null
        }
    } else {
        if ($cpu -ge $CpuPause) {
            $script:highStreak++
            if ($script:highStreak -ge $PauseStreak -and $script:autoGuard) {
                $script:highStreak = 0
                Pause-All "CPU $cpu% 超过 $CpuPause%"
            }
        } else {
            $script:highStreak = 0
        }
    }
    return $cpu
}

function Invoke-NoWakeTick {
    if (-not $script:noWake) { return }
    # 用真实的输入桌面判断，而不是自己记录的标志
    $lockedNow = $script:locked
    try { $lockedNow = [PcGuard.Native]::IsLockedDesktop() } catch { }
    $script:locked = $lockedNow
    if (-not $lockedNow) { return }
    $idle = Get-IdleSeconds
    if ($idle -lt 0) { return }            # 取不到空闲时间就什么都不做，绝不拿 -1 当"该关屏"
    if ($idle -lt $NoWakeIdleSec) { return }
    # 两次关屏至少间隔 25 秒，避免任何误判把屏幕刷成闪烁
    if ($script:lastMonitorOff -and ((Get-Date) - $script:lastMonitorOff).TotalSeconds -lt 25) { return }
    if (-not $script:lastMonitorOff -or ((Get-Date) - $script:lastMonitorOff).TotalSeconds -ge 300) {
        Write-Log ('锁屏后关屏（已闲置 {0} 秒）' -f [int]$idle)
    }
    $script:lastMonitorOff = Get-Date
    Close-MonitorAsync
}

# ---------- 命令行动作（供 DSH 插件调用） ----------
if ($Action -ne 'ui') {
    switch ($Action) {
        'lock' {
            Lock-Screen
            Write-Output '{"ok":true,"action":"lock"}'
        }
        'status' {
            # 后台采样器先跑起来，等它拿到第一个读数（不是同步空转 CPU 计数器）
            [PcGuard.CpuSampler]::Start()
            $waited = 0
            while (-not [PcGuard.CpuSampler]::Ready -and $waited -lt 1500) {
                Start-Sleep -Milliseconds 100
                $waited += 100
            }
            $cpu = Get-CpuPercent
            if ($cpu -lt 0) { $cpu = 0 }
            $targets = @(Get-TargetProcesses)
            $bat = Get-BatteryInfo
            $obj = [ordered]@{
                ok         = $true
                cpu        = [math]::Round($cpu, 1)
                idleSec    = (Get-IdleSeconds)
                targets    = $targets.Count
                batteryPct = $bat.Percent
                onAC       = $bat.OnAC
                timestamp  = (Get-Date -Format 's')
            }
            Write-Output ($obj | ConvertTo-Json -Compress)
        }
        'shortcut' {
            # 快捷方式不能直接指向 powershell.exe：Win11 会把它交给 Windows Terminal，
            # 屏幕上多出一个控制台窗口，关掉它还会把管家一起带走。
            # 用 wscript 启动器（Run 的第二参数 0 = 隐藏窗口）就没有任何控制台。
            $vbsPath = Join-Path $script:Root 'launch.vbs'
            $vbsBody = @"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$PSCommandPath""", 0, False
"@
            [System.IO.File]::WriteAllText($vbsPath, $vbsBody, (New-Object System.Text.UnicodeEncoding($false, $true)))

            $desktop = [Environment]::GetFolderPath('Desktop')
            $lnkPath = Join-Path $desktop '锁屏管家.lnk'
            $shell = New-Object -ComObject WScript.Shell
            $lnk = $shell.CreateShortcut($lnkPath)
            $lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
            $lnk.Arguments = ('"{0}"' -f $vbsPath)
            $lnk.WorkingDirectory = $script:Root
            $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll,54')
            $lnk.Description = '锁屏管家：一键锁屏 + CPU 守护'
            $lnk.Save()
            $o = [ordered]@{ ok = $true; action = 'shortcut'; path = $lnkPath; launcher = $vbsPath }
            Write-Output ($o | ConvertTo-Json -Compress)
        }
    }
    return
}

# ---------- 自检 ----------
if ($SelfTest) {
    Write-Host ('CPU: {0}%' -f (Get-CpuPercent))
    Write-Host ('空闲秒数: {0}' -f (Get-IdleSeconds))
    Write-Host '--- 默认目标（不含 DSH）---'
    Get-TargetProcesses | Format-Table Id, Kind, Name, Cmd -AutoSize | Out-String -Width 160
    Write-Host '--- 含 DSH 的目标 ---'
    Get-TargetProcesses -IncludeDsh | Format-Table Id, Kind, Name, Cmd -AutoSize | Out-String -Width 160
    return
}

# ---------- 单实例 ----------
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\PcGuard_SingleInstance')
if (-not $script:mutex.WaitOne(0)) {
    # 已有实例在跑：把它的窗口拉到前台，而不是再开一个
    $open = Get-Process -Name powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -eq '锁屏管家' } |
        Select-Object -First 1
    if ($open -and $open.MainWindowHandle -ne 0) {
        # 异步版本：旧窗口要是已经卡住，同步的 ShowWindow 会把新进程一起拖死
        [void][PcGuard.Native]::ShowWindowAsync($open.MainWindowHandle, 9)
        try { [void][PcGuard.Native]::SetForegroundWindow($open.MainWindowHandle) } catch { }
    }
    Write-Log 'PcGuard 已在运行，已尝试激活已有窗口'
    if (-not $Headless) { Write-Host 'PcGuard 已在运行' }
    exit 0
}

# ---------- 无界面模式 ----------
if ($Headless) {
    [PcGuard.CpuSampler]::Start()
    Write-Log "PcGuard 无界面守护启动：暂停阈值 $CpuPause%，恢复阈值 $CpuResume% / $ResumeHoldMin 分钟"
    while ($true) {
        [void](Update-State)
        Invoke-BatteryTick
        Invoke-NoWakeTick
        Start-Sleep -Seconds $IntervalSec
    }
}

# ---------- 界面 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if (-not ('Guard.T' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Drawing','System.Windows.Forms' -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;

namespace Guard {
  public static class T {
    public static readonly Color Bg      = Color.FromArgb(247, 248, 252);
    public static readonly Color Card    = Color.FromArgb(255, 255, 255);
    public static readonly Color Accent  = Color.FromArgb(77, 107, 254);
    public static readonly Color Accent2 = Color.FromArgb(45, 60, 152);
    public static readonly Color AccentSoft = Color.FromArgb(238, 241, 255);
    public static readonly Color Ink     = Color.FromArgb(24, 26, 34);
    public static readonly Color Sub     = Color.FromArgb(122, 128, 146);
    public static readonly Color Line    = Color.FromArgb(233, 235, 242);
    public static readonly Color Danger  = Color.FromArgb(228, 60, 66);
    public static readonly Color Warn    = Color.FromArgb(235, 152, 32);
    public static readonly Color Ok      = Color.FromArgb(20, 158, 88);
    public static readonly Color Track   = Color.FromArgb(233, 236, 245);
    public static readonly Color Off     = Color.FromArgb(206, 210, 222);

    public static GraphicsPath Round(Rectangle r, int rad) {
      var p = new GraphicsPath();
      int d = rad * 2;
      if (d <= 2) { p.AddRectangle(r); return p; }
      if (d > r.Width) d = r.Width;
      if (d > r.Height) d = r.Height;
      p.AddArc(r.X, r.Y, d, d, 180, 90);
      p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
      p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
      p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
      p.CloseFigure();
      return p;
    }
  }

  public class Shell : Form {
    public Shell() {
      SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
      DoubleBuffered = true;
      FormBorderStyle = FormBorderStyle.None;
      BackColor = T.Bg;
      Font = new Font("Microsoft YaHei UI", 9f);
    }
    protected override CreateParams CreateParams {
      get { var cp = base.CreateParams; cp.ClassStyle |= 0x20000; return cp; }
    }
    protected override void OnResize(EventArgs e) {
      base.OnResize(e);
      if (Width > 0 && Height > 0) {
        using (var p = T.Round(new Rectangle(0, 0, Width, Height), 14)) Region = new Region(p);
      }
    }
  }

  public class Card : Panel {
    public int Radius = 12;
    public bool DrawBorder = false;
    public Card() {
      SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
      BackColor = T.Card;
    }
    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.Clear(Parent == null ? T.Bg : Parent.BackColor);
      var r = new Rectangle(0, 0, Width - 1, Height - 1);
      using (var path = T.Round(r, Radius)) {
        using (var b = new SolidBrush(BackColor)) g.FillPath(b, path);
        if (DrawBorder) using (var pen = new Pen(T.Line, 1f)) g.DrawPath(pen, path);
      }
    }
  }

  public class FlatBtn : Button {
    public Color Fill = T.Accent;
    public Color HoverFill = Color.FromArgb(97, 124, 255);
    public Color DownFill = T.Accent2;
    public Color TextColor = Color.White;
    public int Radius = 10;
    public bool Outline = false;
    private bool hover, down;
    public FlatBtn() {
      SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
      FlatStyle = FlatStyle.Flat;
      FlatAppearance.BorderSize = 0;
      Cursor = Cursors.Hand;
      Font = new Font("Microsoft YaHei UI", 10f, FontStyle.Bold);
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.Clear(Parent == null ? T.Bg : Parent.BackColor);
      var r = new Rectangle(0, 0, Width - 1, Height - 1);
      using (var path = T.Round(r, Radius)) {
        if (Outline) {
          using (var b = new SolidBrush(hover ? T.AccentSoft : Color.White)) g.FillPath(b, path);
          using (var pen = new Pen(hover ? T.Accent : T.Line, 1.4f)) g.DrawPath(pen, path);
        } else {
          Color f = down ? DownFill : (hover ? HoverFill : Fill);
          using (var b = new SolidBrush(f)) g.FillPath(b, path);
        }
      }
      Color tc = Outline ? (hover ? T.Accent : T.Ink) : TextColor;
      TextRenderer.DrawText(g, Text, Font, r, tc, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    }
  }

  public class Toggle : CheckBox {
    public Toggle() {
      SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
      Font = new Font("Microsoft YaHei UI", 9f);
      Cursor = Cursors.Hand;
      BackColor = T.Bg;
      Height = 26;
    }
    protected override void OnCheckedChanged(EventArgs e) { Invalidate(); base.OnCheckedChanged(e); }
    protected override void OnMouseEnter(EventArgs e) { Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { Invalidate(); base.OnMouseLeave(e); }
    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.Clear(Parent == null ? T.Bg : Parent.BackColor);
      int tw = 38, th = 21;
      int ty = (Height - th) / 2;
      var track = new Rectangle(0, ty, tw, th);
      using (var path = T.Round(track, th / 2)) {
        using (var b = new SolidBrush(Checked ? T.Accent : T.Off)) g.FillPath(b, path);
      }
      float cx = Checked ? tw - th / 2f : th / 2f;
      using (var b = new SolidBrush(Color.White)) g.FillEllipse(b, cx - 8.5f, ty + 2.5f, 17f, 17f);
      using (var b = new SolidBrush(Checked ? T.Ink : Color.FromArgb(96, 100, 116)))
        g.DrawString(Text, Font, b, new RectangleF(tw + 12, 0, Width - tw - 14, Height),
          new StringFormat { LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap });
    }
  }

  public class Bar : Control {
    public double Value = 0;
    public Bar() {
      SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
      BackColor = T.Card;
    }
    public void SetValue(double v) { Value = v; Invalidate(); }
    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.Clear(Parent == null ? T.Card : Parent.BackColor);
      var track = new Rectangle(0, 0, Width - 1, Height - 1);
      using (var path = T.Round(track, Height / 2)) {
        using (var b = new SolidBrush(T.Track)) g.FillPath(b, path);
        int w = (int)(Width * Math.Max(0, Math.Min(100, Value)) / 100.0);
        if (w > 6) {
          var fill = new Rectangle(0, 0, w, Height - 1);
          Color c = Value >= 90 ? T.Danger : (Value >= 70 ? T.Warn : T.Accent);
          Color c2 = Color.FromArgb(Math.Min(255, c.R + 45), Math.Min(255, c.G + 35), Math.Min(255, c.B + 10));
          using (var fp = T.Round(fill, Height / 2)) {
            using (var b2 = new LinearGradientBrush(new Rectangle(0, 0, Math.Max(w, 2), Math.Max(Height, 2)), c, c2, 0f))
              g.FillPath(b2, fp);
          }
        }
      }
    }
  }

  public class Battery : Control {
    public int Percent = 0;
    public bool Charging = false;
    public bool Present = true;
    public Battery() {
      SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
      BackColor = T.Card;
    }
    public void SetState(int pct, bool charging, bool present) { Percent = pct; Charging = charging; Present = present; Invalidate(); }
    protected override void OnPaint(PaintEventArgs e) {
      var g = e.Graphics;
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.Clear(Parent == null ? T.Card : Parent.BackColor);
      if (!Present) return;
      int h = 14, w = 28, top = (Height - h) / 2;
      var body = new Rectangle(0, top, w - 4, h);
      Color c = Charging ? T.Accent : (Percent <= 20 ? T.Danger : (Percent <= 50 ? T.Warn : T.Ok));
      using (var pen = new Pen(Color.FromArgb(190, c), 1.5f)) {
        using (var path = T.Round(body, 4)) g.DrawPath(pen, path);
      }
      using (var b = new SolidBrush(Color.FromArgb(190, c))) g.FillRectangle(b, w - 4, top + 4, 3, h - 8);
      int innerW = body.Width - 7;
      int fillW = (int)(innerW * Percent / 100.0);
      if (fillW > 0) {
        var inner = new Rectangle(2, top + 3, fillW, h - 6);
        using (var path = T.Round(inner, 2)) using (var b = new SolidBrush(c)) g.FillPath(b, path);
      }
    }
  }
}
'@
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:CardColor = [Guard.T]::Card

$form = New-Object Guard.Shell
$form.Text = '锁屏管家'
$form.ClientSize = New-Object System.Drawing.Size(480, 780)
$form.StartPosition = 'CenterScreen'

# ---------- 标题栏 ----------
$titleBar = New-Object System.Windows.Forms.Panel
$titleBar.Size = New-Object System.Drawing.Size(480, 52)
$titleBar.Location = New-Object System.Drawing.Point(0, 0)
$titleBar.BackColor = [Guard.T]::Card
$form.Controls.Add($titleBar)

$titleBar.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    # 品牌小方块
    $logoPath = [Guard.T]::Round((New-Object System.Drawing.Rectangle(20, 13, 26, 26)), 8)
    $bLogo = New-Object System.Drawing.SolidBrush([Guard.T]::Accent)
    $g.FillPath($bLogo, $logoPath)
    # 白色锁形
    $penLock = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 2.0)
    $g.DrawArc($penLock, 27, 19, 12, 12, 180, 180)
    $bWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $g.FillRectangle($bWhite, 27, 25, 12, 10)
    # 标题
    $fTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 13.5, [System.Drawing.FontStyle]::Bold)
    $bInk = New-Object System.Drawing.SolidBrush([Guard.T]::Ink)
    $g.DrawString('锁屏管家', $fTitle, $bInk, 58, 9)
    $fSub = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $bSub = New-Object System.Drawing.SolidBrush([Guard.T]::Sub)
    $g.DrawString('LOCK  &  CPU  GUARD', $fSub, $bSub, 60, 33)
})

$btnMin = New-Object System.Windows.Forms.Label
$btnMin.Text = '–'
$btnMin.Font = New-Object System.Drawing.Font('Segoe UI', 12)
$btnMin.ForeColor = [Guard.T]::Sub
$btnMin.BackColor = [Guard.T]::Card
$btnMin.TextAlign = 'MiddleCenter'
$btnMin.Size = New-Object System.Drawing.Size(30, 30)
$btnMin.Location = New-Object System.Drawing.Point(392, 11)
$btnMin.Cursor = 'Hand'
$btnMin.Add_Click({ $form.WindowState = 'Minimized' })
$titleBar.Controls.Add($btnMin)

$btnClose = New-Object System.Windows.Forms.Label
$btnClose.Text = '×'
$btnClose.Font = New-Object System.Drawing.Font('Segoe UI', 14)
$btnClose.ForeColor = [Guard.T]::Sub
$btnClose.BackColor = [Guard.T]::Card
$btnClose.TextAlign = 'MiddleCenter'
$btnClose.Size = New-Object System.Drawing.Size(30, 30)
$btnClose.Location = New-Object System.Drawing.Point(426, 11)
$btnClose.Cursor = 'Hand'
$btnClose.Add_Click({ $form.Close() })
$btnClose.Add_MouseEnter({ $btnClose.ForeColor = [Guard.T]::Danger })
$btnClose.Add_MouseLeave({ $btnClose.ForeColor = [Guard.T]::Sub })
$titleBar.Controls.Add($btnClose)

# 拖动
$script:dragOrigin = $null
$script:dragForm = $null
$titleBar.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragOrigin = $s.PointToScreen($e.Location)
        $script:dragForm = $form.Location
    }
})
$titleBar.Add_MouseMove({
    param($s, $e)
    if ($null -ne $script:dragOrigin -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $p = $s.PointToScreen($e.Location)
        $form.Location = New-Object System.Drawing.Point((
            $script:dragForm.X + ($p.X - $script:dragOrigin.X)),
            ($script:dragForm.Y + ($p.Y - $script:dragOrigin.Y)))
    }
})
$titleBar.Add_MouseUp({ $script:dragOrigin = $null; $script:dragForm = $null })

# ---------- CPU 卡片 ----------
$cardCpu = New-Object Guard.Card
$cardCpu.Location = New-Object System.Drawing.Point(16, 64)
$cardCpu.Size = New-Object System.Drawing.Size(448, 108)
$form.Controls.Add($cardCpu)

$lblCpuTitle = New-Object System.Windows.Forms.Label
$lblCpuTitle.Text = 'CPU 占用'
$lblCpuTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$lblCpuTitle.ForeColor = [Guard.T]::Sub
$lblCpuTitle.BackColor = [System.Drawing.Color]::Transparent
$lblCpuTitle.AutoSize = $true
$lblCpuTitle.Location = New-Object System.Drawing.Point(20, 14)
$cardCpu.Controls.Add($lblCpuTitle)

$lblCpu = New-Object System.Windows.Forms.Label
$lblCpu.Text = '--'
$lblCpu.Font = New-Object System.Drawing.Font('Segoe UI', 34, [System.Drawing.FontStyle]::Bold)
$lblCpu.ForeColor = [Guard.T]::Accent
$lblCpu.BackColor = [System.Drawing.Color]::Transparent
$lblCpu.Location = New-Object System.Drawing.Point(18, 32)
$lblCpu.Size = New-Object System.Drawing.Size(160, 62)
$cardCpu.Controls.Add($lblCpu)

$barCpu = New-Object Guard.Bar
$barCpu.Location = New-Object System.Drawing.Point(196, 62)
$barCpu.Size = New-Object System.Drawing.Size(232, 10)
$cardCpu.Controls.Add($barCpu)

$lblThr = New-Object System.Windows.Forms.Label
$lblThr.Text = ('暂停 {0}%   恢复 {1}%' -f $CpuPause, $CpuResume)
$lblThr.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblThr.ForeColor = [Guard.T]::Sub
$lblThr.BackColor = [System.Drawing.Color]::Transparent
$lblThr.AutoSize = $true
$lblThr.Location = New-Object System.Drawing.Point(198, 38)
$cardCpu.Controls.Add($lblThr)

# ---------- 状态卡片 ----------
$cardStatus = New-Object Guard.Card
$cardStatus.Location = New-Object System.Drawing.Point(16, 182)
$cardStatus.Size = New-Object System.Drawing.Size(448, 100)
$form.Controls.Add($cardStatus)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '监控中'
$lblStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [Guard.T]::Ink
$lblStatus.BackColor = [System.Drawing.Color]::Transparent
$lblStatus.Location = New-Object System.Drawing.Point(20, 14)
$lblStatus.Size = New-Object System.Drawing.Size(408, 34)
$cardStatus.Controls.Add($lblStatus)

$batCtl = New-Object Guard.Battery
$batCtl.Location = New-Object System.Drawing.Point(20, 58)
$batCtl.Size = New-Object System.Drawing.Size(30, 18)
$cardStatus.Controls.Add($batCtl)

$lblBat = New-Object System.Windows.Forms.Label
$lblBat.Text = '正在读取电池…'
$lblBat.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$lblBat.ForeColor = [Guard.T]::Sub
$lblBat.BackColor = [System.Drawing.Color]::Transparent
$lblBat.Location = New-Object System.Drawing.Point(58, 54)
$lblBat.Size = New-Object System.Drawing.Size(368, 24)
$cardStatus.Controls.Add($lblBat)

# ---------- 开关 ----------
$chkAuto = New-Object Guard.Toggle
$chkAuto.Text = ('CPU 超过 {0}% 自动暂停，低于 {1}% 持续 {2} 分钟后恢复' -f $CpuPause, $CpuResume, $ResumeHoldMin)
$chkAuto.Location = New-Object System.Drawing.Point(18, 294)
$chkAuto.Size = New-Object System.Drawing.Size(444, 26)
$chkAuto.Checked = $true
$form.Controls.Add($chkAuto)

$chkDsh = New-Object Guard.Toggle
$chkDsh.Text = '同时暂停 DeepSeek Harness 进程（对话界面会暂时冻结）'
$chkDsh.Location = New-Object System.Drawing.Point(18, 324)
$chkDsh.Size = New-Object System.Drawing.Size(444, 26)
$chkDsh.Checked = $false
$form.Controls.Add($chkDsh)

$chkNoWake = New-Object Guard.Toggle
$chkNoWake.Text = '锁屏后压制自动亮屏（无操作时反复关屏）'
$chkNoWake.Location = New-Object System.Drawing.Point(18, 354)
$chkNoWake.Size = New-Object System.Drawing.Size(444, 26)
$chkNoWake.Checked = $true
$form.Controls.Add($chkNoWake)

$chkAutoLock = New-Object Guard.Toggle
$chkAutoLock.Text = ('空闲 {0} 分钟后自动锁屏（锁屏后自动熄屏）' -f $AutoLockMin)
$chkAutoLock.Location = New-Object System.Drawing.Point(18, 384)
$chkAutoLock.Size = New-Object System.Drawing.Size(444, 26)
$chkAutoLock.Checked = $true
$form.Controls.Add($chkAutoLock)

$chkBattery = New-Object Guard.Toggle
$chkBattery.Text = ('低电量保护：未接电源且电量 <= {0}% 时暂停任务并节能' -f $LowBatteryPct)
$chkBattery.Location = New-Object System.Drawing.Point(18, 414)
$chkBattery.Size = New-Object System.Drawing.Size(444, 26)
$chkBattery.Checked = $true
$form.Controls.Add($chkBattery)

# ---------- 命中进程 ----------
$lblTargets = New-Object System.Windows.Forms.Label
$lblTargets.Text = '命中进程'
$lblTargets.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$lblTargets.ForeColor = [Guard.T]::Ink
$lblTargets.AutoSize = $true
$lblTargets.Location = New-Object System.Drawing.Point(18, 452)
$form.Controls.Add($lblTargets)

$lblTargetCount = New-Object System.Windows.Forms.Label
$lblTargetCount.Text = ''
$lblTargetCount.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$lblTargetCount.ForeColor = [Guard.T]::Sub
$lblTargetCount.AutoSize = $false
$lblTargetCount.TextAlign = 'MiddleRight'
$lblTargetCount.Size = New-Object System.Drawing.Size(444, 20)
$lblTargetCount.Location = New-Object System.Drawing.Point(18, 448)
$form.Controls.Add($lblTargetCount)

$cardList = New-Object Guard.Card
$cardList.Location = New-Object System.Drawing.Point(16, 470)
$cardList.Size = New-Object System.Drawing.Size(448, 110)
$form.Controls.Add($cardList)

$lstTargets = New-Object System.Windows.Forms.ListBox
$lstTargets.Location = New-Object System.Drawing.Point(10, 10)
$lstTargets.Size = New-Object System.Drawing.Size(428, 90)
$lstTargets.BorderStyle = 'None'
$lstTargets.BackColor = [Guard.T]::Card
$lstTargets.ForeColor = [Guard.T]::Ink
$lstTargets.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$lstTargets.HorizontalScrollbar = $true
$cardList.Controls.Add($lstTargets)

# ---------- 自定义进程 ----------
$cardInput = New-Object Guard.Card
$cardInput.Location = New-Object System.Drawing.Point(16, 586)
$cardInput.Size = New-Object System.Drawing.Size(296, 34)
$cardInput.DrawBorder = $true
$form.Controls.Add($cardInput)

$txtCustom = New-Object System.Windows.Forms.TextBox
$txtCustom.Location = New-Object System.Drawing.Point(10, 7)
$txtCustom.Size = New-Object System.Drawing.Size(276, 20)
$txtCustom.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$txtCustom.BorderStyle = 'None'
$txtCustom.BackColor = [Guard.T]::Card
$cardInput.Controls.Add($txtCustom)

$btnAdd = New-Object Guard.FlatBtn
$btnAdd.Text = '添加'
$btnAdd.Location = New-Object System.Drawing.Point(318, 588)
$btnAdd.Size = New-Object System.Drawing.Size(72, 30)
$btnAdd.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$btnAdd.Outline = $true
$btnAdd.Radius = 8
$form.Controls.Add($btnAdd)

$btnClear = New-Object Guard.FlatBtn
$btnClear.Text = '清空'
$btnClear.Location = New-Object System.Drawing.Point(396, 588)
$btnClear.Size = New-Object System.Drawing.Size(68, 30)
$btnClear.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$btnClear.Outline = $true
$btnClear.Radius = 8
$form.Controls.Add($btnClear)

$lblCustomInfo = New-Object System.Windows.Forms.Label
$lblCustomInfo.Text = '自定义进程：无'
$lblCustomInfo.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblCustomInfo.ForeColor = [Guard.T]::Sub
$lblCustomInfo.Location = New-Object System.Drawing.Point(18, 622)
$lblCustomInfo.Size = New-Object System.Drawing.Size(444, 18)
$form.Controls.Add($lblCustomInfo)

# ---------- 三个按钮 ----------
$btnLock = New-Object Guard.FlatBtn
$btnLock.Text = '一键锁屏'
$btnLock.Location = New-Object System.Drawing.Point(16, 648)
$btnLock.Size = New-Object System.Drawing.Size(200, 48)
$btnLock.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11.5, [System.Drawing.FontStyle]::Bold)
$btnLock.Radius = 12
$form.Controls.Add($btnLock)

$btnPause = New-Object Guard.FlatBtn
$btnPause.Text = '立即暂停'
$btnPause.Location = New-Object System.Drawing.Point(228, 648)
$btnPause.Size = New-Object System.Drawing.Size(112, 48)
$btnPause.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
$btnPause.Outline = $true
$btnPause.Radius = 12
$form.Controls.Add($btnPause)

$btnResume = New-Object Guard.FlatBtn
$btnResume.Text = '恢复'
$btnResume.Location = New-Object System.Drawing.Point(352, 648)
$btnResume.Size = New-Object System.Drawing.Size(110, 48)
$btnResume.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5, [System.Drawing.FontStyle]::Bold)
$btnResume.Outline = $true
$btnResume.Radius = 12
$form.Controls.Add($btnResume)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '锁屏不会关闭后台程序，也不会休眠；解锁后一切照旧。'
$lblHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$lblHint.ForeColor = [Guard.T]::Sub
$lblHint.Location = New-Object System.Drawing.Point(18, 704)
$lblHint.Size = New-Object System.Drawing.Size(444, 20)
$form.Controls.Add($lblHint)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = ''
$lblLog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblLog.ForeColor = [Guard.T]::Sub
$lblLog.Location = New-Object System.Drawing.Point(18, 726)
$lblLog.Size = New-Object System.Drawing.Size(444, 18)
$form.Controls.Add($lblLog)

$lblPaused = New-Object System.Windows.Forms.Label
$lblPaused.Text = ''
$lblPaused.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5, [System.Drawing.FontStyle]::Bold)
$lblPaused.ForeColor = [Guard.T]::Danger
$lblPaused.Location = New-Object System.Drawing.Point(18, 746)
$lblPaused.Size = New-Object System.Drawing.Size(444, 20)
$form.Controls.Add($lblPaused)

# ---------- 逻辑 ----------
$script:customFile = Join-Path $script:Root 'pc-guard.custom.txt'

function Save-CustomNames {
    try {
        if ($script:extraNames.Count -gt 0) {
            Set-Content -LiteralPath $script:customFile -Value $script:extraNames -Encoding UTF8
        } elseif (Test-Path -LiteralPath $script:customFile) {
            Remove-Item -LiteralPath $script:customFile -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Load-CustomNames {
    if (Test-Path -LiteralPath $script:customFile) {
        try {
            $lines = Get-Content -LiteralPath $script:customFile -Encoding UTF8
            $script:extraNames = @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } catch { }
    }
}

function Refresh-CustomInfo {
    if ($script:extraNames.Count -gt 0) {
        $lblCustomInfo.Text = ('自定义进程：{0}' -f ($script:extraNames -join '、'))
    } else {
        $lblCustomInfo.Text = '自定义进程：无（在上面输入进程名，例如 ffmpeg、chrome）'
    }
}

function Refresh-TargetList {
    $items = @(Get-TargetProcesses -IncludeDsh:$chkDsh.Checked)
    $lstTargets.BeginUpdate()
    $lstTargets.Items.Clear()
    foreach ($t in $items) {
        $short = $t.Cmd
        if ($short.Length -gt 62) { $short = $short.Substring(0, 62) + '...' }
        [void]$lstTargets.Items.Add(('[#{0}] {1} · {2} · {3}' -f $t.Id, $t.Kind, $t.Name, $short))
    }
    if ($lstTargets.Items.Count -eq 0) {
        [void]$lstTargets.Items.Add('（当前没有匹配的进程）')
    }
    $lstTargets.EndUpdate()
    $lblTargetCount.Text = ('{0} 个' -f $items.Count)
}

$btnAdd.Add_Click({
    $name = ($txtCustom.Text -replace '\.exe$', '').Trim()
    if (-not $name) { return }
    if ($script:extraNames -notcontains $name) {
        $script:extraNames = @($script:extraNames) + $name
        Save-CustomNames
        Write-Log ("添加自定义进程：$name")
    }
    $txtCustom.Text = ''
    Refresh-CustomInfo
    Refresh-TargetList
})

$txtCustom.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $btnAdd.PerformClick() }
})

$btnClear.Add_Click({
    $script:extraNames = @()
    Save-CustomNames
    Refresh-CustomInfo
    Refresh-TargetList
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $IntervalSec * 1000
$timer.Add_Tick({
    $cpu = Update-State
    try { Invoke-BatteryTick } catch { }
    if ($cpu -ge 0) {
        $lblCpu.Text = ('{0}' -f [int][math]::Round($cpu))
        $barCpu.SetValue([double]$cpu)
        if ($cpu -ge $CpuPause) { $lblCpu.ForeColor = [Guard.T]::Danger }
        elseif ($cpu -ge 70) { $lblCpu.ForeColor = [Guard.T]::Warn }
        else { $lblCpu.ForeColor = [Guard.T]::Accent }
    }

    if ($script:battery -and $script:battery.HasBattery) {
        $batCtl.SetState([int]$script:battery.Percent, [bool]$script:battery.OnAC, $true)
        $acTxt = '未接电源'
        if ($script:battery.OnAC) { $acTxt = '已接电源' }
        $leftTxt = ''
        if (-not $script:battery.OnAC -and $script:battery.Percent -le $LowBatteryPct) {
            $leftTxt = ('  ·  低于 {0}%，即将进入保护' -f $LowBatteryPct)
        }
        $lblBat.Text = ('电池 {0}%  ·  {1}{2}' -f $script:battery.Percent, $acTxt, $leftTxt)
        $lblBat.ForeColor = if ($script:battery.Percent -le $LowBatteryPct -and -not $script:battery.OnAC) { [Guard.T]::Danger } else { [Guard.T]::Sub }
    } elseif ($script:battery) {
        $batCtl.SetState(0, $false, $false)
        $lblBat.Text = '未检测到电池（台式机）'
        $lblBat.ForeColor = [Guard.T]::Sub
    }

    $lockPrefix = ''
    try { $script:locked = [PcGuard.Native]::IsLockedDesktop() } catch { }
    if ($script:locked) { $lockPrefix = '已锁屏  ·  ' }
    if ($script:pausedIds.Count -gt 0) {
        $mins = 0
        if ($script:pausedAt) { $mins = [math]::Round(((Get-Date) - $script:pausedAt).TotalMinutes, 1) }
        $why = ''
        if ($script:pauseReason -eq 'battery') { $why = '（低电量）' }
        $lblStatus.Text = ('{0}已暂停 {1} 个进程{2} · {3} 分钟' -f $lockPrefix, $script:pausedIds.Count, $why, $mins)
        $lblStatus.ForeColor = [Guard.T]::Danger
        $lblPaused.Text = ('已暂停 PID：{0}' -f ($script:pausedIds -join ', '))
    } else {
        $lblStatus.Text = ('{0}监控中' -f $lockPrefix)
        $lblStatus.ForeColor = [Guard.T]::Ink
        $lblPaused.Text = ''
    }

    # 空闲自动锁屏
    if ($script:autoLock -and -not $script:locked) {
        $idle = Get-IdleSeconds
        if ($idle -ge ($script:autoLockMin * 60)) {
            Write-Log ('空闲 {0} 分钟，自动锁屏' -f $script:autoLockMin)
            Lock-Screen
        }
    }
})
$timer.Start()

$timerList = New-Object System.Windows.Forms.Timer
$timerList.Interval = 20000
$timerList.Add_Tick({ try { Refresh-TargetList } catch { } })
$timerList.Start()

$timerNoWake = New-Object System.Windows.Forms.Timer
$timerNoWake.Interval = 10000
$timerNoWake.Add_Tick({ try { Invoke-NoWakeTick } catch { } })
$timerNoWake.Start()

$btnLock.Add_Click({
    Lock-Screen
    $lblStatus.Text = '已锁屏  ·  后台继续运行'
    $lblStatus.ForeColor = [Guard.T]::Ink
})
$btnPause.Add_Click({
    Pause-All '手动暂停'
    Refresh-TargetList
})
$btnResume.Add_Click({
    Resume-All '手动恢复'
    Refresh-TargetList
})
$chkDsh.Add_CheckedChanged({ $script:includeDsh = $chkDsh.Checked; Refresh-TargetList })
$chkAuto.Add_CheckedChanged({ $script:autoGuard = $chkAuto.Checked })
$chkNoWake.Add_CheckedChanged({ $script:noWake = $chkNoWake.Checked })
$chkAutoLock.Add_CheckedChanged({ $script:autoLock = $chkAutoLock.Checked })
$chkBattery.Add_CheckedChanged({
    $script:lowBattery = $chkBattery.Checked
    if (-not $script:lowBattery) {
        if ($script:pauseReason -eq 'battery') { Resume-All '用户关闭了低电量保护' }
        if ($script:saverOn) { Set-PowerSaver }
    } else {
        try { Invoke-BatteryTick } catch { }
    }
})

# 锁屏状态不再依赖 SessionSwitch 事件：事件 Action 有独立作用域，对 $script: 的赋值
# 写不回主脚本，曾导致解锁后仍被当成"锁屏中"。现在统一由 IsLockedDesktop() 读取真实输入桌面。

$form.Add_Shown({
    [PcGuard.CpuSampler]::Start()
    try {
        [void][PcGuard.Native]::ShowWindow($form.Handle, 1)
        [void][PcGuard.Native]::ShowWindow($form.Handle, 5)
        [void][PcGuard.Native]::SetForegroundWindow($form.Handle)
        $form.Activate()
    } catch {}
    Load-CustomNames
    Refresh-CustomInfo
    Refresh-TargetList
    Write-Log '界面已启动'
})

$form.Add_FormClosing({
    $timer.Stop(); $timerList.Stop(); $timerNoWake.Stop()
    if ($script:pausedIds.Count -gt 0) { Resume-All '关闭守护程序' }
    Write-Log '界面已关闭'
})

[void]$form.ShowDialog()
Write-Log 'PcGuard 退出'
