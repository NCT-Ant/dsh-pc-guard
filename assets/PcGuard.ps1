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
    [ValidateSet('ui', 'lock', 'status')]
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
namespace PcGuard {
  public static class Native {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr hProcess);
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr hProcess);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool LockWorkStation();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
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
$script:autoGuard   = $true
$script:includeDsh  = $false
$script:noWake      = $true
$script:autoLock    = $true
$script:autoLockMin = $AutoLockMin
$script:lastLockAt  = [datetime]::MinValue
$script:lastCpu     = 0
$script:extraNames  = @()

$script:cpuCounter = $null
try {
    $script:cpuCounter = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total')
    [void]$script:cpuCounter.NextValue()
} catch { Write-Log "PerformanceCounter 不可用，改用 CIM: $($_.Exception.Message)" }

function Get-CpuPercent {
    if ($script:cpuCounter) {
        try { return [math]::Round([double]$script:cpuCounter.NextValue(), 1) } catch { }
    }
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
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

function Close-Monitor {
    [void][PcGuard.Native]::SendMessage($SCRIPT:HWND_BROADCAST, $SCRIPT:WM_SYSCOMMAND, [IntPtr]$SCRIPT:SC_MONITORPOWER, [IntPtr]2)
}

function Lock-Screen {
    $script:locked = $true
    [void][PcGuard.Native]::LockWorkStation()
    Write-Log '已锁屏（后台程序保持运行，不休眠）'
    Start-Sleep -Milliseconds 600
    Close-Monitor
}

# ---------- 进程选择 ----------
$script:OcrPattern = 'ocr|paddle|rapidocr|easyocr|ppocr|tesseract|cnocr|image.?recogni'

function Get-TargetProcesses {
    param([switch]$IncludeDsh)
    $result = New-Object System.Collections.ArrayList
    $filter = "Name='python.exe' OR Name='pythonw.exe' OR Name='tesseract.exe' OR Name='DeepSeek Harness.exe'"
    $procs = @()
    try { $procs = Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop } catch { }
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
    param([string]$Reason)
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
}

function Update-State {
    $cpu = Get-CpuPercent
    if ($cpu -lt 0) { return $script:lastCpu }
    $script:lastCpu = $cpu

    if ($script:pausedIds.Count -gt 0) {
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
    if (-not $script:locked) { return }
    $idle = Get-IdleSeconds
    if ($idle -ge $NoWakeIdleSec -or $idle -lt 0) {
        Close-Monitor
    }
}

# ---------- 命令行动作（供 DSH 插件调用） ----------
if ($Action -ne 'ui') {
    switch ($Action) {
        'lock' {
            Lock-Screen
            Write-Output '{"ok":true,"action":"lock"}'
        }
        'status' {
            # 预热一次计数器，避免刚启动时采样到 0
            Start-Sleep -Milliseconds 300
            $cpu = Get-CpuPercent
            if ($cpu -lt 0) { $cpu = 0 }
            $targets = @(Get-TargetProcesses)
            $obj = [ordered]@{
                ok        = $true
                cpu       = [math]::Round($cpu, 1)
                idleSec   = (Get-IdleSeconds)
                targets   = $targets.Count
                timestamp = (Get-Date -Format 's')
            }
            Write-Output ($obj | ConvertTo-Json -Compress)
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
    Write-Log 'PcGuard 已在运行，本次退出'
    if (-not $Headless) { Write-Host 'PcGuard 已在运行' }
    exit 0
}

# ---------- 无界面模式 ----------
if ($Headless) {
    Write-Log "PcGuard 无界面守护启动：暂停阈值 $CpuPause%，恢复阈值 $CpuResume% / $ResumeHoldMin 分钟"
    while ($true) {
        [void](Update-State)
        Invoke-NoWakeTick
        Start-Sleep -Seconds $IntervalSec
    }
}

# ---------- 界面 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PC 守护'
$form.Size = New-Object System.Drawing.Size(470, 640)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$lblCpuTitle = New-Object System.Windows.Forms.Label
$lblCpuTitle.Text = 'CPU 占用'
$lblCpuTitle.Location = New-Object System.Drawing.Point(18, 14)
$lblCpuTitle.AutoSize = $true
$form.Controls.Add($lblCpuTitle)

$lblCpu = New-Object System.Windows.Forms.Label
$lblCpu.Text = '--'
$lblCpu.Location = New-Object System.Drawing.Point(14, 30)
$lblCpu.Size = New-Object System.Drawing.Size(200, 56)
$lblCpu.Font = New-Object System.Drawing.Font('Segoe UI', 30, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblCpu)

$barCpu = New-Object System.Windows.Forms.ProgressBar
$barCpu.Location = New-Object System.Drawing.Point(215, 44)
$barCpu.Size = New-Object System.Drawing.Size(225, 24)
$barCpu.Minimum = 0
$barCpu.Maximum = 100
$form.Controls.Add($barCpu)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '状态：监控中'
$lblStatus.Location = New-Object System.Drawing.Point(18, 92)
$lblStatus.Size = New-Object System.Drawing.Size(425, 40)
$form.Controls.Add($lblStatus)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = ('CPU 超过 {0}% 自动暂停，低于 {1}% 持续 {2} 分钟后恢复' -f $CpuPause, $CpuResume, $ResumeHoldMin)
$chkAuto.Location = New-Object System.Drawing.Point(18, 136)
$chkAuto.Size = New-Object System.Drawing.Size(425, 24)
$chkAuto.Checked = $true
$form.Controls.Add($chkAuto)

$chkDsh = New-Object System.Windows.Forms.CheckBox
$chkDsh.Text = '同时暂停 DeepSeek Harness 进程（对话界面会暂时冻结）'
$chkDsh.Location = New-Object System.Drawing.Point(18, 162)
$chkDsh.Size = New-Object System.Drawing.Size(425, 24)
$chkDsh.Checked = $false
$form.Controls.Add($chkDsh)

$chkNoWake = New-Object System.Windows.Forms.CheckBox
$chkNoWake.Text = '锁屏后压制自动亮屏（无操作时反复关屏）'
$chkNoWake.Location = New-Object System.Drawing.Point(18, 188)
$chkNoWake.Size = New-Object System.Drawing.Size(425, 24)
$chkNoWake.Checked = $true
$form.Controls.Add($chkNoWake)

$chkAutoLock = New-Object System.Windows.Forms.CheckBox
$chkAutoLock.Text = ('空闲 {0} 分钟后自动锁屏（锁屏后自动熄屏）' -f $AutoLockMin)
$chkAutoLock.Location = New-Object System.Drawing.Point(18, 214)
$chkAutoLock.Size = New-Object System.Drawing.Size(425, 24)
$chkAutoLock.Checked = $true
$form.Controls.Add($chkAutoLock)

$lblTargets = New-Object System.Windows.Forms.Label
$lblTargets.Text = '命中进程（OCR / DSH / 自定义）'
$lblTargets.Location = New-Object System.Drawing.Point(18, 248)
$lblTargets.AutoSize = $true
$form.Controls.Add($lblTargets)

$lstTargets = New-Object System.Windows.Forms.ListBox
$lstTargets.Location = New-Object System.Drawing.Point(18, 270)
$lstTargets.Size = New-Object System.Drawing.Size(425, 118)
$lstTargets.HorizontalScrollbar = $true
$form.Controls.Add($lstTargets)

$btnLock = New-Object System.Windows.Forms.Button
$btnLock.Text = '一键锁屏'
$btnLock.Location = New-Object System.Drawing.Point(18, 400)
$btnLock.Size = New-Object System.Drawing.Size(200, 46)
$btnLock.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnLock)

$btnPause = New-Object System.Windows.Forms.Button
$btnPause.Text = '立即暂停'
$btnPause.Location = New-Object System.Drawing.Point(228, 400)
$btnPause.Size = New-Object System.Drawing.Size(105, 46)
$form.Controls.Add($btnPause)

$btnResume = New-Object System.Windows.Forms.Button
$btnResume.Text = '恢复'
$btnResume.Location = New-Object System.Drawing.Point(341, 400)
$btnResume.Size = New-Object System.Drawing.Size(102, 46)
$form.Controls.Add($btnResume)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = ''
$lblLog.Location = New-Object System.Drawing.Point(18, 456)
$lblLog.Size = New-Object System.Drawing.Size(425, 60)
$lblLog.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblLog)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '锁屏不会关闭后台程序，也不会休眠；解锁后一切照旧。'
$lblHint.Location = New-Object System.Drawing.Point(18, 522)
$lblHint.Size = New-Object System.Drawing.Size(425, 40)
$lblHint.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblHint)

$lblPaused = New-Object System.Windows.Forms.Label
$lblPaused.Text = ''
$lblPaused.Location = New-Object System.Drawing.Point(18, 566)
$lblPaused.Size = New-Object System.Drawing.Size(425, 40)
$lblPaused.ForeColor = [System.Drawing.Color]::Firebrick
$form.Controls.Add($lblPaused)

function Refresh-TargetList {
    $items = @(Get-TargetProcesses -IncludeDsh:$chkDsh.Checked)
    $lstTargets.BeginUpdate()
    $lstTargets.Items.Clear()
    foreach ($t in $items) {
        $short = $t.Cmd
        if ($short.Length -gt 70) { $short = $short.Substring(0, 70) + '...' }
        [void]$lstTargets.Items.Add(('[#{0}] {1} · {2} · {3}' -f $t.Id, $t.Kind, $t.Name, $short))
    }
    if ($lstTargets.Items.Count -eq 0) {
        [void]$lstTargets.Items.Add('（当前没有匹配的 OCR / DSH 进程）')
    }
    $lstTargets.EndUpdate()
}

$script:logLines = New-Object System.Collections.ArrayList

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $IntervalSec * 1000
$timer.Add_Tick({
    $cpu = Update-State
    if ($cpu -ge 0) {
        $lblCpu.Text = ('{0}%' -f [int][math]::Round($cpu))
        if ($cpu -gt 100) { $cpu = 100 }
        $barCpu.Value = [int][math]::Min(100, [math]::Max(0, [math]::Round($cpu)))
        if ($cpu -ge $CpuPause) { $lblCpu.ForeColor = [System.Drawing.Color]::Firebrick }
        else { $lblCpu.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 60) }
    }
    if ($script:pausedIds.Count -gt 0) {
        $mins = 0
        if ($script:pausedAt) { $mins = [math]::Round(((Get-Date) - $script:pausedAt).TotalMinutes, 1) }
        $lblStatus.Text = ('状态：已暂停 {0} 个进程，已持续 {1} 分钟' -f $script:pausedIds.Count, $mins)
        $lblPaused.Text = ('已暂停 PID：{0}' -f ($script:pausedIds -join ', '))
    } else {
        $lblStatus.Text = ('状态：监控中（暂停阈值 {0}%，恢复阈值 {1}%）' -f $CpuPause, $CpuResume)
        $lblPaused.Text = ''
    }
    if ($script:locked) { $lblStatus.Text = '状态：已锁屏 · ' + $lblStatus.Text.Replace('状态：', '') }

    # 空闲自动锁屏：解锁状态下长时间无输入 -> 锁屏并熄屏
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
$timerList.Interval = 15000
$timerList.Add_Tick({ try { Refresh-TargetList } catch { } })
$timerList.Start()

$timerNoWake = New-Object System.Windows.Forms.Timer
$timerNoWake.Interval = 10000
$timerNoWake.Add_Tick({ try { Invoke-NoWakeTick } catch { } })
$timerNoWake.Start()

$btnLock.Add_Click({
    Lock-Screen
    $lblStatus.Text = '状态：已锁屏（后台继续运行）'
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

Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionSwitch -Action {
    $reason = $Event.SourceEventArgs.Reason
    if ($reason -eq 'SessionLock') { $script:locked = $true }
    elseif ($reason -eq 'SessionUnlock') { $script:locked = $false }
} | Out-Null

$form.Add_Shown({
    # 以隐藏窗口方式启动时，STARTUPINFO 的 SW_HIDE 会被首次 ShowWindow 采用，
    # 导致 WinForms 窗口不可见。这里在显示后再显式 ShowWindow 一次。
    try {
        [void][PcGuard.Native]::ShowWindow($form.Handle, 1)
        [void][PcGuard.Native]::ShowWindow($form.Handle, 5)
        [void][PcGuard.Native]::SetForegroundWindow($form.Handle)
        $form.Activate()
    } catch {}
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
