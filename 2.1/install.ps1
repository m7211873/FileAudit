# ============================================================
#  IP监控2.1（NetWatcher 2.1）安装脚本
#  纯系统自带组件（PowerShell + WScript.Shell），无需管理员权限。
#
#  只做 2.1 自己的三件事（可重复执行，幂等）：
#   1) 创建数据目录（默认 %APPDATA%\NetWatcher，与 2.0 共用；可用 -DataDir 指定）
#   2) 调用 NetWatcher.exe --autostart-on 写入 HKCU 开机自启项（值名 NetWatcher2.1）
#   3) 在桌面创建「IP监控2.1」快捷方式（目标安装目录里的 NetWatcher.exe）
#
# 与 2.0 的边界（重要，本脚本刻意不做的事）：
#   · 2.1 用独立安装目录 %LOCALAPPDATA%\Programs\NetWatcher2.1，
#     绝不复制/删除/改写 %LOCALAPPDATA%\Programs\NetWatcher（2.0 的安装目录）
#   · 只写 HKCU\...\Run\NetWatcher2.1，绝不修改或删除 2.0 的 Run\NetWatcher
#   · 只创建/更新桌面「IP监控2.1.lnk」，绝不删除 2.0 的「IP监控.lnk」
#   · 不清理 1.0/2.0 遗留快捷方式，也不做任何"跨版本收拾"（那是各版本自己卸载脚本的事）
#   · 数据目录沿用 %APPDATA%\NetWatcher（历史连续）；升级前请先在 2.0 托盘右键「退出」。
#     2.1 的"同一数据目录单写实例"锁（NetWatcher2.1_DataLock_<数据目录哈希>）只约束 2.1
#     自己（GUI 与 --daemon 抢占），管不到 2.0，所以"先退出 2.0"必须由人来做。
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -NoShortcut
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -DataDir "D:\NetWatcherData"
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Portable
#
#  卸载：运行同目录的 uninstall.ps1（默认保留数据；加 -DeleteData 才删除）
# ============================================================
param(
    [switch]$NoShortcut,
    [switch]$Portable,
    [string]$DataDir = ''
)

# 注意：这里不使用 $ErrorActionPreference='Stop'。
# Windows PowerShell 5.1 下，外部程序（git/pwsh 等）把提示写到 stderr 时，
# 配合 'Stop' 会被当成 NativeCommandError 抛出并中断脚本。
# 本脚本逐步骤判断、显式给出中文提示，不依赖全局异常设置。
$ErrorActionPreference = 'Continue'

$Root          = $PSScriptRoot
$BinExe        = Join-Path $Root 'bin\NetWatcher.exe'
$Exe           = $BinExe
$Icon          = Join-Path $Root 'app.ico'
$InstallDir    = Join-Path $env:LOCALAPPDATA 'Programs\NetWatcher2.1'
$InstalledExe  = Join-Path $InstallDir 'NetWatcher.exe'
$ShortcutName  = 'IP监控2.1.lnk'
$RunKeyPath    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName  = 'NetWatcher2.1'
# 2.0 的注册表值名（只读检查用：本脚本绝不写它）
$LegacyRunValueName = 'NetWatcher'

$script:ExitCode = 0

function Write-Step([string]$Message) { Write-Host ">> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "   $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message)  { Write-Host "   $Message" -ForegroundColor Red }

# 读取 HKCU Run 里指定名字的值；不存在返回空字符串
function Get-RunValue([string]$Name) {
    try {
        $item = Get-ItemProperty -Path $RunKeyPath -ErrorAction Stop
        $prop = $item.PSObject.Properties[$Name]
        if ($null -ne $prop -and $null -ne $prop.Value) { return [string]$prop.Value }
    } catch { }
    return ''
}

# 写入 HKCU Run 里 2.1 自己的值；成功返回 $true
function Set-RunValue([string]$Value) {
    try {
        if (-not (Test-Path -Path $RunKeyPath)) {
            New-Item -Path $RunKeyPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value $Value -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# 调用 NetWatcher.exe 并等待退出（最多 TimeoutMs 毫秒）。
# 返回进程退出码；启动失败/超时返回 -1。
# 用 .NET Process 而不是 Start-Process -Wait：脚本内更可控，超时能兜底。
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

# 判断一个进程路径是否属于 2.1（仓库 bin 或 2.1 安装目录）
function Test-OurExe([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return $Path.Equals($BinExe, [System.StringComparison]::OrdinalIgnoreCase) -or
           $Path.Equals($InstalledExe, [System.StringComparison]::OrdinalIgnoreCase)
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  IP监控2.1（NetWatcher 2.1）安装' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

# ---- 0) 检查程序 ----
Write-Step '检查程序文件'
if (-not (Test-Path -LiteralPath $BinExe)) {
    Write-Err ("没有找到 {0}" -f $BinExe)
    Write-Warn '请把本脚本放在 2.1 目录（与 bin 文件夹同级），或先双击 2.1 目录下的 build.bat 重新编译。'
    exit 1
}
Write-Ok ("程序: {0}" -f $BinExe)

# 如果 exe 是从网页/聊天软件下载来的，会带 Mark-of-the-Web（下载标记），
# 双击时 Windows SmartScreen 可能弹「Windows 已保护你的电脑」。这里顺手解除锁定。
try {
    $zone = Get-Content -LiteralPath $BinExe -Stream Zone.Identifier -ErrorAction Stop
    if ($zone) {
        Unblock-File -LiteralPath $BinExe -ErrorAction Stop
        Write-Ok '已解除程序的"下载"标记（避免 SmartScreen 拦截）'
    }
} catch { }

# ---- 0.4) 只读检查：与 2.0 的关系（不修改 2.0 任何东西）----
Write-Step '检查与 2.0 的关系（只读，不修改 2.0）'
$legacyRun = Get-RunValue $LegacyRunValueName
if ($legacyRun) {
    Write-Warn ("检测到 2.0 的开机自启项仍存在: {0}" -f $legacyRun)
    Write-Warn '2.1 不会修改或删除它。若以后只想保留 2.1，请运行 2.0 目录下的 uninstall.ps1（默认保留数据），'
    Write-Warn '或在 2.0 的设置里关闭「开机自动启动」。'
} else {
    Write-Ok '没有检测到 2.0 的开机自启项（或 2.0 已卸载）'
}
# 只枚举进程、只读路径，不杀任何进程：提示用户先退出旧实例，避免两个版本同时写数据目录
$otherRunning = 0
$unknownRunning = 0
$ourRunning = 0
try {
    foreach ($proc in @(Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue)) {
        $procPath = ''
        try { $procPath = [string]$proc.Path } catch { $procPath = '' }
        if ([string]::IsNullOrEmpty($procPath)) { $unknownRunning++; continue }
        if (Test-OurExe $procPath) { $ourRunning++; continue }
        $otherRunning++
    }
} catch { }
if ($ourRunning -gt 0) {
    Write-Warn ("检测到 {0} 个 2.1 实例正在运行：请先退出 2.1（托盘右键「退出」）再安装，" -f $ourRunning)
    Write-Warn '否则安装目录里的 exe 可能被占用、替换失败。数据不会因此丢失。'
}
if ($otherRunning -gt 0) {
    Write-Warn ("检测到 {0} 个其它 NetWatcher 实例正在运行（可能是 2.0 或其它副本）。" -f $otherRunning)
    Write-Warn '2.1 与 2.0 共用数据目录 %APPDATA%\NetWatcher；启动 2.1 前请先在旧实例托盘右键「退出」，'
    Write-Warn '保证同一时间只有一个实例写数据（2.1 的单写锁只约束 2.1 自己）。'
} elseif ($unknownRunning -gt 0) {
    Write-Warn ("检测到 {0} 个 NetWatcher 进程（无法读取可执行路径，可能是管理员实例）。" -f $unknownRunning)
    Write-Warn '如果是 2.0，请先在它托盘右键「退出」再启动 2.1。'
} else {
    Write-Ok '没有检测到其它 NetWatcher 实例在运行'
}

# ---- 0.5) 复制到安装目录 ----
# 重要：从"受限目录"（例如被沙箱/安全软件管辖的目录、临时目录、网络盘）直接运行，
#       程序可能无法写 %APPDATA%，表现为"进程在、没数据、托盘异常"。
#       因此默认把程序复制到 %LOCALAPPDATA%\Programs\NetWatcher2.1 后再注册快捷方式/自启。
#       想保持"绿色版、原地运行"，加 -Portable。
if (-not $Portable) {
    Write-Step ("安装到: {0}" -f $InstallDir)
    try {
        New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $BinExe -Destination $InstalledExe -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $Icon) {
            Copy-Item -LiteralPath $Icon -Destination (Join-Path $InstallDir 'app.ico') -Force -ErrorAction Stop
        }
        $Exe  = $InstalledExe
        $Icon = Join-Path $InstallDir 'app.ico'
        Write-Ok '程序已复制到 2.1 安装目录（之后快捷方式/开机自启都指向这里）'
    } catch {
        Write-Warn ("复制到安装目录失败，将从原位置运行: {0}" -f $_.Exception.Message)
    }
} else {
    Write-Step '绿色模式（-Portable）：原地运行，不复制到 LOCALAPPDATA'
}

# ---- 1) 数据目录 ----
if ([string]::IsNullOrWhiteSpace($DataDir)) {
    $DataDir = Join-Path $env:APPDATA 'NetWatcher'
}
try { $DataDir = [System.IO.Path]::GetFullPath($DataDir) } catch { }
# 去掉末尾反斜杠（盘符根目录除外），避免拼进命令行时把引号转义掉
if ($DataDir.Length -gt 3 -and $DataDir.EndsWith('\')) { $DataDir = $DataDir.TrimEnd('\') }

Write-Step ("准备数据目录: {0}" -f $DataDir)
try {
    New-Item -ItemType Directory -Path $DataDir -Force -ErrorAction Stop | Out-Null
    Write-Ok '数据目录已就绪（已有数据不会被覆盖或删除）'
    Write-Ok '该目录与 2.0 共用：升级不需要迁移历史数据，但两个版本不能同时运行'
} catch {
    Write-Err ("创建数据目录失败: {0}" -f $_.Exception.Message)
    $script:ExitCode = 1
}

# ---- 2) 开机自启（HKCU Run，普通用户即可） ----
Write-Step '注册开机自启（HKCU 启动项，不需要管理员权限）'
$autostartOk = $false
$customDataDir = $PSBoundParameters.ContainsKey('DataDir')

if (Get-RunValue $RunValueName) {
    Write-Ok '检测到 2.1 已注册，将覆盖更新（幂等）。'
}

$invokeArgs = @('--autostart-on')
if ($customDataDir) { $invokeArgs += @('--datadir', $DataDir) }
$rc = Invoke-NetWatcher -Arguments $invokeArgs
$runValue = Get-RunValue $RunValueName

if ($rc -eq 0 -and $runValue) {
    $autostartOk = $true
    Write-Ok ("已由程序注册: {0}" -f $runValue)
} else {
    if ($rc -ne 0) {
        Write-Warn ("程序调用返回 {0}，改用安装脚本直接写入（与程序等价）。" -f $rc)
    } else {
        Write-Warn '程序返回成功但注册表里没有 2.1 的自启项，改用安装脚本直接写入（与程序等价）。'
    }
    $fallbackValue = '"' + $Exe + '" --background'
    if ($customDataDir) { $fallbackValue += ' --datadir "' + $DataDir + '"' }
    if (Set-RunValue $fallbackValue) {
        $autostartOk = $true
        Write-Ok ("已写入: {0}" -f $fallbackValue)
    } else {
        Write-Err '写入 HKCU 启动项 NetWatcher2.1 失败（可能被安全软件拦截），开机自启没有生效。'
        $script:ExitCode = 1
    }
}

# 自启值应指向当前 exe；如果指向旧路径（目录被移动过），修正。
if ($autostartOk) {
    $runValue = Get-RunValue $RunValueName
    if ($runValue -and $runValue.IndexOf($Exe, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $fixed = '"' + $Exe + '" --background'
        if ($customDataDir) { $fixed += ' --datadir "' + $DataDir + '"' }
        if (Set-RunValue $fixed) {
            Write-Ok ("自启项原指向旧路径，已修正为: {0}" -f $fixed)
        } else {
            Write-Warn '自启项路径修正失败，请检查 HKCU 注册表权限。'
        }
    } elseif ($customDataDir -and $runValue -and $runValue -notmatch '--datadir') {
        # 自定义数据目录：程序没把 --datadir 写进自启命令时由安装脚本补上。
        $appended = $runValue + ' --datadir "' + $DataDir + '"'
        if (Set-RunValue $appended) {
            Write-Ok ("已把 --datadir 写入自启命令: {0}" -f $appended)
        } else {
            Write-Warn '把 --datadir 写入自启命令失败，开机后将使用默认数据目录。'
        }
    }
}

# ---- 3) 桌面快捷方式 ----
if ($NoShortcut) {
    Write-Step '跳过桌面快捷方式（-NoShortcut）'
} else {
    Write-Step '创建桌面快捷方式'
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($desktop)) {
            throw '无法获取桌面路径'
        }
        $lnkPath = Join-Path $desktop $ShortcutName
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnkPath)
        $shortcut.TargetPath       = $Exe
        $shortcut.Arguments        = ''
        $shortcut.WorkingDirectory = Split-Path -Parent $Exe
        $shortcut.Description      = 'IP监控2.1 · 网络连接监控'
        if (Test-Path -LiteralPath $Icon) {
            $shortcut.IconLocation = $Icon + ',0'
        } else {
            $shortcut.IconLocation = $Exe + ',0'
        }
        $shortcut.Save()
        Write-Ok ("已创建/更新: {0}" -f $lnkPath)
        # 注意：2.1 不删除 2.0 的「IP监控.lnk」，也不清理 1.0 遗留的「NetWatcher.lnk」。
        #       桌面同时存在「IP监控」和「IP监控2.1」是预期行为（两个版本并列）。
        Write-Ok '未改动 2.0 的「IP监控.lnk」（2.1 只管理自己的快捷方式）'
    } catch {
        Write-Err ("创建快捷方式失败: {0}" -f $_.Exception.Message)
        $script:ExitCode = 1
    }
}

# ---- 完成 ----
Write-Host ''
if ($script:ExitCode -eq 0) {
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '  安装完成' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
} else {
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  安装完成，但有警告（见上面的红色提示）' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Yellow
}
Write-Host ("  程序：   {0}" -f $Exe)
Write-Host ("  数据：   {0}（与 2.0 共用）" -f $DataDir)
if ($autostartOk) { Write-Host '  开机自启：已开启（HKCU 值名 NetWatcher2.1；登录 Windows 后自动在后台运行）' } else { Write-Host '  开机自启：未生效' -ForegroundColor Yellow }
if ($NoShortcut) { Write-Host '  快捷方式：已跳过（-NoShortcut）' } else { Write-Host '  快捷方式：桌面「IP监控2.1」' }
Write-Host ''
Write-Host '  下一步：' -ForegroundColor Cyan
if ($NoShortcut) {
    Write-Host ("   · 双击 {0} 启动；关闭窗口会最小化到系统托盘。" -f $Exe)
} else {
    Write-Host '   · 双击桌面「IP监控2.1」启动；关闭窗口会最小化到系统托盘。'
}
Write-Host '   · 如果 2.0 还在运行，请先在 2.0 托盘右键「退出」，再启动 2.1（数据目录共用，只能有一个写入实例）。'
Write-Host '   · 如果启动时提示「数据目录已被另一个实例占用」，请先退出另一个 2.1 实例；'
Write-Host '     并行测试请给每个实例指定不同的 --datadir（2.1 不认识 2.0 的锁，建议升级前退出 2.0）。'
Write-Host '   · 普通权限下逐 IP 字节为「估算」；要尝试精确逐 IP 流量，请右键快捷方式'
Write-Host '     选「以管理员身份运行」，或在程序里点「以管理员身份重启」。'
Write-Host '   · 卸载：运行同目录的 uninstall.ps1（默认保留数据；加 -DeleteData 才删）。'
Write-Host ''
exit $script:ExitCode
