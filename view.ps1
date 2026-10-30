# ============================================================
#  FileAudit 查看器（图形界面）
#  生成一个自包含的 HTML 报告并在浏览器中打开：
#    · 顶部汇总栏：进程数 / 时间范围 / 总条数 / 报告路径 / 防绕开时间
#    · 按应用程序分组，可展开/折叠
#    · 每条/每组/全部 都可一键复制
#  用法：
#    .\view.ps1                 # 生成并打开图形界面（默认）
#    .\view.ps1 -Html 路径      # 指定输出路径
#    .\view.ps1 -NoOpen         # 只生成不打开
#    .\view.ps1 -Console        # 纯文本表格（后备）
#    .\view.ps1 -Process xxx -Path yyy -Operation Read -Since 2026-10-30
#    .\view.ps1 -Open "D:\x.txt"  # 在资源管理器中定位文件
# ============================================================
param(
    [string]$Process,
    [string]$Path,
    [ValidateSet('All','Read','Write','Create','Delete','Other')]$Operation = 'All',
    [string]$Since,
    [string]$Until,
    [int]$Top = 0,
    [string]$Html,
    [switch]$NoOpen,
    [switch]$Console,
    [string]$Open
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'config.ps1')
. (Join-Path $PSScriptRoot 'common.ps1')

# 直达定位：在资源管理器中选中该文件
if ($Open) {
    if (Test-Path $Open) { Start-Process explorer.exe -ArgumentList "/select,`"$Open`"" }
    else { Write-Host "文件不存在: $Open" -ForegroundColor Yellow }
    return
}

$files = Get-ChildItem -Path $EventDir -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $files) {
    Write-Host "暂无记录（$EventDir 为空）。请先安装并等待产生文件操作。" -ForegroundColor Yellow
    return
}

$rows = foreach ($f in $files) { try { Import-Csv $f.FullName } catch {} }
if (-not $rows) { Write-Host "没有读取到任何记录。" -ForegroundColor Yellow; return }

# 规范化：老数据若带 %% 权限码，翻译成友好名并重新归类
foreach ($r in $rows) {
    if ($r.Accesses -match '%%') {
        if ($r.Operation -eq 'Other') {
            $isDir = $false
            try { $isDir = (Test-Path -LiteralPath $r.File -PathType Container) } catch {}
            $r.Operation = Get-Operation $r.Accesses $isDir
        }
        $r.Accesses = Get-FriendlyAccesses $r.Accesses
    }
}

# 预过滤
if ($Since)    { $d0 = [datetime]$Since; $rows = $rows | Where-Object { [datetime]$_.Time -ge $d0 } }
if ($Until)    { $d1 = [datetime]$Until; $rows = $rows | Where-Object { [datetime]$_.Time -le $d1 } }
if ($Operation -ne 'All') { $rows = $rows | Where-Object { $_.Operation -eq $Operation } }
if ($Process)  { $rows = $rows | Where-Object { $_.Process -like "*$Process*" } }
if ($Path)     { $rows = $rows | Where-Object { $_.File -like "*$Path*" } }
$rows = @($rows | Sort-Object Time -Descending)
if ($Top -gt 0) { $rows = @($rows | Select-Object -First $Top) }
if (-not $rows) { Write-Host "没有符合条件的记录。" -ForegroundColor Yellow; return }

# 纯文本后备
if ($Console) {
    $rows | Select-Object Time, Operation, Process, Pid, File | Format-Table -AutoSize -Wrap
    Write-Host ("共 {0} 条。" -f $rows.Count)
    return
}

# ---- 汇总信息 ----
$total     = $rows.Count
$groups    = @($rows | Group-Object Process | Sort-Object Count -Descending)
$procCount = $groups.Count
$tmin      = $rows[-1].Time
$tmax      = $rows[0].Time

$tamperRows = foreach ($f in (Get-ChildItem $TamperDir -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object Name)) { try { Import-Csv $f.FullName } catch {} }
$tamperRows = @($tamperRows | Sort-Object Time -Descending)
$tamperCount = $tamperRows.Count
$tamperLatest = if ($tamperCount -gt 0) { $tamperRows[0].Time } else { '无' }

$htmlPath = if ($Html) { $Html } else { Join-Path (Join-Path $StoreRoot 'reports') 'report.html' }
$htmlDir  = Split-Path -Parent $htmlPath
New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null

$opCn    = @{ Read='读取'; Write='写入'; Create='创建'; Delete='删除'; Other='其他' }
$opClass = @{ Read='op-read'; Write='op-write'; Create='op-create'; Delete='op-del'; Other='op-other' }
$esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }

$CSS = @'
*{box-sizing:border-box}
body{margin:0;font-family:"Segoe UI","Microsoft YaHei",sans-serif;font-size:14px;background:#f5f6f8;color:#222}
.topbar{position:sticky;top:0;background:#1f2430;color:#eef;padding:12px 16px;z-index:10;box-shadow:0 2px 8px rgba(0,0,0,.3)}
.tb-title{font-size:18px;font-weight:700;margin-bottom:8px}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:10px}
.chip{background:#2a3040;border:1px solid #3a4256;border-radius:6px;padding:4px 10px;font-size:12px;white-space:nowrap}
.chip b{color:#ffd166;font-weight:600}
.chip .mono{font-family:Consolas,monospace;font-weight:400;color:#9fc}
.filters{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
.filters input{flex:1;min-width:160px;padding:7px 10px;border:1px solid #3a4256;border-radius:6px;background:#141821;color:#eef;font-size:13px}
.filters select{padding:7px 10px;border:1px solid #3a4256;border-radius:6px;background:#141821;color:#eef;font-size:13px}
.filters button{padding:7px 12px;border:1px solid #3a4256;border-radius:6px;background:#2a3040;color:#eef;cursor:pointer;font-size:13px}
.filters button:hover{background:#3a4256}
.sub{font-size:12px;color:#aab;margin-top:8px}
.sub b{color:#ffd166}
main{padding:14px 16px;max-width:1200px;margin:0 auto}
details.group{background:#fff;border:1px solid #ddd;border-radius:8px;margin-bottom:12px;overflow:hidden}
details.group>summary{display:flex;align-items:center;gap:10px;padding:10px 14px;cursor:pointer;list-style:none;background:#fafbfc}
details.group>summary::-webkit-details-marker{display:none}
details.group>summary:hover{background:#f0f2f5}
summary .proc{font-weight:700;font-size:14px;color:#0b57d0}
summary .path{font-family:Consolas,monospace;font-size:12px;color:#666;flex:1;word-break:break-all}
summary .cnt{background:#e8f0fe;color:#0b57d0;border-radius:10px;padding:2px 10px;font-size:12px;font-weight:600}
summary .legend{font-size:12px;color:#666;white-space:nowrap}
summary .legend .op-read{color:#0b57d0}
summary .legend .op-write{color:#b45309}
summary .legend .op-create{color:#15803d}
summary .legend .op-del{color:#c62828}
button.copy{padding:4px 10px;border:1px solid #ccc;border-radius:6px;background:#fff;color:#333;cursor:pointer;font-size:12px}
button.copy:hover{background:#eef;border-color:#0b57d0;color:#0b57d0}
table{width:100%;border-collapse:collapse}
th{background:#f5f6f8;text-align:left;padding:6px 10px;font-size:12px;color:#555;border-bottom:1px solid #e5e7eb}
td{padding:6px 10px;border-bottom:1px solid #f0f1f3;font-size:13px;vertical-align:top}
td.time{white-space:nowrap;font-family:Consolas,monospace;color:#555;font-size:12px}
td.op{white-space:nowrap}
td.file{word-break:break-all}
td.file a{color:#0b57d0;text-decoration:none}
td.file a:hover{text-decoration:underline}
td.acc{color:#777;font-size:12px;white-space:nowrap}
td.btn{white-space:nowrap}
.op-read{color:#0b57d0;font-weight:600}
.op-write{color:#b45309;font-weight:600}
.op-create{color:#15803d;font-weight:600}
.op-del{color:#c62828;font-weight:600}
.op-other{color:#777;font-weight:600}
details.tamper>summary .proc{color:#c62828}
.empty{padding:14px;color:#888}
.foot{padding:12px 16px;text-align:center;color:#999;font-size:12px}
#toast{position:fixed;bottom:30px;left:50%;transform:translateX(-50%);background:#1f2430;color:#fff;padding:8px 18px;border-radius:20px;font-size:13px;display:none;z-index:99}
'@

$JS = @'
function fallbackCopy(t){
  var ta=document.createElement('textarea');
  ta.value=t; ta.style.position='fixed'; ta.style.top='-9999px'; ta.style.left='-9999px';
  document.body.appendChild(ta); ta.focus(); ta.select();
  try{ document.execCommand('copy'); }catch(e){}
  document.body.removeChild(ta);
}
function doCopy(t){
  if(navigator.clipboard && navigator.clipboard.writeText){
    navigator.clipboard.writeText(t).catch(function(){ fallbackCopy(t); });
  } else { fallbackCopy(t); }
  toast('已复制');
}
function copyRow(btn){ var tr=btn.closest('tr'); doCopy(tr.dataset.copy); }
function copyGroup(btn){
  var g=btn.closest('details'); var lines=[];
  g.querySelectorAll('.row').forEach(function(r){ lines.push(r.dataset.copy); });
  doCopy(lines.join('\n'));
}
function copyAll(){
  var lines=[]; document.querySelectorAll('.row').forEach(function(r){ lines.push(r.dataset.copy); });
  doCopy(lines.join('\n'));
}
function setAll(open){ document.querySelectorAll('details.group').forEach(function(d){ d.open=open; }); }
function applyFilter(){
  var p=(document.getElementById('fProc').value||'').toLowerCase();
  var f=(document.getElementById('fPath').value||'').toLowerCase();
  var op=document.getElementById('fOp').value;
  var shown=0;
  document.querySelectorAll('details.group').forEach(function(g){
    var gshow=false;
    g.querySelectorAll('.row').forEach(function(r){
      var m=(!p||r.dataset.proc.toLowerCase().indexOf(p)>=0)
         &&(!f||r.dataset.file.toLowerCase().indexOf(f)>=0)
         &&(!op||r.dataset.op===op);
      r.style.display=m?'':'none';
      if(m){ gshow=true; shown++; }
    });
    g.style.display=gshow?'':'none';
  });
  document.getElementById('cnt').textContent=shown;
}
function toast(m){
  var t=document.getElementById('toast');
  if(!t){ t=document.createElement('div'); t.id='toast'; document.body.appendChild(t); }
  t.textContent=m; t.style.display='block';
  clearTimeout(t._h); t._h=setTimeout(function(){ t.style.display='none'; },1200);
}
'@

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">')
[void]$sb.AppendLine('<title>文件访问记录 · FileAudit</title>')
[void]$sb.AppendLine('<style>')
[void]$sb.AppendLine($CSS)
[void]$sb.AppendLine('</style>')
[void]$sb.AppendLine('</head><body>')

# 顶部汇总栏
[void]$sb.AppendLine('<div class="topbar">')
[void]$sb.AppendLine('  <div class="tb-title">📁 文件访问记录</div>')
[void]$sb.AppendLine('  <div class="chips">')
[void]$sb.AppendLine(('    <span class="chip">总条数 <b>{0}</b></span>' -f $total))
[void]$sb.AppendLine(('    <span class="chip">进程数 <b>{0}</b></span>' -f $procCount))
[void]$sb.AppendLine(('    <span class="chip">时间 <b>{0} ~ {1}</b></span>' -f (& $esc $tmin), (& $esc $tmax)))
[void]$sb.AppendLine(('    <span class="chip">报告 <b class="mono">{0}</b></span>' -f (& $esc $htmlPath)))
[void]$sb.AppendLine(('    <span class="chip">防绕开 <b>{0} 条 · {1}</b></span>' -f $tamperCount, (& $esc $tamperLatest)))
[void]$sb.AppendLine(('    <span class="chip">生成 <b>{0}</b></span>' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
[void]$sb.AppendLine('  </div>')
[void]$sb.AppendLine('  <div class="filters">')
[void]$sb.AppendLine('    <input id="fProc" placeholder="按进程名/路径筛选" oninput="applyFilter()">')
[void]$sb.AppendLine('    <input id="fPath" placeholder="按文件路径筛选" oninput="applyFilter()">')
[void]$sb.AppendLine('    <select id="fOp" onchange="applyFilter()"><option value="">全部操作</option><option value="Read">读取</option><option value="Write">写入</option><option value="Create">创建</option><option value="Delete">删除</option><option value="Other">其他</option></select>')
[void]$sb.AppendLine('    <button onclick="copyAll()">📋 复制全部</button>')
[void]$sb.AppendLine('    <button onclick="setAll(true)">⊞ 展开全部</button>')
[void]$sb.AppendLine('    <button onclick="setAll(false)">⊟ 折叠全部</button>')
[void]$sb.AppendLine('  </div>')
[void]$sb.AppendLine(('  <div class="sub">当前显示 <b id="cnt">{0}</b> 条</div>' -f $total))
[void]$sb.AppendLine('</div>')

[void]$sb.AppendLine('<main>')

# 按进程分组
foreach ($g in $groups) {
    $proc = [string]$g.Name
    $grows = @($g.Group | Sort-Object Time -Descending)
    $rc = @($grows | Where-Object { $_.Operation -eq 'Read' }).Count
    $wc = @($grows | Where-Object { $_.Operation -eq 'Write' }).Count
    $cc = @($grows | Where-Object { $_.Operation -eq 'Create' }).Count
    $dc = @($grows | Where-Object { $_.Operation -eq 'Delete' }).Count
    $oc = @($grows | Where-Object { $_.Operation -eq 'Other' }).Count
    $leaf = [System.IO.Path]::GetFileName($proc)

    [void]$sb.AppendLine('<details class="group" open>')
    [void]$sb.AppendLine('  <summary>')
    [void]$sb.AppendLine(('    <span class="proc" title="{0}">{1}</span>' -f (& $esc $proc), (& $esc $leaf)))
    [void]$sb.AppendLine(('    <span class="path">{0}</span>' -f (& $esc $proc)))
    [void]$sb.AppendLine(('    <span class="cnt">{0} 条</span>' -f $grows.Count))
    [void]$sb.AppendLine(('    <span class="legend">读 <b class="op-read">{0}</b> · 写 <b class="op-write">{1}</b> · 建 <b class="op-create">{2}</b> · 删 <b class="op-del">{3}</b> · 其他 {4}</span>' -f $rc, $wc, $cc, $dc, $oc))
    [void]$sb.AppendLine('    <button class="copy" onclick="copyGroup(this)" title="复制本程序全部记录">复制</button>')
    [void]$sb.AppendLine('  </summary>')
    [void]$sb.AppendLine('  <table>')
    [void]$sb.AppendLine('    <tr><th class="time">时间</th><th class="op">操作</th><th class="file">文件（可点击直达）</th><th class="acc">访问权限</th><th class="btn"></th></tr>')
    foreach ($r in $grows) {
        $cn  = $opCn[$r.Operation];  if (-not $cn) { $cn = '其他' }
        $cls = $opClass[$r.Operation]; if (-not $cls) { $cls = 'op-other' }
        $link = 'file:///' + ([string]$r.File -replace '\\','/')
        $copy = "{0} | {1} | {2} | {3}" -f $r.Time, $cn, $r.Process, $r.File
        [void]$sb.AppendLine(('<tr class="row" data-proc="{0}" data-file="{1}" data-op="{2}" data-copy="{3}">' -f (& $esc $r.Process), (& $esc $r.File), (& $esc $r.Operation), (& $esc $copy)))
        [void]$sb.AppendLine(('  <td class="time">{0}</td>' -f (& $esc $r.Time)))
        [void]$sb.AppendLine(('  <td class="op {0}">{1}</td>' -f $cls, (& $esc $cn)))
        [void]$sb.AppendLine(('  <td class="file"><a href="{0}" title="{1}">{2}</a></td>' -f (& $esc $link), (& $esc $r.File), (& $esc $r.File)))
        [void]$sb.AppendLine(('  <td class="acc">{0}</td>' -f (& $esc $r.Accesses)))
        [void]$sb.AppendLine('  <td class="btn"><button class="copy" onclick="copyRow(this)" title="复制这一条">复制</button></td>')
        [void]$sb.AppendLine('</tr>')
    }
    [void]$sb.AppendLine('  </table>')
    [void]$sb.AppendLine('</details>')
}

# 防绕开事件
[void]$sb.AppendLine('<details class="group tamper">')
[void]$sb.AppendLine(('  <summary><span class="proc">🛡 防绕开事件</span><span class="cnt">{0} 条</span></summary>' -f $tamperCount))
if ($tamperCount -gt 0) {
    [void]$sb.AppendLine('  <table><tr><th class="time">时间</th><th class="op">事件</th><th class="file">详情</th></tr>')
    foreach ($t in $tamperRows) {
        [void]$sb.AppendLine(('  <tr><td class="time">{0}</td><td class="op op-del">{1}</td><td class="file">{2}</td></tr>' -f (& $esc $t.Time), (& $esc $t.Event), (& $esc $t.Details)))
    }
    [void]$sb.AppendLine('  </table>')
} else {
    [void]$sb.AppendLine('  <div class="empty">暂无防绕开事件（审计策略/SACL/安全日志未被改动）。</div>')
}
[void]$sb.AppendLine('</details>')

[void]$sb.AppendLine('</main>')
[void]$sb.AppendLine('<div class="foot">数据每 5 分钟由计划任务更新一次；重新双击桌面「文件监控·查看」可刷新本报告。</div>')
[void]$sb.AppendLine('<div id="toast"></div>')
[void]$sb.AppendLine('<script>')
[void]$sb.AppendLine($JS)
[void]$sb.AppendLine('</script>')
[void]$sb.AppendLine('</body></html>')

[System.IO.File]::WriteAllText($htmlPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
Write-Host ("已生成报告: {0}（共 {1} 条，进程 {2} 个）" -f $htmlPath, $total, $procCount) -ForegroundColor Green
if (-not $NoOpen) { Start-Process $htmlPath }
