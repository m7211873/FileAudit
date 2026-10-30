# ============================================================
#  FileAudit 导出器
#  由计划任务以 SYSTEM 身份每 5 分钟运行一次：
#   1. 从「安全」日志读取文件访问审计事件(4663)，过滤后导出为 CSV
#   2. 导出防绕开事件(4719/4907/1102/4608/4616)到 tamper 目录
#   3. 每轮补回被移除的 SACL、覆盖新建目录（防绕开）
# ============================================================
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')

New-Item -ItemType Directory -Path $EventDir  -Force | Out-Null
New-Item -ItemType Directory -Path $TamperDir -Force | Out-Null

# 防重入：同一时刻只运行一个导出
$lock = Join-Path $StoreRoot '.export.lock'
if (Test-Path $lock) { exit }
Set-Content -Path $lock -Value '' -ErrorAction SilentlyContinue

try {
    # ---- 防绕开：每轮补回被移除的审计规则、覆盖新建目录 ----
    try {
        . (Join-Path $PSScriptRoot 'sacl.ps1')
        Add-FileAuditSacls
    } catch {
        Add-Content -Path $LogFile -Value ("{0} SACL 补全失败: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) -Encoding UTF8
    }

    $lastId = 0
    if (Test-Path $StateFile) {
        try { $lastId = [long](Get-Content $StateFile -Raw | ConvertFrom-Json).lastId } catch { $lastId = 0 }
    }

    # 首次运行：以当前最新事件为基准，只记录之后的（避免把历史全量导出）
    if ($lastId -le 0) {
        $newest = Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($newest) { $lastId = [long]$newest.RecordId }
    }

    # ---- 文件访问事件 4663 ----
    $xpath = "*[System[(EventID=4663) and (EventRecordID > $lastId)]]"
    try {
        $evts = Get-WinEvent -LogName Security -FilterXPath $xpath -ErrorAction Stop
    } catch {
        $evts = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4663 } -ErrorAction SilentlyContinue |
                Where-Object { [long]$_.RecordId -gt $lastId }
    }

    $rows  = New-Object System.Collections.Generic.List[object]
    $maxId = $lastId

    foreach ($e in $evts) {
        if ([long]$e.RecordId -gt $maxId) { $maxId = [long]$e.RecordId }
        $p = $e.Properties
        if ($p.Count -lt 12) { continue }
        $procName = [string]$p[11].Value
        $objName  = [string]$p[6].Value
        $accesses = [string]$p[8].Value
        $user     = [string]$p[1].Value
        $pidNum   = [string]$p[10].Value

        $skip = $false
        $leaf = [System.IO.Path]::GetFileName($procName)
        if ($ExcludeProcessNames -contains $leaf) { $skip = $true }
        if (-not $skip) {
            $pnl = $procName.ToLowerInvariant()
            foreach ($pre in $ExcludeProcessPrefixes) {
                if ($pnl.StartsWith($pre.ToLowerInvariant())) { $skip = $true; break }
            }
        }
        if (-not $skip) {
            $onl = $objName.ToLowerInvariant()
            foreach ($pre in $ExcludeObjectPrefixes) {
                if ($onl.StartsWith($pre.ToLowerInvariant())) { $skip = $true; break }
            }
        }
        if ($skip) { continue }

        $isDir = $false
        try { $isDir = (Test-Path -LiteralPath $objName -PathType Container) } catch {}
        $op = Get-Operation $accesses $isDir
        $accessesFriendly = Get-FriendlyAccesses $accesses

        $rows.Add([pscustomobject]@{
            Time      = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss.fff')
            RecordId  = $e.RecordId
            Process   = $procName
            Pid       = $pidNum
            User      = $user
            Operation = $op
            Accesses  = $accessesFriendly
            File      = $objName
        })
    }

    # 关联：把「创建」事件（记录在父目录）关联到同进程紧接着写出的具体新文件
    $createRows = @($rows | Where-Object { $_.Operation -eq 'Create' })
    if ($createRows.Count -gt 0) {
        $writeRows = @($rows | Where-Object { $_.Operation -eq 'Write' })
        $usedWrite = @{}
        foreach ($c in $createRows) {
            $cdir = ([string]$c.File).TrimEnd('\')
            $best = $null
            $bestDt = [double]::MaxValue
            foreach ($w in $writeRows) {
                if ($usedWrite.ContainsKey([string]$w.RecordId)) { continue }
                if ([string]$w.Process -ne [string]$c.Process) { continue }
                $parent = Split-Path -Parent ([string]$w.File)
                if (-not $parent) { continue }
                if ($parent.TrimEnd('\') -ne $cdir) { continue }
                $dt = [math]::Abs(([datetime]$w.Time - [datetime]$c.Time).TotalSeconds)
                if ($dt -gt 3) { continue }
                if ($dt -lt $bestDt) { $best = $w; $bestDt = $dt }
            }
            if ($best) {
                $c.File = [string]$best.File
                $usedWrite[[string]$best.RecordId] = $true
            }
        }
    }

    if ($rows.Count -gt 0) {
        $day = (Get-Date).ToString('yyyy-MM-dd')
        $csv = Join-Path $EventDir "$day.csv"
        $csvText = $rows | ConvertTo-Csv -NoTypeInformation
        if (-not (Test-Path $csv)) {
            [System.IO.File]::WriteAllLines($csv, $csvText, (New-Object System.Text.UTF8Encoding($true)))
        } else {
            $data = $csvText | Select-Object -Skip 1
            if ($data) { [System.IO.File]::AppendAllLines($csv, $data, (New-Object System.Text.UTF8Encoding($false))) }
        }
    }

    # ---- 防绕开事件（不过滤，全部记录）----
    $tamperXPath = "*[System[(EventID=4719 or EventID=4907 or EventID=1102 or EventID=4608 or EventID=4616) and (EventRecordID > $lastId)]]"
    try {
        $tevts = Get-WinEvent -LogName Security -FilterXPath $tamperXPath -ErrorAction Stop
    } catch {
        $tevts = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4719,4907,1102,4608,4616 } -ErrorAction SilentlyContinue |
                 Where-Object { [long]$_.RecordId -gt $lastId }
    }

    $trows = New-Object System.Collections.Generic.List[object]
    foreach ($e in $tevts) {
        if ([long]$e.RecordId -gt $maxId) { $maxId = [long]$e.RecordId }
        switch ($e.Id) {
            4719 { $desc = '系统审计策略被修改' }
            4907 { $desc = '对象审核设置(SACL)被修改' }
            1102 { $desc = '安全日志被清除' }
            4608 { $desc = 'Windows 安全状态启动/变更' }
            4616 { $desc = '系统时间被修改' }
            default { $desc = '其他安全事件' }
        }
        $msg = ($e.Message -replace "`r|`n", ' ')
        if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) }
        $trows.Add([pscustomobject]@{
            Time     = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss.fff')
            RecordId = $e.RecordId
            EventId  = $e.Id
            Event    = $desc
            Details  = $msg
        })
    }

    if ($trows.Count -gt 0) {
        $tday = (Get-Date).ToString('yyyy-MM-dd')
        $tcsv = Join-Path $TamperDir "tamper-$tday.csv"
        $tText = $trows | ConvertTo-Csv -NoTypeInformation
        if (-not (Test-Path $tcsv)) {
            [System.IO.File]::WriteAllLines($tcsv, $tText, (New-Object System.Text.UTF8Encoding($true)))
        } else {
            $td = $tText | Select-Object -Skip 1
            if ($td) { [System.IO.File]::AppendAllLines($tcsv, $td, (New-Object System.Text.UTF8Encoding($false))) }
        }
    }

    # 始终持久化水位线（含首次运行的基线），避免下次重复基线而漏事件
    @{ lastId = $maxId } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8

    Add-Content -Path $LogFile -Value ("{0} 文件事件 {1} 条, 防绕开事件 {2} 条, 水位线 {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $rows.Count, $trows.Count, $maxId) -Encoding UTF8
}
finally {
    Remove-Item -Path $lock -ErrorAction SilentlyContinue
}
