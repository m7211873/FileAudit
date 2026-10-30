# ============================================================
#  common.ps1 —— 事件权限码解析（4663 事件的 Accesses 字段用 %%NNNN 占位符）
#  供 export.ps1 与 view.ps1 共用
# ============================================================

$AccessMap = @{
    '%%1537' = 'DELETE'
    '%%1538' = 'READ_CONTROL'
    '%%1539' = 'WRITE_DAC'
    '%%1540' = 'WRITE_OWNER'
    '%%1541' = 'SYNCHRONIZE'
    '%%4416' = 'ReadData'
    '%%4417' = 'WriteData (or AddFile)'
    '%%4418' = 'AppendData (or AddSubdirectory)'
    '%%4419' = 'ReadEA'
    '%%4420' = 'WriteEA'
    '%%4421' = 'Execute/Traverse'
    '%%4422' = 'DeleteChild'
    '%%4423' = 'ReadAttributes'
    '%%4424' = 'WriteAttributes'
}

# 根据权限码归类：删除 > 创建 > 写入 > 读取 > 其他
#  IsDir = 目标对象是不是目录；当“目录 + 添加文件/子目录”时即判定为「创建」
function Get-Operation([string]$accesses, [bool]$IsDir = $false) {
    if (-not $accesses) { return 'Other' }
    if ($accesses -match '%%1537|%%4422') { return 'Delete' }
    if ($IsDir -and $accesses -match '%%4417|%%4418') { return 'Create' }
    if ($accesses -match '%%4417|%%4418|%%4420|%%4424|%%1539') { return 'Write' }
    if ($accesses -match '%%4416|%%4419|%%4421|%%4423|%%1538') { return 'Read' }
    return 'Other'
}

# 把 %%NNNN 权限码翻译成友好名
function Get-FriendlyAccesses([string]$accesses) {
    if (-not $accesses) { return '' }
    $codes = [regex]::Matches($accesses, '%%\d+') | ForEach-Object { $_.Value } | Select-Object -Unique
    if (-not $codes) { return $accesses }
    ($codes | ForEach-Object { if ($AccessMap.ContainsKey($_)) { $AccessMap[$_] } else { $_ } }) -join ', '
}
