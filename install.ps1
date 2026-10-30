# ============================================================
#  FileAudit 安装脚本 —— 必须以管理员身份运行
#  功能：
#   1. 启用「文件系统」成功审计 + 防绕开审计（策略更改/安全状态更改）
#   2. 对 C:/D: 数据目录设置 SACL（排除 Windows 与 Steam）
#   3. 加大「安全」日志并允许按需覆盖
#   4. 生成 config.ps1（含 Steam 游戏库路径）
#   5. 注册计划任务 FileAuditExport（SYSTEM，每 5 分钟导出 + 补审计规则）
#   6. 创建桌面快捷方式（查看 / 安装）
# ============================================================
$ErrorActionPreference = 'Stop'

# ---- 1) 确保提权 ----
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '需要管理员权限，正在请求提权...' -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath)
    exit
}

$StoreRoot = 'D:\FileAudit'
New-Item -ItemType Directory -Path $StoreRoot -Force | Out-Null

# ---- 2) 启用审计子类别（GUID，跨语言通用）----
Write-Host '>> 启用审计子类别...' -ForegroundColor Cyan
$subs = @(
    @{ Name = 'File System (文件系统)';         Guid = '{0CCE921D-69AE-11D9-BED3-505054503030}' },
    @{ Name = 'Audit Policy Change (策略更改)';  Guid = '{0CCE9213-69AE-11D9-BED3-505054503030}' },
    @{ Name = 'Security State Change (安全状态)'; Guid = '{0CCE9210-69AE-11D9-BED3-505054503030}' }
)
foreach ($s in $subs) {
    auditpol /set /subcategory:$($s.Guid) /success:enable | Out-Null
    Write-Host ("   已启用: {0}" -f $s.Name)
}

# ---- 3) 设置/补全 SACL（幂等，供安装与后续每轮防绕开复用）----
Write-Host '>> 设置目录审计(SACL)...' -ForegroundColor Cyan
. (Join-Path $PSScriptRoot 'sacl.ps1')
Add-FileAuditSacls

# ---- 4) 发现 Steam 游戏库 ----
$steamPaths = New-Object System.Collections.Generic.List[string]
foreach ($vf in 'C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf','C:\Program Files (x86)\Steam\config\libraryfolders.vdf') {
    if (Test-Path $vf) {
        $ms = [regex]::Matches((Get-Content $vf -Raw), '"path"\s+"([^"]+)"')
        foreach ($m in $ms) { $steamPaths.Add(($m.Groups[1].Value -replace '\\\\','\')) }
    }
}
$steamPaths = @($steamPaths | Select-Object -Unique)
if (-not $steamPaths) { $steamPaths = @('C:\Program Files (x86)\Steam','D:\SteamLibrary') }
Write-Host "   检测到 Steam 路径: $($steamPaths -join ' | ')"

# ---- 5) 生成 config.ps1 ----
$prefixes = @("'C:\Windows\'") + ($steamPaths | ForEach-Object { "'" + ($_.TrimEnd('\')) + "\'" })
$objPrefixes = $prefixes + @("'D:\FileAudit\'")

$config = @"
# ============================================================
#  FileAudit 共享配置（由 install.ps1 生成，可手工修改后生效）
# ============================================================

`$StoreRoot = 'D:\FileAudit'
`$EventDir  = Join-Path `$StoreRoot 'events'
`$TamperDir = Join-Path `$StoreRoot 'tamper'
`$StateFile = Join-Path `$StoreRoot 'state.json'
`$LogFile   = Join-Path `$StoreRoot 'export.log'

# 排除「进程」（完整路径前缀，不区分大小写）
`$ExcludeProcessPrefixes = @(
    $($prefixes -join ",`n    ")
)

# 排除「进程」（按可执行文件名）
`$ExcludeProcessNames = @(
    '', 'System', 'Idle', 'Registry', 'Memory Compression',
    'MsMpEng.exe', 'MsSense.exe', 'MpCmdRun.exe', 'NisSrv.exe',
    'SecurityHealthService.exe', 'SecurityHealthSystray.exe',
    'SearchIndexer.exe', 'SearchProtocolHost.exe', 'SearchFilterHost.exe'
)

# 排除「对象路径」
`$ExcludeObjectPrefixes = @(
    $($objPrefixes -join ",`n    ")
)
"@
[System.IO.File]::WriteAllText((Join-Path $StoreRoot 'config.ps1'), $config, (New-Object System.Text.UTF8Encoding($true)))
Write-Host '   已生成 config.ps1'

# ---- 6) 加大安全日志并允许按需覆盖 ----
Write-Host '>> 调整安全日志大小(256MB, 按需覆盖)...' -ForegroundColor Cyan
wevtutil sl Security /ms:268435456 /ret:false | Out-Null

# ---- 7) 创建报告输出目录（不锁定权限，避免误伤自己）----
Write-Host '>> 创建报告输出目录...' -ForegroundColor Cyan
$reportDir = Join-Path $StoreRoot 'reports'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

# ---- 8) 注册计划任务 ----
Write-Host '>> 注册计划任务 FileAuditExport(每 5 分钟)...' -ForegroundColor Cyan
schtasks /Create /F /TN 'FileAuditExport' /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\FileAudit\export.ps1"' | Out-Null

# ---- 9) 立即导出一次（含补审计规则）----
Write-Host '>> 立即导出一次...' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$StoreRoot\export.ps1"

# ---- 10) 创建桌面快捷方式 ----
Write-Host '>> 创建桌面快捷方式...' -ForegroundColor Cyan
try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $ws = New-Object -ComObject WScript.Shell
    $mk = {
        param($name, $target, $desc)
        $lnk = Join-Path $desktop $name
        $s = $ws.CreateShortcut($lnk)
        $s.TargetPath = $target
        $s.WorkingDirectory = $StoreRoot
        $s.Description = $desc
        $icoPath = Join-Path $StoreRoot 'assets\fish.ico'
        if (Test-Path $icoPath) { $s.IconLocation = "$icoPath,0" }
        $s.Save()
    }
    & $mk '文件监控·查看.lnk' "$StoreRoot\view.cmd" '打开文件访问记录查看器'
    & $mk '文件监控·安装.lnk' "$StoreRoot\install.cmd" '安装/修复 FileAudit（需管理员）'
    Write-Host '   已在桌面创建: 文件监控·查看 / 文件监控·安装'
} catch {
    Write-Host ("   创建快捷方式失败: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host ' 安装完成！' -ForegroundColor Green
Write-Host '  · 记录持续写入 D:\FileAudit\events\*.csv' -ForegroundColor Green
Write-Host '  · 防绕开事件写入 D:\FileAudit\tamper\*.csv' -ForegroundColor Green
Write-Host '  · 双击 D:\FileAudit\view.cmd 查看记录' -ForegroundColor Green
Write-Host '  · 详见 D:\FileAudit\使用说明.md' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
