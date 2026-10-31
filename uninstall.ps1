# ============================================================
#  IP监控2.0（NetWatcher）卸载脚本
#  纯系统自带组件，默认不需要管理员权限。
#
#  做四件事（可重复执行，幂等）：
#   1) 结束正在运行的 NetWatcher 进程
#   2) 调用 NetWatcher.exe --autostart-off 删除 HKCU 开机自启项
#   3) 删除桌面「IP监控」快捷方式
#   4) 加 -DeleteData 时，删除数据目录（默认 %APPDATA%\NetWatcher）
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
$InstallDir   = Join-Path $env:LOCALAPPDATA 'Programs\NetWatcher'
$InstalledExe = Join-Path $InstallDir 'NetWatcher.exe'
# install.ps1 会把程序复制到 LocalAppData 再运行；优先用安装副本
if (Test-Path -LiteralPath $InstalledExe) { $Exe = $InstalledExe } else { $Exe = $BinExe }
$ShortcutName = 'IP监控.lnk'
$RunKeyPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'NetWatcher'

$script:ExitCode = 0

# 判断某个进程路径是否属于本程序（安装副本或仓库 bin 都算）
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

# 删除 HKCU Run 值；本就存在与否都算成功，真正的失败（无权限）返回 $false
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

# 取快捷方式目标路径（不是本程序的快捷方式才不会被误删）
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
Write-Host '  IP监控2.0（NetWatcher）卸载' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

# ---- 1) 结束运行中的进程 ----
Write-Step '结束正在运行的 NetWatcher 进程'
# 只结束本安装目录（bin\NetWatcher.exe）启动的实例，避免误杀其它位置的 NetWatcher 副本。
$processes = @(Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue)
$killed = 0
$skipped = 0
$blocked = 0
if ($processes.Count -eq 0) {
    Write-Ok '没有正在运行的进程'
} else {
    foreach ($proc in $processes) {
        $procId = $proc.Id
        $procPath = ''
        try { $procPath = [string]$proc.Path } catch { $procPath = '' }
        if ([string]::IsNullOrEmpty($procPath)) {
            $blocked++
            Write-Warn ("无法读取 PID {0} 的可执行路径（可能受保护/权限不足），跳过；请在托盘右键退出该实例。" -f $procId)
            continue
        }
        if (-not (Test-OurExe $procPath)) {
            $skipped++
            Write-Ok ("跳过非本安装的 NetWatcher 进程 PID {0}: {1}" -f $procId, $procPath)
            continue
        }
        try {
            Stop-Process -Id $procId -Force -ErrorAction Stop
            $killed++
            Write-Ok ("已结束进程 PID {0}" -f $procId)
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
        Write-Warn ("还有 {0} 个本安装的 NetWatcher 进程在运行（可能以管理员身份启动）。" -f $left.Count)
        Write-Warn '当前普通权限无法结束它：请在系统托盘右键退出，或用管理员 PowerShell 再运行一次本脚本。'
    }
}

# ---- 2) 关闭开机自启 ----
Write-Step '关闭开机自启（HKCU 启动项）'
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
        Write-Ok '已删除开机自启项'
    } else {
        Write-Err '删除 HKCU 启动项失败（可能被安全软件拦截或权限不足）。'
        $script:ExitCode = 1
    }
} else {
    Write-Ok '原本就没有开机自启项，跳过'
}

# ---- 3) 删除桌面快捷方式 ----
Write-Step '删除桌面快捷方式'
try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $removed = 0
    $skipped = 0
    # 2.0 的「IP监控.lnk」和 1.0 遗留的「NetWatcher.lnk」都尝试删除；
    # 仅在确认旧快捷方式指向本程序（或指向路径失效）时才删，避免误删用户桌面上的同名文件。
    foreach ($name in @($ShortcutName, 'NetWatcher.lnk')) {
        $lnkPath = Join-Path $desktop $name
        if (-not (Test-Path -LiteralPath $lnkPath)) { continue }
        if ($name -eq 'NetWatcher.lnk') {
            $target = Get-ShortcutTarget $lnkPath
            $isOurs = $false
            if ([string]::IsNullOrEmpty($target)) { $isOurs = $true }
            elseif ($target.Equals($Exe, [System.StringComparison]::OrdinalIgnoreCase)) { $isOurs = $true }
            elseif ($target.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) { $isOurs = $true }
            if (-not $isOurs) {
                Write-Warn ("桌面「NetWatcher.lnk」不指向本程序，未删除: {0}" -f $target)
                $skipped++
                continue
            }
        }
        try {
            Remove-Item -LiteralPath $lnkPath -Force -ErrorAction Stop
            Write-Ok ("已删除: {0}" -f $lnkPath)
            $removed++
        } catch {
            Write-Err ("删除快捷方式失败 {0}: {1}" -f $lnkPath, $_.Exception.Message)
            $script:ExitCode = 1
        }
    }
    if ($removed -eq 0 -and $skipped -eq 0) {
        Write-Ok '原本就没有桌面快捷方式，跳过'
    }
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
    Write-Ok ("数据目录: {0}" -f $DataDir)
}

# ---- 5) 删除安装目录（%LOCALAPPDATA%\Programs\NetWatcher）----
if ($KeepBinary) {
    Write-Step '保留程序文件（-KeepBinary）'
    Write-Ok ("安装目录: {0}" -f $InstallDir)
} else {
    Write-Step ("删除安装目录: {0}" -f $InstallDir)
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
                Write-Ok '安装目录已删除'
            } else {
                Write-Warn ("安装目录里还有其它文件，未整体删除: {0}" -f $InstallDir)
            }
        } catch {
            Write-Warn ("删除安装目录失败: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Ok '安装目录不存在，跳过'
    }
}

# ---- 完成 ----
Write-Host ''
if ($script:ExitCode -eq 0) {
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '  卸载完成' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
} else {
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  卸载完成，但有警告（见上面的红色提示）' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Yellow
}
if (-not $DeleteData) {
    Write-Host ("  数据仍保留在: {0}" -f $DataDir)
    Write-Host '  如需连同数据一起删除： uninstall.ps1 -DeleteData'
}
Write-Host '  数据保留策略见上方提示；程序文件按 -KeepBinary 决定是否保留。'
Write-Host ''
exit $script:ExitCode
