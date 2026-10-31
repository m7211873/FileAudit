# 2.1 回归：二次启动唤出（单实例）与数据写锁的先后顺序
# 背景：2.1 的 P0-4「同一数据目录单写实例」若在单实例唤出判断之前抢锁，
#       会导致「双击第二次启动」先报“数据目录被占用”，破坏 2.0 的「重复双击 = 唤出窗口」体验。
# 本脚本锁定该行为：同一 mutex-tag 的二次启动必须先唤出，不报占用；不同 tag 才报占用。
# 纪律：所有实例用绝对临时 --datadir；exe 先复制到 %TEMP% 再启动；只结束自己记录的 PID。
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exeSrc = Join-Path $repo 'bin\NetWatcher.exe'
if (-not (Test-Path -LiteralPath $exeSrc)) { Write-Host "找不到 $exeSrc（先 cmd /c build.bat）"; exit 1 }
$run = Join-Path $env:TEMP ('nw21-act-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$exe = Join-Path $run 'NetWatcher.exe'
Copy-Item -LiteralPath $exeSrc -Destination $exe -Force
$results = New-Object System.Collections.ArrayList
function Add-R([string]$n, [bool]$ok, [string]$d) {
    [void]$results.Add([pscustomobject]@{ Check = $n; OK = $ok; Detail = $d })
    Write-Host ("{0}  {1}  {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $n, $d)
}
function New-D([string]$tag) {
    $x = Join-Path $run $tag
    New-Item -ItemType Directory -Path (Join-Path $x 'data') -Force | Out-Null
    $cfg = '{"ScanIntervalSeconds":5,"AutoStart":false,"RetentionDays":0,"StartMinimized":true,"GeoEnabled":false,"GeoApi":"http://ip-api.com/json/{0}","NewIpAlert":false,"ShowLocalIp":true}'
    [IO.File]::WriteAllText((Join-Path $x 'config.json'), $cfg, (New-Object System.Text.UTF8Encoding($false)))
    return $x
}
function Start-P([string]$dir, [string]$tag, [string]$extra = '') {
    $cmd = '"' + $exe + '" --datadir "' + $dir + '" --mutex-tag ' + $tag + ' ' + $extra
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
    return [int]$r.ProcessId
}
function Stop-P([int]$id) { try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch { } }

# A：同一 tag，--show 二次启动 -> 唤出窗口后二次进程退出
$d1 = New-D 'a'
$a1 = Start-P $d1 'aw'
Start-Sleep -Seconds 8
$p1 = Get-Process -Id $a1 -ErrorAction SilentlyContinue
Add-R 'A1 StartMinimized 隐藏启动' (($p1 -ne $null) -and ($p1.MainWindowHandle -eq [IntPtr]::Zero)) ("alive=$($p1 -ne $null) handle=$(if ($p1) { $p1.MainWindowHandle } else { 'n/a' })")
$a2 = Start-P $d1 'aw' '--show'
Start-Sleep -Seconds 4
$p2 = Get-Process -Id $a2 -ErrorAction SilentlyContinue
$p1b = Get-Process -Id $a1 -ErrorAction SilentlyContinue
Add-R 'A2 二次 --show 未被数据锁拦截（快速退出）' ($p2 -eq $null) ("second_alive=$($p2 -ne $null)")
Add-R 'A3 二次启动唤出已有窗口' (($p1b -ne $null) -and ($p1b.MainWindowHandle -ne [IntPtr]::Zero)) ("main_handle=$(if ($p1b) { $p1b.MainWindowHandle } else { 'n/a' }) title=$(if ($p1b) { $p1b.MainWindowTitle } else { 'n/a' })")
Stop-P $a1
Start-Sleep -Seconds 1

# B：同一 tag，普通二次启动（无 --show）也唤出并退出
$d2 = New-D 'b'
$b1 = Start-P $d2 'bw'
Start-Sleep -Seconds 8
$b2 = Start-P $d2 'bw'
$bExited = $false
for ($i = 0; $i -lt 20 -and -not $bExited; $i++) { Start-Sleep -Milliseconds 300; $bExited = ((Get-Process -Id $b2 -ErrorAction SilentlyContinue) -eq $null) }
$b1p = Get-Process -Id $b1 -ErrorAction SilentlyContinue
Add-R 'B1 普通二次启动快速退出' $bExited ("second_alive=$(-not $bExited)")
Add-R 'B2 普通二次启动唤出窗口' (($b1p -ne $null) -and ($b1p.MainWindowHandle -ne [IntPtr]::Zero)) ("handle=$(if ($b1p) { $b1p.MainWindowHandle } else { 'n/a' })")
Stop-P $b1
Start-Sleep -Seconds 1

# C：不同 tag、同一数据目录 -> 数据写锁冲突提示（预期）
$d3 = New-D 'c'
$c1 = Start-P $d3 'cw1'
Start-Sleep -Seconds 8
$c2 = Start-P $d3 'cw2'
Start-Sleep -Seconds 8
$c2p = Get-Process -Id $c2 -ErrorAction SilentlyContinue
$c1p = Get-Process -Id $c1 -ErrorAction SilentlyContinue
Add-R 'C1 不同 tag 同 datadir 提示「数据目录被占用」' (($c2p -ne $null) -and ($c2p.MainWindowTitle -eq 'IP监控2.1')) ("alive=$($c2p -ne $null) title=$(if ($c2p) { $c2p.MainWindowTitle } else { 'n/a' })")
Add-R 'C2 首个实例不受影响' ($c1p -ne $null) ("alive=$($c1p -ne $null)")
# D：daemon 冲突退出码 2
$o = Join-Path $run 'o.txt'; $e = Join-Path $run 'e.txt'
$dp = Start-Process -FilePath $exe -ArgumentList @('--daemon', '5', '--datadir', ('"' + $d3 + '"')) -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $e
Add-R 'D1 daemon 冲突退出码=2' ($dp.ExitCode -eq 2) ("exit=$($dp.ExitCode)")
Stop-P $c2; Stop-P $c1
Start-Sleep -Seconds 1
$left = @(Get-CimInstance Win32_Process -Filter "Name='NetWatcher.exe'" | Where-Object { $_.ExecutablePath -eq $exe })
Add-R 'E1 测试进程已清理' ($left.Count -eq 0) ("left=$($left.Count)")

$pass = @($results | Where-Object { $_.OK }).Count
$fail = @($results | Where-Object { -not $_.OK }).Count
Write-Host ''
Write-Host ("RESULT: {0}  PASS={1}  FAIL={2}" -f $(if ($fail -gt 0) { 'FAIL' } else { 'PASS' }), $pass, $fail)
Write-Host "temp dir : $run"
if ($fail -gt 0) { exit 1 } else { exit 0 }
