#requires -Version 5.0
<#
.SYNOPSIS
  IP监控2.1 P0 修复回归测试（R1~R5）：同日重启累积 / selftest 只读 / 单写实例 / 真实数据护栏。

.DESCRIPTION
  针对 2.1 P0 四项修复做可复跑回归，全部输出实际数值与 PASS/FAIL：
    R1 同日重启累积：daemon 12s（datadir A）-> 读 data\今天.json -> 再 daemon 12s
       -> sampleCount 必须 >= 第一次+1、firstSampleUnix 不变、bytes 不回退。
    R2 selftest 不动当天数据：预置 data\<今天>.json 哨兵（bytesIn=123456, sampleCount=42）
       -> --selftest -> 文件 SHA256/大小/字段完全一致，data\ 无新增/删除文件。
    R3 selftest 不动自启：HKCU Run\NetWatcher2.1 与 Run\NetWatcher 前后值完全一致；
       且 selftest.log 必须出现「临时值写入后=True 删除后=True」证据；Run 键不得残留临时值。
    R4 单写实例：GUI 占住 datadir B 后，--daemon 同一 datadir B 必须快速退出且退出码=2、
       GUI 仍存活、GUI 数据文件未破坏、daemon.log 有冲突记录。
    R5 真实数据护栏：全程前后对 %APPDATA%\NetWatcher 做 size+mtime+SHA256 快照对比；
       若用户 2.0 管理员实例 PID 10856 正在写导致变化，按 INFO 归因（不算失败），
       归因依据见 _analysis\control_realdata.txt 的闲置对照组实验。

  安全约束（本机怪癖，脚本已内建）：
  1. 被测 exe 先复制到 %TEMP% 再运行（从仓库目录直接启动会被秒杀）。
  2. 所有实例一律传绝对 --datadir（均在 %TEMP%\ipmon-p0reg-<tag>\ 下），绝不写 %APPDATA%\NetWatcher。
  3. 只结束本脚本自己通过 Win32_Process.Create 启动并记录 PID 的进程；绝不按进程名杀。
  4. 用户管理员实例 PID 10856 全程不碰（只读探测）。
  5. GUI 用 Invoke-CimMethod Win32_Process Create 启动；退出码用 cmd 包装脚本落盘捕获。

.PARAMETER Exe
  被测 exe，默认 <2.1 根>\bin\NetWatcher.exe。

.PARAMETER Seconds
  R1 单次 daemon 采集秒数（默认 12）。

.PARAMETER R4DaemonSeconds
  R4 冲突 daemon 的 --daemon 秒数（默认 8；正常应无法采集、立即以退出码 2 退出）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-p0.ps1

.NOTES
  退出码：有 FAIL -> 1；否则 0。
  报告：tools\qa\out\regression_<tag>.txt / .json。
#>
[CmdletBinding()]
param(
    [string]$Exe = '',
    [string]$OutDir = '',
    [int]$Seconds = 12,
    [int]$R4DaemonSeconds = 8,
    [string]$MutexTag = 'p0reg',
    [int]$UserPidGuard = 10856,
    [int]$SelftestTimeoutSec = 240,
    [int]$StartTimeoutSec = 40
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# JavaScriptSerializer 来自 System.Web.Extensions（与程序自身 JSON 序列化器一致）
Add-Type -AssemblyName System.Web.Extensions | Out-Null
# v2.3.0：.nwipdb 加密小时文件只读适配层（明文头/DPAPI+AES+HMAC+GZip 解密/按日合并）
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
# 每次运行使用唯一 mutex-tag，避免上一次异常退出的 GUI 单实例锁残留导致本次 GUI 启动即退出
$MutexTag = $MutexTag + '-' + (Get-Date -Format 'HHmmss')
$TempRoot = Join-Path $env:TEMP ("ipmon-p0reg-" + $RunTag)
$RunDir = Join-Path $TempRoot 'run'
$RunExe = Join-Path $RunDir 'NetWatcher.exe'
$DataA = Join-Path $TempRoot 'data-A'
$DataB = Join-Path $TempRoot 'data-B'
$DataC = Join-Path $TempRoot 'data-C'
$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RealNetWatcherRunValue = 'NetWatcher'
$NewNetWatcherRunValue = 'NetWatcher2.1'
$CfgText = '{"ScanIntervalSeconds":2,"AutoStart":false,"RetentionDays":0,"StartMinimized":false,"GeoEnabled":true,"GeoApi":"http://ip-api.com/json/{0}?fields=status,message,country,regionName,city,isp,lat,lon&lang=zh-CN","NewIpAlert":true,"ShowLocalIp":true}'

$script:Results = New-Object System.Collections.ArrayList
$script:InfoRows = New-Object System.Collections.ArrayList
$script:ActivePids = New-Object System.Collections.ArrayList
$script:Evidence = New-Object System.Collections.ArrayList
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

# ------------------------------------------------------------------ 进程 / 文件 / JSON 辅助
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

# 只结束「本脚本启动的 PID」派生的进程树（cmd 包装器 + 其子进程），不按进程名批量杀
function Stop-ProcessTree {
    param([int]$RootPid)
    try {
        $children = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $RootPid) -ErrorAction SilentlyContinue)
        foreach ($c in $children) { [void](Stop-QaProcess -ProcessId ([int]$c.ProcessId) -WaitSec 2) }
    } catch { }
    [void](Stop-QaProcess -ProcessId $RootPid -WaitSec 4)
}

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
    param([string]$Dir)
    New-Item -ItemType Directory -Path (Join-Path $Dir 'data') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $Dir 'config.json'), $CfgText, (New-Object System.Text.UTF8Encoding($false)))
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

function Get-DataDirListing {
    param([string]$Dir)
    $d = Join-Path $Dir 'data'
    $list = @()
    if (Test-Path $d) {
        $list = @(Get-ChildItem $d -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Length = $_.Length; Sha = (Get-Sha256 $_.FullName) }
        })
    }
    return ,$list
}

function Get-DirSnapshot {
    param([string]$Dir)
    $snap = @{}
    if (Test-Path $Dir) {
        Get-ChildItem $Dir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $snap[$_.FullName] = ('{0}|{1}|{2}' -f $_.Length, $_.LastWriteTimeUtc.Ticks, (Get-Sha256 $_.FullName))
        }
    }
    return $snap
}

function Compare-DirSnapshotDetailed {
    param($Before, $After)
    $changes = New-Object System.Collections.ArrayList
    foreach ($k in $Before.Keys) {
        if (-not $After.ContainsKey($k)) { [void]$changes.Add([pscustomobject]@{ Kind = '删除'; Path = $k; Before = $Before[$k]; After = '' }); continue }
        if ($Before[$k] -ne $After[$k]) { [void]$changes.Add([pscustomobject]@{ Kind = '修改'; Path = $k; Before = $Before[$k]; After = $After[$k] }) }
    }
    foreach ($k in $After.Keys) {
        if (-not $Before.ContainsKey($k)) { [void]$changes.Add([pscustomobject]@{ Kind = '新增'; Path = $k; Before = ''; After = $After[$k] }) }
    }
    return ,$changes
}

function Get-RegRunSnapshot {
    $snap = @{}
    if (Test-Path $RegPath) {
        $item = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
        if ($item) {
            foreach ($p in $item.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                $snap[$p.Name] = [string]$p.Value
            }
        }
    }
    return $snap
}
function Format-RegValue {
    param($Snap, [string]$Name)
    if ($Snap.ContainsKey($Name)) { return ('"' + $Snap[$Name] + '"') }
    return '<不存在>'
}
function Test-RegValueEqual {
    param($A, $B, [string]$Name)
    if ($A.ContainsKey($Name) -ne $B.ContainsKey($Name)) { return $false }
    if (-not $A.ContainsKey($Name)) { return $true }
    return ([string]$A[$Name] -eq [string]$B[$Name])
}

# 用 cmd 包装 exe，把退出码落盘（WMI Create 拿不到退出码；Start-Process 会因继承管道挂住）
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
    param([string]$DataDir)
    $procId = Start-WmiProcess -FilePath $RunExe -Arguments @('--datadir', $DataDir, '--mutex-tag', $MutexTag) -WorkingDirectory $RunDir
    [void]$script:ActivePids.Add($procId)
    return $procId
}

# ------------------------------------------------------------------ 0. 预检 / 环境隔离
Write-Host ''
Write-Host "IP监控2.1 P0 回归测试  ($RunTag)" -ForegroundColor White
Write-Host ("repo    = {0}" -f $RepoRoot)
Write-Host ("exe     = {0}" -f $Exe)
Write-Host ("temp    = {0}" -f $TempRoot)
Write-Host ("out     = {0}" -f $OutDir)
Write-Host ("seconds = {0}  R4daemon = {1}s  mutexTag = {2}" -f $Seconds, $R4DaemonSeconds, $MutexTag)

Write-Section '0. 预检 / 环境隔离'
Add-Info 'TIME' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Add-Info 'USER' ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
$shellAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Info 'SHELL_ADMIN' ([string]$shellAdmin)
Add-Info 'PS' ($PSVersionTable.PSVersion.ToString())

if (Test-Path $Exe) {
    $fi = Get-Item $Exe
    Pass 'PRE_EXE' ("{0}  {1:N0} bytes  mtime={2}  SHA256={3}..." -f $Exe, $fi.Length, $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'), (Short-Sha (Get-Sha256 $Exe)))
} else {
    Fail 'PRE_EXE' ("找不到被测 exe: {0}" -f $Exe)
    $script:CanRun = $false
}

# 数据目录必须绝对、在 %TEMP% 下、且不在仓库 / 用户真实数据目录内
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

# 运行副本：必须先复制到 %TEMP%（本机从仓库目录启动会被秒杀）
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

# 用户 2.0 管理员实例（PID 10856）只读探测，绝不碰
$userProc = Get-Process -Id $UserPidGuard -ErrorAction SilentlyContinue
$userStart = $null
if ($userProc) { try { $userStart = $userProc.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { $userStart = '?' } }
if ($userProc) {
    Add-Info 'PRE_USER_INSTANCE' ("用户 2.0 管理员实例 PID {0} 存活（start={1}），全程不结束、不干预；本脚本所有实例均带独立绝对 --datadir" -f $UserPidGuard, $userStart)
} else {
    Add-Info 'PRE_USER_INSTANCE' ("PID {0} 当前不在运行（若 2.0 实例已退出，R5 的严格判定会生效）" -f $UserPidGuard)
}
$nwProcs = @(Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue)
Add-Info 'PRE_NETWATCHER_PROCS' ("当前 NetWatcher 进程数={0}（PID: {1}）" -f $nwProcs.Count, (($nwProcs | ForEach-Object { $_.Id }) -join ','))

# R5 基线快照（必须在任何被测进程启动前取）
$realSnapBefore = Get-DirSnapshot $RealDataDir
Add-Info 'R5_REALDATA_BASELINE' ("{0}  文件数={1}  size+mtime+SHA256 已记录" -f $RealDataDir, $realSnapBefore.Count)

# ------------------------------------------------------------------ 主流程（异常隔离，保证汇总一定输出）
try {
    # ============================================================== R1 同日重启累积
    if ($script:CanRun) {
        Write-Section ("R1 同日重启累积（--daemon {0}s x2，datadir A；v2.3.0 加密小时文件）" -f $Seconds)
        try {
            Initialize-TestDataDir $DataA
            $r1a = $null; $r1b = $null
            $files1 = @(); $files2 = @()
            $daemon1 = Invoke-ExeWithExitCode -Tag 'r1-daemon1' -Arguments @('--daemon', "$Seconds", '--datadir', $DataA, '--mutex-tag', $MutexTag) -TimeoutSec ($Seconds + 90)
            if ($daemon1.TimedOut) {
                Fail 'R1_DAEMON1_EXIT' ("{0}s 内未退出（已清理）" -f ($Seconds + 90))
            } elseif ($daemon1.ExitCode -eq 0) {
                Pass 'R1_DAEMON1_EXIT' ("退出码=0  elapsed={0}s" -f $daemon1.ElapsedSec)
            } else {
                Fail 'R1_DAEMON1_EXIT' ("退出码={0}（期望 0）elapsed={1}s stdout={2}" -f $daemon1.ExitCode, $daemon1.ElapsedSec, $daemon1.StdoutLog)
            }
            $files1 = Get-NwipdbFiles -DataDir $DataA -Date $Today
            $r1a = Get-DayMergedSummary -DataDir $DataA -Date $Today
            if ($files1.Count -lt 1) {
                Fail 'R1_DAEMON1_DATA' ("{0}\data 下没有今天的 *.nwipdb（v2.3.0 小时文件）" -f $DataA)
            } elseif (-not $r1a.Ok) {
                Fail 'R1_DAEMON1_DATA' ("小时文件合并/解密失败: {0}（文件 {1} 个）" -f $r1a.Error, $files1.Count)
            } else {
                Pass 'R1_DAEMON1_DATA' ("{0} 个今天小时文件  sampleCount={1}  bytesIn={2:N0}  bytesOut={3:N0}  分钟桶={4}  firstSampleUnix={5}" -f $files1.Count, $r1a.SampleCount, $r1a.BytesIn, $r1a.BytesOut, $r1a.SamplesCount, $r1a.FirstSampleUnix)
            }

            if ($r1a -and $r1a.Ok) {
                Start-Sleep -Milliseconds 400
                $daemon2 = Invoke-ExeWithExitCode -Tag 'r1-daemon2' -Arguments @('--daemon', "$Seconds", '--datadir', $DataA, '--mutex-tag', $MutexTag) -TimeoutSec ($Seconds + 90)
                if ($daemon2.TimedOut) {
                    Fail 'R1_DAEMON2_EXIT' ("{0}s 内未退出（已清理）" -f ($Seconds + 90))
                } elseif ($daemon2.ExitCode -eq 0) {
                    Pass 'R1_DAEMON2_EXIT' ("退出码=0  elapsed={0}s" -f $daemon2.ElapsedSec)
                } else {
                    Fail 'R1_DAEMON2_EXIT' ("退出码={0}（期望 0）elapsed={1}s" -f $daemon2.ExitCode, $daemon2.ElapsedSec)
                }
                $files2 = Get-NwipdbFiles -DataDir $DataA -Date $Today
                $r1b = Get-DayMergedSummary -DataDir $DataA -Date $Today
                if (-not $r1b -or -not $r1b.Ok) {
                    Fail 'R1_SAME_DAY_RESUME' ("第二次 daemon 后今天的 .nwipdb 合并失败: {0}" -f $(if ($r1b) { $r1b.Error } else { '无' }))
                } else {
                    Add-Info 'R1_VALUES' ("第一次: 文件={0} sampleCount={1} bytesIn={2:N0} bytesOut={3:N0} firstSampleUnix={4}" -f $files1.Count, $r1a.SampleCount, $r1a.BytesIn, $r1a.BytesOut, $r1a.FirstSampleUnix)
                    Add-Info 'R1_VALUES' ("第二次: 文件={0} sampleCount={1} bytesIn={2:N0} bytesOut={3:N0} firstSampleUnix={4}" -f $files2.Count, $r1b.SampleCount, $r1b.BytesIn, $r1b.BytesOut, $r1b.FirstSampleUnix)
                    # v2.3.0 新判据：每次启动必建新小时文件（同小时多 session 文件）
                    if ($files2.Count -gt $files1.Count) {
                        Pass 'R1_SESSION_FILE_GROWTH' ("每次启动新增小时文件：{0} -> {1} 个（{2}）" -f $files1.Count, $files2.Count, (($files2 | ForEach-Object { $_.Name }) -join ','))
                    } else {
                        Fail 'R1_SESSION_FILE_GROWTH' ("重启后未新增小时文件：{0} -> {1}（v2.3.0 要求每次启动必建新文件）" -f $files1.Count, $files2.Count)
                    }
                    if ($r1b.SampleCount -ge ($r1a.SampleCount + 1)) {
                        Pass 'R1_SAMPLE_COUNT_GROWTH' ("同日合并 sampleCount {0} -> {1}（>= +1，累积已恢复）" -f $r1a.SampleCount, $r1b.SampleCount)
                    } else {
                        Fail 'R1_SAMPLE_COUNT_GROWTH' ("sampleCount {0} -> {1}（期望 >= {2}；疑似重启后未 LoadDay 合并，第一次写盘覆盖了当天累计）" -f $r1a.SampleCount, $r1b.SampleCount, ($r1a.SampleCount + 1))
                    }
                    if ($r1a.FirstSampleUnix -gt 0 -and $r1b.FirstSampleUnix -eq $r1a.FirstSampleUnix) {
                        Pass 'R1_FIRST_SAMPLE_UNIX' ("合并 firstSampleUnix={0} 保持不变" -f $r1b.FirstSampleUnix)
                    } else {
                        Fail 'R1_FIRST_SAMPLE_UNIX' ("firstSampleUnix {0} -> {1}（期望不变且 >0）" -f $r1a.FirstSampleUnix, $r1b.FirstSampleUnix)
                    }
                    if ($r1b.BytesIn -ge $r1a.BytesIn -and $r1b.BytesOut -ge $r1a.BytesOut) {
                        Pass 'R1_BYTES_NO_REGRESS' ("合并 bytesIn {0:N0} -> {1:N0}；bytesOut {2:N0} -> {3:N0}（不回退）" -f $r1a.BytesIn, $r1b.BytesIn, $r1a.BytesOut, $r1b.BytesOut)
                    } else {
                        Fail 'R1_BYTES_NO_REGRESS' ("bytes 回退：in {0:N0} -> {1:N0}，out {2:N0} -> {3:N0}" -f $r1a.BytesIn, $r1b.BytesIn, $r1a.BytesOut, $r1b.BytesOut)
                    }
                    $badDate = @($files2 | Where-Object { $_.Date -ne $Today })
                    if ($files2.Count -ge 2 -and $badDate.Count -eq 0 -and ($files2 | Where-Object { $_.Kind -eq 'hour' }).Count -ge 2) {
                        Pass 'R1_SAME_DAY_FILES' ("今天小时文件 {0} 个且日期均为 {1}（{2} 种 session）" -f $files2.Count, $Today, (($files2 | ForEach-Object { $_.Kind }) -join ','))
                    } else {
                        Fail 'R1_SAME_DAY_FILES' ("同一天小时文件异常：{0} 个，非今天 {1} 个" -f $files2.Count, $badDate.Count)
                    }
                }
            }
            $daemonLogA = Join-Path $DataA 'daemon.log'
            if (Test-Path $daemonLogA) { Add-Info 'R1_DAEMON_LOG' ("{0} 存在（{1:N0}B）" -f $daemonLogA, (Get-Item $daemonLogA).Length) }
            $keyA = Get-NwipdbKeyInfo -DataDir $DataA
            if ($keyA.Exists -and $keyA.Valid) { Pass 'R1_STOREKEY' ("data\{0} 已生成且 magic 正确（{1}B）" -f $script:NwipdbFormat.KeyPathName, $keyA.Length) }
            else { Fail 'R1_STOREKEY' ("未生成有效密钥文件 data\{0}（Exists={1} Magic={2}）" -f $script:NwipdbFormat.KeyPathName, $keyA.Exists, $keyA.Magic) }
        } catch {
            Fail 'R1_UNEXPECTED' ("异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
        }
    }

    # ============================================================== R2 + R3：--selftest 只读
    if ($script:CanRun) {
        Write-Section 'R2/R3 --selftest 只读校验（datadir C）'
        try {
            Initialize-TestDataDir $DataC
            $sentinelPath = Join-Path (Join-Path $DataC 'data') ($Today + '.json')
            $sentinelJson = '{"date":"' + $Today + '","bytesIn":123456,"bytesOut":654321,"peakInBps":0,"peakOutBps":0,"firstSampleUnix":1700000000,"lastSampleUnix":1700000060,"sampleCount":42,"bytesPrecise":false,"ips":{},"procs":{},"samples":[[1700000000,123,456]]}'
            [IO.File]::WriteAllText($sentinelPath, $sentinelJson, (New-Object System.Text.UTF8Encoding($false)))
            $sentBefore = Read-DaySummary $sentinelPath
            $listingBefore = Get-DataDirListing $DataC
            $regBefore = Get-RegRunSnapshot
            Add-Info 'R2_SENTINEL' ("已预置哨兵 {0}  size={1:N0}B  SHA256={2}...  bytesIn=123456 sampleCount=42" -f $sentinelPath, $sentBefore.Size, (Short-Sha $sentBefore.Sha))
            Add-Info 'R3_REG_BASELINE' ("Run\NetWatcher2.1={0}  Run\NetWatcher={1}" -f (Format-RegValue $regBefore $NewNetWatcherRunValue), (Format-RegValue $regBefore $RealNetWatcherRunValue))

            $st = Invoke-ExeWithExitCode -Tag 'selftest' -Arguments @('--selftest', '--datadir', $DataC, '--mutex-tag', $MutexTag) -TimeoutSec $SelftestTimeoutSec
            if ($st.TimedOut) {
                Fail 'R2_SELFTEST_EXIT' ("{0}s 内未退出（已清理）" -f $SelftestTimeoutSec)
            } elseif ($st.ExitCode -eq 0) {
                Pass 'R2_SELFTEST_EXIT' ("退出码=0  elapsed={0}s" -f $st.ElapsedSec)
            } else {
                Fail 'R2_SELFTEST_EXIT' ("退出码={0}（期望 0）elapsed={1}s stdout={2}" -f $st.ExitCode, $st.ElapsedSec, $st.StdoutLog)
            }

            $selftestLog = Join-Path $DataC 'selftest.log'
            $stText = ''
            if (Test-Path $selftestLog) {
                $stText = [IO.File]::ReadAllText($selftestLog, [Text.Encoding]::UTF8)
                $logBytes = (Get-Item $selftestLog).Length
                if ($logBytes -gt 0) { Pass 'R2_SELFTEST_LOG' ("selftest.log {0:N0} bytes" -f $logBytes) }
                else { Fail 'R2_SELFTEST_LOG' 'selftest.log 为空' }
            } else {
                Fail 'R2_SELFTEST_LOG' ("未生成 {0}" -f $selftestLog)
            }

            # ---- R2: 当天数据哨兵必须完全不变
            $sentAfter = Read-DaySummary $sentinelPath
            if ($sentBefore.Sha -eq $sentAfter.Sha -and $sentBefore.Size -eq $sentAfter.Size) {
                Pass 'R2_DATA_SHA_UNCHANGED' ("SHA256 前后一致: {0}...（size {1:N0}B）" -f (Short-Sha $sentAfter.Sha), $sentAfter.Size)
            } else {
                Fail 'R2_DATA_SHA_UNCHANGED' ("当天数据被 selftest 改动！before SHA={0}... size={1}  after SHA={2}... size={3}" -f (Short-Sha $sentBefore.Sha), $sentBefore.Size, (Short-Sha $sentAfter.Sha), $sentAfter.Size)
            }
            if ($sentAfter.ParseOk -and $sentAfter.BytesIn -eq 123456 -and $sentAfter.BytesOut -eq 654321 -and $sentAfter.SampleCount -eq 42) {
                Pass 'R2_DATA_FIELDS_UNCHANGED' ("bytesIn=123456 bytesOut=654321 sampleCount=42 均保持")
            } else {
                Fail 'R2_DATA_FIELDS_UNCHANGED' ("哨兵字段被改：bytesIn={0} bytesOut={1} sampleCount={2}（期望 123456/654321/42）" -f $sentAfter.BytesIn, $sentAfter.BytesOut, $sentAfter.SampleCount)
            }
            $listingAfter = Get-DataDirListing $DataC
            $beforeSig = (($listingBefore | ForEach-Object { $_.Name + '|' + $_.Sha }) -join ';')
            $afterSig = (($listingAfter | ForEach-Object { $_.Name + '|' + $_.Sha }) -join ';')
            if ($beforeSig -eq $afterSig) {
                Pass 'R2_DATA_DIR_CLEAN' ("data\ 文件集合不变（{0} 个）" -f $listingAfter.Count)
            } else {
                Fail 'R2_DATA_DIR_CLEAN' ("data\ 文件集合被改：before=[{0}] after=[{1}]" -f (($listingBefore | ForEach-Object { $_.Name }) -join ','), (($listingAfter | ForEach-Object { $_.Name }) -join ','))
            }
            $stStoreDir = Join-Path $DataC 'selftest-store'
            if (Test-Path $stStoreDir) { Warn 'R2_STORE_TMPDIR_CLEAN' ("selftest 临时目录残留: {0}" -f $stStoreDir) }
            else { Pass 'R2_STORE_TMPDIR_CLEAN' 'selftest-store 临时目录已清理（未留在 datadir）' }

            # ---- R3: HKCU Run 真实自启值必须完全不变
            $regAfter = Get-RegRunSnapshot
            $regChanged = @()
            foreach ($vn in @($NewNetWatcherRunValue, $RealNetWatcherRunValue)) {
                $chkName = if ($vn -eq $NewNetWatcherRunValue) { 'R3_RUN_NETWATCHER2_1' } else { 'R3_RUN_NETWATCHER_20' }
                $bRepr = Format-RegValue $regBefore $vn
                $aRepr = Format-RegValue $regAfter $vn
                if (Test-RegValueEqual $regBefore $regAfter $vn) {
                    Pass $chkName ("{0} 前后一致: {1}" -f $vn, $aRepr)
                } else {
                    Fail $chkName ("{0} 被 selftest 改动！before={1}  after={2}" -f $vn, $bRepr, $aRepr)
                    $regChanged += $vn
                }
            }
            if ($regChanged.Count -gt 0) {
                # 立刻恢复原值，避免把用户真实自启项指向临时目录（恢复动作不掩盖上面的 FAIL）
                foreach ($vn in $regChanged) {
                    try {
                        if ($regBefore.ContainsKey($vn)) {
                            Set-ItemProperty -Path $RegPath -Name $vn -Value $regBefore[$vn] -ErrorAction Stop
                        } else {
                            Remove-ItemProperty -Path $RegPath -Name $vn -ErrorAction Stop
                        }
                        $verify = Get-RegRunSnapshot
                        if (Test-RegValueEqual $regBefore $verify $vn) {
                            Add-Info 'R3_REG_RESTORE' ("已恢复 Run\{0} 为原值: {1}" -f $vn, (Format-RegValue $regBefore $vn))
                        } else {
                            Add-Info 'R3_REG_RESTORE_FAILED' ("恢复 Run\{0} 失败，当前值见上" -f $vn)
                        }
                    } catch {
                        Add-Info 'R3_REG_RESTORE_FAILED' ("恢复 Run\{0} 异常: {1}" -f $vn, $_.Exception.Message)
                    }
                }
            }
            $leftover = @(@($regAfter.Keys) | Where-Object { $_ -match '(?i)NetWatcher.*SelfTest' })
            if ($leftover.Count -eq 0) {
                Pass 'R3_NO_TEMP_LEFTOVER' 'Run 键无残留临时测试值（*SelfTest*）'
            } else {
                Fail 'R3_NO_TEMP_LEFTOVER' ("Run 键残留临时测试值: {0}" -f ($leftover -join ', '))
            }
            $allNames = @(@($regBefore.Keys) + @($regAfter.Keys) | Sort-Object -Unique)
            $otherChanged = @()
            foreach ($n in $allNames) {
                if ($n -eq $NewNetWatcherRunValue -or $n -eq $RealNetWatcherRunValue) { continue }
                if (-not (Test-RegValueEqual $regBefore $regAfter $n)) { $otherChanged += $n }
            }
            if ($otherChanged.Count -eq 0) { Add-Info 'R3_OTHER_RUN_VALUES' 'Run 键其它值无变化' }
            else { Warn 'R3_OTHER_RUN_VALUES' ("Run 键其它值出现变化（需人工确认）: {0}" -f ($otherChanged -join ', ')) }

            if ($stText -match '临时值写入后\s*=\s*True[^\r\n]*删除后\s*=\s*False') {
                Pass 'R3_TEMP_VALUE_EVIDENCE' 'selftest.log 含「临时值写入后=True 删除后=False」（使用临时值名测试，删除成功）'
            } elseif ($stText -match '注册表写入后') {
                Fail 'R3_TEMP_VALUE_EVIDENCE' 'selftest.log 仍出现「注册表写入后」，疑似仍改真实自启值名'
            } elseif ($stText.Length -gt 0) {
                Warn 'R3_TEMP_VALUE_EVIDENCE' 'selftest.log 缺少自启临时值往返结果行（无法证明用临时值名）'
            } else {
                Warn 'R3_TEMP_VALUE_EVIDENCE' '无 selftest.log，无法检查自启测试证据'
            }
            if ($stText -match '(不触碰真实|未触碰)\s*data') {
                Pass 'R2_STORAGE_TEST_DECL' 'selftest.log 声明存储测试使用独立目录、未触碰 data\'
            } else {
                Add-Info 'R2_STORAGE_TEST_DECL' 'selftest.log 未出现「未触碰 data」说明（不影响 SHA 判定）'
            }
        } catch {
            Fail 'R2R3_UNEXPECTED' ("异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
        }
    }

    # ============================================================== R4 单写实例
    if ($script:CanRun) {
        Write-Section 'R4 单写实例（GUI 占住 datadir B，daemon 应退出码=2）'
        $guiPid = 0
        $guiKilled = $false
        try {
            Initialize-TestDataDir $DataB
            $guiPid = Start-Gui -DataDir $DataB
            Add-Info 'R4_GUI' ("启动 GUI pid={0} datadir={1}" -f $guiPid, $DataB)

            # 等 GUI 起来并落第一份数据（v2.3.0：加密小时文件 .nwipdb；启动即建空小时文件并随采样写盘）
            $deadline = (Get-Date).AddSeconds($StartTimeoutSec)
            $guiAlive = $true
            $guiFiles = @()
            while ((Get-Date) -lt $deadline) {
                if (-not (Get-Process -Id $guiPid -ErrorAction SilentlyContinue)) { $guiAlive = $false; break }
                $guiFiles = Get-NwipdbFiles -DataDir $DataB -Date $Today
                if ($guiFiles.Count -ge 1) { break }
                Start-Sleep -Milliseconds 300
            }
            if (-not $guiAlive) {
                Fail 'R4_GUI_START' ("GUI 进程 pid={0} 提前退出（crash.log/startup.log 见 {1}）" -f $guiPid, $DataB)
            } elseif ($guiFiles.Count -lt 1) {
                Fail 'R4_GUI_START' ("{0}s 内 GUI 未产生今天的加密小时文件（data\*.nwipdb，pid={1}）" -f $StartTimeoutSec, $guiPid)
            } else {
                Pass 'R4_GUI_START' ("GUI pid={0} 存活并已落盘加密小时文件 {1}" -f $guiPid, (($guiFiles | ForEach-Object { $_.Name }) -join ','))
            }

            if ($guiAlive -and $guiFiles.Count -ge 1) {
                Start-Sleep -Milliseconds 800   # 确保 GUI 已持有 data 锁
                $r4Before = Get-DayMergedSummary -DataDir $DataB -Date $Today
                if ($r4Before.Ok) {
                    Add-Info 'R4_GUI_DATA_BEFORE' ("sampleCount={0} bytesIn={1:N0} bytesOut={2:N0} 文件={3}" -f $r4Before.SampleCount, $r4Before.BytesIn, $r4Before.BytesOut, $r4Before.Files)
                } else {
                    Add-Info 'R4_GUI_DATA_BEFORE' ("合并失败: {0}" -f $r4Before.Error)
                }

                # 同一 datadir + 同一 mutex-tag 起 daemon（2.1 数据锁由绝对 datadir 派生，必须抢不到）
                $r4 = Invoke-ExeWithExitCode -Tag 'r4-daemon' -Arguments @('--daemon', "$R4DaemonSeconds", '--datadir', $DataB, '--mutex-tag', $MutexTag) -TimeoutSec ($R4DaemonSeconds + 60)
                if ($r4.TimedOut) {
                    Fail 'R4_DAEMON_EXITCODE' ("{0}s 内未退出（期望立即以退出码 2 退出；已清理）" -f ($R4DaemonSeconds + 60))
                } elseif ($r4.ExitCode -eq 2) {
                    Pass 'R4_DAEMON_EXITCODE' ("退出码=2（期望 2）elapsed={0}s" -f $r4.ElapsedSec)
                } else {
                    Fail 'R4_DAEMON_EXITCODE' ("退出码={0}（期望 2；若为 0 表示同一 datadir 被两个实例同时写）elapsed={1}s" -f $r4.ExitCode, $r4.ElapsedSec)
                }
                if (-not $r4.TimedOut -and $r4.ElapsedSec -le 20) {
                    Pass 'R4_DAEMON_FAST' ("{0}s 内退出（未实际采集 {1}s）" -f $r4.ElapsedSec, $R4DaemonSeconds)
                } elseif (-not $r4.TimedOut) {
                    Warn 'R4_DAEMON_FAST' ("退出耗时 {0}s，偏慢（可能等到超时才撞锁，需人工复核）" -f $r4.ElapsedSec)
                }

                $guiAliveAfter = [bool](Get-Process -Id $guiPid -ErrorAction SilentlyContinue)
                if ($guiAliveAfter) { Pass 'R4_GUI_ALIVE' ("GUI pid={0} 在 daemon 冲突尝试后仍存活" -f $guiPid) }
                else { Fail 'R4_GUI_ALIVE' ("GUI pid={0} 在 daemon 尝试后消失（疑似被抢锁逻辑误杀/自行退出）" -f $guiPid) }

                # GUI 数据文件未被破坏：加密小时文件仍可解密合并、sampleCount/bytes 不回退
                Start-Sleep -Milliseconds 1500
                $r4After = Get-DayMergedSummary -DataDir $DataB -Date $Today
                if (-not $r4After.Ok) {
                    Fail 'R4_DATA_INTACT' ("daemon 冲突尝试后 GUI 加密数据不可读/合并失败: {0}" -f $r4After.Error)
                } elseif ($r4Before.Ok -and ($r4After.SampleCount -lt $r4Before.SampleCount -or $r4After.BytesIn -lt $r4Before.BytesIn -or $r4After.BytesOut -lt $r4Before.BytesOut)) {
                    Fail 'R4_DATA_INTACT' ("数据回退：sampleCount {0}->{1} bytesIn {2:N0}->{3:N0} bytesOut {4:N0}->{5:N0}" -f $r4Before.SampleCount, $r4After.SampleCount, $r4Before.BytesIn, $r4After.BytesIn, $r4Before.BytesOut, $r4After.BytesOut)
                } else {
                    Pass 'R4_DATA_INTACT' ("加密小时文件可解密合并；sampleCount {0}->{1}，bytesIn {2:N0}->{3:N0}（不回退）" -f $r4Before.SampleCount, $r4After.SampleCount, $r4Before.BytesIn, $r4After.BytesIn)
                }

                # daemon.log 必须有冲突记录
                $r4DaemonLog = Join-Path $DataB 'daemon.log'
                if (Test-Path $r4DaemonLog) {
                    $dlText = [IO.File]::ReadAllText($r4DaemonLog, [Text.Encoding]::UTF8).Trim()
                    if ($dlText.Length -gt 0) {
                        Pass 'R4_DAEMON_LOG' ("daemon.log 存在且非空（{0:N0}B）：{1}" -f (Get-Item $r4DaemonLog).Length, (($dlText -split "`r?`n")[-1]))
                    } else {
                        Fail 'R4_DAEMON_LOG' 'daemon.log 存在但为空（要求写冲突原因）'
                    }
                } else {
                    Fail 'R4_DAEMON_LOG' ("缺少 {0}（要求抢锁失败时写日志）" -f $r4DaemonLog)
                }

                # P0-4 附带：Store 临时文件改为唯一名，冲突尝试后不应有残留/过期 .tmp
                $tmpFiles = @(Get-ChildItem (Join-Path $DataB 'data') -Filter '*.tmp' -File -ErrorAction SilentlyContinue)
                $staleTmp = @($tmpFiles | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalSeconds -gt 10 })
                if ($staleTmp.Count -eq 0) {
                    Pass 'R4_NO_STALE_TMP' ("data\ 下无过期 .tmp（当前 {0} 个瞬时 tmp）" -f $tmpFiles.Count)
                } else {
                    Fail 'R4_NO_STALE_TMP' ("残留过期 .tmp {0} 个: {1}" -f $staleTmp.Count, (($staleTmp | ForEach-Object { $_.Name }) -join ','))
                }
            }
        } catch {
            Fail 'R4_UNEXPECTED' ("异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
        } finally {
            if ($guiPid -gt 0) {
                $guiKilled = Stop-QaProcess -ProcessId $guiPid -WaitSec 8
                if ($guiKilled) { Pass 'R4_CLEANUP_GUI' ("已结束本脚本启动的 GUI pid={0}" -f $guiPid) }
                else { Fail 'R4_CLEANUP_GUI' ("无法结束本脚本启动的 GUI pid={0}" -f $guiPid) }
            }
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
}

# ------------------------------------------------------------------ R5 用户真实数据护栏
Write-Section 'R5 用户真实数据护栏（%APPDATA%\NetWatcher，size+mtime+SHA256）'
try {
    $realSnapAfter = Get-DirSnapshot $RealDataDir
    $realChanges = Compare-DirSnapshotDetailed $realSnapBefore $realSnapAfter
    $userAliveEnd = [bool](Get-Process -Id $UserPidGuard -ErrorAction SilentlyContinue)
    $nwAliveEnd = @(Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue)
    Add-Info 'R5_SNAPSHOT' ("{0}  前={1} 文件 / 后={2} 文件  size+mtime+SHA256 逐文件对比" -f $RealDataDir, $realSnapBefore.Count, $realSnapAfter.Count)
    if (-not (Test-Path $RealDataDir)) {
        Add-Info 'R5_REALDATA' '真实数据目录不存在，跳过对比'
    } elseif ($realChanges.Count -eq 0) {
        Pass 'R5_REALDATA_UNTOUCHED' ("与测试开始前完全一致（{0} 个文件）" -f $realSnapAfter.Count)
    } else {
        $diffText = (($realChanges | Select-Object -First 8 | ForEach-Object { "{0} {1} [{2} -> {3}]" -f $_.Kind, $_.Path, $_.Before, $_.After }) -join '; ')
        Add-Info 'R5_REALDATA_CHANGED_DETAIL' ("变化 {0} 处: {1}" -f $realChanges.Count, $diffText)
        if ($userAliveEnd) {
            # 用户 2.0 管理员实例仍在实时写 -> 归因 INFO，不算失败（与 _analysis\control_realdata.txt 对照组一致）
            Add-Info 'R5_REALDATA_CHANGED' ("{0} 处变化归因为用户实例 PID {1} 实时写入（INFO，不算测试失败）" -f $realChanges.Count, $UserPidGuard)
            Add-Info 'R5_ATTRIBUTION' '对照实验（_analysis\control_realdata.txt）：在 45s 闲置且未启动任何被测进程期间，data\2026-10-31.json 仍被改动（size 170902->170909、SHA FCDB4226..->9A0A6EC2..），而同组 PID 10856 前后均存活 -> 变化来自用户管理员实例实时写入，不是本脚本/被测 2.1 程序。'
        } elseif ($nwAliveEnd.Count -gt 0) {
            Warn 'R5_REALDATA_CHANGED' ("{0} 处变化；PID {1} 已不在但有其它 NetWatcher 进程（{2}），归因不确定，需人工复核" -f $realChanges.Count, $UserPidGuard, (($nwAliveEnd | ForEach-Object { $_.Id }) -join ','))
        } else {
            Fail 'R5_REALDATA_UNTOUCHED' ("{0} 处变化且无 NetWatcher 进程在运行（疑似测试污染真实数据）: {1}" -f $realChanges.Count, $diffText)
        }
    }
} catch {
    Fail 'R5_UNEXPECTED' ("异常: " + $_.Exception.Message)
}

# ------------------------------------------------------------------ 汇总与报告
Write-Section '汇总'
$passCount = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$infoCount = @($script:Results | Where-Object { $_.Status -eq 'INFO' }).Count

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

# 证据归档
$evidencePairs = @(
    @{ Src = (Join-Path $DataC 'selftest.log'); Dst = ("regression_selftest_{0}.log" -f $RunTag) },
    @{ Src = (Join-Path $DataA 'daemon.log'); Dst = ("regression_daemon_A_{0}.log" -f $RunTag) },
    @{ Src = (Join-Path $DataB 'daemon.log'); Dst = ("regression_daemon_B_{0}.log" -f $RunTag) }
)
foreach ($pair in $evidencePairs) {
    try {
        if (Test-Path $pair.Src) {
            $dst = Join-Path $OutDir $pair.Dst
            Copy-Item $pair.Src $dst -Force
            [void]$script:Evidence.Add($dst)
        }
    } catch { }
}
try {
    $dataEv = [pscustomobject]@{
        today = $Today
        r1 = [pscustomobject]@{ datadir = $DataA }
        r2r3 = [pscustomobject]@{ datadir = $DataC; sentinel = (Join-Path (Join-Path $DataC 'data') ($Today + '.json')) }
        r4 = [pscustomobject]@{ datadir = $DataB }
        tempRoot = $TempRoot
    }
    $dataEvPath = Join-Path $OutDir ("regression_data_{0}.json" -f $RunTag)
    $dataEv | ConvertTo-Json -Depth 5 | Set-Content -Path $dataEvPath -Encoding UTF8
    [void]$script:Evidence.Add($dataEvPath)
} catch { }

$reportTxt = Join-Path $OutDir ("regression_{0}.txt" -f $RunTag)
$reportJson = Join-Path $OutDir ("regression_{0}.json" -f $RunTag)
$txt = @()
$txt += "IP监控2.1 P0 回归测试报告  $RunTag"
$txt += ("开始: {0}" -f $StartedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))
$txt += ("结束: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
$txt += ("exe: {0}" -f $Exe)
if (Test-Path $Exe) { $txt += ("exe SHA256: {0}" -f (Get-Sha256 $Exe)) }
$txt += ("tempRoot: {0}" -f $TempRoot)
$txt += ("seconds={0} R4daemon={1} mutexTag={2}" -f $Seconds, $R4DaemonSeconds, $MutexTag)
$txt += ("userPidGuard={0}" -f $UserPidGuard)
$txt += ''
$txt += ("RESULT: {0}  PASS={1} FAIL={2} WARN={3}" -f $resultText, $passCount, $failCount, $warnCount)
$txt += ''
$txt += '-- checks --'
foreach ($r in $script:Results) { $txt += ("[{0}] {1,-32} {2}" -f $r.Status, $r.Check, $r.Detail) }
$txt += ''
$txt += '-- info --'
foreach ($r in $script:InfoRows) { $txt += ("[INFO] {0,-32} {1}" -f $r.Check, $r.Detail) }
$txt += ''
$txt += '-- evidence --'
foreach ($e in $script:Evidence) { $txt += $e }
$txt | Set-Content -Path $reportTxt -Encoding UTF8

$meta = [pscustomobject]@{
    time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
    result = $resultText; pass = $passCount; fail = $failCount; warn = $warnCount; infoCount = $infoCount
    exe = $Exe; tempRoot = $TempRoot; outDir = $OutDir
    seconds = $Seconds; r4DaemonSeconds = $R4DaemonSeconds; mutexTag = $MutexTag; userPidGuard = $UserPidGuard
    checks = @($script:Results)
    info = @($script:InfoRows)
    evidence = @($script:Evidence)
}
$meta | ConvertTo-Json -Depth 6 | Set-Content -Path $reportJson -Encoding UTF8
Write-Host ("report   : {0}" -f $reportTxt)
Write-Host ("machine  : {0}" -f $reportJson)

if ($failCount -gt 0) { exit 1 } else { exit 0 }
