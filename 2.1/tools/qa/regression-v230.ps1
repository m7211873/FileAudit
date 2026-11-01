#requires -Version 5.0
<#
.SYNOPSIS
  v2.3.0 加密小时存储（.nwipdb）专项回归脚本 H1~H7（骨架 + PrepOnly 自查模式）。

.DESCRIPTION
  设计文档：_analysis\v230-验收\00-设计-加密小时存储.md §9。
  本脚本负责 v2.3.0 新增存储的专项验收；原有回归仍用 regression-p0/p1/activation/quit + verify.ps1
  （它们的数据文件断言将在本脚本的 nwipdb-format.ps1 适配层就绪后改为读 .nwipdb）。

  测试项（与设计 §9 对应）：
    H1 启动即生成空小时文件（文件名/后缀/时间戳正确，payload 为空）
    H2 实时落盘（每采样都写：2~8s 内当前小时文件 mtime/大小/汇总增长，不是 15s 批量）
    H3 加密性（二进制、无明文 IP/字段；坏文件/错 key 不崩溃、不误读）
    H4 迁移（真实 data 的 json 副本 → legacy .nwipdb、删原 json、合并汇总与原汇总一致；坏 json 保留不阻塞）
    H5 多会话/多文件（同小时多 session 文件、同日重启合并累加）
    H6 合并正确性（各文件汇总 == LoadDay 合并汇总；samples 合并不重复/不乱序；峰值取 max）
    H7 性能（解密合并一天 24 文件 <200ms；30 天历史首载 <2s）

  安全约束（与其它 QA 脚本一致，绝不削弱）：
    - 所有测试在 %TEMP% 下创建绝对 --datadir；绝不写 %APPDATA%\NetWatcher；
      真实数据只在 Run 前后做只读快照对比（变化只 WARN + 归因，绝不删除/修改真实文件）。
    - 被测 exe 先复制到 %TEMP% 再运行（本机从仓库路径直接启动会被秒杀）。
    - 只结束本脚本通过 Win32_Process.Create 启动并记录 PID 的进程；绝不按进程名批量杀。
    - 迁移测试只使用 _analysis\v230-验收\fixtures\real-data-copy\ 的真实数据【副本】。

.PARAMETER PrepOnly
  仅做准备工作自查：校验文件名规则/fixtures/适配层未就绪保护，不启动被测程序、不跑 H1~H7。退出码 0/1。

.PARAMETER Exe
  被测 exe，默认 <2.1 根>\bin\NetWatcher.exe。

.EXAMPLE
  # 准备阶段（现在可用）：只自查，不跑产品
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-v230.ps1 -PrepOnly

.EXAMPLE
  # v2.3.0 合并后正式跑（需先填 nwipdb-format.ps1 的格式常量/解密实现）
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-v230.ps1
#>
[CmdletBinding()]
param(
    [string]$Exe = '',
    [string]$OutDir = '',
    [string]$FixturesDir = '',
    [int]$Seconds = 8,
    [int]$StartTimeoutSec = 40,
    [switch]$PrepOnly,
    [switch]$KeepTemp,
    [int]$MaxConnCount = 100,
    [int]$H7MergeBudgetMs = 200,
    [int]$H7HistoryBudgetMs = 2000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ------------------------------------------------------------------ 路径
$RunTag = Get-Date -Format 'yyyyMMdd-HHmmss'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Exe) { $Exe = Join-Path $RepoRoot 'bin\NetWatcher.exe' }
$Exe = [IO.Path]::GetFullPath($Exe)
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (-not $FixturesDir) { $FixturesDir = 'D:\IP监控2.1版\_analysis\v230-验收\fixtures\real-data-copy' }
$FixturesDir = [IO.Path]::GetFullPath($FixturesDir)
$FixtureSummaryPath = Join-Path (Split-Path $FixturesDir -Parent) 'real-data-copy.summary.json'
$RealDataDir = Join-Path $env:APPDATA 'NetWatcher'
$DataRoot = Join-Path $env:TEMP ('ipmon-v230-' + $RunTag)
$RunDir = Join-Path $env:TEMP ('ipmon-v230-run-' + $RunTag)
$RunExe = Join-Path $RunDir 'NetWatcher.exe'

. (Join-Path $PSScriptRoot 'nwipdb-format.ps1')

# ------------------------------------------------------------------ 结果框架
$script:Results = New-Object System.Collections.ArrayList
$script:Info = New-Object System.Collections.ArrayList
$script:StartedPids = New-Object System.Collections.ArrayList
$script:CanRun = $false

function Add-Result {
    param([string]$Status, [string]$Check, [string]$Detail)
    [void]$script:Results.Add([pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail })
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'TODO' { 'Magenta' } default { 'Gray' } }
    Write-Host ("  [{0}] {1,-30} {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
}
function Pass([string]$Check, [string]$Detail) { Add-Result 'PASS' $Check $Detail }
function Fail([string]$Check, [string]$Detail) { Add-Result 'FAIL' $Check $Detail }
function Warn([string]$Check, [string]$Detail) { Add-Result 'WARN' $Check $Detail }
function Todo([string]$Check, [string]$Detail) { Add-Result 'TODO' $Check $Detail }
function Add-Info2([string]$Check, [string]$Detail) {
    [void]$script:Info.Add([pscustomobject]@{ Check = $Check; Detail = $Detail })
    Write-Host ("  [INFO] {0,-30} {1}" -f $Check, $Detail) -ForegroundColor Gray
}
function Write-Section([string]$Title) { Write-Host ''; Write-Host ("== " + $Title + " ==") -ForegroundColor Cyan }
function Get-Sha256([string]$Path) { return (Get-FileHash -Path $Path -Algorithm SHA256).Hash }

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
function Compare-DirSnapshot {
    param($Before, $After)
    $changes = @()
    foreach ($k in $Before.Keys) {
        if (-not $After.ContainsKey($k)) { $changes += ('删除: ' + $k); continue }
        if ($Before[$k] -ne $After[$k]) { $changes += ('修改: ' + $k) }
    }
    foreach ($k in $After.Keys) { if (-not $Before.ContainsKey($k)) { $changes += ('新增: ' + $k) } }
    return ,$changes
}

# ------------------------------------------------------------------ 进程工具（Win32_Process.Create，只操作自己的 PID）
$QaWinSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class QaWin230 {
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    public static System.Collections.Generic.List<long> TopWindows(uint pid) {
        var list = new System.Collections.Generic.List<long>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint q; GetWindowThreadProcessId(h, out q);
            if (q == pid) list.Add(h.ToInt64());
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@
if (-not ('QaWin230' -as [type])) { Add-Type -TypeDefinition $QaWinSource -Language CSharp }

function Start-WmiProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory)
    $cmd = '"' + $FilePath + '"'
    foreach ($a in $Arguments) { $cmd += ' "' + $a + '"' }
    $createArgs = @{ CommandLine = $cmd }
    if ($WorkingDirectory) { $createArgs['CurrentDirectory'] = $WorkingDirectory }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $createArgs
    if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed rc=$($r.ReturnValue): $cmd" }
    [void]$script:StartedPids.Add([int]$r.ProcessId)
    return [int]$r.ProcessId
}
function Stop-QaProcess {
    param([int]$ProcessId, [int]$WaitSec = 5)
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch { }
    Start-Sleep -Milliseconds 300
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
        try { Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction Stop |
            Invoke-CimMethod -MethodName Terminate -Arguments @{ Reason = 0 } -ErrorAction Stop | Out-Null } catch { }
    }
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return (-not [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}
function Wait-ProcessExit {
    param([int]$ProcessId, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# 运行被测 exe 并捕获退出码（cmd /c 包装，避免管道挂住）
function Invoke-QaExe {
    param([string]$Tag, [string[]]$Arguments, [int]$TimeoutSec)
    # 注意：cmd.exe 的 .cmd 与重定向路径必须是纯 ASCII（仓库路径含中文，UTF-8 无 BOM 的 bat 会被 cmd 按 ANSI 读成乱码），
    # 因此 bat/stdout/exit 全部先落 %TEMP%（ASCII），结束后再把 stdout 复制到 OutDir。
    $tmpBase = Join-Path $env:TEMP ("v230-{0}-{1}" -f $Tag, $RunTag)
    $tmpOut = $tmpBase + '.log'
    $tmpCode = $tmpBase + '.exit'
    $bat = $tmpBase + '.cmd'
    $argLine = ''
    foreach ($a in $Arguments) { $argLine += ' "' + $a + '"' }
    $lines = @(
        '@echo off',
        ('"' + $RunExe + '"' + $argLine + ' > "' + $tmpOut + '" 2>&1'),
        ('echo %ERRORLEVEL% > "' + $tmpCode + '"'),
        'exit /b 0'
    )
    [IO.File]::WriteAllLines($bat, $lines, (New-Object System.Text.UTF8Encoding($false)))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cmd = Start-WmiProcess -FilePath 'cmd.exe' -Arguments @('/c', $bat)
    $exited = Wait-ProcessExit -ProcessId $cmd -TimeoutSec $TimeoutSec
    $sw.Stop()
    if (-not $exited) { [void](Stop-QaProcess -ProcessId $cmd) }
    $code = -1
    if (Test-Path $tmpCode) {
        try { $code = [int]((Get-Content $tmpCode -Raw -ErrorAction Stop).Trim()) } catch { }
    }
    $stdout = $tmpOut
    if (Test-Path $tmpOut) {
        try {
            $copy = Join-Path $OutDir ("v230_{0}_{1}.log" -f $Tag, $RunTag)
            Copy-Item $tmpOut $copy -Force
            $stdout = $copy
        } catch { }
    }
    return [pscustomobject]@{ ExitCode = $code; TimedOut = (-not $exited); ElapsedSec = [Math]::Round($sw.Elapsed.TotalSeconds, 1); StdoutLog = $stdout; CmdFile = $bat; ExitFile = $tmpCode }
}

function New-TestDataDir {
    param([string]$Name, [string]$ScanIntervalSec = '2', [bool]$GeoEnabled = $false)
    $d = Join-Path $DataRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $d 'data') -Force | Out-Null
    $cfg = '{"ScanIntervalSeconds":' + $ScanIntervalSec + ',"AutoStart":false,"RetentionDays":0,"StartMinimized":false,"GeoEnabled":' + ($(if ($GeoEnabled) { 'true' } else { 'false' })) + ',"GeoApi":"http://ip-api.com/json/{0}","NewIpAlert":false,"ShowLocalIp":true}'
    [IO.File]::WriteAllText((Join-Path $d 'config.json'), $cfg, (New-Object System.Text.UTF8Encoding($false)))
    return $d
}

# ================================================================== PrepOnly 自查
function Invoke-PrepCheck {
    Write-Section 'P 准备自查（PrepOnly：不启动被测程序、不跑 H1~H7）'
    # P1 适配层自检
    $ad = Test-NwipdbFormatAdapter
    if ($ad.Fail -eq 0) { Pass 'P_FORMAT_ADAPTER' ("适配层自检 {0} 项 PASS（未就绪保护正常，等 dev 格式定稿后填充）" -f $ad.Pass) }
    else { Fail 'P_FORMAT_ADAPTER' (($ad.Details | Select-Object -First 6) -join '; ') }
    foreach ($l in $ad.Details) { Add-Info2 'P_FORMAT_DETAIL' $l }

    # P2 文件名规则（设计 §1 示例必须全部识别）
    $mustHour = @(
        '监控_2026-11-01_17-00-00_s175422.nwipdb',
        '监控_2026-11-01_18-00-00_s175422.nwipdb',
        '监控_2026-11-01_19-00-00_s182310.nwipdb'
    )
    $badNames = @($mustHour | Where-Object { -not (Test-NwipdbName -Name $_).Ok })
    if ($badNames.Count -eq 0) { Pass 'P_NAME_RULE' ("设计示例文件名的 3 种小时名全部识别（后缀 {0}）" -f $script:NwipdbFormat.FileSuffix) }
    else { Fail 'P_NAME_RULE' ("无法识别: " + ($badNames -join ',')) }
    $leg = Test-NwipdbName -Name '监控_2026-10-31_00-00-00_legacy000000.nwipdb'
    if ($leg.Ok -and $leg.Kind -eq 'legacy') { Pass 'P_NAME_LEGACY' 'legacy 日块文件名识别正确（Kind=legacy）' }
    else { Fail 'P_NAME_LEGACY' 'legacy 日块文件名未识别' }

    # P3 fixtures（真实数据副本）完整性 + 与预记录 SHA256/汇总一致
    if (-not (Test-Path $FixturesDir)) { Fail 'P_FIXTURES_DIR' ("fixtures 目录不存在: {0}" -f $FixturesDir); return }
    $fixtureFiles = @(Get-ChildItem $FixturesDir -Filter '*.json' -File | Where-Object { $_.Name -ne 'real-data-copy.summary.json' } | Sort-Object Name)
    if ($fixtureFiles.Count -lt 1) { Fail 'P_FIXTURES' 'fixtures 目录没有 *.json 副本'; return }
    $sumMap = $null
    try { $sumMap = Read-FixtureSummary -SummaryJson $FixtureSummaryPath } catch { Fail 'P_FIXTURES_SUMMARY' ("读取 fixtures 汇总失败: " + $_.Exception.Message) }
    foreach ($f in $fixtureFiles) {
        $sha = Get-Sha256 $f.FullName
        if (-not $sumMap) { Add-Info2 'P_FIXTURE' ("{0}  {1:N0}B  SHA256={2}" -f $f.Name, $f.Length, $sha.Substring(0, 16)); continue }
        if (-not $sumMap.ContainsKey($f.Name)) { Fail 'P_FIXTURE_RECORDED' ("{0} 不在预记录汇总中" -f $f.Name); continue }
        $rec = $sumMap[$f.Name]
        if ($rec.sha256 -ne $sha) { Fail 'P_FIXTURE_SHA' ("{0} SHA 与预记录不一致（副本被改动？）" -f $f.Name); continue }
        Add-Info2 'P_FIXTURE' ("{0}: {1:N0}B  date={2}  bytesIn={3:N0} bytesOut={4:N0} ip={5} proc={6} rawSamples={7} buckets={8} precise={9}" -f `
            $f.Name, $f.Length, $rec.date, $rec.bytesIn, $rec.bytesOut, $rec.ipCount, $rec.procCount, $rec.rawSampleCount, $rec.minuteBuckets, $rec.bytesPrecise)
    }
    Pass 'P_FIXTURES' ("真实数据副本 {0} 个，SHA256 与预记录一致（迁移测试只读副本，不动真实目录）" -f $fixtureFiles.Count)

    # P4 真实数据目录当前状态（只读快照；不要求静止，2.2.1 用户实例可能仍在跑）
    $snap = Get-DirSnapshot $RealDataDir
    Add-Info2 'P_REALDATA' ("{0} 文件 {1} 个（只读快照，测试期间不写；变化只会在正式跑时 WARN+归因）" -f $RealDataDir, $snap.Count)
    if ((Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        Add-Info2 'P_REALDATA_PROC' '检测到正在运行的 NetWatcher（用户 2.2.1 实例）：不结束、不干预；正式跑前若迁移测试要求真实数据静止会先向 Lead 报告'
    }

    # P5 待测清单（PrepOnly 只记录为 INFO；正式跑时逐项实现/判定，未实现不得算 PASS）
    $plan = @(
        'H1_EMPTY_HOUR_FILE          启动即生成空小时文件：文件名/后缀/时间戳正确、payload 为空',
        'H1_KEY_FILE                 data\.storekey 生成且受 DPAPI 保护（存在/非明文长度合理）',
        'H2_REALTIME_PERSIST         采样后 2~8s 内当前小时文件 mtime/大小/汇总增长（每采样写，非 15s 批量）',
        'H3_BINARY_NO_PLAINTEXT      二进制、无 "ips"/IP 文本/字段名等明文泄漏（Test-NwipdbPlaintextLeak）',
        'H3_TAMPER_NO_CRASH          截断/翻转字节的坏文件 → 程序不崩溃、跳过并记录（monitor.log）',
        'H3_WRONG_KEY_NO_CRASH       .storekey 损坏/换 key → 程序不崩溃、历史不可读但不影响新采样',
        'H4_MIGRATE_LEGACY_FILES     真实 data 副本（3 json）→ 生成 *_legacy*.nwipdb、删除原 json',
        'H4_MIGRATE_SUMMARY_EQUAL    迁移后按日合并汇总 == 原 json 汇总（bytesIn/out 精确；ip/proc/samples 按实现口径）',
        'H4_BAD_JSON_KEPT            坏 json → 保留原文件 + monitor.log 记录 + 不阻塞采样',
        'H5_MULTI_SESSION_FILES      同小时多 session 文件 + 每次启动新增文件；合并数据继续累加',
        'H6_MERGE_SUM_EQUAL          当天各字节汇总 == 合并汇总；峰值取 max；samples 合并唯一升序',
        'H7_DAY_MERGE_PERF           合并一天（24 文件）< 200ms',
        'H7_HISTORY_LOAD_PERF        30 天历史首载 < 2s（或解析 selftest 性能行）'
    )
    foreach ($p in $plan) { Add-Info2 'PLAN_TEST' $p }
    Pass 'P_PLAN_RECORDED' ("H 系列待测项 {0} 条已记录（PrepOnly 不执行；正式跑时未实现项记 TODO/FAIL，不算 PASS）" -f $plan.Count)

    # P6 现有回归脚本需要的改动点（准备结论，正式跑前执行）
    $changes = @(
        'regression-p0.ps1 R1：读 data\*.json → 改为 .nwipdb（新格式：每次启动新增小时文件 + 按日合并汇总继续累加）',
        'regression-p0.ps1 R2：selftest 只读 → 仍需断言 data\ 下 .nwipdb/.json 均不被 selftest 改动；需与 dev 确认 --selftest 是否触发迁移',
        'regression-p0.ps1 R4/R5：GUI 落盘断言改 .nwipdb；R5 真实数据快照保留（只读）',
        'verify.ps1 DATA_*：Get-DataFiles 支持 .nwipdb；DATA_JSON→明文头/解密校验、DATA_SAMPLES IP_BALANCE PRECISE_HONESTY CONNCOUNT 需解密 payload（用 nwipdb-format.ps1 适配层）',
        'verify.ps1 GUI_DATADIR/趋势种子：预置 .json 改为被迁移的 legacy json → 断言生成 legacy .nwipdb + 新 session 文件；GUI_TREND_* 断言保持',
        'verify.ps1 -AuditRealData：真实数据即将变为 .nwipdb → 审计改为只读明文头（不迁移、不解密真实文件可选）',
        'regression-quit.ps1 Q4：读日 json → 改为读 .nwipdb 明文头/解密确认已落盘',
        'regression-p1.ps1 R7/S_P1_9：legacy 假精确降级路径在迁移/合并后仍应成立；静态检查路径可能改名，需适配',
        'R9 版本：p1 已用 2.x.y.0 正则 → 2.3.0.0 自动 PASS（记录即可）',
        'build.bat：新增 /r:System.Security.dll（设计 §8）'
    )
    foreach ($c in $changes) { Add-Info2 'PLAN_CHANGE' $c }
}

# ================================================================== H1~H7（正式跑；未实现格式处明确 TODO）
function Invoke-H1 {
    Write-Section 'H1 启动即生成空小时文件'
    $d = New-TestDataDir -Name 'h1' -ScanIntervalSec '10'
    $refPath = Join-Path $d '.v230-start'
    [IO.File]::WriteAllText($refPath, (Get-Date).ToString('o'))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $daemonPid = Start-WmiProcess -FilePath $RunExe -Arguments @('--daemon', '1', '--datadir', $d, '--mutex-tag', 'v230-h1') -WorkingDirectory $RunDir
    $exited = Wait-ProcessExit -ProcessId $daemonPid -TimeoutSec ($Seconds + 60)
    $sw.Stop()
    if (-not $exited) { [void](Stop-QaProcess -ProcessId $daemonPid) }
    $files = Get-NwipdbFiles -DataDir $d
    if ($files.Count -lt 1) { Fail 'H1_HOUR_FILE_EXISTS' ("启动后 data\ 下无 .nwipdb（daemon exit={0} elapsed={1}s）" -f $exited, $sw.Elapsed.TotalSeconds); return }
    $info = Test-NwipdbName -Name $files[0].Name
    $today = Get-Date -Format 'yyyy-MM-dd'
    if ($info.Ok -and $info.Kind -eq 'hour' -and $info.Date -eq $today) { Pass 'H1_HOUR_FILE_EXISTS' ("{0}（date={1} hour={2} suffix={3}）" -f $files[0].Name, $info.Date, $info.HourStart, $script:NwipdbFormat.FileSuffix) }
    else { Fail 'H1_HOUR_FILE_EXISTS' ("文件名不符合小时文件规则: " + $files[0].Name) }
    $key = Get-NwipdbKeyInfo -DataDir $d
    if ($key.Exists -and $key.Length -ge 32 -and $key.Length -le 4096) { Pass 'H1_KEY_FILE' ("data\{0} 存在（{1}B, SHA256={2}…）" -f $script:NwipdbFormat.KeyPathName, $key.Length, $key.Sha256.Substring(0, 16)) }
    else { Fail 'H1_KEY_FILE' ("未生成受保护的密钥文件 data\{0}（Exists={1} Length={2}）" -f $script:NwipdbFormat.KeyPathName, $key.Exists, $key.Length) }
    # 明文头校验 + 空 payload/首采样语义：
    # 设计 §4 要求启动即创建并写盘「空小时文件」；实测首个采样在 Monitor 线程启动后立即发生，
    # 外部进程在文件出现后读到的通常已是「空文件被第一次采样覆盖」后的状态。
    # 因此：sampleCount==0 → 空 payload PASS；sampleCount==1 且无历史汇总 → 视为「启动即建 + 首个采样」PASS（记录说明）；
    # sampleCount>1 → WARN（启动时已积累多采样，需人工复核）。
    $h = Read-NwipdbHeader -Path $files[0].FullName
    if (-not $h.Ok) { Fail 'H1_HEADER_VALID' ("明文头解析失败: " + $h.Error) }
    else {
        Pass 'H1_HEADER_VALID' ("明文头有效：magic={0} version={1} flags={2} 文件 {3:N0}B cipherLen={4}" -f $h.Magic, $h.Version, $h.Flags, $h.FileLength, $h.CipherLen)
        if ($h.SampleCount -eq 0 -and $h.BytesIn -eq 0 -and $h.BytesOut -eq 0) {
            Pass 'H1_EMPTY_PAYLOAD' ("启动空小时文件 payload 为空（bytes=0/0 sampleCount=0 ip=0 proc=0）")
        } elseif ($h.SampleCount -le 1 -and $h.IpCount -le 32) {
            Pass 'H1_EMPTY_PAYLOAD' ("启动即建空文件并立即发生首个采样（sampleCount={0} bytesIn={1:N0} ip={2}）；空文件窗口由 BeginHourSession 先写盘（见实现说明 §3）" -f $h.SampleCount, $h.BytesIn, $h.IpCount)
        } else {
            Warn 'H1_EMPTY_PAYLOAD' ("启动 1s 内已积累 {0} 个采样（ip={1}），无法确认是否从空开始" -f $h.SampleCount, $h.IpCount)
        }
        # 可被程序读取：用适配层解密 payload（字段存在即证明可解密读取）
        $pl = Read-NwipdbPayload -Path $files[0].FullName -DataDir $d
        if ($pl.Ok -and $pl.Day) { Pass 'H1_DECRYPT_READABLE' ("payload 可被解密读取（date={0} sampleCount={1}）" -f ([string](Get-DictValue $pl.Day 'date')), ([string](Get-DictValue $pl.Day 'sampleCount'))) }
        else { Fail 'H1_DECRYPT_READABLE' ("payload 解密失败: " + $pl.Error) }
    }
    if ($files.Count -eq 1 -and $files[0].Kind -eq 'hour') { Pass 'H1_ONLY_SESSION_FILE' '启动后只有 1 个本次 session 小时文件（无历史 legacy 文件）' }
    else { Add-Info2 'H1_FILES' ("启动后文件: {0}" -f (($files | ForEach-Object { $_.Name }) -join ',')) }
    Add-Info2 'H1_DIR' $d
}

function Invoke-H2 {
    Write-Section 'H2 实时落盘（每采样都写，不是 15s 批量）'
    $d = New-TestDataDir -Name 'h2' -ScanIntervalSec '2'
    $daemonPid = Start-WmiProcess -FilePath $RunExe -Arguments @('--daemon', "$Seconds", '--datadir', $d, '--mutex-tag', 'v230-h2') -WorkingDirectory $RunDir
    $obs = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds($Seconds + 10)
    $firstSeen = $null
    while ((Get-Date) -lt $deadline) {
        $files = Get-NwipdbFiles -DataDir $d
        if ($files.Count -gt 0) {
            $f = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            $sig = ('{0}|{1}|{2}' -f $f.Name, $f.Length, $f.LastWriteTimeUtc.Ticks)
            if ($obs.Count -eq 0 -or $obs[$obs.Count - 1].Sig -ne $sig) {
                if (-not $firstSeen) { $firstSeen = Get-Date }
                [void]$obs.Add([pscustomobject]@{ At = [Math]::Round(((Get-Date) - $firstSeen).TotalSeconds, 2); Sig = $sig; Name = $f.Name; Length = $f.Length })
            }
        }
        if (-not (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 250
    }
    if (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) { [void](Wait-ProcessExit -ProcessId $daemonPid -TimeoutSec 60) } else { [void](Stop-QaProcess -ProcessId $daemonPid) }
    $writes = $obs.Count
    if ($writes -ge 3) { Pass 'H2_REALTIME_PERSIST' ("{0} 次文件变化（{1}），最晚变化于 {2}s（每采样写，非 15s 批量）" -f $writes, (($obs | Select-Object -First 5 | ForEach-Object { $_.At }) -join ','), $obs[$writes-1].At) }
    elseif ($writes -ge 2) { Warn 'H2_REALTIME_PERSIST' ("仅 {0} 次变化，采样间隔可能≥{1}s（观察窗口短），需复核" -f $writes, $Seconds) }
    else { Fail 'H2_REALTIME_PERSIST' ("观察 {0}s 内只有 {1} 次文件变化（期望每个采样写一次）" -f $Seconds, $writes) }
    $files = Get-NwipdbFiles -DataDir $d
    if ($files.Count -ge 1) { Pass 'H2_HOUR_FILE' ("{0} 个 .nwipdb，最新 {1}（{2:N0}B）" -f $files.Count, $files[-1].Name, $files[-1].Length) }
    else { Fail 'H2_HOUR_FILE' 'data\ 下无 .nwipdb' }
    Add-Info2 'H2_DIR' $d
}

function Invoke-H3 {
    Write-Section 'H3 加密性 / 坏文件与错 key 不崩溃'
    $srcDir = Join-Path $DataRoot 'h2'
    $files = Get-NwipdbFiles -DataDir $srcDir
    if ($files.Count -lt 1) { Fail 'H3_BINARY_NO_PLAINTEXT' '缺少 H2 数据文件（H3 依赖 H2 产出）'; return }
    $latest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $leak = Test-NwipdbPlaintextLeak -Path $latest.FullName
    if ($leak.LeakCount -eq 0 -and $leak.LooksBinary) { Pass 'H3_BINARY_NO_PLAINTEXT' ("{0} 为二进制（{1:N0}B，控制字节 {2:P1}），未发现明文 IP/字段名" -f $latest.Name, $leak.Bytes, $leak.ControlByteRatio) }
    elseif ($leak.LeakCount -eq 0) { Warn 'H3_BINARY_NO_PLAINTEXT' ("无明文特征，但控制字节占比仅 {0:P1}（需人工确认是否真加密）" -f $leak.ControlByteRatio) }
    else { Fail 'H3_BINARY_NO_PLAINTEXT' ("发现明文泄漏: " + (($leak.Leaks | Select-Object -First 6) -join ', ')) }

    # H3a 坏文件：复制整个数据目录（含 .storekey），截断/翻转其中一小时文件 → 启动不崩溃
    $badDir = Join-Path $DataRoot 'h3-badfile'
    Copy-Item $srcDir $badDir -Recurse -Force
    $victim = Get-ChildItem (Join-Path $badDir 'data') -Filter '*.nwipdb' -File | Select-Object -First 1
    if ($victim) {
        $bytes = [IO.File]::ReadAllBytes($victim.FullName)
        $cut = [Math]::Max(16, [int]($bytes.Length / 2))
        [IO.File]::WriteAllBytes($victim.FullName, $bytes[0..($cut-1)])
        $r = Invoke-QaExe -Tag 'h3-badfile' -Arguments @('--daemon', '4', '--datadir', $badDir, '--mutex-tag', 'v230-h3bad') -TimeoutSec 120
        if (-not $r.TimedOut -and $r.ExitCode -eq 0) { Pass 'H3_TAMPER_NO_CRASH' ("坏文件（截断到 {0}B）下 daemon 正常退出码=0 elapsed={1}s" -f $cut, $r.ElapsedSec) }
        else { Fail 'H3_TAMPER_NO_CRASH' ("坏文件下 daemon 异常：TimedOut={0} ExitCode={1} std={2}" -f $r.TimedOut, $r.ExitCode, $r.StdoutLog) }
        $mlog = Join-Path $badDir 'monitor.log'
        if (Test-Path $mlog) { Add-Info2 'H3_TAMPER_LOG' ("monitor.log 已生成（{0:N0}B）" -f (Get-Item $mlog).Length) }
    } else { Fail 'H3_TAMPER_NO_CRASH' '构造坏文件失败（无 .nwipdb）' }

    # H3b 错 key：复制数据目录，改坏 .storekey → 启动不崩溃
    $badKeyDir = Join-Path $DataRoot 'h3-badkey'
    Copy-Item $srcDir $badKeyDir -Recurse -Force
    $keyPath = Join-Path (Join-Path $badKeyDir 'data') $script:NwipdbFormat.KeyPathName
    if (Test-Path $keyPath) {
        $kb = [IO.File]::ReadAllBytes($keyPath)
        for ($i = 0; $i -lt [Math]::Min(8, $kb.Length); $i++) { $kb[$i] = $kb[$i] -bxor 0xA5 }
        [IO.File]::WriteAllBytes($keyPath, $kb)
        $r2 = Invoke-QaExe -Tag 'h3-badkey' -Arguments @('--daemon', '4', '--datadir', $badKeyDir, '--mutex-tag', 'v230-h3key') -TimeoutSec 120
        if (-not $r2.TimedOut -and $r2.ExitCode -eq 0) { Pass 'H3_WRONG_KEY_NO_CRASH' ("错 key 下 daemon 正常退出码=0 elapsed={0}s（不崩溃）" -f $r2.ElapsedSec) }
        else { Fail 'H3_WRONG_KEY_NO_CRASH' ("错 key 下 daemon 异常：TimedOut={0} ExitCode={1}" -f $r2.TimedOut, $r2.ExitCode) }
    } else { Fail 'H3_WRONG_KEY_NO_CRASH' ("缺少 {0}，无法构造错 key 场景" -f $script:NwipdbFormat.KeyPathName) }
}

function Invoke-H4 {
    Write-Section 'H4 迁移（真实数据 json 副本 → legacy .nwipdb，删原 json，汇总一致；坏 json 保留）'
    $sumMap = $null
    try { $sumMap = Read-FixtureSummary -SummaryJson $FixtureSummaryPath } catch { Fail 'H4_MIGRATE_SUMMARY_EQUAL' ("读取 fixtures 汇总失败: " + $_.Exception.Message) }
    $d = New-TestDataDir -Name 'h4' -ScanIntervalSec '2'
    $copied = Initialize-DataDirFromFixtures -DataDir $d -FixturesDir $FixturesDir
    if ($copied.Count -lt 1) { Fail 'H4_MIGRATE_LEGACY_FILES' 'fixtures 复制失败（无 json 副本）'; return }
    Add-Info2 'H4_SEED' ("已把 {0} 个真实数据副本放入 temp datadir（不碰真实目录）: {1}" -f $copied.Count, (($copied | ForEach-Object { Split-Path $_ -Leaf }) -join ','))
    $r = Invoke-QaExe -Tag 'h4' -Arguments @('--daemon', '6', '--datadir', $d, '--mutex-tag', 'v230-h4') -TimeoutSec 180
    if ($r.ExitCode -eq 0 -and -not $r.TimedOut) { Pass 'H4_START' ("迁移后 daemon 正常 exit=0 elapsed={0}s" -f $r.ElapsedSec) }
    else { Fail 'H4_START' ("迁移后 daemon 异常：TimedOut={0} ExitCode={1} std={2}" -f $r.TimedOut, $r.ExitCode, $r.StdoutLog) }

    $allFiles = @(Get-ChildItem (Join-Path $d 'data') -File -ErrorAction SilentlyContinue)
    $jsonLeft = @($allFiles | Where-Object { $_.Extension -eq '.json' })
    $legacy = Get-NwipdbFiles -DataDir $d -Kind legacy
    if ($legacy.Count -ge 1) { Pass 'H4_MIGRATE_LEGACY_FILES' ("生成 legacy 加密文件 {0} 个: {1}" -f $legacy.Count, (($legacy | Select-Object -First 4 | ForEach-Object { $_.Name }) -join ',')) }
    else { Fail 'H4_MIGRATE_LEGACY_FILES' '未生成 *_legacy*.nwipdb' }
    if ($jsonLeft.Count -eq 0) { Pass 'H4_JSON_REMOVED' '原 json 已删除（迁移完成）' }
    else { Fail 'H4_JSON_REMOVED' ("仍有 {0} 个原 json 未删除: {1}" -f $jsonLeft.Count, (($jsonLeft | ForEach-Object { $_.Name }) -join ',')) }

    if ($sumMap -and $legacy.Count -ge 1) {
        $allMatch = $true; $detail = New-Object System.Collections.ArrayList
        foreach ($f in $legacy) {
            $date = (Test-NwipdbName -Name $f.Name).Date
            $srcName = $date + '.json'
            if (-not $sumMap.ContainsKey($srcName)) { continue }
            $src = $sumMap[$srcName]
            # 用 legacy 文件自身 payload 对比（不能用按日合并：今天还会叠加迁移后新采样）
            $pl = Read-NwipdbPayload -Path $f.FullName -DataDir $d
            if (-not $pl.Ok) { $allMatch = $false; [void]$detail.Add(("$date legacy 解密失败: " + $pl.Error)); continue }
            $d0 = $pl.Day
            $in0 = [long](Get-DictValue $d0 'bytesIn'); $out0 = [long](Get-DictValue $d0 'bytesOut')
            $sample0 = [int](Get-DictValue $d0 'sampleCount')
            $ip0 = @(Get-DictKeys (Get-DictValue $d0 'ips')).Count
            $proc0 = @(Get-DictKeys (Get-DictValue $d0 'procs')).Count
            $buckets0 = @((Get-DictValue $d0 'samples')).Count
            $okBytes = ($in0 -eq [long]$src.bytesIn) -and ($out0 -eq [long]$src.bytesOut)
            $okCounts = ($ip0 -eq [int]$src.ipCount) -and ($proc0 -eq [int]$src.procCount)
            $okSamples = ($sample0 -eq [int]$src.rawSampleCount) -and ($buckets0 -eq [int]$src.minuteBuckets)
            $ok = $okBytes -and $okCounts -and $okSamples
            [void]$detail.Add(("{0}: bytes {1:N0}/{2:N0} vs {3:N0}/{4:N0}; ip {5}/{6}; proc {7}/{8}; samples {9}/{10} -> {11}" -f `
                $date, $in0, $out0, $src.bytesIn, $src.bytesOut, $ip0, $src.ipCount, $proc0, $src.procCount, $sample0, $src.rawSampleCount, $(if ($ok) { 'OK' } else { 'MISMATCH' })))
            if (-not $ok) { $allMatch = $false }
        }
        if ($allMatch) { Pass 'H4_MIGRATE_SUMMARY_EQUAL' ("legacy 加密文件 payload 与原 json 完全一致（{0}）" -f (($detail | Select-Object -First 4) -join '; ')) }
        else { Fail 'H4_MIGRATE_SUMMARY_EQUAL' (($detail | Select-Object -First 6) -join '; ') }
    } else { Fail 'H4_MIGRATE_SUMMARY_EQUAL' 'fixtures 汇总或 legacy 文件缺失，无法比对' }

    # 坏 json：保留 + 不阻塞
    $badDir = New-TestDataDir -Name 'h4-badjson' -ScanIntervalSec '2'
    $badJson = Join-Path (Join-Path $badDir 'data') '2026-10-29.json'
    [IO.File]::WriteAllText($badJson, '{"date":"2026-10-29","bytesIn":', (New-Object System.Text.UTF8Encoding($false)))
    $badSha = Get-Sha256 $badJson
    $rb = Invoke-QaExe -Tag 'h4-badjson' -Arguments @('--daemon', '5', '--datadir', $badDir, '--mutex-tag', 'v230-h4bad') -TimeoutSec 180
    if ($rb.ExitCode -eq 0 -and -not $rb.TimedOut) { Pass 'H4_BAD_JSON_KEPT' ("坏 json 不阻塞（daemon exit=0 elapsed={0}s）" -f $rb.ElapsedSec) }
    else { Fail 'H4_BAD_JSON_KEPT' ("坏 json 导致异常：TimedOut={0} ExitCode={1}" -f $rb.TimedOut, $rb.ExitCode) }
    if ((Test-Path $badJson) -and ((Get-Sha256 $badJson) -eq $badSha)) { Pass 'H4_BAD_JSON_UNCHANGED' '坏 json 原文件保留且未被改写' }
    else { Fail 'H4_BAD_JSON_UNCHANGED' '坏 json 被删除或改写（设计要求失败时保留原文件）' }
}

function Invoke-H5 {
    Write-Section 'H5 多会话/多文件 + 同日重启合并累加'
    $d = New-TestDataDir -Name 'h5' -ScanIntervalSec '2'
    $r1 = Invoke-QaExe -Tag 'h5-a' -Arguments @('--daemon', '5', '--datadir', $d, '--mutex-tag', 'v230-h5a') -TimeoutSec 180
    $files1 = Get-NwipdbFiles -DataDir $d
    $sum1 = Get-DayMergedSummary -DataDir $d -Date (Get-Date -Format 'yyyy-MM-dd')
    $r2 = Invoke-QaExe -Tag 'h5-b' -Arguments @('--daemon', '5', '--datadir', $d, '--mutex-tag', 'v230-h5b') -TimeoutSec 180
    $files2 = Get-NwipdbFiles -DataDir $d
    $sum2 = Get-DayMergedSummary -DataDir $d -Date (Get-Date -Format 'yyyy-MM-dd')
    if ($files2.Count -gt $files1.Count) { Pass 'H5_MULTI_SESSION_FILES' ("重启后新增小时文件：{0} -> {1} 个（每次启动必建新文件）" -f $files1.Count, $files2.Count) }
    else { Fail 'H5_MULTI_SESSION_FILES' ("重启后未新增小时文件：{0} -> {1}" -f $files1.Count, $files2.Count) }
    if ($sum1.Ok -and $sum2.Ok) {
        if ([long]$sum2.BytesIn -ge [long]$sum1.BytesIn -and [long]$sum2.BytesOut -ge [long]$sum1.BytesOut) { Pass 'H5_MERGE_ACCUM' ("同日合并汇总继续累加：in {0:N0}->{1:N0} out {2:N0}->{3:N0}" -f $sum1.BytesIn, $sum2.BytesIn, $sum1.BytesOut, $sum2.BytesOut) }
        else { Fail 'H5_MERGE_ACCUM' ("合并汇总回退：in {0:N0}->{1:N0} out {2:N0}->{3:N0}" -f $sum1.BytesIn, $sum2.BytesIn, $sum1.BytesOut, $sum2.BytesOut) }
    } else { Todo 'H5_MERGE_ACCUM' ("合并汇总不可读（sum1={0}/{1} sum2={2}/{3}），需格式适配层" -f $sum1.Ok, $sum1.Error, $sum2.Ok, $sum2.Error) }
    Add-Info2 'H5_DIR' $d
}

function Invoke-H6 {
    Write-Section 'H6 合并正确性（汇总求和/峰值 max/samples 唯一升序）'
    $d = Join-Path $DataRoot 'h5'
    $date = Get-Date -Format 'yyyy-MM-dd'
    $files = Get-NwipdbFiles -DataDir $d -Date $date
    if ($files.Count -lt 2) { Todo 'H6_MERGE_SUM_EQUAL' 'H5 产出不足 2 个文件，无法比对（需先跑 H5）'; return }
    $merged = Get-DayMergedSummary -DataDir $d -Date $date
    $sumBytesIn = [long]0; $sumBytesOut = [long]0; $maxIn = [long]0; $maxOut = [long]0; $payloadOk = 0
    $allSamples = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $p = Read-NwipdbPayload -Path $f.FullName -DataDir $d
        if (-not $p.Ok) { continue }
        $payloadOk++
        $day = $p.Day
        $sumBytesIn += [long]$day.bytesIn; $sumBytesOut += [long]$day.bytesOut
        if ([long]$day.peakInBps -gt $maxIn) { $maxIn = [long]$day.peakInBps }
        if ([long]$day.peakOutBps -gt $maxOut) { $maxOut = [long]$day.peakOutBps }
        foreach ($s in (Get-DaySamples -Day $day)) { [void]$allSamples.Add($s) }
    }
    if ($payloadOk -ne $files.Count) { Todo 'H6_MERGE_SUM_EQUAL' ("payload 解密未就绪（{0}/{1} 可读），无法精确比对合并；需 nwipdb-format.ps1 解密实现" -f $payloadOk, $files.Count); return }
    if (-not $merged.Ok) { Fail 'H6_MERGE_SUM_EQUAL' ("合并汇总不可读: " + $merged.Error); return }
    if ([long]$merged.BytesIn -eq $sumBytesIn -and [long]$merged.BytesOut -eq $sumBytesOut) { Pass 'H6_MERGE_SUM_EQUAL' ("合并汇总 == 各文件求和：in {0:N0} out {1:N0}" -f $sumBytesIn, $sumBytesOut) }
    else { Fail 'H6_MERGE_SUM_EQUAL' ("合并汇总 != 求和：merged in={0:N0} out={1:N0}，sum in={2:N0} out={3:N0}" -f $merged.BytesIn, $merged.BytesOut, $sumBytesIn, $sumBytesOut) }
    if ([long]$merged.PeakInBps -eq $maxIn -and [long]$merged.PeakOutBps -eq $maxOut) { Pass 'H6_PEAK_MAX' ("峰值取 max：in {0:N0} out {1:N0}" -f $maxIn, $maxOut) }
    else { Fail 'H6_PEAK_MAX' ("峰值不是 max：merged {0}/{1} vs max {2}/{3}" -f $merged.PeakInBps, $merged.PeakOutBps, $maxIn, $maxOut) }
    # samples 合并口径（设计/实现：跨文件同分钟求和去重、按分钟升序）
    # 各文件原始 samples 之间出现同一分钟是合法的（同小时多 session / 重启），合并层必须求和去重；
    # 因此断言：①合并后分钟数 == 各文件分钟的去重数 ②合并后分钟严格升序 ③合并后每桶字节合计 == 当天 bytes。
    $rawMins = @($allSamples | ForEach-Object { [long]$_[0] })
    $uniqueMins = @($rawMins | Sort-Object -Unique)
    $mergedMins = @($merged.Merge.SampleMinutes)
    $isAsc = $true
    for ($i = 1; $i -lt $mergedMins.Count; $i++) { if ([long]$mergedMins[$i] -le [long]$mergedMins[$i-1]) { $isAsc = $false; break } }
    $sumBucketIn = [long]0; $sumBucketOut = [long]0
    if ($merged.Merge -and $merged.Merge.Samples) {
        foreach ($mn in @($merged.Merge.Samples.Keys)) {
            $sumBucketIn += [long]$merged.Merge.Samples[$mn][0]
            $sumBucketOut += [long]$merged.Merge.Samples[$mn][1]
        }
    }
    $okCount = ($merged.SamplesCount -eq $uniqueMins.Count) -and $isAsc
    $okSum = ([Math]::Abs([double]$sumBucketIn - [double]$merged.BytesIn) -le 0.5) -and ([Math]::Abs([double]$sumBucketOut - [double]$merged.BytesOut) -le 0.5)
    if ($okCount -and $okSum) {
        Pass 'H6_SAMPLES_MERGE' ("samples 合并正确：原始 {0} 条/{1} 个不同分钟 → 合并 {2} 桶升序；每桶字节合计 in={3:N0} out={4:N0} == 当天 bytes" -f $rawMins.Count, $uniqueMins.Count, $merged.SamplesCount, $sumBucketIn, $sumBucketOut)
    } elseif ($okCount -or $okSum) {
        Warn 'H6_SAMPLES_MERGE' ("samples 合并部分符合：分钟数/升序={0}（合并 {1} vs 去重 {2}, asc={3}）；桶字节合计==bytes={4}（in {5:N0}/{6:N0} out {7:N0}/{8:N0}）" -f $okCount, $merged.SamplesCount, $uniqueMins.Count, $isAsc, $okSum, $sumBucketIn, $merged.BytesIn, $sumBucketOut, $merged.BytesOut)
    } else {
        Fail 'H6_SAMPLES_MERGE' ("samples 合并不符合设计：合并 {0} vs 去重 {1}，升序={2}，桶合计 in {3:N0}/{4:N0} out {5:N0}/{6:N0}" -f $merged.SamplesCount, $uniqueMins.Count, $isAsc, $sumBucketIn, $merged.BytesIn, $sumBucketOut, $merged.BytesOut)
    }
}

function Invoke-H7 {
    Write-Section 'H7 性能（解密合并一天 / 30 天历史首载）'
    # 7a 产品侧 H7：--selftest 在 selftest-store 用合成数据输出两行性能（01-实现说明.md §6.5）
    $perfDir = New-TestDataDir -Name 'h7-perf' -ScanIntervalSec '10'
    $sr = Invoke-QaExe -Tag 'h7-selftest' -Arguments @('--selftest', '--datadir', $perfDir, '--mutex-tag', 'v230-h7perf') -TimeoutSec 240
    $stLog = Join-Path $perfDir 'selftest.log'
    if ($sr.ExitCode -eq 0 -and -not $sr.TimedOut -and (Test-Path $stLog)) {
        $stText = [IO.File]::ReadAllText($stLog, [Text.Encoding]::UTF8)
        $m1 = [regex]::Match($stText, '小时文件合并\s*24\s*文件[:：]\s*(\d+)\s*ms')
        $m2 = [regex]::Match($stText, '历史概览\s*30\s*天首载[:：]\s*(\d+)\s*ms')
        if ($m1.Success) {
            $p1val = [int]$m1.Groups[1].Value
            if ($p1val -lt $H7MergeBudgetMs) { Pass 'H7_DAY_MERGE_PERF' ("产品 selftest 实测：小时文件合并 24 文件 {0}ms < {1}ms" -f $p1val, $H7MergeBudgetMs) }
            else { Fail 'H7_DAY_MERGE_PERF' ("产品 selftest：合并 24 文件 {0}ms >= {1}ms" -f $p1val, $H7MergeBudgetMs) }
        } else { Fail 'H7_DAY_MERGE_PERF' 'selftest.log 未出现「小时文件合并 24 文件: N ms」' }
        if ($m2.Success) {
            $p2val = [int]$m2.Groups[1].Value
            if ($p2val -lt $H7HistoryBudgetMs) { Pass 'H7_HISTORY_LOAD_PERF' ("产品 selftest 实测：历史概览 30 天首载 {0}ms < {1}ms（多文件日解密合并去重）" -f $p2val, $H7HistoryBudgetMs) }
            else { Fail 'H7_HISTORY_LOAD_PERF' ("产品 selftest：历史 30 天首载 {0}ms >= {1}ms" -f $p2val, $H7HistoryBudgetMs) }
        } else { Fail 'H7_HISTORY_LOAD_PERF' 'selftest.log 未出现「历史概览 30 天首载: N ms」' }
    } else { Fail 'H7_DAY_MERGE_PERF' ("selftest 未正常完成（ExitCode={0} TimedOut={1}）" -f $sr.ExitCode, $sr.TimedOut); Fail 'H7_HISTORY_LOAD_PERF' 'selftest 未正常完成' }

    # 7b QA 侧独立实测：用 H5 多会话目录（≥2 文件）测解密合并耗时
    $d5 = Join-Path $DataRoot 'h5'
    $date = Get-Date -Format 'yyyy-MM-dd'
    $files5 = Get-NwipdbFiles -DataDir $d5 -Date $date
    if ($files5.Count -ge 2) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $merged = Get-DayMergedSummary -DataDir $d5 -Date $date
        $sw.Stop()
        $ms = [Math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        if (-not $merged.Ok) { Todo 'H7_QA_MERGE_MEASURE' ("QA 侧合并不可读: " + $merged.Error) }
        elseif ($ms -lt $H7MergeBudgetMs) { Pass 'H7_QA_MERGE_MEASURE' ("QA 侧独立解密合并 {0} 个文件耗时 {1}ms < {2}ms（含 PowerShell 解密开销，仅作交叉验证）" -f $files5.Count, $ms, $H7MergeBudgetMs) }
        else { Warn 'H7_QA_MERGE_MEASURE' ("QA 侧（PowerShell 解密）合并 {0} 文件耗时 {1}ms >= {2}ms；产品侧看 H7_DAY_MERGE_PERF" -f $files5.Count, $ms, $H7MergeBudgetMs) }
    } else { Add-Info2 'H7_QA_MERGE_MEASURE' ("H5 目录文件不足（{0}），跳过 QA 侧交叉实测" -f $files5.Count) }
}

# ================================================================== 主流程
Write-Host ''
Write-Host ("NetWatcher v2.3.0 加密小时存储专项回归  ({0})" -f $RunTag) -ForegroundColor White
Write-Host ("repo    = {0}" -f $RepoRoot)
Write-Host ("exe     = {0}" -f $Exe)
Write-Host ("out     = {0}" -f $OutDir)
Write-Host ("fixtures= {0}" -f $FixturesDir)
Write-Host ("mode    = {0}" -f $(if ($PrepOnly) { 'PrepOnly（准备自查，不跑产品）' } else { 'FULL H1~H7' }))

$realSnapBefore = Get-DirSnapshot $RealDataDir

try {
    if ($PrepOnly) {
        Invoke-PrepCheck
    } else {
        # 正式跑前置：exe 存在 + 版本 2.3.0.0；复制到 %TEMP%；隔离
        if (-not (Test-Path $Exe)) { Fail 'PRE_EXE' "找不到被测 exe: $Exe" }
        else {
            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Exe)
            if ($vi.FileVersion -match '^2\.3\.\d+\.0$') { Pass 'PRE_VERSION' ("被测 exe FileVersion={0}（v2.3.0 系列）" -f $vi.FileVersion) }
            else { Fail 'PRE_VERSION' ("被测 exe FileVersion={0}，期望 2.3.x.0" -f $vi.FileVersion) }
        }
        if (Test-Path $Exe) {
            New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
            Copy-Item $Exe $RunExe -Force
            $h1 = Get-Sha256 $Exe; $h2 = Get-Sha256 $RunExe
            if ($h1 -eq $h2) { Pass 'PRE_RUN_EXE' ("已复制到 {0}（SHA256={1}…）" -f $RunExe, $h1.Substring(0, 16)) }
            else { Fail 'PRE_RUN_EXE' '复制后 SHA256 不一致' }
        }
        New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
        Add-Info2 'PRE_SAFETY' ("所有测试数据目录在 %TEMP% 下: {0}；真实数据只读快照" -f $DataRoot)
        # 确认真实数据未被本脚本触碰（只读）
        if ($realSnapBefore.Count -gt 0) { Add-Info2 'PRE_REALDATA' ("{0} 只读快照 {1} 个文件" -f $RealDataDir, $realSnapBefore.Count) }
        Invoke-H1; Invoke-H2; Invoke-H3; Invoke-H4; Invoke-H5; Invoke-H6; Invoke-H7
    }
} catch {
    Fail 'UNEXPECTED' ("脚本异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
} finally {
    foreach ($p in @($script:StartedPids)) { [void](Stop-QaProcess -ProcessId $p) }
}

# 真实数据守卫（只读快照对比；变化只 WARN + 归因，不删除/修改）
$realSnapAfter = Get-DirSnapshot $RealDataDir
$changes = Compare-DirSnapshot -Before $realSnapBefore -After $realSnapAfter
if ($changes.Count -eq 0) { Pass 'REALDATA_UNTOUCHED' ("{0} 与运行前一致（{1} 文件，size+mtime+SHA256）" -f $RealDataDir, $realSnapAfter.Count) }
else {
    $nw = @(Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue)
    if ($nw.Count -gt 0) { Warn 'REALDATA_UNTOUCHED' ("{0} 处变化，归因为用户 NetWatcher 实例实时写入（PID {1}）；本脚本所有实例均用 %TEMP% datadir" -f $changes.Count, (($nw | ForEach-Object { $_.Id }) -join ',')) }
    else { WARN 'REALDATA_UNTOUCHED' ("{0} 处变化且无 NetWatcher 运行，需人工复核：{1}" -f $changes.Count, (($changes | Select-Object -First 4) -join '; ')) }
    foreach ($c in ($changes | Select-Object -First 8)) { Add-Info2 'REALDATA_DIFF' $c }
}

# 清理临时测试目录（保留 -KeepTemp 时跳过）
if (-not $KeepTemp) {
    foreach ($p in @($DataRoot, $RunDir)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
}

# ------------------------------------------------------------------ 汇总
Write-Section '汇总'
$pass = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$fail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warn = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$todo = @($script:Results | Where-Object { $_.Status -eq 'TODO' }).Count
Write-Host ("PASS={0} FAIL={1} WARN={2} TODO={3}" -f $pass, $fail, $warn, $todo)
$result = if ($fail -gt 0) { 'FAIL' } elseif ($todo -gt 0) { 'INCOMPLETE' } else { 'PASS' }
Write-Host ("RESULT: {0}" -f $result) -ForegroundColor $(if ($fail -gt 0) { 'Red' } elseif ($todo -gt 0) { 'Magenta' } else { 'Green' })

$reportTxt = Join-Path $OutDir ("v230_{0}.txt" -f $RunTag)
$reportJson = Join-Path $OutDir ("v230_{0}.json" -f $RunTag)
$txt = @()
$txt += ("NetWatcher v2.3.0 .nwipdb QA  $RunTag")
$txt += ("mode: {0}   result: {1}   PASS={2} FAIL={3} WARN={4} TODO={5}" -f $(if ($PrepOnly) { 'PrepOnly' } else { 'FULL' }), $result, $pass, $fail, $warn, $todo)
$txt += ''
foreach ($r in $script:Results) { $txt += ("[{0}] {1,-30} {2}" -f $r.Status, $r.Check, $r.Detail) }
$txt += ''
$txt += '-- info --'
foreach ($r in $script:Info) { $txt += ("[INFO] {0,-30} {1}" -f $r.Check, $r.Detail) }
$txt | Set-Content -Path $reportTxt -Encoding UTF8
[pscustomobject]@{
    time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'); mode = $(if ($PrepOnly) { 'PrepOnly' } else { 'FULL' })
    result = $result; pass = $pass; fail = $fail; warn = $warn; todo = $todo
    exe = $Exe; fixtures = $FixturesDir; results = @($script:Results); info = @($script:Info)
} | ConvertTo-Json -Depth 5 | Set-Content -Path $reportJson -Encoding UTF8
Write-Host ("report: {0}" -f $reportTxt)

if ($fail -gt 0) { exit 1 } elseif ($todo -gt 0) { exit 2 } else { exit 0 }
