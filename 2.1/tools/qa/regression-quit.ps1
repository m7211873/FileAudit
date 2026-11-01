# 2.1.1 回归：--quit 优雅退出（保存数据 + 移除托盘图标 + 正常退出）
# 为什么需要：自动化测试/脚本以前只能用 Stop-Process 强杀，强杀会在 Windows 通知区域留下
# "幽灵图标"（鼠标划过才消失）。--quit 让主实例走 ExitApp：保存数据、Dispose 托盘图标、正常退出。
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
# v2.3.0：.nwipdb 加密小时文件只读适配层（Q4 用解密合并确认已落盘）
. (Join-Path $PSScriptRoot 'nwipdb-format.ps1')
$exeSrc = Join-Path $repo 'bin\NetWatcher.exe'
if (-not (Test-Path -LiteralPath $exeSrc)) { Write-Host "找不到 $exeSrc（先 cmd /c build.bat）"; exit 1 }
$run = Join-Path $env:TEMP ('nw21-quit-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$exe = Join-Path $run 'NetWatcher.exe'
Copy-Item -LiteralPath $exeSrc -Destination $exe -Force
$d = Join-Path $run 'data'
New-Item -ItemType Directory -Path (Join-Path $d 'data') -Force | Out-Null
$cfg = '{"ScanIntervalSeconds":2,"AutoStart":false,"RetentionDays":0,"StartMinimized":true,"GeoEnabled":false,"GeoApi":"http://ip-api.com/json/{0}","NewIpAlert":false,"ShowLocalIp":true}'
[IO.File]::WriteAllText((Join-Path $d 'config.json'), $cfg, (New-Object System.Text.UTF8Encoding($false)))
$results = New-Object System.Collections.ArrayList
function Add-R([string]$n, [bool]$ok, [string]$detail) {
    [void]$results.Add([pscustomobject]@{ Check = $n; OK = $ok; Detail = $detail })
    Write-Host ("{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $n, $detail)
}
$tag = 'quitreg'
$startCmd = '"' + $exe + '" --datadir "' + $d + '" --mutex-tag ' + $tag
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $startCmd }
$pid1 = [int]$r.ProcessId
Start-Sleep -Seconds 8
$p = Get-Process -Id $pid1 -ErrorAction SilentlyContinue
Add-R 'Q1 启动成功且按 StartMinimized 隐藏' (($p -ne $null) -and ($p.MainWindowHandle -eq [IntPtr]::Zero)) ("alive=$($p -ne $null) handle=$(if ($p) { $p.MainWindowHandle } else { 'n/a' })")
$quitCmd = '"' + $exe + '" --datadir "' + $d + '" --mutex-tag ' + $tag + ' --quit'
[void](Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $quitCmd })
$exited = $false
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 250; if (-not (Get-Process -Id $pid1 -ErrorAction SilentlyContinue)) { $exited = $true; break } }
Add-R 'Q2 --quit 后主实例在 10 秒内退出' $exited ("elapsed=$([math]::Round(($i + 1) * 0.25, 1))s")
$log = ''
$logPath = Join-Path $d 'startup.log'
if (Test-Path $logPath) { $log = Get-Content $logPath -Raw -Encoding UTF8 }
Add-R 'Q3 退出走正常路径（startup.log 有 Application.Run 退出）' ($log -match 'Application\.Run 退出') ''
$today = (Get-Date).ToString('yyyy-MM-dd')
$storeFiles = Get-NwipdbFiles -DataDir $d -Date $today
$daySum = Get-DayMergedSummary -DataDir $d -Date $today
$okData = $false; $detail = 'missing'
if ($storeFiles.Count -ge 1 -and $daySum.Ok) {
    $okData = $true
    $detail = ("文件={0} sampleCount={1} bytesIn={2} 分钟桶={3}" -f $storeFiles.Count, $daySum.SampleCount, $daySum.BytesIn, $daySum.SamplesCount)
} elseif ($storeFiles.Count -ge 1) {
    $detail = ("有 {0} 个 .nwipdb 但解密合并失败: {1}" -f $storeFiles.Count, $daySum.Error)
} else {
    $detail = ("data\ 下无今天的 .nwipdb（{0}）" -f $d)
}
Add-R 'Q4 退出前数据已落盘且加密小时文件可解密' $okData $detail
Add-R 'Q5 无 ui-error/crash 日志' ((-not (Test-Path (Join-Path $d 'ui-error.log'))) -and (-not (Test-Path (Join-Path $d 'crash.log')))) ''
Start-Sleep -Seconds 1
$left = @(Get-CimInstance Win32_Process -Filter "Name='NetWatcher.exe'" | Where-Object { $_.ExecutablePath -eq $exe })
Add-R 'Q6 测试进程已清理' ($left.Count -eq 0) ("left=$($left.Count)")
$fail = @($results | Where-Object { -not $_.OK }).Count
$pass = @($results | Where-Object { $_.OK }).Count
Write-Host ''
Write-Host ("RESULT: {0}  PASS={1}  FAIL={2}" -f $(if ($fail -gt 0) { 'FAIL' } else { 'PASS' }), $pass, $fail)
Write-Host "temp dir : $run"
if ($fail -gt 0) { exit 1 } else { exit 0 }
