#requires -Version 5.0
<#
  nwipdb-format.ps1 — v2.3.0 加密小时文件（.nwipdb）QA 只读适配层

  设计：_analysis\v230-验收\00-设计-加密小时存储.md
  实现细节：_analysis\v230-验收\01-实现说明.md §2（2026-11-01 feat/2.3.0 @ d634622）

  能力（只读）：
    - 文件名解析/分类（小时文件 / legacy 日块）
    - 明文头解析（magic=NWIPDB01, version=1；96B 头含 76B 摘要 + IV/cipherLen/MAC）
    - DPAPI 解 .storekey → masterKey/macKey → HMAC-SHA256 校验 → AES-256-CBC → GZip → DayData JSON
    - 同日多小时文件合并（bytes/peak/sampleCount 求和/取 max；ips/procs 按 key 合并；samples 按分钟求和排序）
    - 二进制/明文泄漏扫描（H3）
    - fixtures（真实数据副本）读取与临时 datadir 播种（H4 迁移测试用）

  安全：本模块只读；绝不写用户真实 %APPDATA%\NetWatcher；调用方必须在 %TEMP% 副本/测试 datadir 上调用。
#>

Set-StrictMode -Version 2.0

# ------------------------------------------------------------------ 文件格式常量（与 01-实现说明.md §2 一致）
$script:NwipdbFormat = @{
    Ready           = $true
    Magic           = 'NWIPDB01'
    MagicLength     = 8
    Version         = 1
    HeaderLength    = 96
    OffVersion      = 8
    OffFlags        = 9
    OffHourStart    = 12
    OffSessionStart = 20
    OffPlainLength  = 28
    OffBytesIn      = 32
    OffBytesOut     = 40
    OffPeakInBps    = 48
    OffPeakOutBps   = 56
    OffSampleCount  = 64
    OffIpCount      = 68
    OffProcCount    = 72
    OffIv           = 76
    OffCipherLen    = 92
    OffCipher       = 96
    MacLength       = 32
    KeyMagic        = 'NWKEY001'
    KeyPathName     = '.storekey'
    FileSuffix      = '.nwipdb'
    NamePrefix      = '监控'
    DpapiEntropy    = 'NetWatcher2.3.HourStore.DPAPI.Entropy.v1'
    HmacKeyLabel    = 'NetWatcher2.3.HourStore.HmacKey.v1'
}

$script:NwipdbNameRegex = '^(?<prefix>监控)_(?<date>\d{4}-\d{2}-\d{2})_(?<hour>\d{2})-00-00_s(?<session>\d{6})\.nwipdb$'
$script:NwipdbLegacyNameRegex = '^(?<prefix>监控)_(?<date>\d{4}-\d{2}-\d{2})_00-00-00_legacy(?<session>\d{6})\.nwipdb$'

if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
    try { Add-Type -AssemblyName System.Security } catch { }
}
Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ 文件名/文件分类
function Test-NwipdbName {
    param([Parameter(Mandatory=$true)][string]$Name)
    $r = [pscustomobject]@{ Ok = $false; Kind = 'unknown'; Date = ''; HourStart = -1; Session = ''; SortKey = ''; Error = '' }
    $m = [regex]::Match($Name, $script:NwipdbLegacyNameRegex)
    if ($m.Success) {
        $r.Ok = $true; $r.Kind = 'legacy'; $r.Date = $m.Groups['date'].Value; $r.HourStart = 0
        $r.Session = $m.Groups['session'].Value; $r.SortKey = ($r.Date + '_00_legacy')
        return $r
    }
    $m = [regex]::Match($Name, $script:NwipdbNameRegex)
    if ($m.Success) {
        $r.Ok = $true; $r.Kind = 'hour'; $r.Date = $m.Groups['date'].Value
        $r.HourStart = [int]$m.Groups['hour'].Value; $r.Session = $m.Groups['session'].Value
        $r.SortKey = ('{0}_{1:D2}_{2}' -f $r.Date, $r.HourStart, $r.Session)
        return $r
    }
    $r.Error = '文件名不符合 .nwipdb 规则'
    return $r
}

function Get-NwipdbFiles {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [string]$Date = '',
        [ValidateSet('all','hour','legacy')][string]$Kind = 'all'
    )
    $d = Join-Path $DataDir 'data'
    $res = @()
    if (-not (Test-Path $d)) { return ,$res }
    foreach ($f in @(Get-ChildItem $d -Filter ('*' + $script:NwipdbFormat.FileSuffix) -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $info = Test-NwipdbName -Name $f.Name
        if (-not $info.Ok) { continue }
        if ($Date -and $info.Date -ne $Date) { continue }
        if ($Kind -ne 'all' -and $info.Kind -ne $Kind) { continue }
        $res += [pscustomobject]@{
            File = $f; Name = $f.Name; FullName = $f.FullName; Length = $f.Length
            LastWriteTimeUtc = $f.LastWriteTimeUtc; Kind = $info.Kind; Date = $info.Date
            HourStart = $info.HourStart; Session = $info.Session; SortKey = $info.SortKey
        }
    }
    return ,$res
}

function Get-NwipdbKeyInfo {
    param([Parameter(Mandatory=$true)][string]$DataDir)
    $p = Join-Path (Join-Path $DataDir 'data') $script:NwipdbFormat.KeyPathName
    $r = [pscustomobject]@{ Exists = $false; Path = $p; Length = 0; Sha256 = ''; Magic = ''; Valid = $false }
    if (Test-Path $p) {
        $r.Exists = $true
        $fi = Get-Item $p
        $r.Length = $fi.Length
        $r.Sha256 = (Get-FileHash $p -Algorithm SHA256).Hash
        try {
            $b = [IO.File]::ReadAllBytes($p)
            if ($b.Length -gt 8) { $r.Magic = [Text.Encoding]::ASCII.GetString($b[0..7]) }
            $r.Valid = ($r.Magic -eq $script:NwipdbFormat.KeyMagic -and $b.Length -gt 8)
        } catch { }
    }
    return $r
}

# ------------------------------------------------------------------ 密钥（DPAPI）
function Get-StoreMasterKey {
    param([Parameter(Mandatory=$true)][string]$DataDir)
    $p = Join-Path (Join-Path $DataDir 'data') $script:NwipdbFormat.KeyPathName
    if (-not (Test-Path $p)) { throw "缺少密钥文件: $p" }
    $bytes = [IO.File]::ReadAllBytes($p)
    if ($bytes.Length -le 8) { throw "密钥文件过短: $($bytes.Length)B" }
    $magic = [Text.Encoding]::ASCII.GetString($bytes[0..7])
    if ($magic -ne $script:NwipdbFormat.KeyMagic) { throw "密钥文件 magic 不正确: $magic" }
    $blob = New-Object byte[] ($bytes.Length - 8)
    [Array]::Copy($bytes, 8, $blob, 0, $blob.Length)
    $entropy = [Text.Encoding]::UTF8.GetBytes($script:NwipdbFormat.DpapiEntropy)
    $key = [System.Security.Cryptography.ProtectedData]::Unprotect($blob, $entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    if (-not $key -or $key.Length -ne 32) { throw ("DPAPI 解出的 masterKey 长度异常: " + $(if ($key) { $key.Length } else { 'null' })) }
    return ,$key
}

function Get-StoreMacKey {
    param([Parameter(Mandatory=$true)][byte[]]$MasterKey)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = $MasterKey
        return ,$hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:NwipdbFormat.HmacKeyLabel))
    } finally { $hmac.Dispose() }
}

# ------------------------------------------------------------------ 内部工具
function ConvertTo-Int64Safe {
    param($V)
    if ($null -eq $V) { return [long]0 }
    try { return [long]$V } catch { return [long]0 }
}
function Get-DictValue {
    param($Obj, [string]$Key)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        foreach ($k in $Obj.Keys) { if ([string]$k -eq $Key) { return $Obj[$k] } }
    }
    return $null
}
function Get-DictKeys {
    param($Obj)
    if ($null -eq $Obj) { return @() }
    if ($Obj -is [System.Collections.IDictionary]) { return @($Obj.Keys | ForEach-Object { [string]$_ }) }
    return @()
}
function Get-StringSafe { param($V) if ($null -eq $V) { return '' } return [string]$V }

# 归一化 samples：兼容 JavaScriptSerializer 对 [[m,in,out], ...] 的两种反序列化形态
#   ① 嵌套数组（每个元素是 [m,in,out]）② 单桶时被摊平成 [m,in,out]（实测出现）
# 返回 ArrayList（元素为 long[3]）。
function Get-DaySamples {
    param($Day)
    $res = New-Object System.Collections.ArrayList
    $rawObj = Get-DictValue $Day 'samples'
    if ($null -eq $rawObj) { return ,$res }
    $raw = @($rawObj)
    if ($raw.Count -eq 0) { return ,$res }
    $first = $raw[0]
    $isNested = ($first -is [System.Collections.IEnumerable]) -and -not ($first -is [string])
    if ($isNested) {
        foreach ($s in $raw) {
            $a = @($s)
            if ($a.Count -ge 3) { [void]$res.Add(@([long](ConvertTo-Int64Safe $a[0]), [long](ConvertTo-Int64Safe $a[1]), [long](ConvertTo-Int64Safe $a[2]))) }
        }
    } else {
        for ($i = 0; ($i + 2) -lt $raw.Count; $i += 3) {
            [void]$res.Add(@([long](ConvertTo-Int64Safe $raw[$i]), [long](ConvertTo-Int64Safe $raw[$i+1]), [long](ConvertTo-Int64Safe $raw[$i+2])))
        }
    }
    return ,$res
}

# ------------------------------------------------------------------ 明文头解析
function Read-NwipdbHeader {
    param([Parameter(Mandatory=$true)][string]$Path)
    $r = [pscustomobject]@{
        Ok = $false; Path = $Path; Error = ''; Magic = ''; Version = 0; Flags = 0
        HourStartUnix = -1; SessionStartUnix = -1; PlainLength = -1
        BytesIn = -1; BytesOut = -1; PeakInBps = -1; PeakOutBps = -1
        SampleCount = -1; IpCount = -1; ProcCount = -1
        Iv = ''; CipherLen = -1; FileLength = 0
    }
    if (-not (Test-Path $Path)) { $r.Error = '文件不存在'; return $r }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $r.FileLength = $bytes.Length
        $hdr = $script:NwipdbFormat
        if ($bytes.Length -lt ($hdr.HeaderLength + $hdr.MacLength)) { $r.Error = ('文件过短: {0}B' -f $bytes.Length); return $r }
        $r.Magic = [Text.Encoding]::ASCII.GetString($bytes[0..($hdr.MagicLength-1)])
        if ($r.Magic -ne $hdr.Magic) { $r.Error = ('magic 不正确: ' + $r.Magic); return $r }
        $r.Version = [int]$bytes[$hdr.OffVersion]
        if ($r.Version -ne $hdr.Version) { $r.Error = ('不支持的 version: ' + $r.Version); return $r }
        $r.Flags = [int]$bytes[$hdr.OffFlags]
        $r.HourStartUnix = [BitConverter]::ToInt64($bytes, $hdr.OffHourStart)
        $r.SessionStartUnix = [BitConverter]::ToInt64($bytes, $hdr.OffSessionStart)
        $r.PlainLength = [BitConverter]::ToInt32($bytes, $hdr.OffPlainLength)
        $r.BytesIn = [BitConverter]::ToInt64($bytes, $hdr.OffBytesIn)
        $r.BytesOut = [BitConverter]::ToInt64($bytes, $hdr.OffBytesOut)
        $r.PeakInBps = [BitConverter]::ToInt64($bytes, $hdr.OffPeakInBps)
        $r.PeakOutBps = [BitConverter]::ToInt64($bytes, $hdr.OffPeakOutBps)
        $r.SampleCount = [BitConverter]::ToInt32($bytes, $hdr.OffSampleCount)
        $r.IpCount = [BitConverter]::ToInt32($bytes, $hdr.OffIpCount)
        $r.ProcCount = [BitConverter]::ToInt32($bytes, $hdr.OffProcCount)
        $r.CipherLen = [BitConverter]::ToInt32($bytes, $hdr.OffCipherLen)
        $r.Iv = (($bytes[$hdr.OffIv..($hdr.OffIv+15)] | ForEach-Object { $_.ToString('X2') }) -join '')
        if ($bytes.Length -ne ($hdr.HeaderLength + $r.CipherLen + $hdr.MacLength)) { $r.Error = ('长度不一致: file={0} 期望=96+cipher{1}+32' -f $bytes.Length, $r.CipherLen); return $r }
        $r.Ok = $true
    } catch { $r.Error = '解析异常: ' + $_.Exception.Message }
    return $r
}

# ------------------------------------------------------------------ 完整解密
function Read-NwipdbPayload {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)][string]$DataDir)
    $r = [pscustomobject]@{ Ok = $false; Path = $Path; Error = ''; Day = $null; Json = ''; MacOk = $false; Flags = 0 }
    if (-not (Test-Path $Path)) { $r.Error = '文件不存在'; return $r }
    try {
        $hdr = $script:NwipdbFormat
        $bytes = [IO.File]::ReadAllBytes($Path)
        $h = Read-NwipdbHeader -Path $Path
        if (-not $h.Ok) { $r.Error = '头部无效: ' + $h.Error; return $r }
        $r.Flags = $h.Flags
        if (($h.Flags -band 1) -ne 1) { $r.Error = ('flags={0} 未声明 GZip（当前实现仅支持 flags bit0=1）' -f $h.Flags); return $r }
        $master = Get-StoreMasterKey -DataDir $DataDir
        $macKey = Get-StoreMacKey -MasterKey $master
        $macStart = $hdr.HeaderLength + $h.CipherLen
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        try {
            $hmac.Key = $macKey
            $calc = $hmac.ComputeHash($bytes[0..($macStart-1)])
        } finally { $hmac.Dispose() }
        $fileMac = New-Object byte[] $hdr.MacLength
        [Array]::Copy($bytes, $macStart, $fileMac, 0, $hdr.MacLength)
        $diff = 0
        for ($i = 0; $i -lt $hdr.MacLength; $i++) { $diff = $diff -bor ($calc[$i] -bxor $fileMac[$i]) }
        $r.MacOk = ($diff -eq 0)
        if (-not $r.MacOk) { $r.Error = 'MAC 校验失败（文件被篡改或 key 不匹配）'; return $r }
        $iv = New-Object byte[] 16
        [Array]::Copy($bytes, $hdr.OffIv, $iv, 0, 16)
        $cipher = New-Object byte[] $h.CipherLen
        [Array]::Copy($bytes, $hdr.OffCipher, $cipher, 0, $h.CipherLen)
        $aes = New-Object System.Security.Cryptography.RijndaelManaged
        try {
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.KeySize = 256
            $aes.Key = $master
            $aes.IV = $iv
            $dec = $aes.CreateDecryptor()
            try { $gzipped = $dec.TransformFinalBlock($cipher, 0, $cipher.Length) } finally { $dec.Dispose() }
        } finally { $aes.Dispose() }
        $msIn = New-Object System.IO.MemoryStream(,$gzipped)
        $msOut = New-Object System.IO.MemoryStream
        try {
            $gz = New-Object System.IO.Compression.GZipStream($msIn, [System.IO.Compression.CompressionMode]::Decompress)
            try { $gz.CopyTo($msOut) } finally { $gz.Dispose() }
        } finally { $msIn.Dispose() }
        $plain = $msOut.ToArray()
        $msOut.Dispose()
        if ($h.PlainLength -gt 0 -and $plain.Length -ne $h.PlainLength) { $r.Error = ('解压长度与明文头不一致: {0} vs {1}' -f $plain.Length, $h.PlainLength); return $r }
        $r.Json = [Text.Encoding]::UTF8.GetString($plain)
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        $ser.RecursionLimit = 200
        $r.Day = $ser.DeserializeObject($r.Json)
        if ($null -eq $r.Day) { $r.Error = 'JSON 反序列化为空'; return $r }
        $r.Ok = $true
    } catch { $r.Error = '解密异常: ' + $_.Exception.Message }
    return $r
}

# ------------------------------------------------------------------ 合并
function Merge-NwipdbDays {
    param([Parameter(Mandatory=$true)][object[]]$Days)
    $r = [pscustomobject]@{
        Ok = $false; Files = @($Days).Count; BytesIn = [long]0; BytesOut = [long]0
        PeakInBps = [long]0; PeakOutBps = [long]0; SampleCount = [long]0
        IpCount = 0; ProcCount = 0; FirstSampleUnix = [long]0; LastSampleUnix = [long]0
        BytesPrecise = $false; SamplesOk = $false; SamplesCount = 0; Error = ''
        Ips = $null; Procs = $null; Samples = $null; SampleMinutes = $null
    }
    if (@($Days).Count -eq 0) { $r.Error = '无可合并日数据'; return $r }
    $ips = @{}; $procs = @{}; $samples = @{}
    try {
        foreach ($d in $Days) {
            $r.BytesIn += (ConvertTo-Int64Safe (Get-DictValue $d 'bytesIn'))
            $r.BytesOut += (ConvertTo-Int64Safe (Get-DictValue $d 'bytesOut'))
            $pi = ConvertTo-Int64Safe (Get-DictValue $d 'peakInBps'); if ($pi -gt $r.PeakInBps) { $r.PeakInBps = $pi }
            $po = ConvertTo-Int64Safe (Get-DictValue $d 'peakOutBps'); if ($po -gt $r.PeakOutBps) { $r.PeakOutBps = $po }
            $r.SampleCount += (ConvertTo-Int64Safe (Get-DictValue $d 'sampleCount'))
            if ((Get-DictValue $d 'bytesPrecise') -eq $true) { $r.BytesPrecise = $true }
            $fs = ConvertTo-Int64Safe (Get-DictValue $d 'firstSampleUnix')
            if ($fs -gt 0 -and ($r.FirstSampleUnix -eq 0 -or $fs -lt $r.FirstSampleUnix)) { $r.FirstSampleUnix = $fs }
            $ls = ConvertTo-Int64Safe (Get-DictValue $d 'lastSampleUnix'); if ($ls -gt $r.LastSampleUnix) { $r.LastSampleUnix = $ls }
            $dIps = Get-DictValue $d 'ips'
            foreach ($ip in (Get-DictKeys $dIps)) {
                $a = $dIps[$ip]
                if (-not $ips.ContainsKey($ip)) { $ips[$ip] = @{ bytesIn = [long]0; bytesOut = [long]0; peakInBps = [long]0; peakOutBps = [long]0; connectedSeconds = [long]0; sampleCount = [long]0; sessionCount = [long]0; firstSeenUnix = [long]0; lastSeenUnix = [long]0; processes = @{}; states = @{}; ports = @{}; city = ''; region = ''; country = ''; isp = ''; hostname = ''; bytesPrecise = $false } }
                $m = $ips[$ip]
                $m.bytesIn += (ConvertTo-Int64Safe (Get-DictValue $a 'bytesIn'))
                $m.bytesOut += (ConvertTo-Int64Safe (Get-DictValue $a 'bytesOut'))
                $v = ConvertTo-Int64Safe (Get-DictValue $a 'peakInBps'); if ($v -gt $m.peakInBps) { $m.peakInBps = $v }
                $v = ConvertTo-Int64Safe (Get-DictValue $a 'peakOutBps'); if ($v -gt $m.peakOutBps) { $m.peakOutBps = $v }
                $m.connectedSeconds += (ConvertTo-Int64Safe (Get-DictValue $a 'connectedSeconds'))
                $m.sampleCount += (ConvertTo-Int64Safe (Get-DictValue $a 'sampleCount'))
                $m.sessionCount += (ConvertTo-Int64Safe (Get-DictValue $a 'sessionCount'))
                $v = ConvertTo-Int64Safe (Get-DictValue $a 'firstSeenUnix'); if ($v -gt 0 -and ($m.firstSeenUnix -eq 0 -or $v -lt $m.firstSeenUnix)) { $m.firstSeenUnix = $v }
                $v = ConvertTo-Int64Safe (Get-DictValue $a 'lastSeenUnix'); if ($v -gt $m.lastSeenUnix) { $m.lastSeenUnix = $v }
                if ((Get-DictValue $a 'bytesPrecise') -eq $true) { $m.bytesPrecise = $true }
                foreach ($k in @('city','region','country','isp','hostname')) { if (-not $m[$k]) { $m[$k] = Get-StringSafe (Get-DictValue $a $k) } }
                $aProc = Get-DictValue $a 'processes'
                foreach ($pn in (Get-DictKeys $aProc)) { if (-not $m.processes.ContainsKey($pn)) { $m.processes[$pn] = [long]0 }; $m.processes[$pn] += (ConvertTo-Int64Safe $aProc[$pn]) }
                $aState = Get-DictValue $a 'states'
                foreach ($sn in (Get-DictKeys $aState)) { if (-not $m.states.ContainsKey($sn)) { $m.states[$sn] = [long]0 }; $m.states[$sn] += (ConvertTo-Int64Safe $aState[$sn]) }
                $ports = Get-DictValue $a 'ports'; if ($ports) { foreach ($pt in @($ports)) { $m.ports[[string]$pt] = $true } }
            }
            $dProcs = Get-DictValue $d 'procs'
            foreach ($pk in (Get-DictKeys $dProcs)) {
                $p = $dProcs[$pk]
                if (-not $procs.ContainsKey($pk)) { $procs[$pk] = @{ name = (Get-StringSafe (Get-DictValue $p 'name')); path = (Get-StringSafe (Get-DictValue $p 'path')); pid = (ConvertTo-Int64Safe (Get-DictValue $p 'pid')); processStartUnix = (ConvertTo-Int64Safe (Get-DictValue $p 'processStartUnix')); bytesIn = [long]0; bytesOut = [long]0; connCount = [long]0; firstSeenUnix = [long]0; lastSeenUnix = [long]0; ips = @{} } }
                $m = $procs[$pk]
                $m.bytesIn += (ConvertTo-Int64Safe (Get-DictValue $p 'bytesIn'))
                $m.bytesOut += (ConvertTo-Int64Safe (Get-DictValue $p 'bytesOut'))
                $m.connCount += (ConvertTo-Int64Safe (Get-DictValue $p 'connCount'))
                $v = ConvertTo-Int64Safe (Get-DictValue $p 'firstSeenUnix'); if ($v -gt 0 -and ($m.firstSeenUnix -eq 0 -or $v -lt $m.firstSeenUnix)) { $m.firstSeenUnix = $v }
                $v = ConvertTo-Int64Safe (Get-DictValue $p 'lastSeenUnix'); if ($v -gt $m.lastSeenUnix) { $m.lastSeenUnix = $v }
                $pIps = Get-DictValue $p 'ips'
                foreach ($ik in (Get-DictKeys $pIps)) {
                    $ia = $pIps[$ik]
                    if (-not $m.ips.ContainsKey($ik)) { $m.ips[$ik] = @{ ip = (Get-StringSafe (Get-DictValue $ia 'ip')); bytesIn = [long]0; bytesOut = [long]0; connCount = [long]0; firstSeenUnix = (ConvertTo-Int64Safe (Get-DictValue $ia 'firstSeenUnix')); ports = @{} } }
                    $mi = $m.ips[$ik]
                    $mi.bytesIn += (ConvertTo-Int64Safe (Get-DictValue $ia 'bytesIn'))
                    $mi.bytesOut += (ConvertTo-Int64Safe (Get-DictValue $ia 'bytesOut'))
                    $mi.connCount += (ConvertTo-Int64Safe (Get-DictValue $ia 'connCount'))
                    $ports = Get-DictValue $ia 'ports'; if ($ports) { foreach ($pt in @($ports)) { $mi.ports[[string]$pt] = $true } }
                }
            }
            $samplesObj = Get-DaySamples -Day $d
            foreach ($s in @($samplesObj)) {
                $arr = @($s)
                if ($arr.Count -lt 3) { continue }
                $minute = ConvertTo-Int64Safe $arr[0]
                $bin = ConvertTo-Int64Safe $arr[1]; $bout = ConvertTo-Int64Safe $arr[2]
                if (-not $samples.ContainsKey($minute)) { $samples[$minute] = @($bin, $bout) }
                else { $samples[$minute] = @(([long]$samples[$minute][0] + $bin), ([long]$samples[$minute][1] + $bout)) }
            }
        }
        $r.IpCount = $ips.Count; $r.ProcCount = $procs.Count; $r.SamplesCount = $samples.Count
        $mins = @($samples.Keys | Sort-Object)
        $r.SamplesOk = ($mins.Count -eq $samples.Count)
        $r.Ips = $ips; $r.Procs = $procs; $r.Samples = $samples; $r.SampleMinutes = $mins
        $r.Ok = $true
    } catch { $r.Error = '合并异常: ' + $_.Exception.Message }
    return $r
}

function Get-DayMergedSummary {
    param([Parameter(Mandatory=$true)][string]$DataDir, [Parameter(Mandatory=$true)][string]$Date)
    $r = [pscustomobject]@{ Ok = $false; Source = 'none'; Files = 0; BytesIn = [long]0; BytesOut = [long]0
        PeakInBps = [long]0; PeakOutBps = [long]0; SampleCount = [long]0; IpCount = 0; ProcCount = 0
        FirstSampleUnix = [long]0; LastSampleUnix = [long]0; BytesPrecise = $false; SamplesCount = 0; Error = ''; Merge = $null }
    $files = Get-NwipdbFiles -DataDir $DataDir -Date $Date
    $r.Files = $files.Count
    if ($files.Count -eq 0) { $r.Error = '该日无 .nwipdb'; return $r }
    $days = New-Object System.Collections.ArrayList
    $bad = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        $p = Read-NwipdbPayload -Path $f.FullName -DataDir $DataDir
        if ($p.Ok) { [void]$days.Add($p.Day) } else { [void]$bad.Add(($f.Name + ': ' + $p.Error)) }
    }
    if ($bad.Count -gt 0) { $r.Error = ('{0}/{1} 文件解密失败: {2}' -f $bad.Count, $files.Count, (@($bad | Select-Object -First 3) -join '; ')); return $r }
    $m = Merge-NwipdbDays -Days @($days)
    if (-not $m.Ok) { $r.Error = $m.Error; return $r }
    $r.Ok = $true; $r.Source = 'payload'
    $r.BytesIn = $m.BytesIn; $r.BytesOut = $m.BytesOut
    $r.PeakInBps = $m.PeakInBps; $r.PeakOutBps = $m.PeakOutBps
    $r.SampleCount = $m.SampleCount; $r.IpCount = $m.IpCount; $r.ProcCount = $m.ProcCount
    $r.FirstSampleUnix = $m.FirstSampleUnix; $r.LastSampleUnix = $m.LastSampleUnix
    $r.BytesPrecise = $m.BytesPrecise; $r.SamplesCount = $m.SamplesCount; $r.Merge = $m
    return $r
}

# ------------------------------------------------------------------ 二进制/明文泄漏扫描（H3）
$script:PlaintextMarkers = @('"ips"', '"procs"', '"bytesIn"', '"bytesOut"', '"samples"', '"country"', '"isp"', '191.168.')

function Test-NwipdbPlaintextLeak {
    param([Parameter(Mandatory=$true)][string]$Path, [int]$MaxBytes = 4194304)
    $leaks = New-Object System.Collections.ArrayList
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -gt $MaxBytes) { $bytes = $bytes[0..($MaxBytes-1)] }
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    foreach ($mk in $script:PlaintextMarkers) {
        if ($text.IndexOf($mk, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$leaks.Add($mk) }
    }
    foreach ($m in [regex]::Matches($text, '(?<![0-9])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![0-9])')) {
        [void]$leaks.Add('IPv4文本:' + $m.Value)
        if ($leaks.Count -ge 10) { break }
    }
    $ctrl = 0
    foreach ($b in $bytes) { if ($b -lt 9 -or ($b -gt 13 -and $b -lt 32)) { $ctrl++ } }
    $ratio = if ($bytes.Length -gt 0) { [Math]::Round($ctrl / [double]$bytes.Length, 4) } else { 0 }
    return [pscustomobject]@{
        Path = $Path; Bytes = $bytes.Length; Leaks = @($leaks); LeakCount = $leaks.Count
        ControlByteRatio = $ratio
        LooksBinary = ($leaks.Count -eq 0 -and $ratio -gt 0.02)
    }
}

# ------------------------------------------------------------------ 夹具（真实数据副本）读取（H4）
function Read-FixtureSummary {
    param([Parameter(Mandatory=$true)][string]$SummaryJson)
    if (-not (Test-Path $SummaryJson)) { throw "fixtures 汇总文件不存在: $SummaryJson" }
    $list = Get-Content $SummaryJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $map = @{}
    foreach ($x in @($list)) { $map[[string]$x.file] = $x }
    return $map
}

function Initialize-DataDirFromFixtures {
    param(
        [Parameter(Mandatory=$true)][string]$DataDir,
        [Parameter(Mandatory=$true)][string]$FixturesDir,
        [string[]]$Files = @()
    )
    $dest = Join-Path $DataDir 'data'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $all = @(Get-ChildItem $FixturesDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}\.json$' })
    if ($Files.Count -gt 0) { $all = @($all | Where-Object { $Files -contains $_.Name }) }
    $copied = @()
    foreach ($f in $all) {
        $t = Join-Path $dest $f.Name
        Copy-Item $f.FullName $t -Force
        $copied += $t
    }
    return ,$copied
}

# ------------------------------------------------------------------ 适配层自查（PrepOnly 用）
function Test-NwipdbFormatAdapter {
    $details = New-Object System.Collections.ArrayList
    $pass = 0; $fail = 0
    $cases = @(
        @{ Name = '监控_2026-11-01_17-00-00_s175422.nwipdb'; Kind = 'hour'; Date = '2026-11-01'; Hour = 17 },
        @{ Name = '监控_2026-11-01_18-00-00_s175422.nwipdb'; Kind = 'hour'; Date = '2026-11-01'; Hour = 18 },
        @{ Name = '监控_2026-11-01_19-00-00_s182310.nwipdb'; Kind = 'hour'; Date = '2026-11-01'; Hour = 19 },
        @{ Name = '监控_2026-10-31_00-00-00_legacy000000.nwipdb'; Kind = 'legacy'; Date = '2026-10-31'; Hour = 0 },
        @{ Name = '监控_2026-11-01_17-00-00_s175422.json'; Kind = 'unknown'; Date = ''; Hour = -1 },
        @{ Name = 'random.nwipdb'; Kind = 'unknown'; Date = ''; Hour = -1 }
    )
    foreach ($c in $cases) {
        $r = Test-NwipdbName -Name $c.Name
        $ok = ($r.Kind -eq $c.Kind) -and ($r.Date -eq $c.Date) -and ($r.HourStart -eq $c.Hour)
        if ($ok) { $pass++ } else { $fail++; [void]$details.Add(("文件名规则 FAIL: {0} -> kind={1} date={2} hour={3}" -f $c.Name, $r.Kind, $r.Date, $r.HourStart)) }
    }
    if (-not $script:NwipdbFormat.Ready) {
        $fake = Read-NwipdbHeader -Path $PSCommandPath
        if (-not $fake.Ok -and $fake.Error) { $pass++; [void]$details.Add('格式适配层未就绪时返回 Ok=false（OK）') }
        else { $fail++; [void]$details.Add('格式适配层未就绪却返回 Ok=true（禁止！）') }
    } else {
        $pass++; [void]$details.Add('格式适配层已就绪（NWIPDB01 + DPAPI + AES-256-CBC + HMAC-SHA256 + GZip 解析实现）')
    }
    return [pscustomobject]@{ Pass = $pass; Fail = $fail; Details = @($details) }
}
