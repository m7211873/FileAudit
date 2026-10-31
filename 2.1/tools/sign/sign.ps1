#requires -Version 5.1
<#
.SYNOPSIS
    NetWatcher 自签名流水线：创建/复用自签名代码签名证书 -> 签名 exe -> 导入本机受信任存储 -> 导出 .cer/.pfx。

.DESCRIPTION
    本脚本只用 Windows 自带的 PowerShell(PKI/Security 模块) 与 .NET Framework，
    不依赖 signtool.exe，也不要求安装 Windows SDK。
    用 CurrentUser 存储，因此不需要管理员权限（在 UAC 过滤令牌下也能跑）。

    ⚠ 自签名的边界（务必先读 tools\sign\README.md）：
      - 本机（导入了 .cer 的机器）可以消除“未知发布者”，Get-AuthenticodeSignature 为 Valid；
      - 别人的机器默认不信任你的自签名根证书，仍然会提示风险；
      - 对 Microsoft Defender SmartScreen 与 Smart App Control 没有帮助（自签 == 未签名）；
      - 第三方杀软（如火绒 HipsDaemon）仍可能有自己的规则。
      要“别人机器也不报警”，只能走受信任 CA（OV/EV）或 Azure Artifact Signing / SignPath 等途径。

.PARAMETER Exe
    要签名的 exe 路径，默认 <仓库根>\bin\NetWatcher.exe。

.PARAMETER Subject
    证书主题，默认 CN=NSYBdeDFY NetWatcher。

.PARAMETER PfxPath
    导出的 pfx 路径，默认 tools\sign\out\NetWatcher.pfx。

.PARAMETER PfxPassword
    pfx 密码（明文）。不传则在交互式终端里提示输入；非交互环境会随机生成并打印。

.PARAMETER InstallTrusted
    是否把证书导入 CurrentUser\Root 和 CurrentUser\TrustedPublisher，默认 $true。
    设为 $false 只签名、不动本机信任存储。

.PARAMETER ExportDir
    .cer/.pfx 输出目录，默认 tools\sign\out。

.PARAMETER ForceNew
    即使已有可用的同名证书也重新创建（换证书会导致“发布者身份”变化，慎用）。

.EXAMPLE
    .\sign.ps1
    .\sign.ps1 -Exe ..\..\bin\NetWatcher.exe -InstallTrusted $false
    .\sign.ps1 -PfxPath D:\keys\NetWatcher.pfx -PfxPassword 'my-pass'
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [string]$Subject = 'CN=NSYBdeDFY NetWatcher',
    [string]$PfxPath,
    [string]$PfxPassword,
    [bool]$InstallTrusted = $true,
    [string]$ExportDir,
    [switch]$ForceNew
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------- 路径解析 ----------
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($Exe)) { $Exe = Join-Path $repoRoot 'bin\NetWatcher.exe' }
if ([string]::IsNullOrWhiteSpace($ExportDir)) { $ExportDir = Join-Path $PSScriptRoot 'out' }
if ([string]::IsNullOrWhiteSpace($PfxPath)) { $PfxPath = Join-Path $ExportDir 'NetWatcher.pfx' }

function Write-Step([string]$msg) { Write-Host "[sign] $msg" }
function Write-Ok([string]$msg) { Write-Host "[sign] OK  $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "[sign] !!  $msg" -ForegroundColor Yellow }

function Stop-WithError([string]$msg) {
    Write-Host "[sign] ERROR $msg" -ForegroundColor Red
    exit 1
}

# ---------- 0. 前置检查 ----------
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    Stop-WithError "找不到要签名的文件: $Exe"
}
$Exe = (Resolve-Path -LiteralPath $Exe).Path
if (-not (Test-Path -LiteralPath $ExportDir)) {
    New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath (Split-Path -Parent $PfxPath))) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $PfxPath) -Force | Out-Null
}

# 文件被占用时 Set-AuthenticodeSignature 会报错，提前给明确提示
try {
    $fs = [System.IO.File]::Open($Exe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $fs.Close()
} catch {
    Stop-WithError "文件被占用（先关闭正在运行的 NetWatcher / 等构建结束）: $Exe"
}

Write-Step "目标文件 : $Exe"
Write-Step "证书主题 : $Subject"
Write-Step "输出目录 : $ExportDir"

# ---------- 1. 复用或创建证书 ----------
function Test-CertExportable([System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert) {
    $probe = Join-Path $env:TEMP ('nw-pfx-probe-' + [guid]::NewGuid().ToString('N') + '.pfx')
    try {
        $sec = ConvertTo-SecureString -String 'probe' -AsPlainText -Force
        Export-PfxCertificate -Cert $Cert -FilePath $probe -Password $sec -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

$cert = $null
if (-not $ForceNew) {
    $candidates = @(Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Subject -and $_.HasPrivateKey })
    foreach ($c in $candidates) {
        if (Test-CertExportable $c) { $cert = $c; break }
    }
    if ($cert) {
        Write-Ok "复用已有证书: $($cert.Thumbprint) (到期 $($cert.NotAfter.ToString('yyyy-MM-dd')))"
    } else {
        Write-Step "CurrentUser\My 中没有可复用的可导出代码签名证书，将新建"
    }
}

if (-not $cert) {
    try {
        $cert = New-SelfSignedCertificate -Type CodeSigningCert `
            -Subject $Subject `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyUsage DigitalSignature `
            -KeyUsageProperty Sign `
            -KeyExportPolicy Exportable `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3') `
            -KeyLength 2048 `
            -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddYears(3) `
            -ErrorAction Stop
        Write-Ok "新建证书: $($cert.Thumbprint) (到期 $($cert.NotAfter.ToString('yyyy-MM-dd')))"
    } catch {
        Stop-WithError "New-SelfSignedCertificate 失败: $($_.Exception.Message)"
    }
}

# 重新取一次，确保拿到带私钥的证书对象（New-SelfSignedCertificate 返回的对象有时不带 PrivateKey 句柄）
$cert = Get-Item -LiteralPath ("Cert:\CurrentUser\My\" + $cert.Thumbprint)
if (-not $cert.HasPrivateKey) { Stop-WithError "证书 $($cert.Thumbprint) 不包含私钥" }

# ---------- 2. 时间戳：自签名刻意跳过 ----------
# 公共时间戳服务器（RFC3161）只证明“这个签名发生在某个时刻”，用于证书过期后仍能验证旧签名。
# 自签名证书的信任完全来自“目标机器手工导入了这个根证书/发布者证书”，
# 时间戳既不能让它变成受信任根，也不会让别的机器少一次警告；同时会引入公网依赖
# （离线/内网构建直接失败），部分 TSA 也会拒绝对自签证书的时间戳请求。
# 因此这里不做时间戳；如果将来换成 OV/EV/云签名，请务必用 signtool /tr <TSA> 加时间戳。

# ---------- 3. 导入受信任存储（CurrentUser，无需管理员） ----------
$cerPath = Join-Path $ExportDir 'NetWatcher.cer'
Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT -ErrorAction Stop | Out-Null
Write-Ok "已导出公钥证书: $cerPath"

$storePath = 'Cert:\CurrentUser\Root'
$publisherPath = 'Cert:\CurrentUser\TrustedPublisher'
$trusted = @{ Root = $false; TrustedPublisher = $false }

if ($InstallTrusted) {
    foreach ($pair in @(@{ Path = $storePath; Name = 'Root' }, @{ Path = $publisherPath; Name = 'TrustedPublisher' })) {
        $exists = @(Get-ChildItem -LiteralPath $pair.Path -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $cert.Thumbprint }).Count -gt 0
        if ($exists) {
            Write-Ok "证书已在 $($pair.Path)（跳过导入）"
            $trusted[$pair.Name] = $true
            continue
        }
        try {
            Import-Certificate -FilePath $cerPath -CertStoreLocation $pair.Path -ErrorAction Stop | Out-Null
            Write-Ok "证书已导入 $($pair.Path)"
            $trusted[$pair.Name] = $true
        } catch {
            Write-Warn "导入 $($pair.Path) 失败: $($_.Exception.Message)"
        }
    }
} else {
    Write-Warn "已按 -InstallTrusted `$false 跳过导入本机信任存储（本机验证会是 UnknownError）"
}

# ---------- 4. 签名 ----------
Write-Step "正在签名（Set-AuthenticodeSignature，SHA256）..."
try {
    $sig = Set-AuthenticodeSignature -FilePath $Exe -Certificate $cert -HashAlgorithm SHA256 -ErrorAction Stop
} catch {
    Stop-WithError "签名失败: $($_.Exception.Message)"
}
if ($null -eq $sig -or $sig.Status -eq 'NotSigned') {
    Stop-WithError "签名没有生效，请检查文件权限/证书私钥"
}

# ---------- 5. 验证 ----------
$verify = Get-AuthenticodeSignature -LiteralPath $Exe
Write-Host ""
Write-Host "---------------- Get-AuthenticodeSignature ----------------"
Write-Host ("Path          : " + $verify.Path)
Write-Host ("Status        : " + $verify.Status)
Write-Host ("StatusMessage : " + $verify.StatusMessage)
if ($verify.SignerCertificate) {
    Write-Host ("Signer        : " + $verify.SignerCertificate.Subject)
    Write-Host ("Thumbprint    : " + $verify.SignerCertificate.Thumbprint)
    Write-Host ("NotAfter      : " + $verify.SignerCertificate.NotAfter)
} else {
    Write-Host "Signer        : <无>"
}
Write-Host ("IsOSBinary    : " + $verify.IsOSBinary)
Write-Host "-----------------------------------------------------------"
Write-Host ""

if ($verify.Status -ne 'Valid' -and $InstallTrusted) {
    Write-Warn "签名状态不是 Valid（$($verify.Status)）。若刚导入根证书，可重新运行 verify-sign.ps1 确认。"
}

# ---------- 6. 导出 .pfx ----------
if (-not $PfxPassword) {
    if ([Environment]::UserInteractive) {
        Write-Step "请输入要写入 $PfxPath 的 pfx 密码（留空则随机生成）："
        $secure = Read-Host -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $PfxPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $PfxPassword) {
        $bytes = New-Object byte[] 18
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $PfxPassword = [Convert]::ToBase64String($bytes)
        Write-Warn "非交互模式：已随机生成 pfx 密码，请立即保存：$PfxPassword"
    }
}

$pwdSecure = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
try {
    Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $pwdSecure -ErrorAction Stop | Out-Null
    Write-Ok "已导出带私钥的 pfx: $PfxPath"
} catch {
    Write-Warn "pfx 导出失败（可能是私钥不可导出）: $($_.Exception.Message)"
}

# ---------- 7. 总结 ----------
$hash = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash
Write-Host ""
Write-Host "==================== 结果 ===================="
Write-Host ("签名文件      : " + $Exe)
Write-Host ("SHA256        : " + $hash)
Write-Host ("签名状态      : " + $verify.Status)
Write-Host ("证书指纹      : " + $cert.Thumbprint)
Write-Host ("证书主题      : " + $cert.Subject)
Write-Host ("有效期至      : " + $cert.NotAfter)
Write-Host ("公钥证书(.cer): " + $cerPath)
Write-Host ("带私钥(.pfx)  : " + $PfxPath)
Write-Host ("本机 Root     : " + $trusted['Root'])
Write-Host ("本机 TrustedPublisher : " + $trusted['TrustedPublisher'])
Write-Host ""
Write-Host "别的机器需要做（每台一次，当前用户即可，无需管理员）："
Write-Host ("  1) 把 NetWatcher.cer 拷过去")
Write-Host ("  2) Import-Certificate -FilePath .\NetWatcher.cer -CertStoreLocation Cert:\CurrentUser\Root")
Write-Host ("  3) Import-Certificate -FilePath .\NetWatcher.cer -CertStoreLocation Cert:\CurrentUser\TrustedPublisher")
Write-Host "  或者管理员一次性部署到本机所有用户："
Write-Host ("     Import-Certificate -FilePath .\NetWatcher.cer -CertStoreLocation Cert:\LocalMachine\Root")
Write-Host ("     Import-Certificate -FilePath .\NetWatcher.cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher")
Write-Host "  证书不导入 = 别的机器依然提示“未知发布者”，且 SmartScreen/Smart App Control 照旧拦截。"
Write-Host "=============================================="

if ($verify.Status -eq 'Valid') { exit 0 } else { exit 2 }
