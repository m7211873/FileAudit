#requires -Version 5.1
<#
.SYNOPSIS
    验证 NetWatcher（或任意 exe）的 Authenticode 签名：状态、签名者、证书链、是否已在可信发布者/根存储中。

.DESCRIPTION
    只用 Get-AuthenticodeSignature + X509Chain，不依赖 signtool / Windows SDK。
    退出码：
      0 = 签名 Valid 且证书已在 CurrentUser(或 LocalMachine) 的 Root 或 TrustedPublisher 中
      1 = 文件未签名 / 签名损坏
      2 = 签名 Valid，但本机未导入该自签名证书（别的机器上等同于“未知发布者”）

.PARAMETER Exe
    要检查的 exe 路径，默认 <仓库根>\bin\NetWatcher.exe。

.PARAMETER Thumbprint
    期望的签名证书指纹（可选）。给出后与签名者不一致时退出码为 3。

.EXAMPLE
    .\verify-sign.ps1
    .\verify-sign.ps1 -Exe .\test\NetWatcher-test.exe
#>
[CmdletBinding()]
param(
    [string]$Exe,
    [string]$Thumbprint
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($Exe)) { $Exe = Join-Path $repoRoot 'bin\NetWatcher.exe' }

if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    Write-Host "[verify] ERROR 找不到文件: $Exe" -ForegroundColor Red
    exit 1
}
$Exe = (Resolve-Path -LiteralPath $Exe).Path

function Has-Cert([string]$storePath, [string]$tp) {
    $hit = @(Get-ChildItem -LiteralPath $storePath -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $tp })
    return $hit.Count -gt 0
}

Write-Host "文件   : $Exe"
Write-Host ("SHA256 : " + (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash)
Write-Host ("大小   : " + (Get-Item -LiteralPath $Exe).Length + " 字节")
Write-Host ""

$sig = Get-AuthenticodeSignature -LiteralPath $Exe

Write-Host "----------------- 签名状态 -----------------"
Write-Host ("Status          : " + $sig.Status)
Write-Host ("StatusMessage   : " + $sig.StatusMessage)
Write-Host ("SignatureType   : " + $sig.SignatureType)
Write-Host ("IsOSBinary      : " + $sig.IsOSBinary)
Write-Host ("TimeStamper     : " + $(if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { '<无时间戳（自签名刻意跳过，见 sign.ps1 说明）>' }))
Write-Host ""

if ($sig.Status -eq 'NotSigned' -or $null -eq $sig.SignerCertificate) {
    Write-Host "[verify] 结果: 未签名或签名已损坏。" -ForegroundColor Red
    exit 1
}

$signer = $sig.SignerCertificate
$tp = $signer.Thumbprint

Write-Host "----------------- 签名证书 -----------------"
Write-Host ("Subject         : " + $signer.Subject)
Write-Host ("Issuer          : " + $signer.Issuer)
Write-Host ("Thumbprint      : " + $tp)
Write-Host ("SerialNumber    : " + $signer.SerialNumber)
Write-Host ("NotBefore       : " + $signer.NotBefore)
Write-Host ("NotAfter        : " + $signer.NotAfter)
Write-Host ("自签名(SelfSigned): " + ($signer.Subject -eq $signer.Issuer))
Write-Host ""

# 证书链（离线验证，不查吊销，避免无网时误报）
$chainOk = $false
try {
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag
    $chainOk = $chain.Build($signer)
    Write-Host "----------------- 证书链 -----------------"
    $i = 0
    foreach ($el in $chain.ChainElements) {
        $i++
        Write-Host ("[$i] " + $el.Certificate.Subject)
        Write-Host ("    Thumbprint: " + $el.Certificate.Thumbprint + "   NotAfter: " + $el.Certificate.NotAfter)
        foreach ($st in $el.ChainElementStatus) {
            Write-Host ("    Status: " + $st.Status + " - " + $st.StatusInformation)
        }
    }
    Write-Host ("Chain.Build     : " + $chainOk)
} catch {
    Write-Host ("[verify] 证书链构建异常: " + $_.Exception.Message) -ForegroundColor Yellow
}
Write-Host ""

Write-Host "----------------- 本机信任存储 -----------------"
$rootCU = Has-Cert 'Cert:\CurrentUser\Root' $tp
$pubCU = Has-Cert 'Cert:\CurrentUser\TrustedPublisher' $tp
$rootLM = Has-Cert 'Cert:\LocalMachine\Root' $tp
$pubLM = Has-Cert 'Cert:\LocalMachine\TrustedPublisher' $tp
Write-Host ("CurrentUser\Root            : " + $rootCU)
Write-Host ("CurrentUser\TrustedPublisher: " + $pubCU)
Write-Host ("LocalMachine\Root           : " + $rootLM)
Write-Host ("LocalMachine\TrustedPublisher: " + $pubLM)
Write-Host ""

if ($Thumbprint -and ($Thumbprint -ne $tp)) {
    Write-Host ("[verify] 结果: 签名者指纹与期望不符（期望 $Thumbprint）。") -ForegroundColor Red
    exit 3
}

if (-not ($rootCU -or $rootLM -or $pubCU -or $pubLM)) {
    Write-Host "[verify] 结果: 签名 Valid，但本机未导入该自签名证书。" -ForegroundColor Yellow
    Write-Host "         在本机也等同于“未知发布者”；把 NetWatcher.cer 导入 Root 与 TrustedPublisher 后即可。" -ForegroundColor Yellow
    exit 2
}

if ($sig.Status -eq 'Valid') {
    Write-Host "[verify] 结果: 签名 Valid，证书已被本机信任。" -ForegroundColor Green
    Write-Host "         注意：这只能保证“本机”不再显示未知发布者；SmartScreen / Smart App Control 仍按自己的规则判断。" -ForegroundColor Yellow
    exit 0
}

Write-Host ("[verify] 结果: 证书已在本机存储中，但签名状态为 " + $sig.Status + "。") -ForegroundColor Yellow
exit 2
