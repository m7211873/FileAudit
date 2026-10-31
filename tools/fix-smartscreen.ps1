param(
    [string]$Exe = 'C:\Users\m7211\Documents\deepseek-harness\default-workspace\NetWatcher\bin\NetWatcher.exe'
)
# ============================================================
#  SmartScreen 排查/修复小工具
#  用法: powershell -NoProfile -ExecutionPolicy Bypass -File tools\fix-smartscreen.ps1
#        powershell ... -File tools\fix-smartscreen.ps1 -Exe "C:\路径\NetWatcher.exe"
# ============================================================
$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $Exe)) { Write-Host "找不到文件: $Exe" -ForegroundColor Red; exit 1 }

Write-Host "文件: $Exe" -ForegroundColor Cyan
$item = Get-Item -LiteralPath $Exe
Write-Host ("  大小: {0} 字节   修改时间: {1}" -f $item.Length, $item.LastWriteTime)

# ---- 1) Mark-of-the-Web（下载标记）----
$zone = $null
try { $zone = Get-Content -LiteralPath $Exe -Stream Zone.Identifier -ErrorAction Stop } catch { }
if ($zone) {
    Write-Host "  [问题] 存在 Mark-of-the-Web（文件来自网络/下载）:" -ForegroundColor Yellow
    $zone | ForEach-Object { Write-Host "         $_" }
    try {
        Unblock-File -LiteralPath $Exe -ErrorAction Stop
        Write-Host "  [已修复] 已解除锁定（Unblock-File）" -ForegroundColor Green
    } catch {
        Write-Host ("  [失败] 解除锁定失败: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
} else {
    Write-Host "  [OK] 没有 Mark-of-the-Web（不是"下载文件"）" -ForegroundColor Green
}

# ---- 2) 数字签名 ----
$sig = Get-AuthenticodeSignature -LiteralPath $Exe
Write-Host ("  签名状态: {0}  ({1})" -f $sig.Status, $sig.StatusMessage)
if ($sig.SignerCertificate) {
    Write-Host ("  签名者: {0}" -f $sig.SignerCertificate.Subject)
    Write-Host ("  指纹:   {0}" -f $sig.SignerCertificate.Thumbprint)
}

# ---- 3) SmartScreen 相关设置（只读展示）----
Write-Host ""
Write-Host "SmartScreen 设置（仅供参考，修改需你自己决定）:" -ForegroundColor Cyan
$keys = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'SmartScreenEnabled' },
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'SmartScreenEnabled' },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableSmartScreen' },
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost'; Name = 'EnableWebContentEvaluation' }
)
foreach ($k in $keys) {
    $v = (Get-ItemProperty -Path $k.Path -Name $k.Name -ErrorAction SilentlyContinue).$($k.Name)
    if ($null -eq $v) { Write-Host ("  {0}\{1} = <未设置>" -f $k.Path, $k.Name) }
    else { Write-Host ("  {0}\{1} = {2}" -f $k.Path, $k.Name, $v) }
}

Write-Host ""
Write-Host "如果双击仍然弹出「Windows 已保护你的电脑」：" -ForegroundColor Yellow
Write-Host "  1) 点「更多信息」→「仍要运行」（仅本次有效）"
Write-Host "  2) 确认双击的是本地这个 exe，而不是从网页/聊天软件下载的副本"
Write-Host "  3) 要在所有机器上彻底消失：需要购买受信任的代码签名证书（见 tools\sign\README.md）"
Write-Host "  4) 只是自己机器用：可在「Windows 安全中心 → 应用和浏览器控制 → 基于声誉的保护」里关闭"
Write-Host "     '检查应用和文件'（会降低防护，自行权衡）"
