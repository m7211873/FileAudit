# ============================================================
#  IP监控2.1（NetWatcher 2.1）卸载脚本
#  纯系统自带组件，默认不需要管理员权限。
#
#  只做 2.1 自己的四件事（可重复执行，幂等）：
#   1) 结束正在运行的 2.1 实例（按可执行文件路径精确匹配，不误杀 2.0）
#   2) 调用 NetWatcher.exe --autostart-off 删除 HKCU 自启项（值名 NetWatcher2.1）
#   3) 删除桌面「IP监控2.1」快捷方式
#   4) 加 -DeleteData 时，删除数据目录（默认 %APPDATA%\NetWatcher，与 2.0 共用）
#
#  与 2.0 的边界（本脚本刻意不做的事）：
#   · 不结束/不改动 2.0 的进程、%LOCALAPPDATA%\Programs\NetWatcher、桌面「IP监控.lnk」、
#     HKCU\...\Run\NetWatcher —— 2.0 请用它自己的 uninstall.ps1 卸载
#   · 默认保留数据目录；数据目录与 2.0 共用，-DeleteData 会连 2.0 的历史一起删（会二次警告）
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -DeleteData
#    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -DataDir "D:\NetWatcherData"
# ============================================================
param(
    [switch]$DeleteData,
    [switch]$KeepBinary,
    [string]$DataDir = ''
)

# 同 install.ps1：不用 $ErrorActionPreference='Stop'，避免外部命令 stderr 陷阱。
$ErrorActionPreference = 'Continue'

$Root         = $PSScriptRoot
$BinExe       = Join-Path $Root 'bin\NetWatcher.exe'
$InstallDir   = Join-Path $env:LOCALAPPDATA 'Programs\NetWatcher2.1'
$InstalledExe = Join-Path $InstallDir 'NetWatcher.exe'
# install.ps1 会把程序复制到 LocalAppData 再运行；优先用安装副本
if (Test-Path -LiteralPath $InstalledExe) { $Exe = $InstalledExe } else { $Exe = $BinExe }
$ShortcutName = 'IP监控2.1.lnk'
$RunKeyPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'NetWatcher2.1'

$script:ExitCode = 0

# 判断某个进程路径是否属于 2.1（安装副本或 2.1 仓库 bin 都算）。
# 2.0 的进程路径（%LOCALAPPDATA%\Programs\NetWatcher\...）不在此列，会被跳过。
function Test-OurExe([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return $Path.Equals($InstalledExe, [System.StringComparison]::OrdinalIgnoreCase) -or
           $Path.Equals($BinExe, [System.StringComparison]::OrdinalIgnoreCase)
}

function Write-Step([string]$Message) { Write-Host ">> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "   $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message)  { Write-Host "   $Message" -ForegroundColor Red }

function Get-RunValue {
    try {
        $item = Get-ItemProperty -Path $RunKeyPath -ErrorAction Stop
        $prop = $item.PSObject.Properties[$RunValueName]
        if ($null -ne $prop -and $null -ne $prop.Value) { return [string]$prop.Value }
    } catch { }
    return ''
}

# 删除 HKCU Run 里 2.1 的值；本就存在与否都算成功，真正的失败（无权限）返回 $false
function Remove-RunValue {
    if (-not (Get-RunValue)) { return $true }
    try {
        Remove-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction Stop
    } catch { }
    return ((Get-RunValue) -eq '')
}

function Invoke-NetWatcher {
    param(
        [string[]]$Arguments,
        [int]$TimeoutMs = 20000
    )
    $quoted = @()
    foreach ($a in $Arguments) {
        if ($a -match '\s') { $quoted += ('"' + $a + '"') } else { $quoted += $a }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $Exe
    $psi.Arguments       = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Warn ("无法启动程序: {0}" -f $_.Exception.Message)
        return -1
    }
    if (-not $p.WaitForExit($TimeoutMs)) {
        Write-Warn ("程序在 {0} 毫秒内没有退出，已强制结束。" -f $TimeoutMs)
        try { $p.Kill() } catch { }
        return -1
    }
    return $p.ExitCode
}

# 取快捷方式目标路径（只有确认指向 2.1 时才删除，避免误删桌面同名文件）
function Get-ShortcutTarget([string]$LnkPath) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($LnkPath)
        return [string]$sc.TargetPath
    } catch {
        return ''
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  IP监控2.1（NetWatcher 2.1）卸载' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

# ---- 1) 结束运行中的 2.1 进程 ----
Write-Step '结束正在运行的 2.1 进程'
# 只结束「2.1 安装目录 / 2.1 仓库 bin」启动的实例；2.0 与其它位置的副本一律跳过。
# 禁止按进程名批量杀：用户可能同时开着 2.0 的管理员实例。
$processes = @(Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue)
$killed = 0
$skipped = 0
$blocked = 0
if ($processes.Count -eq 0) {
    Write-Ok '没有正在运行的 NetWatcher 进程'
} else {
    foreach ($proc in $processes) {
        $procId = $proc.Id
        $procPath = ''
        try { $procPath = [string]$proc.Path } catch { $procPath = '' }
        if ([string]::IsNullOrEmpty($procPath)) {
            $blocked++
            Write-Warn ("无法读取 PID {0} 的可执行路径（可能受保护/权限不足），跳过；如果是 2.1，请在托盘右键退出该实例。" -f $procId)
            continue
        }
        if (-not (Test-OurExe $procPath)) {
            $skipped++
            Write-Ok ("跳过非 2.1 的 NetWatcher 进程 PID {0}（2.0 或其它副本，不会动它）: {1}" -f $procId, $procPath)
            continue
        }
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            $killed++
            Write-Ok ("已结束 2.1 进程 PID {0}" -f $procId)
        } catch {
            $blocked++
            Write-Warn ("无法结束 PID {0}: {1}" -f $procId, $_.Exception.Message)
        }
    }
    if ($killed -gt 0) { Start-Sleep -Milliseconds 500 }
    $left = @(Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue | Where-Object {
        $lp = ''
        try { $lp = [string]$_.Path } catch { $lp = '' }
        Test-OurExe $lp
    })
    if ($left.Count -gt 0) {
        Write-Warn ("还有 {0} 个 2.1 进程在运行（可能以管理员身份启动）。" -f $left.Count)
        Write-Warn '当前普通权限无法结束它：请在系统托盘右键退出，或用管理员 PowerShell 再运行一次本脚本。'
    }
}

# ---- 2) 关闭 2.1 的开机自启 ----
Write-Step '关闭开机自启（HKCU 值 NetWatcher2.1）'
$hadRunValue = (Get-RunValue) -ne ''
$exeExists = Test-Path -LiteralPath $Exe
if ($hadRunValue) {
    if ($exeExists) {
        $rc = Invoke-NetWatcher -Arguments @('--autostart-off')
        if ($rc -ne 0) {
            Write-Warn ("程序调用返回 {0}，改用卸载脚本直接删除（与程序等价）。" -f $rc)
        }
    }
    if (Remove-RunValue) {
        Write-Ok '已删除 2.1 的开机自启项'
    } else {
        Write-Err '删除 HKCU 启动项 NetWatcher2.1 失败（可能被安全软件拦截或权限不足）。'
        $script:ExitCode = 1
    }
} else {
    Write-Ok '原本就没有 2.1 的开机自启项，跳过'
}

# ---- 3) 删除桌面快捷方式（只删 2.1 自己的） ----
Write-Step '删除桌面快捷方式'
try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $removed = 0
    $lnkPath = Join-Path $desktop $ShortcutName
    if (Test-Path -LiteralPath $lnkPath) {
        # 只删确认指向 2.1 的快捷方式；桌面同时存在 2.0 的「IP监控.lnk」，那边不动。
        $target = Get-ShortcutTarget $lnkPath
        $isOurs = $false
        if ([string]::IsNullOrEmpty($target)) { $isOurs = $true }
        elseif ($target.Equals($Exe, [System.StringComparison]::OrdinalIgnoreCase)) { $isOurs = $true }
        elseif ($target.Equals($BinExe, [System.StringComparison]::OrdinalIgnoreCase)) { $isOurs = $true }
        elseif ($target.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) { $isOurs = $true }
        elseif ($target.StartsWith($InstallDir, [System.StringComparison]::OrdinalIgnoreCase)) { $isOurs = $true }
        if (-not $isOurs) {
            Write-Warn ("桌面「{0}」不指向 2.1 程序，未删除: {1}" -f $ShortcutName, $target)
        } else {
            try {
                Remove-Item -LiteralPath $lnkPath -Force -ErrorAction Stop
                Write-Ok ("已删除: {0}" -f $lnkPath)
                $removed++
            } catch {
                Write-Err ("删除快捷方式失败 {0}: {1}" -f $lnkPath, $_.Exception.Message)
                $script:ExitCode = 1
            }
        }
    }
    if ($removed -eq 0) {
        if (-not (Test-Path -LiteralPath $lnkPath)) {
            Write-Ok '原本就没有「IP监控2.1」桌面快捷方式，跳过'
        }
    }
    Write-Ok '未改动 2.0 的「IP监控.lnk」（不属于 2.1 的卸载范围）'
} catch {
    Write-Err ("删除快捷方式失败: {0}" -f $_.Exception.Message)
    $script:ExitCode = 1
}

# ---- 4) 数据目录 ----
if ([string]::IsNullOrWhiteSpace($DataDir)) {
    $DataDir = Join-Path $env:APPDATA 'NetWatcher'
}
try { $DataDir = [System.IO.Path]::GetFullPath($DataDir) } catch { }
if ($DataDir.Length -gt 3 -and $DataDir.EndsWith('\')) { $DataDir = $DataDir.TrimEnd('\') }

if ($DeleteData) {
    Write-Step ("删除数据目录: {0}" -f $DataDir)
    Write-Warn '注意：2.1 与 2.0 共用这个数据目录；删除后 2.0 的历史数据也会一起丢失，且不可恢复。'
    # 安全护栏：拒绝删除盘符根目录/空白路径
    $trimmed = $DataDir.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -match '^[A-Za-z]:$') {
        Write-Err '数据目录路径不合法，已拒绝删除。'
        $script:ExitCode = 1
    } elseif (Test-Path -LiteralPath $DataDir) {
        try {
            Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction Stop
            Write-Ok '数据目录已删除'
        } catch {
            Write-Err ("删除失败（可能有进程占用）: {0}" -f $_.Exception.Message)
            $script:ExitCode = 1
        }
    } else {
        Write-Ok '数据目录不存在，跳过'
    }
} else {
    Write-Step '保留数据目录（加 -DeleteData 才会删除）'
    Write-Ok ("数据目录: {0}（与 2.0 共用，保留后 2.1/2.0 都能继续读历史）" -f $DataDir)
}

# ---- 5) 删除 2.1 安装目录（%LOCALAPPDATA%\Programs\NetWatcher2.1）----
if ($KeepBinary) {
    Write-Step '保留程序文件（-KeepBinary）'
    Write-Ok ("安装目录: {0}" -f $InstallDir)
} else {
    Write-Step ("删除 2.1 安装目录: {0}" -f $InstallDir)
    if (Test-Path -LiteralPath $InstallDir) {
        try {
            # 先删我们自己复制进去的文件，再删空目录（不碰用户自己放进去的东西）
            foreach ($f in @('NetWatcher.exe', 'app.ico')) {
                $p = Join-Path $InstallDir $f
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
            }
            $rest = @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue)
            if ($rest.Count -eq 0) {
                Remove-Item -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue
                Write-Ok '2.1 安装目录已删除'
            } else {
                Write-Warn ("安装目录里还有其它文件，未整体删除: {0}" -f $InstallDir)
            }
        } catch {
            Write-Warn ("删除安装目录失败: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Ok '2.1 安装目录不存在，跳过'
    }
}
# 明确边界：2.0 的安装目录（%LOCALAPPDATA%\Programs\NetWatcher）本脚本从不触碰
Write-Ok '未改动 2.0 的安装目录（%LOCALAPPDATA%\Programs\NetWatcher）'

# ---- 完成 ----
Write-Host ''
if ($script:ExitCode -eq 0) {
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '  2.1 卸载完成' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
} else {
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  2.1 卸载完成，但有警告（见上面的红色提示）' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Yellow
}
if (-not $DeleteData) {
    Write-Host ("  数据仍保留在: {0}（与 2.0 共用）" -f $DataDir)
    Write-Host '  如需连同数据一起删除： uninstall.ps1 -DeleteData（注意：2.0 的历史也会一起删）'
}
Write-Host '  2.0 的安装目录 / 开机自启 / 桌面快捷方式 / 数据均未改动。'
Write-Host ''
exit $script:ExitCode
