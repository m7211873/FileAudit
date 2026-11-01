#requires -Version 5.0
<#
.SYNOPSIS
  IP监控2.1 P1-A/B 修复回归测试（R6~R11）：启动最小化 / --show / 旧数据假精确降级 /
  自启往返 / 版本资源 / GUI-GUI 数据目录冲突 / 自启状态对账，附 P1-5/6/7/8/10/11/12 静态检查。

.DESCRIPTION
  与 regression-p0.ps1 独立（P0 的 R1~R5 单独复跑），本脚本只覆盖 P1 改动，全部输出实际数值：
    R6 StartMinimized：config.StartMinimized=true → GUI 进程存活且 MainWindowHandle=0、无可见主窗口；
       同 datadir 换 --show 启动 → 主窗口可见（MainWindowHandle != 0）。
    R7 旧数据假精确降级：预置 1.0 legacy 格式 data\<今天>.json（bytesPrecise=true、bytesIn>0、逐 IP 全 0）
       → --daemon 8s → 文件 bytesPrecise=false、sampleCount>10、bytes 不回退。
    R8 自启往返：备份 Run\NetWatcher2.1 与 Run\NetWatcher(2.0) → 清 2.1 值 →
       --autostart-on --datadir <temp> 写入（含 --background/--datadir/指向被测 exe）→
       --autostart-off 删除 → 断言 2.0 的 Run\NetWatcher 全程未变。
    R9 版本资源：被测 exe FileVersion/ProductVersion = 2.x.y.0（2.1.0 / 2.1.1 / 2.2.0 …）。
    R10 GUI-GUI 数据目录冲突：GUI A 占 datadir（tag a）→ GUI B 同 datadir 不同 tag →
       5 秒重试后弹出标题恰为「IP监控2.1」的提示框，且 A 仍存活；按记录 PID 结束 B、A。
    R11 自启状态对账：sentinel 写入 Run\NetWatcher2.1 + config.AutoStart=false → 启动 GUI 8s
       （不打开设置、不保存）→ 杀进程 → sentinel 仍在且值不变（启动流程不得误删自启）。

  安全约束：
  1. 所有注册表改动前后必须精确恢复（原本不存在→删除；原本存在→恢复原值），finally 兜底；
     绝不改变用户 2.0 实例的 Run\NetWatcher 最终值；注册表值名含点号，统一用 .NET Registry API
     按完整值名读写（等价于 `.'NetWatcher2.1'` 的安全写法）。
  2. 被测 exe 先复制到 %TEMP% 再运行；所有实例带绝对 %TEMP% --datadir；只结束本脚本记录的 PID；
     绝不按进程名杀进程，绝不碰用户管理员实例 PID 10856。
  3. 报告写 tools\qa\out；退出码：有 FAIL → 1，否则 0。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-p1.ps1
#>
[CmdletBinding()]
param(
    [string]$Exe = '',
    [string]$OutDir = '',
    [int]$DaemonSeconds = 8,
    [int]$GuiObserveSec = 8,
    [string]$MutexTag = 'p1reg',
    [int]$UserPidGuard = 10856,
    [int]$StartTimeoutSec = 40
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# JavaScriptSerializer 来自 System.Web.Extensions（解析 data\*.json）
Add-Type -AssemblyName System.Web.Extensions | Out-Null
# v2.3.0：.nwipdb 加密小时文件只读适配层（迁移后按日合并/解密读取）
. (Join-Path $PSScriptRoot 'nwipdb-format.ps1')

# ------------------------------------------------------------------ 路径与运行参数
$RunTag = Get-Date -Format 'yyyyMMdd-HHmmss'
$StartedAt = Get-Date
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Exe) { $Exe = Join-Path $RepoRoot 'bin\NetWatcher.exe' }
$Exe = [IO.Path]::GetFullPath($Exe)
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$RealDataDir = Join-Path $env:APPDATA 'NetWatcher'
$Today = Get-Date -Format 'yyyy-MM-dd'
# 每次运行唯一 mutex-tag，避免上一次异常退出的 GUI 单实例锁残留
$MutexTag = $MutexTag + '-' + (Get-Date -Format 'HHmmss')
$TempRoot = Join-Path $env:TEMP ("ipmon-p1reg-" + $RunTag)
$RunDir = Join-Path $TempRoot 'run'
$RunExe = Join-Path $RunDir 'NetWatcher.exe'
$DataR6 = Join-Path $TempRoot 'data-R6'
$DataR7 = Join-Path $TempRoot 'data-R7'
$DataR8 = Join-Path $TempRoot 'data-R8'
$DataR10 = Join-Path $TempRoot 'data-R10'
$DataR11 = Join-Path $TempRoot 'data-R11'
$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RegSubKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$ValueName21 = 'NetWatcher2.1'
$ValueName20 = 'NetWatcher'
$CfgText = '{"ScanIntervalSeconds":2,"AutoStart":false,"RetentionDays":0,"StartMinimized":false,"GeoEnabled":true,"GeoApi":"http://ip-api.com/json/{0}?fields=status,message,country,regionName,city,isp,lat,lon&lang=zh-CN","NewIpAlert":true,"ShowLocalIp":true}'

$script:Results = New-Object System.Collections.ArrayList
$script:InfoRows = New-Object System.Collections.ArrayList
$script:ActivePids = New-Object System.Collections.ArrayList
$script:Evidence = New-Object System.Collections.ArrayList
$script:RegBackup = @{}
$script:CanRun = $true

# ------------------------------------------------------------------ 结果输出辅助
function Add-Result {
    param([string]$Status, [string]$Check, [string]$Detail)
    $row = [pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail }
    [void]$script:Results.Add($row)
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host ("  [{0}] {1,-32} {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
}
function Add-Info {
    param([string]$Check, [string]$Detail)
    [void]$script:InfoRows.Add([pscustomobject]@{ Check = $Check; Detail = $Detail })
    Write-Host ("  [INFO] {0,-32} {1}" -f $Check, $Detail) -ForegroundColor Gray
}
function Pass([string]$Check, [string]$Detail) { Add-Result -Status 'PASS' -Check $Check -Detail $Detail }
function Fail([string]$Check, [string]$Detail) { Add-Result -Status 'FAIL' -Check $Check -Detail $Detail }
function Warn([string]$Check, [string]$Detail) { Add-Result -Status 'WARN' -Check $Check -Detail $Detail }
function Write-Section([string]$Title) { Write-Host ''; Write-Host ("== " + $Title + " ==") -ForegroundColor Cyan }
function Get-Sha256([string]$Path) { return (Get-FileHash -Path $Path -Algorithm SHA256).Hash }
function Short-Sha([string]$Sha, [int]$Len = 16) {
    if ([string]::IsNullOrEmpty($Sha)) { return '<无>' }
    if ($Sha.Length -le $Len) { return $Sha }
    return $Sha.Substring(0, $Len)
}

# ------------------------------------------------------------------ 进程辅助（只结束自己记录的 PID）
function Start-WmiProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory)
    $cmd = '"' + $FilePath + '"'
    foreach ($a in $Arguments) { $cmd += ' "' + $a + '"' }
    $createArgs = @{ CommandLine = $cmd }
    if ($WorkingDirectory) { $createArgs['CurrentDirectory'] = $WorkingDirectory }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $createArgs
    if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed rc=$($r.ReturnValue): $cmd" }
    return [int]$r.ProcessId
}
function Stop-QaProcess {
    param([int]$ProcessId, [int]$WaitSec = 5)
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch { }
    Start-Sleep -Milliseconds 300
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
        try {
            Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction Stop |
                Invoke-CimMethod -MethodName Terminate -Arguments @{ Reason = 0 } -ErrorAction Stop | Out-Null
        } catch { }
    }
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return (-not [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}
function Stop-ProcessTree {
    param([int]$RootPid)
    try {
        $children = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $RootPid) -ErrorAction SilentlyContinue)
        foreach ($c in $children) { [void](Stop-QaProcess -ProcessId ([int]$c.ProcessId) -WaitSec 2) }
    } catch { }
    [void](Stop-QaProcess -ProcessId $RootPid -WaitSec 4)
}

# 用 cmd 包装 exe 捕获退出码
function Invoke-ExeWithExitCode {
    param([string]$Tag, [string[]]$Arguments, [int]$TimeoutSec)
    $base = Join-Path $RunDir ('exe_' + $Tag)
    $stdout = $base + '.stdout.log'
    $exitFile = $base + '.exit.txt'
    $bat = $base + '.cmd'
    Remove-Item $stdout, $exitFile, $bat -Force -ErrorAction SilentlyContinue
    $quoted = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $lines = @(
        '@echo off',
        ('"' + $RunExe + '" ' + $quoted + ' > "' + $stdout + '" 2>&1'),
        ('echo %ERRORLEVEL% > "' + $exitFile + '"')
    )
    [IO.File]::WriteAllText($bat, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
    $comspec = $env:ComSpec
    if (-not $comspec) { $comspec = Join-Path $env:WINDIR 'System32\cmd.exe' }
    $started = Get-Date
    $procId = Start-WmiProcess -FilePath $comspec -Arguments @('/c', $bat) -WorkingDirectory $RunDir
    [void]$script:ActivePids.Add($procId)
    $deadline = $started.AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $exitFile) { break }
        if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 300
            if (Test-Path $exitFile) { break }
            break
        }
        Start-Sleep -Milliseconds 200
    }
    $timedOut = $false
    if (-not (Test-Path $exitFile)) {
        $timedOut = $true
        Stop-ProcessTree $procId
        Start-Sleep -Milliseconds 600
    }
    $code = -999
    if (Test-Path $exitFile) {
        try { $code = [int](([IO.File]::ReadAllText($exitFile)).Trim()) } catch { $code = -998 }
    }
    $elapsed = ((Get-Date) - $started).TotalSeconds
    return [pscustomobject]@{
        Tag = $Tag; Pid = $procId; ExitCode = $code; TimedOut = $timedOut
        ElapsedSec = [Math]::Round($elapsed, 1); StdoutLog = $stdout; ExitFile = $exitFile; Batch = $bat
    }
}

function Start-Gui {
    param([string]$DataDir, [string]$TagSuffix = '', [string[]]$ExtraArgs = @())
    $argList = @('--datadir', $DataDir, '--mutex-tag', ($MutexTag + $TagSuffix)) + $ExtraArgs
    $procId = Start-WmiProcess -FilePath $RunExe -Arguments $argList -WorkingDirectory $RunDir
    [void]$script:ActivePids.Add($procId)
    return $procId
}
function Wait-GuiStarted {
    param([int]$ProcessId, [string]$DataDir, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $false }
        # v2.3.0：启动即创建本次会话的空加密小时文件（.nwipdb），不再写日 json
        $storeFiles = @(Get-NwipdbFiles -DataDir $DataDir)
        if ($storeFiles.Count -gt 0) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# ------------------------------------------------------------------ 注册表辅助（值名含点号：.NET API 按完整值名读写）
function Get-RunValue {
    param([string]$Name)
    $res = [pscustomobject]@{ Exists = $false; Value = ''; Error = '' }
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegSubKey, $false)
        if ($null -eq $k) { return $res }
        try {
            $v = $k.GetValue($Name, $null)
            if ($null -ne $v) { $res.Exists = $true; $res.Value = [string]$v }
        } finally { $k.Close() }
    } catch { $res.Error = $_.Exception.Message }
    return $res
}
function Set-RunValue {
    param([string]$Name, [string]$Value)
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegSubKey, $true)
    if ($null -eq $k) { throw 'HKCU Run 不可写' }
    try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String) } finally { $k.Close() }
}
function Remove-RunValue {
    param([string]$Name)
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegSubKey, $true)
    if ($null -eq $k) { return }
    try { $k.DeleteValue($Name, $false) } catch { } finally { $k.Close() }
}
function Format-RunValueText {
    param($Rec)
    if ($Rec.Exists) { return ('"' + $Rec.Value + '"') }
    return '<不存在>'
}
function Backup-RunValue {
    param([string]$Name)
    if (-not $script:RegBackup.ContainsKey($Name)) {
        $script:RegBackup[$Name] = Get-RunValue $Name
        Add-Info 'REG_BACKUP' ("Run\{0} 原值已备份: {1}" -f $Name, (Format-RunValueText $script:RegBackup[$Name]))
    }
}
function Restore-RunValue {
    param([string]$Name)
    if (-not $script:RegBackup.ContainsKey($Name)) { return $true }
    $orig = $script:RegBackup[$Name]
    try {
        if ($orig.Exists) { Set-RunValue $Name $orig.Value } else { Remove-RunValue $Name }
        $now = Get-RunValue $Name
        if ($now.Exists -eq $orig.Exists -and $now.Value -eq $orig.Value) { return $true }
        return $false
    } catch { return $false }
}

# ------------------------------------------------------------------ 窗口枚举（R6 可见性 / R10 冲突提示框）
$P1WinSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class P1Win
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);

    public class W { public long H; public uint Pid; public string Title; public string Cls; public bool Visible; }

    public static List<W> Windows(uint pid)
    {
        var list = new List<W>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == pid)
            {
                var sb = new StringBuilder(1024); GetWindowText(h, sb, 1024);
                var cb = new StringBuilder(256); GetClassName(h, cb, 256);
                var w = new W();
                w.H = h.ToInt64(); w.Pid = wp; w.Title = sb.ToString(); w.Cls = cb.ToString();
                w.Visible = IsWindowVisible(h);
                list.Add(w);
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@
if (-not ('P1Win' -as [type])) { Add-Type -TypeDefinition $P1WinSource -Language CSharp }

# ------------------------------------------------------------------ JSON / 数据文件辅助
function New-JsonSerializer {
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 100
    return $ser
}
function Get-JVal {
    param($Obj, [string]$Key)
    if ($null -eq $Obj) { return $null }
    try {
        if ($Obj -is [System.Collections.IDictionary]) {
            foreach ($k in $Obj.Keys) { if ([string]$k -eq $Key) { return $Obj[$k] } }
        }
    } catch { }
    return $null
}
function Initialize-TestDataDir {
    param([string]$Dir, [bool]$StartMinimized = $false)
    New-Item -ItemType Directory -Path (Join-Path $Dir 'data') -Force | Out-Null
    $cfg = $CfgText
    if ($StartMinimized) { $cfg = $cfg.Replace('"StartMinimized":false', '"StartMinimized":true') }
    [IO.File]::WriteAllText((Join-Path $Dir 'config.json'), $cfg, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-NewestDayFile {
    param([string]$Dir)
    $d = Join-Path $Dir 'data'
    if (-not (Test-Path $d)) { return $null }
    $files = @(Get-ChildItem $d -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { return $null }
    return $files[0]
}
function Read-DaySummary {
    param($Path)
    if ($Path -is [System.IO.FileSystemInfo]) { $Path = $Path.FullName }
    $Path = [string]$Path
    $r = [pscustomobject]@{
        Exists = $false; Path = $Path; Name = ''; Sha = ''; Size = 0; ParseOk = $false; Error = ''
        Date = ''; SampleCount = -1; BytesIn = -1; BytesOut = -1
        FirstSampleUnix = -1; LastSampleUnix = -1; BytesPrecise = $false
    }
    if (-not (Test-Path $Path)) { $r.Error = '文件不存在'; return $r }
    $r.Exists = $true
    $r.Name = Split-Path $Path -Leaf
    try { $fi = Get-Item $Path; $r.Size = $fi.Length; $r.Sha = Get-Sha256 $Path } catch { }
    try {
        $ser = New-JsonSerializer
        $d = $ser.DeserializeObject([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))
        if ($null -ne $d) {
            $r.ParseOk = $true
            $v = Get-JVal $d 'date'; if ($null -ne $v) { $r.Date = [string]$v }
            $v = Get-JVal $d 'sampleCount'; if ($null -ne $v) { $r.SampleCount = [long]$v }
            $v = Get-JVal $d 'bytesIn'; if ($null -ne $v) { $r.BytesIn = [long]$v }
            $v = Get-JVal $d 'bytesOut'; if ($null -ne $v) { $r.BytesOut = [long]$v }
            $v = Get-JVal $d 'firstSampleUnix'; if ($null -ne $v) { $r.FirstSampleUnix = [long]$v }
            $v = Get-JVal $d 'lastSampleUnix'; if ($null -ne $v) { $r.LastSampleUnix = [long]$v }
            $v = Get-JVal $d 'bytesPrecise'; if ($null -ne $v) { $r.BytesPrecise = [bool]$v }
        }
    } catch { $r.Error = $_.Exception.Message }
    return $r
}

# ------------------------------------------------------------------ 0. 预检 / 环境隔离
Write-Host ''
Write-Host "IP监控2.1 P1-A/B 回归测试  ($RunTag)" -ForegroundColor White
Write-Host ("repo    = {0}" -f $RepoRoot)
Write-Host ("exe     = {0}" -f $Exe)
Write-Host ("temp    = {0}" -f $TempRoot)
Write-Host ("out     = {0}" -f $OutDir)
Write-Host ("R7daemon= {0}s  R11observe={1}s  mutexTag={2}" -f $DaemonSeconds, $GuiObserveSec, $MutexTag)

Write-Section '0. 预检 / 环境隔离'
Add-Info 'TIME' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Add-Info 'USER' ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
$shellAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Info 'SHELL_ADMIN' ([string]$shellAdmin)

if (Test-Path $Exe) {
    $fi = Get-Item $Exe
    Pass 'PRE_EXE' ("{0}  {1:N0} bytes  mtime={2}  SHA256={3}..." -f $Exe, $fi.Length, $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), (Short-Sha (Get-Sha256 $Exe)))
} else {
    Fail 'PRE_EXE' ("找不到被测 exe: {0}" -f $Exe)
    $script:CanRun = $false
}

$tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
$insideTemp = $TempRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)
$insideRepo = $TempRoot.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)
$insideReal = $TempRoot.StartsWith($RealDataDir, [StringComparison]::OrdinalIgnoreCase)
if ($insideTemp -and -not $insideRepo -and -not $insideReal) {
    Pass 'PRE_SAFETY' ("测试目录在 %TEMP% 下且与仓库/真实数据隔离: {0}" -f $TempRoot)
} else {
    Fail 'PRE_SAFETY' ("测试目录不安全（inTemp={0} inRepo={1} inReal={2}）: {3}" -f $insideTemp, $insideRepo, $insideReal, $TempRoot)
    $script:CanRun = $false
}

if ($script:CanRun) {
    try {
        if (Test-Path $RunDir) { Remove-Item $RunDir -Recurse -Force }
        New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
        Copy-Item $Exe $RunExe -Force
        $h1 = Get-Sha256 $Exe
        $h2 = Get-Sha256 $RunExe
        if ($h1 -eq $h2) { Pass 'PRE_RUN_EXE' ("已复制到 {0}（SHA256={1}...）" -f $RunExe, (Short-Sha $h1)) }
        else { Fail 'PRE_RUN_EXE' '运行副本 SHA256 与被测 exe 不一致'; $script:CanRun = $false }
    } catch {
        Fail 'PRE_RUN_EXE' ("复制失败: " + $_.Exception.Message)
        $script:CanRun = $false
    }
}

# 用户 2.0 管理员实例只读探测
$userProc = Get-Process -Id $UserPidGuard -ErrorAction SilentlyContinue
if ($userProc) {
    $ust = $null
    try { $ust = $userProc.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { $ust = '?' }
    Add-Info 'PRE_USER_INSTANCE' ("用户 2.0 管理员实例 PID {0} 存活（start={1}），全程不结束、不干预；本脚本不写 %APPDATA%\NetWatcher" -f $UserPidGuard, $ust)
} else {
    Add-Info 'PRE_USER_INSTANCE' ("PID {0} 当前不在运行" -f $UserPidGuard)
}
$nwProcs = @(Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue)
Add-Info 'PRE_NETWATCHER_PROCS' ("当前 NetWatcher 进程数={0}（PID: {1}）" -f $nwProcs.Count, (($nwProcs | ForEach-Object { $_.Id }) -join ','))

# 注册表原值备份（R8/R11 会临时改动，finally 精确恢复）
Backup-RunValue $ValueName21
Backup-RunValue $ValueName20
$script:RegBackupValid = $script:RegBackup.ContainsKey($ValueName21) -and $script:RegBackup.ContainsKey($ValueName20)

# ------------------------------------------------------------------ 主流程
try {
    if ($script:CanRun) {

        # ============================================================== R6 StartMinimized / --show
        Write-Section 'R6 StartMinimized 生效 / --show 强制可见'
        try {
            Initialize-TestDataDir $DataR6 -StartMinimized $true
            $gui6a = Start-Gui -DataDir $DataR6
            $started6a = Wait-GuiStarted -ProcessId $gui6a -DataDir $DataR6 -TimeoutSec $StartTimeoutSec
            Start-Sleep -Milliseconds 1200
            $proc6a = Get-Process -Id $gui6a -ErrorAction SilentlyContinue
            $handle6a = -1
            if ($proc6a) { $handle6a = $proc6a.MainWindowHandle.ToInt64() }
            $visWins6a = @()
            try { $visWins6a = @([P1Win]::Windows([uint32]$gui6a) | Where-Object { $_.Visible }) } catch { }
            $titleWins6a = @($visWins6a | Where-Object { $_.Title -match 'IP监控2\.1' })
            if (-not $proc6a) {
                Fail 'R6_HIDDEN_START' ("GUI pid={0} 启动后进程已退出（datadir={1}）" -f $gui6a, $DataR6)
            } elseif (-not $started6a) {
                Fail 'R6_HIDDEN_START' ("{0}s 内 GUI 未落盘数据（pid={1}），无法确认已初始化" -f $StartTimeoutSec, $gui6a)
            } elseif ($handle6a -ne 0) {
                Fail 'R6_HIDDEN_START' ("StartMinimized=true 但 MainWindowHandle={0}（期望 0 隐藏）" -f $handle6a)
            } elseif ($titleWins6a.Count -gt 0) {
                Fail 'R6_HIDDEN_START' ("StartMinimized=true 但仍存在 {0} 个可见主窗口: {1}" -f $titleWins6a.Count, (($titleWins6a | ForEach-Object { $_.Title }) -join ','))
            } else {
                Pass 'R6_HIDDEN_START' ("pid={0} 存活、MainWindowHandle=0、可见顶层窗口数=0（StartMinimized 生效）" -f $gui6a)
            }
            $k6 = Stop-QaProcess -ProcessId $gui6a -WaitSec 8
            if ($k6) { Pass 'R6_CLEANUP_HIDDEN' ("已结束隐藏实例 pid={0}" -f $gui6a) } else { Fail 'R6_CLEANUP_HIDDEN' ("无法结束隐藏实例 pid={0}" -f $gui6a) }
            Start-Sleep -Milliseconds 600

            # 同一 datadir 以 --show 启动（StartMinimized 仍为 true，但 --show 必须强制可见）
            $gui6b = Start-Gui -DataDir $DataR6 -TagSuffix '-show' -ExtraArgs @('--show')
            $started6b = Wait-GuiStarted -ProcessId $gui6b -DataDir $DataR6 -TimeoutSec $StartTimeoutSec
            $deadline = (Get-Date).AddSeconds(15)
            $handle6b = 0
            while ((Get-Date) -lt $deadline) {
                $p6b = Get-Process -Id $gui6b -ErrorAction SilentlyContinue
                if (-not $p6b) { break }
                $handle6b = $p6b.MainWindowHandle.ToInt64()
                if ($handle6b -ne 0) { break }
                Start-Sleep -Milliseconds 300
            }
            Start-Sleep -Milliseconds 600
            $proc6b = Get-Process -Id $gui6b -ErrorAction SilentlyContinue
            $visWins6b = @()
            try { $visWins6b = @([P1Win]::Windows([uint32]$gui6b) | Where-Object { $_.Visible -and $_.Title -match 'IP监控2\.1' }) } catch { }
            if (-not $proc6b) {
                Fail 'R6_SHOW_VISIBLE' ("--show 实例 pid={0} 启动后进程已退出" -f $gui6b)
            } elseif (-not $started6b) {
                Fail 'R6_SHOW_VISIBLE' ("--show 实例 {0}s 内未落盘数据（pid={1}）" -f $StartTimeoutSec, $gui6b)
            } elseif ($handle6b -eq 0 -or $visWins6b.Count -eq 0) {
                Fail 'R6_SHOW_VISIBLE' ("--show 未强制可见：MainWindowHandle={0}，可见主窗口数={1}" -f $handle6b, $visWins6b.Count)
            } else {
                Pass 'R6_SHOW_VISIBLE' ("pid={0} MainWindowHandle={1}，可见主窗口 '{2}'" -f $gui6b, $handle6b, $visWins6b[0].Title)
            }
            $k6b = Stop-QaProcess -ProcessId $gui6b -WaitSec 8
            if ($k6b) { Pass 'R6_CLEANUP_SHOW' ("已结束 --show 实例 pid={0}" -f $gui6b) } else { Fail 'R6_CLEANUP_SHOW' ("无法结束 --show 实例 pid={0}" -f $gui6b) }
        } catch {
            Fail 'R6_UNEXPECTED' ("异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
        }

        # ============================================================== R7 旧数据假精确降级
        Write-Section 'R7 1.0 旧数据假精确降级（LoadDay）'
        try {
            Initialize-TestDataDir $DataR7
            $legacyPath = Join-Path (Join-Path $DataR7 'data') ($Today + '.json')
            $legacyJson = '{"date":"' + $Today + '","bytesIn":123456,"bytesOut":654321,"peakInBps":0,"peakOutBps":0,"firstSampleUnix":1700000000,"lastSampleUnix":1700000060,"sampleCount":10,"bytesPrecise":true,"ips":{"203.0.113.7":{"ip":"203.0.113.7","bytesIn":0,"bytesOut":0,"connCount":3,"ports":[443],"proto":"TCP","city":"","region":"","country":"","isp":"","hostname":"","firstSeenUnix":1700000000}},"procs":{},"samples":[[1700000000,123,456]]}'
            [IO.File]::WriteAllText($legacyPath, $legacyJson, (New-Object System.Text.UTF8Encoding($false)))
            $before7 = Read-DaySummary $legacyPath
            Add-Info 'R7_LEGACY' ("预置 legacy: bytesPrecise={0} bytesIn={1:N0} bytesOut={2:N0} sampleCount={3} 逐IP合计=0" -f $before7.BytesPrecise, $before7.BytesIn, $before7.BytesOut, $before7.SampleCount)

            $r7 = Invoke-ExeWithExitCode -Tag 'r7-daemon' -Arguments @('--daemon', "$DaemonSeconds", '--datadir', $DataR7, '--mutex-tag', $MutexTag) -TimeoutSec ($DaemonSeconds + 90)
            if ($r7.TimedOut) { Fail 'R7_DAEMON_EXIT' ("{0}s 内未退出（已清理）" -f ($DaemonSeconds + 90)) }
            elseif ($r7.ExitCode -eq 0) { Pass 'R7_DAEMON_EXIT' ("退出码=0 elapsed={0}s" -f $r7.ElapsedSec) }
            else { Fail 'R7_DAEMON_EXIT' ("退出码={0}（期望 0）" -f $r7.ExitCode) }

            # v2.3.0：daemon 启动时把旧明文 json 迁移为 legacy 加密小时文件；之后按日合并解密读取
            $r7Legacy = Get-NwipdbFiles -DataDir $DataR7 -Kind legacy
            $r7JsonLeft = @(Get-ChildItem (Join-Path $DataR7 'data') -Filter '*.json' -File -ErrorAction SilentlyContinue)
            if ($r7Legacy.Count -ge 1) { Pass 'R7_MIGRATED' ("旧 json 已迁移为 legacy 加密文件: {0}" -f (($r7Legacy | ForEach-Object { $_.Name }) -join ',')) }
            else { Fail 'R7_MIGRATED' '未生成 legacy .nwipdb（v2.3.0 迁移未发生）' }
            if ($r7JsonLeft.Count -eq 0) { Add-Info 'R7_JSON_REMOVED' '原明文 json 已删除（迁移校验通过）' }
            else { Fail 'R7_JSON_REMOVED' ("迁移后仍有明文 json: {0}" -f (($r7JsonLeft | ForEach-Object { $_.Name }) -join ',')) }

            $after7 = Get-DayMergedSummary -DataDir $DataR7 -Date $Today
            if (-not $after7.Ok) {
                Fail 'R7_DOWNGRADED' ("daemon 后加密小时数据合并失败: {0}" -f $after7.Error)
            } else {
                Add-Info 'R7_AFTER' ("bytesPrecise={0} bytesIn={1:N0} bytesOut={2:N0} sampleCount={3} 文件={4} 分钟桶={5}" -f $after7.BytesPrecise, $after7.BytesIn, $after7.BytesOut, $after7.SampleCount, $after7.Files, $after7.SamplesCount)
                if (-not $after7.BytesPrecise) { Pass 'R7_DOWNGRADED' 'bytesPrecise 已从 true 降级为 false（1.0 假精确不再显示）' }
                else { Fail 'R7_DOWNGRADED' 'bytesPrecise 仍为 true（假精确未降级）' }
                if ($after7.SampleCount -gt 10) { Pass 'R7_SAMPLE_ACCUM' ("sampleCount {0} -> {1}（>10，未重置）" -f $before7.SampleCount, $after7.SampleCount) }
                else { Fail 'R7_SAMPLE_ACCUM' ("sampleCount {0} -> {1}（期望 >10，疑似 LoadDay 未接续）" -f $before7.SampleCount, $after7.SampleCount) }
                if ($after7.BytesIn -ge $before7.BytesIn -and $after7.BytesOut -ge $before7.BytesOut) {
                    Pass 'R7_BYTES_NO_REGRESS' ("bytesIn {0:N0} -> {1:N0}；bytesOut {2:N0} -> {3:N0}（不回退）" -f $before7.BytesIn, $after7.BytesIn, $before7.BytesOut, $after7.BytesOut)
                } else {
                    Fail 'R7_BYTES_NO_REGRESS' ("bytes 回退：in {0:N0} -> {1:N0}，out {2:N0} -> {3:N0}" -f $before7.BytesIn, $after7.BytesIn, $before7.BytesOut, $after7.BytesOut)
                }
                if ($after7.Files -ge 1) { Pass 'R7_DATE' ("今天加密小时文件 {0} 个（合并可读）" -f $after7.Files) }
                else { Fail 'R7_DATE' ("今天无可用小时文件（合并文件数={0}）" -f $after7.Files) }
            }
        } catch {
            Fail 'R7_UNEXPECTED' ("异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
        }

        # ============================================================== R8 自启往返
        Write-Section 'R8 自启往返（--autostart-on / --autostart-off）'
        try {
            $orig21 = $script:RegBackup[$ValueName21]
            $orig20 = $script:RegBackup[$ValueName20]
            Remove-RunValue $ValueName21
            $cleared = Get-RunValue $ValueName21
            if (-not $cleared.Exists) { Pass 'R8_CLEAR_BEFORE' 'Run\NetWatcher2.1 已清空（测试前置）' }
            else { Fail 'R8_CLEAR_BEFORE' ("清理失败，当前值: {0}" -f (Format-RunValueText $cleared)) }

            $r8on = Invoke-ExeWithExitCode -Tag 'r8-autostart-on' -Arguments @('--autostart-on', '--datadir', $DataR8) -TimeoutSec 60
            if ($r8on.TimedOut) { Fail 'R8_AUTOSTART_ON_EXIT' '--autostart-on 超时（已清理）' }
            elseif ($r8on.ExitCode -eq 0) { Pass 'R8_AUTOSTART_ON_EXIT' '--autostart-on exit=0' }
            else { Fail 'R8_AUTOSTART_ON_EXIT' ("--autostart-on exit={0}（期望 0）" -f $r8on.ExitCode) }

            $v21 = Get-RunValue $ValueName21
            Add-Info 'R8_VALUE_ON' ("Run\NetWatcher2.1 = {0}" -f (Format-RunValueText $v21))
            if (-not $v21.Exists) {
                Fail 'R8_AUTOSTART_ON_WRITE' '--autostart-on 后 Run\NetWatcher2.1 不存在'
            } else {
                $val = $v21.Value
                $checks = New-Object System.Collections.ArrayList
                if ($val.IndexOf($RunExe, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$checks.Add('指向被测 exe') }
                if ($val -match '--background') { [void]$checks.Add('含 --background') }
                if ($val -match '--datadir') { [void]$checks.Add('含 --datadir') }
                if ($val.IndexOf($DataR8, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$checks.Add('含绝对 datadir') }
                $missing = New-Object System.Collections.ArrayList
                foreach ($c in @('指向被测 exe', '含 --background', '含 --datadir', '含绝对 datadir')) { if ($checks -notcontains $c) { [void]$missing.Add($c) } }
                if ($missing.Count -eq 0) { Pass 'R8_AUTOSTART_ON_WRITE' ("写入值包含: " + ($checks -join '、')) }
                else { Fail 'R8_AUTOSTART_ON_WRITE' ("写入值缺少: " + ($missing -join '、')) }
            }
            $v20on = Get-RunValue $ValueName20
            if ($v20on.Exists -eq $orig20.Exists -and $v20on.Value -eq $orig20.Value) { Pass 'R8_V20_UNCHANGED_ON' '2.0 的 Run\NetWatcher 在 --autostart-on 后未变' }
            else { Fail 'R8_V20_UNCHANGED_ON' ("2.0 的 Run\NetWatcher 被改：before={0} after={1}" -f (Format-RunValueText $orig20), (Format-RunValueText $v20on)) }

            $r8off = Invoke-ExeWithExitCode -Tag 'r8-autostart-off' -Arguments @('--autostart-off') -TimeoutSec 60
            if ($r8off.TimedOut) { Fail 'R8_AUTOSTART_OFF_EXIT' '--autostart-off 超时（已清理）' }
            elseif ($r8off.ExitCode -eq 0) { Pass 'R8_AUTOSTART_OFF_EXIT' '--autostart-off exit=0' }
            else { Fail 'R8_AUTOSTART_OFF_EXIT' ("--autostart-off exit={0}（期望 0）" -f $r8off.ExitCode) }

            $v21off = Get-RunValue $ValueName21
            if (-not $v21off.Exists) { Pass 'R8_AUTOSTART_OFF_DELETE' '--autostart-off 后 Run\NetWatcher2.1 已删除' }
            else { Fail 'R8_AUTOSTART_OFF_DELETE' ("--autostart-off 后仍存在: {0}" -f (Format-RunValueText $v21off)) }
            $v20off = Get-RunValue $ValueName20
            if ($v20off.Exists -eq $orig20.Exists -and $v20off.Value -eq $orig20.Value) { Pass 'R8_V20_UNCHANGED' '2.0 的 Run\NetWatcher 全程未变' }
            else { Fail 'R8_V20_UNCHANGED' ("2.0 的 Run\NetWatcher 被改：before={0} after={1}" -f (Format-RunValueText $orig20), (Format-RunValueText $v20off)) }
        } catch {
            Fail 'R8_UNEXPECTED' ("异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
        } finally {
            if (Restore-RunValue $ValueName21) { Add-Info 'R8_RESTORE' ("Run\NetWatcher2.1 已恢复原值: {0}" -f (Format-RunValueText $script:RegBackup[$ValueName21])) }
            else { Fail 'R8_RESTORE' 'Run\NetWatcher2.1 恢复失败（需人工处理！）' }
        }

        # ============================================================== R9 版本资源
        Write-Section 'R9 版本资源'
        try {
            $viRun = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($RunExe)
            $viSrc = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Exe)
            Add-Info 'R9_VERSION_INFO' ("FileVersion={0} ProductVersion={1} FileDescription={2} ProductName={3}" -f $viRun.FileVersion, $viRun.ProductVersion, $viRun.FileDescription, $viRun.ProductName)
            if ($viRun.FileVersion -match '^2\.\d+\.\d+\.0$') { Pass 'R9_FILE_VERSION' ("FileVersion={0}" -f $viRun.FileVersion) }
            else { Fail 'R9_FILE_VERSION' ("FileVersion={0}（期望 2.1.x.0）" -f $viRun.FileVersion) }
            if ($viRun.ProductVersion -match '^2\.\d+\.\d+\.0$') { Pass 'R9_PRODUCT_VERSION' ("ProductVersion={0}" -f $viRun.ProductVersion) }
            else { Fail 'R9_PRODUCT_VERSION' ("ProductVersion={0}（期望 2.1.x.0）" -f $viRun.ProductVersion) }
            if ($viSrc.FileVersion -match '^2\.\d+\.\d+\.0$') { Add-Info 'R9_SRC_EXE_VERSION' ("源 exe FileVersion={0}" -f $viSrc.FileVersion) }
            else { Warn 'R9_SRC_EXE_VERSION' ("源 exe FileVersion={0}（期望 2.1.x.0）" -f $viSrc.FileVersion) }
        } catch {
            Fail 'R9_UNEXPECTED' ("异常: " + $_.Exception.Message)
        }

        # ============================================================== R10 GUI-GUI 数据目录冲突
        Write-Section 'R10 GUI-GUI 数据目录冲突（第二个 GUI 应弹提示框）'
        $guiA = 0; $guiB = 0
        try {
            Initialize-TestDataDir $DataR10
            $guiA = Start-Gui -DataDir $DataR10 -TagSuffix '-a'
            $startedA = Wait-GuiStarted -ProcessId $guiA -DataDir $DataR10 -TimeoutSec $StartTimeoutSec
            if (-not $startedA) { Fail 'R10_GUI_A_START' ("GUI A(pid={0}) 未在 {1}s 内落盘数据" -f $guiA, $StartTimeoutSec) }
            else { Pass 'R10_GUI_A_START' ("GUI A pid={0} 已占住 datadir R10" -f $guiA) }

            if ($startedA) {
                Start-Sleep -Milliseconds 500
                $guiB = Start-Gui -DataDir $DataR10 -TagSuffix '-b'
                Add-Info 'R10_GUI_B' ("启动 GUI B pid={0}（同一 datadir，不同 tag）" -f $guiB)
                $dlg = $null
                $deadline = (Get-Date).AddSeconds(25)
                while ((Get-Date) -lt $deadline) {
                    if (-not (Get-Process -Id $guiB -ErrorAction SilentlyContinue)) { break }
                    $winsB = @()
                    try { $winsB = @([P1Win]::Windows([uint32]$guiB)) } catch { }
                    $dlg = $winsB | Where-Object { $_.Title -eq 'IP监控2.1' } | Select-Object -First 1
                    if ($dlg) { break }
                    Start-Sleep -Milliseconds 300
                }
                if ($dlg) {
                    Pass 'R10_CONFLICT_DIALOG' ("GUI B pid={0} 弹出提示框：title='{1}' class={2} visible={3}" -f $guiB, $dlg.Title, $dlg.Cls, $dlg.Visible)
                } else {
                    Fail 'R10_CONFLICT_DIALOG' ("25s 内未见标题为「IP监控2.1」的提示框（GUI B pid={0} 存活={1}）" -f $guiB, [bool](Get-Process -Id $guiB -ErrorAction SilentlyContinue))
                }
                $aliveA = [bool](Get-Process -Id $guiA -ErrorAction SilentlyContinue)
                if ($aliveA) { Pass 'R10_GUI_A_ALIVE' ("GUI A pid={0} 在 B 冲突尝试后仍存活" -f $guiA) }
                else { Fail 'R10_GUI_A_ALIVE' ("GUI A pid={0} 已退出（不应被 B 影响）" -f $guiA) }
                $aliveB = [bool](Get-Process -Id $guiB -ErrorAction SilentlyContinue)
                Add-Info 'R10_GUI_B_STATE' ("GUI B 提示框显示期间存活={0}" -f $aliveB)
                $sumA = Get-DayMergedSummary -DataDir $DataR10 -Date $Today
                if ($sumA.Ok) { Add-Info 'R10_GUI_A_DATA' ("加密小时文件={0} 样本={1} bytesIn={2:N0} bytesOut={3:N0}" -f $sumA.Files, $sumA.SampleCount, $sumA.BytesIn, $sumA.BytesOut) }
                else { Add-Info 'R10_GUI_A_DATA' ("GUI A 数据合并失败: " + $sumA.Error) }
            }
        } catch {
            Fail 'R10_UNEXPECTED' ("异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
        } finally {
            if ($guiB -gt 0) {
                $kb = Stop-QaProcess -ProcessId $guiB -WaitSec 8
                if ($kb) { Pass 'R10_CLEANUP_GUI_B' ("已结束本脚本启动的 GUI B pid={0}" -f $guiB) } else { Fail 'R10_CLEANUP_GUI_B' ("无法结束 GUI B pid={0}" -f $guiB) }
            }
            if ($guiA -gt 0) {
                $ka = Stop-QaProcess -ProcessId $guiA -WaitSec 8
                if ($ka) { Pass 'R10_CLEANUP_GUI_A' ("已结束本脚本启动的 GUI A pid={0}" -f $guiA) } else { Fail 'R10_CLEANUP_GUI_A' ("无法结束 GUI A pid={0}" -f $guiA) }
            }
        }

        # ============================================================== R11 自启状态对账
        Write-Section 'R11 启动流程不得误删已存在自启项（P1-5 对账）'
        try {
            Initialize-TestDataDir $DataR11
            $sentinel = '"C:\sentinel\NetWatcher.exe" --background'
            Set-RunValue $ValueName21 $sentinel
            $sentCheck = Get-RunValue $ValueName21
            if ($sentCheck.Exists -and $sentCheck.Value -eq $sentinel) { Pass 'R11_SENTINEL_SET' 'sentinel 已写入 Run\NetWatcher2.1' }
            else { Fail 'R11_SENTINEL_SET' ("sentinel 写入失败，当前: {0}" -f (Format-RunValueText $sentCheck)) }
            $v20before11 = Get-RunValue $ValueName20

            $gui11 = Start-Gui -DataDir $DataR11
            $started11 = Wait-GuiStarted -ProcessId $gui11 -DataDir $DataR11 -TimeoutSec $StartTimeoutSec
            if (-not $started11) { Fail 'R11_GUI_START' ("GUI 未在 {0}s 内落盘数据（pid={1}）" -f $StartTimeoutSec, $gui11) }
            else { Add-Info 'R11_GUI_START' ("GUI pid={0} 已启动，观察 {1}s（不打开设置、不保存）" -f $gui11, $GuiObserveSec) }
            Start-Sleep -Seconds $GuiObserveSec
            $alive11 = [bool](Get-Process -Id $gui11 -ErrorAction SilentlyContinue)
            $k11 = Stop-QaProcess -ProcessId $gui11 -WaitSec 8
            if ($k11) { Pass 'R11_CLEANUP_GUI' ("已结束本脚本启动的 GUI pid={0}（aliveBeforeKill={1}）" -f $gui11, $alive11) }
            else { Fail 'R11_CLEANUP_GUI' ("无法结束 GUI pid={0}" -f $gui11) }
            Start-Sleep -Milliseconds 500

            $v21after11 = Get-RunValue $ValueName21
            Add-Info 'R11_SENTINEL_AFTER' ("启动/退出后 Run\NetWatcher2.1 = {0}" -f (Format-RunValueText $v21after11))
            if ($v21after11.Exists -and $v21after11.Value -eq $sentinel) {
                Pass 'R11_AUTOSTART_RECONCILE' 'sentinel 仍存在且值未变（启动流程未误删自启项）'
            } else {
                Fail 'R11_AUTOSTART_RECONCILE' ("sentinel 被启动流程改动/删除：before={0} after={1}" -f $sentinel, (Format-RunValueText $v21after11))
            }
            $v20after11 = Get-RunValue $ValueName20
            if ($v20after11.Exists -eq $v20before11.Exists -and $v20after11.Value -eq $v20before11.Value) { Pass 'R11_V20_UNCHANGED' '2.0 的 Run\NetWatcher 未被改动' }
            else { Fail 'R11_V20_UNCHANGED' ("2.0 的 Run\NetWatcher 被改：before={0} after={1}" -f (Format-RunValueText $v20before11), (Format-RunValueText $v20after11)) }
        } catch {
            Fail 'R11_UNEXPECTED' ("异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
        } finally {
            if (Restore-RunValue $ValueName21) { Add-Info 'R11_RESTORE' ("Run\NetWatcher2.1 已恢复原值: {0}" -f (Format-RunValueText $script:RegBackup[$ValueName21])) }
            else { Fail 'R11_RESTORE' 'Run\NetWatcher2.1 恢复失败（需人工处理！）' }
        }

        # ============================================================== P1 静态检查（P1-5/6/7/8/10/11/12）
        Write-Section 'P1 静态检查（代码审查证据；非管理员环境无法触发 EStats 成功路径）'
        try {
            $srcProgram = Join-Path $RepoRoot 'src\Program.cs'
            $srcMain = Join-Path $RepoRoot 'src\MainForm.cs'
            $srcMonitor = Join-Path $RepoRoot 'src\Monitor.cs'
            $srcStorage = Join-Path $RepoRoot 'src\Storage.cs'
            $progText = if (Test-Path $srcProgram) { [IO.File]::ReadAllText($srcProgram, [Text.Encoding]::UTF8) } else { '' }
            $mainText = if (Test-Path $srcMain) { [IO.File]::ReadAllText($srcMain, [Text.Encoding]::UTF8) } else { '' }
            $monText = if (Test-Path $srcMonitor) { [IO.File]::ReadAllText($srcMonitor, [Text.Encoding]::UTF8) } else { '' }
            $storeText = if (Test-Path $srcStorage) { [IO.File]::ReadAllText($srcStorage, [Text.Encoding]::UTF8) } else { '' }
            if ($progText.Length -eq 0 -or $mainText.Length -eq 0 -or $monText.Length -eq 0 -or $storeText.Length -eq 0) {
                Warn 'S_SRC_READ' '无法读取 2.1\src（静态检查跳过）'
            } else {
                if ($progText -match 'startHidden\s*=\s*background\s*\|\|\s*\(cfg\.StartMinimized\s*&&\s*!showRequested\)') { Pass 'S_P1_6_STARTHIDDEN' 'Program.cs: startHidden = background || (StartMinimized && !show)' }
                else { Warn 'S_P1_6_STARTHIDDEN' 'Program.cs 未匹配 startHidden 表达式（需人工复核）' }
                if ($mainText -match 'Startup\.IsEnabled\(\)' -and $mainText -match 'Startup\.SetEnabled\(cfg\.AutoStart\)' -and $mainText -match 'cfg\.AutoStart\s*=\s*Startup\.IsEnabled\(\)') { Pass 'S_P1_5_AUTOSTART_RECONCILE' 'MainForm.cs: 设置窗口前对账 + 保存后回读 Run 状态' }
                else { Warn 'S_P1_5_AUTOSTART_RECONCILE' 'MainForm.cs 未完整匹配自启对账代码（需人工复核）' }
                if ($mainText -match '--datadir' -and $mainText -match 'adminArgs\.Append') { Pass 'S_P1_7_ADMIN_DATADIR' 'MainForm.cs: 管理员重启参数拼接包含 --datadir（UAC 交互无法自动化，仅静态证据）' }
                else { Warn 'S_P1_7_ADMIN_DATADIR' 'MainForm.cs 未匹配管理员重启 --datadir 拼接' }
                if ($mainText -match 'GeoIp\.SetEnabled\(cfg\.GeoEnabled\)') { Pass 'S_P1_8_GEOIP_LIVE' 'MainForm.cs: 设置保存后立即 GeoIp.SetEnabled(cfg.GeoEnabled)' }
                else { Warn 'S_P1_8_GEOIP_LIVE' 'MainForm.cs 未匹配 GeoIp.SetEnabled 调用' }
                if ($mainText -match 'IPv4 TCP' -and $mainText -match 'IPv6' -and $mainText -match 'UDP') { Pass 'S_P1_10_PRECISE_TOOLTIP' 'MainForm.cs: 精确模式 tooltip 含 IPv4 TCP / IPv6 / UDP 说明' }
                else { Warn 'S_P1_10_PRECISE_TOOLTIP' 'MainForm.cs 未匹配 tooltip 文案（需人工复核）' }
                if ($mainText -match 'lastProcRebind\)\.TotalSeconds\s*>=\s*5' -and $mainText -match 'lastHistRebind\)\.TotalSeconds\s*>=\s*15') { Pass 'S_P1_11_REFRESH_THROTTLE' 'MainForm.cs: 进程/按日页 >=5s、历史页 >=15s 节流（实时页每次采样）' }
                else { Warn 'S_P1_11_REFRESH_THROTTLE' 'MainForm.cs 未匹配刷新节流阈值（需人工复核）' }
                if ($monText -match 'EStats 首次失败' -and $monText -match 'lastEStatsError\s*=\s*""') { Pass 'S_P1_12_ESTATS_LOG' 'Monitor.cs: EStats 首次失败写 monitor.log + 恢复后清空 lastEStatsError（成功路径无法在本环境触发，仅静态证据）' }
                else { Warn 'S_P1_12_ESTATS_LOG' 'Monitor.cs 未匹配 EStats 失败日志/错误清除逻辑' }
                if ($storeText -match 'P1-9' -and $storeText -match 'ipSum\s*==\s*0') { Pass 'S_P1_9_DOWNGRADE_IMPL' 'Storage.cs: LoadDay 假精确降级实现存在（运行验证见 R7）' }
                else { Warn 'S_P1_9_DOWNGRADE_IMPL' 'Storage.cs 未匹配假精确降级实现' }
            }
        } catch {
            Warn 'S_STATIC_UNEXPECTED' ("静态检查异常: " + $_.Exception.Message)
        }
    }
} catch {
    Fail 'UNEXPECTED' ("脚本异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
} finally {
    # 兜底：只结束本脚本记录的 PID（绝不按进程名杀，绝不碰 PID 10856）
    foreach ($procId in @($script:ActivePids)) {
        $ip = [int]$procId
        if ($ip -eq $UserPidGuard) { continue }
        if (Get-Process -Id $ip -ErrorAction SilentlyContinue) { [void](Stop-QaProcess -ProcessId $ip -WaitSec 5) }
    }
    # 兜底：恢复注册表原值（R8/R11 的 finally 已恢复，这里再核对一次）
    $r21ok = Restore-RunValue $ValueName21
    $r20ok = Restore-RunValue $ValueName20
    if ($r21ok -and $r20ok) {
        Add-Info 'REG_FINAL_STATE' ("任务结束注册表已恢复：Run\NetWatcher2.1={0}；Run\NetWatcher={1}" -f (Format-RunValueText (Get-RunValue $ValueName21)), (Format-RunValueText (Get-RunValue $ValueName20)))
    } else {
        Fail 'REG_FINAL_RESTORE' '注册表最终恢复失败（需人工处理！）'
    }
}

# ------------------------------------------------------------------ 汇总与报告
Write-Section '汇总'
$passCount = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count

$table = $script:Results | Format-Table -AutoSize Status, Check, Detail | Out-String -Width 240
Write-Host $table
$resultText = if ($failCount -gt 0) { 'FAIL' } else { 'PASS' }
Write-Host ("RESULT: {0}   PASS={1}  FAIL={2}  WARN={3}" -f $resultText, $passCount, $failCount, $warnCount) -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ("temp dir : {0}" -f $TempRoot)
Write-Host ("evidence : {0}" -f $OutDir)
if ($failCount -gt 0) {
    Write-Host 'FAIL 明细:' -ForegroundColor Red
    foreach ($f in @($script:Results | Where-Object { $_.Status -eq 'FAIL' })) { Write-Host ("  - " + $f.Check + ": " + $f.Detail) -ForegroundColor Red }
}

$reportTxt = Join-Path $OutDir ("regression_p1_{0}.txt" -f $RunTag)
$reportJson = Join-Path $OutDir ("regression_p1_{0}.json" -f $RunTag)
$txt = @()
$txt += "IP监控2.1 P1-A/B 回归测试报告  $RunTag"
$txt += ("开始: {0}" -f $StartedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))
$txt += ("结束: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
$txt += ("exe: {0}" -f $Exe)
if (Test-Path $Exe) { $txt += ("exe SHA256: {0}" -f (Get-Sha256 $Exe)) }
$txt += ("tempRoot: {0}" -f $TempRoot)
$txt += ("daemonSeconds={0} guiObserve={1} mutexTag={2} userPidGuard={3}" -f $DaemonSeconds, $GuiObserveSec, $MutexTag, $UserPidGuard)
$txt += ("registry backup: NetWatcher2.1=[{0}] NetWatcher=[{1}]" -f (Format-RunValueText $script:RegBackup[$ValueName21]), (Format-RunValueText $script:RegBackup[$ValueName20]))
$txt += ''
$txt += ("RESULT: {0}  PASS={1} FAIL={2} WARN={3}" -f $resultText, $passCount, $failCount, $warnCount)
$txt += ''
$txt += '-- checks --'
foreach ($r in $script:Results) { $txt += ("[{0}] {1,-32} {2}" -f $r.Status, $r.Check, $r.Detail) }
$txt += ''
$txt += '-- info --'
foreach ($r in $script:InfoRows) { $txt += ("[INFO] {0,-32} {1}" -f $r.Check, $r.Detail) }
$txt | Set-Content -Path $reportTxt -Encoding UTF8

$meta = [pscustomobject]@{
    time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
    result = $resultText; pass = $passCount; fail = $failCount; warn = $warnCount
    exe = $Exe; tempRoot = $TempRoot; outDir = $OutDir
    daemonSeconds = $DaemonSeconds; guiObserveSec = $GuiObserveSec; mutexTag = $MutexTag
    registryBackup = [pscustomobject]@{
        netWatcher21 = (Format-RunValueText $script:RegBackup[$ValueName21])
        netWatcher20 = (Format-RunValueText $script:RegBackup[$ValueName20])
    }
    checks = @($script:Results)
    info = @($script:InfoRows)
}
$meta | ConvertTo-Json -Depth 6 | Set-Content -Path $reportJson -Encoding UTF8
Write-Host ("report   : {0}" -f $reportTxt)
Write-Host ("machine  : {0}" -f $reportJson)

if ($failCount -gt 0) { exit 1 } else { exit 0 }
