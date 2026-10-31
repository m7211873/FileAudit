# ============================================================
#  IP监控2.0（NetWatcher）安装脚本
#  纯系统自带组件（PowerShell + WScript.Shell），无需管理员权限。
#
#  做三件事（可重复执行，幂等）：
#   1) 创建数据目录（默认 %APPDATA%\NetWatcher，可用 -DataDir 指定）
#   2) 调用 NetWatcher.exe --autostart-on 写入 HKCU 开机自启项
#   3) 在桌面创建「IP监控」快捷方式（目标 bin\NetWatcher.exe）
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -NoShortcut
#    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -DataDir "D:\NetWatcherData"
#
#  卸载：运行 uninstall.ps1（加 -DeleteData 才会删除数据目录）
# ============================================================
param(
    [switch]$NoShortcut,
    [string]$DataDir = ''
)

# 注意：这里不使用 $ErrorActionPreference='Stop'。
# Windows PowerShell 5.1 下，外部程序（git/pwsh 等）把提示写到 stderr 时，
# 配合 'Stop' 会被当成 NativeCommandError 抛出并中断脚本。
# 本脚本逐步骤判断、显式给出中文提示，不依赖全局异常设置。
$ErrorActionPreference = 'Continue'

$Root         = $PSScriptRoot
$Exe          = Join-Path $Root 'bin\NetWatcher.exe'
$Icon         = Join-Path $Root 'app.ico'
$ShortcutName = 'IP监控.lnk'
$RunKeyPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'NetWatcher'

$script:ExitCode = 0

function Write-Step([string]$Message) { Write-Host ">> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "   $Message" -ForegroundColor Yellow }
function Write-Err([string]$Message)  { Write-Host "   $Message" -ForegroundColor Red }

# 读取 HKCU Run 里本程序的自启值；不存在返回空字符串
function Get-RunValue {
    try {
        $item = Get-ItemProperty -Path $RunKeyPath -ErrorAction Stop
        $prop = $item.PSObject.Properties[$RunValueName]
        if ($null -ne $prop -and $null -ne $prop.Value) { return [string]$prop.Value }
    } catch { }
    return ''
}

# 写入 HKCU Run；成功返回 $true
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

# 读取快捷方式的目标路径（用于识别 1.0 遗留的桌面快捷方式）
function Get-ShortcutTarget([string]$LnkPath) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($LnkPath)
        return [string]$sc.TargetPath
    } catch {
        return ''
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

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  IP监控2.0（NetWatcher）安装' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

# ---- 0) 检查程序 ----
Write-Step '检查程序文件'
if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Err ("没有找到 {0}" -f $Exe)
    Write-Warn '请把本脚本放在项目根目录（与 bin 文件夹同级），或先双击 build.bat 重新编译。'
    exit 1
}
Write-Ok ("程序: {0}" -f $Exe)

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
} catch {
    Write-Err ("创建数据目录失败: {0}" -f $_.Exception.Message)
    $script:ExitCode = 1
}

# ---- 2) 开机自启（HKCU Run，普通用户即可） ----
Write-Step '注册开机自启（HKCU 启动项，不需要管理员权限）'
$autostartOk = $false
$customDataDir = $PSBoundParameters.ContainsKey('DataDir')

if (Get-RunValue) {
    Write-Ok '检测到已注册，将覆盖更新（幂等）。'
}

$invokeArgs = @('--autostart-on')
if ($customDataDir) { $invokeArgs += @('--datadir', $DataDir) }
$rc = Invoke-NetWatcher -Arguments $invokeArgs
$runValue = Get-RunValue

if ($rc -eq 0 -and $runValue) {
    $autostartOk = $true
    Write-Ok ("已由程序注册: {0}" -f $runValue)
} else {
    if ($rc -ne 0) {
        Write-Warn ("程序调用返回 {0}，改用安装脚本直接写入（与程序等价）。" -f $rc)
    } else {
        Write-Warn '程序返回成功但注册表里没有自启项，改用安装脚本直接写入（与程序等价）。'
    }
    $fallbackValue = '"' + $Exe + '" --background'
    if ($customDataDir) { $fallbackValue += ' --datadir "' + $DataDir + '"' }
    if (Set-RunValue $fallbackValue) {
        $autostartOk = $true
        Write-Ok ("已写入: {0}" -f $fallbackValue)
    } else {
        Write-Err '写入 HKCU 启动项失败（可能被安全软件拦截），开机自启没有生效。'
        $script:ExitCode = 1
    }
}

# 自启值应指向当前 exe；如果指向旧路径（项目被移动过），修正。
if ($autostartOk) {
    $runValue = Get-RunValue
    if ($runValue -and $runValue.IndexOf($Exe, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        $fixed = '"' + $Exe + '" --background'
        if ($customDataDir) { $fixed += ' --datadir "' + $DataDir + '"' }
        if (Set-RunValue $fixed) {
            Write-Ok ("自启项原指向旧路径，已修正为: {0}" -f $fixed)
        } else {
            Write-Warn '自启项路径修正失败，请以管理员身份检查注册表。'
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
        $shortcut.WorkingDirectory = $Root
        $shortcut.Description      = 'IP监控2.0 · 网络连接监控'
        if (Test-Path -LiteralPath $Icon) {
            $shortcut.IconLocation = $Icon + ',0'
        } else {
            $shortcut.IconLocation = $Exe + ',0'
        }
        $shortcut.Save()
        Write-Ok ("已创建: {0}" -f $lnkPath)
        # 1.0 的旧快捷方式「NetWatcher.lnk」指向同一个 bin\NetWatcher.exe，安装 2.0 时一并清理。
        $legacyLnk = Join-Path $desktop 'NetWatcher.lnk'
        if (Test-Path -LiteralPath $legacyLnk) {
            $legacyTarget = Get-ShortcutTarget $legacyLnk
            $isOurLegacy = $false
            if ([string]::IsNullOrEmpty($legacyTarget)) { $isOurLegacy = $true }
            elseif ($legacyTarget.Equals($Exe, [System.StringComparison]::OrdinalIgnoreCase)) { $isOurLegacy = $true }
            elseif ($legacyTarget.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) { $isOurLegacy = $true }
            if ($isOurLegacy) {
                try {
                    Remove-Item -LiteralPath $legacyLnk -Force -ErrorAction Stop
                    Write-Ok '已删除 1.0 遗留的桌面快捷方式「NetWatcher.lnk」'
                } catch {
                    Write-Warn ("旧版快捷方式「NetWatcher.lnk」删除失败，可手工删除: {0}" -f $_.Exception.Message)
                }
            } else {
                Write-Warn ("桌面有同名「NetWatcher.lnk」但不指向本程序，未删除: {0}" -f $legacyTarget)
            }
        }
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
Write-Host ("  数据：   {0}" -f $DataDir)
if ($autostartOk) { Write-Host '  开机自启：已开启（登录 Windows 后自动在后台运行）' } else { Write-Host '  开机自启：未生效' -ForegroundColor Yellow }
if ($NoShortcut) { Write-Host '  快捷方式：已跳过（-NoShortcut）' } else { Write-Host '  快捷方式：桌面「IP监控」' }
Write-Host ''
Write-Host '  下一步：' -ForegroundColor Cyan
if ($NoShortcut) {
    Write-Host ("   · 双击 {0} 启动；关闭窗口会最小化到系统托盘。" -f $Exe)
} else {
    Write-Host '   · 双击桌面「IP监控」启动；关闭窗口会最小化到系统托盘。'
}
Write-Host '   · 普通权限下逐 IP 字节为「估算」；要精确逐 IP 流量，请右键快捷方式'
Write-Host '     选「以管理员身份运行」，或在程序里点「以管理员身份重启」。'
Write-Host '   · 卸载：运行 uninstall.ps1（不会删除数据；加 -DeleteData 才删）。'
Write-Host ''
exit $script:ExitCode
