#requires -Version 5.0
<#
.SYNOPSIS
  NetWatcher (IP监控2.1) 一键验收脚本：编译 -> --selftest -> --daemon 引擎数据链路 -> GUI 冒烟(标签页/列头/截图)。

.DESCRIPTION
  全自动、可重复运行，输出 PASS/FAIL 表；有 FAIL 时退出码 1。
  只写 tools/qa/** 与仓库外的临时目录；绝不修改 %APPDATA%\NetWatcher 下的用户真实数据
  （运行前后对该目录所有文件做 size+mtime+SHA256 快照对比，有任何变化直接 FAIL 并打印 diff）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1

.EXAMPLE
  # 跳过编译 / 指定被测 exe / 关闭截图
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -SkipBuild -Exe bin\NetWatcher.exe -Seconds 30 -Screenshot:$false

.NOTES
  环境怪癖（已踩坑，脚本内已规避）：
  1. 本环境 PowerShell 执行策略禁止直接运行 .ps1 -> 用 -ExecutionPolicy Bypass 调用。
  2. 从本会话 shell 用 Start-Process 启动 GUI 会因继承 stdout 管道挂住命令 -> 统一用
     Invoke-CimMethod Win32_Process Create 启动，用轮询 Get-Process / EnumWindows 等待。
  3. 从仓库路径（...\NetWatcher\bin\NetWatcher.exe）直接启动的进程在本机会在 ~0.1s 内被
     结束（loader 之前，没有任何日志）；把 exe 复制到 %TEMP% 下再启动则完全正常。
     因此脚本总是先把 bin\NetWatcher.exe 复制到 %TEMP%\ipmon-qa-run-<tag>\ 并校验 SHA256 再运行。
  4. 启动 exe 时必须显式传 --datadir <绝对路径>，否则程序会用 %APPDATA%\NetWatcher 并写真实数据。
     脚本启动后若在 N 秒内没看到 --datadir 下出现 data\*.json，会立即结束进程并判 FAIL。
  5. 不用 UI Automation，控件树用 EnumChildWindows；标签页文本用 TCM_GETITEMW；切页用 PostMessage 点击。
  6. 数据链路验收用 --daemon（无界面，稳定）；GUI 只负责标签页/列头/截图断言。
#>
[CmdletBinding()]
param(
    # 引擎数据目录（默认 $env:TEMP\ipmon-qa-<时间戳>），必须是绝对路径；GUI 用其下 gui 子目录
    [string]$DataDir = '',
    # 采集/观察秒数（daemon 采集时长；GUI 观察取 min(12, Seconds) 秒）
    [int]$Seconds = 25,
    # 是否截图（默认开；-Screenshot:$false 关闭）
    [switch]$Screenshot = $true,
    # 跳过 build.bat
    [switch]$SkipBuild,
    # 编译 warning 只 WARN 不 FAIL（默认 warning 视为 FAIL，符合 design §8 "干净编译"）
    [switch]$AllowWarnings,
    # 证据输出目录（默认 <repo>\tools\qa\out）
    [string]$OutDir = '',
    # 被测 exe（默认 <repo>\bin\NetWatcher.exe）；脚本会复制到 temp 再运行
    [string]$Exe = '',
    # 等待主窗口出现的超时秒数
    [int]$StartTimeoutSec = 20,
    # 等待 --datadir 下出现 data\*.json 的超时秒数（防止程序用错数据目录）
    [int]$DataWaitSec = 25,
    # 允许删除已存在的非默认 $DataDir（默认只允许删 $env:TEMP\ipmon-qa* 下的目录）
    [switch]$ForceClean,
    # 只读审计 %APPDATA%\NetWatcher 用户真实数据（不作为 PASS/FAIL 依据，只输出 INFO）
    [switch]$AuditRealData,
    # 只跑无界面链路（编译/自检/daemon/数据校验/真实数据守卫），完全跳过 GUI（Lead 独占 GUI 验收时使用）
    [switch]$SkipGui,
    # 传给被测程序的 --mutex-tag（2.1 仍接受；GUI 单实例名含该 tag）。
    # 注意：2.1 数据写锁按「绝对 datadir」派生，并发测试必须用不同 --datadir，tag 不能绕开单写锁
    [string]$MutexTag = 'qa',
    # 进程 connCount 上限（2.0 design §2：连接“出现次数”，不再是采样累计；>= 该值视为可疑）
    [int]$MaxConnCount = 100
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ------------------------------------------------------------------ 路径与运行参数
$RunTag = Get-Date -Format 'yyyyMMdd-HHmmss'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Exe) { $Exe = Join-Path $RepoRoot 'bin\NetWatcher.exe' }
$Exe = [IO.Path]::GetFullPath($Exe)
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$RealDataDir = Join-Path $env:APPDATA 'NetWatcher'

if (-not $DataDir) { $DataDir = Join-Path $env:TEMP ("ipmon-qa-" + $RunTag) }
$DataDir = [IO.Path]::GetFullPath($DataDir)
$DataSubDir = Join-Path $DataDir 'data'
$GuiDataDir = Join-Path $DataDir 'gui'
$GuiDataSubDir = Join-Path $GuiDataDir 'data'
$RunDir = Join-Path $env:TEMP ("ipmon-qa-run-" + $RunTag)
$RunExe = Join-Path $RunDir 'NetWatcher.exe'

$script:Results = New-Object System.Collections.ArrayList
$script:ExtraInfo = New-Object System.Collections.ArrayList
$script:GuiPid = 0
$script:RunExe = $RunExe
$script:SelftestAdmin = $false

function Add-Result {
    param([string]$Status, [string]$Check, [string]$Detail)
    $row = [pscustomobject]@{ Status = $Status; Check = $Check; Detail = $Detail }
    [void]$script:Results.Add($row)
    $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
    Write-Host ("  [{0}] {1,-26} {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
}
function Add-Info {
    param([string]$Check, [string]$Detail)
    [void]$script:ExtraInfo.Add([pscustomobject]@{ Check = $Check; Detail = $Detail })
    Write-Host ("  [INFO] {0,-26} {1}" -f $Check, $Detail) -ForegroundColor Gray
}
function Fail([string]$Check, [string]$Detail) { Add-Result -Status 'FAIL' -Check $Check -Detail $Detail }
function Pass([string]$Check, [string]$Detail) { Add-Result -Status 'PASS' -Check $Check -Detail $Detail }
function Warn([string]$Check, [string]$Detail) { Add-Result -Status 'WARN' -Check $Check -Detail $Detail }
function Write-Section([string]$Title) { Write-Host ''; Write-Host ("== " + $Title + " ==") -ForegroundColor Cyan }
function Get-Sha256([string]$Path) { return (Get-FileHash -Path $Path -Algorithm SHA256).Hash }

# ------------------------------------------------------------------ 原生 Win32 辅助（编译一次）
$QaWinSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class QaWin
{
    public const int GW_HWNDPREV = 3;
    public const int GWL_STYLE = -16;
    public const int WM_CLOSE = 0x0010;
    public const int WM_LBUTTONDOWN = 0x0201;
    public const int WM_LBUTTONUP = 0x0202;
    public const int MK_LBUTTON = 0x0001;
    public const int TCM_GETITEMCOUNT = 0x1304;
    public const int TCM_GETCURSEL = 0x130B;
    public const int TCM_HITTEST = 0x130D;
    public const int TCIF_TEXT = 0x0001;
    public const int SM_CXSCREEN = 0;
    public const int SM_CYSCREEN = 1;

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct TCITEMW {
        public uint mask; public uint dwState; public uint dwStateMask;
        public IntPtr pszText; public int cchTextMax; public int iImage; public IntPtr lParam;
    }

    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public static IntPtr ForegroundWindow() { return GetForegroundWindow(); }
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] public static extern IntPtr SendMessageTCItem(IntPtr h, int msg, IntPtr w, ref TCITEMW item);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] public static extern IntPtr SendMessageRect(IntPtr h, int msg, IntPtr w, ref RECT rect);

    public static string Text(IntPtr h) { var sb = new StringBuilder(1024); GetWindowText(h, sb, 1024); return sb.ToString(); }
    public static string Class(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
    public static RECT Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }

    public class WndInfo {
        public long Hwnd; public long Parent; public string Class; public string Text;
        public int X, Y, W, H; public bool Visible; public bool Enabled; public int Style;
        public override string ToString() { return string.Format("0x{0:X}|{1}|vis={2}|{3}x{4}+{5}+{6}|text={7}", Hwnd, Class, Visible, W, H, X, Y, Text); }
    }

    static WndInfo Make(IntPtr h) {
        RECT r; GetWindowRect(h, out r);
        var w = new WndInfo();
        w.Hwnd = h.ToInt64(); w.Parent = GetParent(h).ToInt64();
        w.Class = Class(h); w.Text = Text(h);
        w.X = r.Left; w.Y = r.Top; w.W = r.Right - r.Left; w.H = r.Bottom - r.Top;
        w.Visible = IsWindowVisible(h); w.Enabled = IsWindowEnabled(h); w.Style = GetWindowLong(h, GWL_STYLE);
        return w;
    }

    public static List<WndInfo> Descendants(IntPtr root) {
        var list = new List<WndInfo>();
        EnumChildWindows(root, delegate(IntPtr h, IntPtr p) { list.Add(Make(h)); return true; }, IntPtr.Zero);
        return list;
    }

    public static List<long> TopWindows(uint pid) {
        var list = new List<long>();
        EnumWindows(delegate(IntPtr h, IntPtr p) { uint w; GetWindowThreadProcessId(h, out w); if (w == pid) list.Add(h.ToInt64()); return true; }, IntPtr.Zero);
        return list;
    }

    public static int TabCount(IntPtr tab) { return (int)SendMessage(tab, TCM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero); }
    public static int TabCurSel(IntPtr tab) { return (int)SendMessage(tab, TCM_GETCURSEL, IntPtr.Zero, IntPtr.Zero); }
    public static int TabHitTest(IntPtr tab, int x, int y) {
        IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
        return (int)SendMessage(tab, TCM_HITTEST, IntPtr.Zero, lp);
    }
    public static void ClickTabAt(IntPtr tab, int x, int y) {
        IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
        PostMessage(tab, WM_LBUTTONDOWN, (IntPtr)MK_LBUTTON, lp);
        PostMessage(tab, WM_LBUTTONUP, IntPtr.Zero, lp);
    }

    public class PT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    public static PT ClientPointToScreen(IntPtr h, int x, int y) {
        POINT p; p.X = x; p.Y = y; ClientToScreen(h, ref p);
        return new PT { X = p.X, Y = p.Y };
    }
    // 真实鼠标点击（走系统输入队列，会受窗口遮挡影响 —— 用于“用户能否点到标签栏”验证）
    public static void RealClick(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(80);
        mouse_event(0x0002, 0, 0, 0, IntPtr.Zero); // LEFTDOWN
        System.Threading.Thread.Sleep(60);
        mouse_event(0x0004, 0, 0, 0, IntPtr.Zero); // LEFTUP
    }

    static bool Intersect(RECT a, RECT b, out RECT r) {
        r = new RECT();
        r.Left = Math.Max(a.Left, b.Left); r.Top = Math.Max(a.Top, b.Top);
        r.Right = Math.Min(a.Right, b.Right); r.Bottom = Math.Min(a.Bottom, b.Bottom);
        return r.Right > r.Left && r.Bottom > r.Top;
    }

    // 返回 hwnd 顶部 bandHeight 像素区域实际可见比例 0..1。
    // 计入：祖先可见性、祖先客户区裁剪、屏幕裁剪、z-order 上方窗口遮挡（重叠 >=5% 视为遮挡）。
    public static double VisibleBand(IntPtr hwnd, int bandHeight) {
        if (!IsWindowVisible(hwnd)) return 0;
        RECT wr; GetWindowRect(hwnd, out wr);
        int w = wr.Right - wr.Left, h = wr.Bottom - wr.Top;
        if (w <= 0 || h <= 0) return 0;
        int bh = bandHeight > 0 ? Math.Min(bandHeight, h) : h;
        double origArea = (double)w * bh;
        RECT t = new RECT(); t.Left = wr.Left; t.Top = wr.Top; t.Right = wr.Right; t.Bottom = wr.Top + bh;
        RECT scr = new RECT(); scr.Left = 0; scr.Top = 0; scr.Right = GetSystemMetrics(SM_CXSCREEN); scr.Bottom = GetSystemMetrics(SM_CYSCREEN);
        RECT tmp;
        if (!Intersect(t, scr, out tmp)) return 0;
        t = tmp;
        IntPtr cur = hwnd;
        while (true) {
            IntPtr parent = GetParent(cur);
            if (parent == IntPtr.Zero) break;
            if (!IsWindowVisible(parent)) return 0;
            RECT cr; GetClientRect(parent, out cr);
            POINT pt; pt.X = 0; pt.Y = 0; ClientToScreen(parent, ref pt);
            RECT pcs; pcs.Left = pt.X; pcs.Top = pt.Y; pcs.Right = pt.X + (cr.Right - cr.Left); pcs.Bottom = pt.Y + (cr.Bottom - cr.Top);
            if (!Intersect(t, pcs, out tmp)) return 0;
            t = tmp;
            cur = parent;
        }
        IntPtr child = hwnd;
        while (true) {
            IntPtr parent = GetParent(child);
            // 只比较同一父窗口内的兄弟窗口，不把其它应用的顶层窗口算作遮挡
            if (parent == IntPtr.Zero) break;
            IntPtr sib = GetWindow(child, GW_HWNDPREV);
            while (sib != IntPtr.Zero) {
                if (IsWindowVisible(sib)) {
                    RECT sr; GetWindowRect(sib, out sr);
                    RECT ov;
                    if (Intersect(t, sr, out ov)) {
                        double oa = (double)(ov.Right - ov.Left) * (ov.Bottom - ov.Top);
                        if (oa >= origArea * 0.05) return 0;
                    }
                }
                sib = GetWindow(sib, GW_HWNDPREV);
            }
            child = parent;
        }
        return ((double)(t.Right - t.Left) * (t.Bottom - t.Top)) / origArea;
    }

    // DataGridView 候选：可见、空文本、WinForms 容器类、足够大、直接子窗口只有滚动条（或没有子窗口）。
    public static List<WndInfo> GridCandidates(IntPtr root) {
        var all = Descendants(root);
        var byParent = new Dictionary<long, List<WndInfo>>();
        foreach (var w in all) {
            if (!byParent.ContainsKey(w.Parent)) byParent[w.Parent] = new List<WndInfo>();
            byParent[w.Parent].Add(w);
        }
        var res = new List<WndInfo>();
        foreach (var w in all) {
            if (!w.Visible || w.W < 300 || w.H < 80) continue;
            if (!string.IsNullOrEmpty(w.Text)) continue;
            if (w.Class.IndexOf("WindowsForms10.Window", StringComparison.Ordinal) < 0) continue;
            List<WndInfo> kids;
            bool ok = true;
            if (byParent.TryGetValue(w.Hwnd, out kids)) {
                foreach (var k in kids) {
                    if (k.Class.IndexOf("SCROLLBAR", StringComparison.OrdinalIgnoreCase) < 0) { ok = false; break; }
                }
            }
            if (ok) res.Add(w);
        }
        return res;
    }
}
'@

if (-not ('QaWin' -as [type])) { Add-Type -TypeDefinition $QaWinSource -Language CSharp }
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web.Extensions

# ------------------------------------------------------------------ 通用辅助
function New-JsonSerializer {
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 100
    return $ser
}
function Read-JsonFile([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    return (New-JsonSerializer).DeserializeObject($text)
}

function Start-WmiProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory)
    $cmd = '"' + $FilePath + '"'
    foreach ($a in $Arguments) { $cmd += ' "' + $a + '"' }
    $createArgs = @{ CommandLine = $cmd }
    if ($WorkingDirectory) { $createArgs['CurrentDirectory'] = $WorkingDirectory }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $createArgs
    if ($r.ReturnValue -ne 0) { throw "Win32_Process.Create failed rc=$($r.ReturnValue): $cmd" }
    return [int]$r.ProcessId
}

function Stop-QaProcess {
    param([int]$ProcessId, [int]$WaitSec = 5)
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
    try { Stop-Process -Id $ProcessId -Force -ErrorAction Stop } catch { }
    Start-Sleep -Milliseconds 300
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
        try {
            Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction Stop |
                Invoke-CimMethod -MethodName Terminate -Arguments @{ Reason = 0 } -ErrorAction Stop | Out-Null
        } catch { }
    }
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return (-not [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

function Get-DirSnapshot {
    param([string]$Dir)
    $snap = @{}
    if (Test-Path $Dir) {
        Get-ChildItem $Dir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $snap[$_.FullName] = ('{0}|{1}|{2}' -f $_.Length, $_.LastWriteTimeUtc.Ticks, (Get-Sha256 $_.FullName))
        }
    }
    return $snap
}

function Compare-Snapshot {
    param($Before, $After)
    $changes = New-Object System.Collections.ArrayList
    foreach ($k in $Before.Keys) {
        if (-not $After.ContainsKey($k)) { [void]$changes.Add("删除: $k"); continue }
        if ($Before[$k] -ne $After[$k]) { [void]$changes.Add("修改: $k"); }
    }
    foreach ($k in $After.Keys) {
        if (-not $Before.ContainsKey($k)) { [void]$changes.Add("新增: $k") }
    }
    return ,$changes
}

function Get-DataFiles {
    param([string]$Dir)
    $files = @()
    if (Test-Path $Dir) { $files = @(Get-ChildItem $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) }
    return ,$files
}

function Save-WindowShot {
    param([IntPtr]$Hwnd, [string]$Path)
    $r = [QaWin]::Rect($Hwnd)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { return $null }
    # 优先 PrintWindow（不依赖窗口是否在屏幕内/是否被遮挡，截图内容即窗口真实渲染结果）
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $shotOk = $false
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        try { $shotOk = [QaWin]::PrintWindow($Hwnd, $hdc, 2) } finally { $g.ReleaseHdc($hdc); $g.Dispose() }
    } catch { $shotOk = $false }
    if (-not $shotOk) {
        # 回退：前台置顶后屏幕抓取
        [void][QaWin]::ShowWindow($Hwnd, 9)
        [void][QaWin]::SetForegroundWindow($Hwnd)
        Start-Sleep -Milliseconds 450
        $bmp.Dispose()
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
        $g.Dispose()
    }
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return [pscustomobject]@{ Path = $Path; Width = $w; Height = $h; X = $r.Left; Y = $r.Top; Method = $(if ($shotOk) { 'PrintWindow' } else { 'CopyFromScreen' }) }
}

function Test-ImageNotBlank {
    param([string]$Path)
    $bmp = New-Object System.Drawing.Bitmap($Path)
    try {
        $colors = New-Object 'System.Collections.Generic.HashSet[int]'
        $total = 0; $nonWhite = 0
        for ($y = 0; $y -lt $bmp.Height; $y += 4) {
            for ($x = 0; $x -lt $bmp.Width; $x += 4) {
                $c = $bmp.GetPixel($x, $y)
                [void]$colors.Add($c.ToArgb())
                $total++
                if ($c.R -lt 245 -or $c.G -lt 245 -or $c.B -lt 245) { $nonWhite++ }
            }
        }
        $frac = if ($total -gt 0) { $nonWhite / $total } else { 0 }
        return [pscustomobject]@{
            Ok = ($colors.Count -ge 8 -and $frac -gt 0.02 -and $frac -lt 0.995)
            UniqueColors = $colors.Count; NonWhiteFraction = [Math]::Round($frac, 4)
            Width = $bmp.Width; Height = $bmp.Height
        }
    } finally { $bmp.Dispose() }
}

function Wait-ProcessExit {
    param([int]$ProcessId, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# 2.2.0：趋势页是自绘 Panel（趋势曲线），截图里在指定矩形内统计「曲线像素」。
# 蓝色 = DrawTrend 的下载线 Color.FromArgb(46,110,200)；橙色 = 上传线 Color.FromArgb(220,120,32)。
# 给抗锯齿留 ±45 容差；按 2px 抽样以控制耗时。仅在脚本自己截的本机窗口图上运行（不读用户数据）。
function Test-ImageRegionCurve {
    param([string]$Path, [int]$X, [int]$Y, [int]$W, [int]$H)
    $bmp = New-Object System.Drawing.Bitmap($Path)
    try {
        $x0 = [Math]::Max(0, $X); $y0 = [Math]::Max(0, $Y)
        $x1 = [Math]::Min($bmp.Width - 1, $X + $W - 1); $y1 = [Math]::Min($bmp.Height - 1, $Y + $H - 1)
        if ($x1 -le $x0 -or $y1 -le $y0) { return [pscustomobject]@{ Ok = $false; Blue = 0; Orange = 0; NonWhiteFraction = 0; Samples = 0; Rect = 'invalid' } }
        $blue = 0; $orange = 0; $nonWhite = 0; $total = 0
        for ($y = $y0; $y -le $y1; $y += 2) {
            for ($x = $x0; $x -le $x1; $x += 2) {
                $c = $bmp.GetPixel($x, $y)
                $total++
                if ($c.R -lt 245 -or $c.G -lt 245 -or $c.B -lt 245) { $nonWhite++ }
                if ([Math]::Abs($c.R - 46) -le 45 -and [Math]::Abs($c.G - 110) -le 45 -and [Math]::Abs($c.B - 200) -le 45) { $blue++ }
                if ([Math]::Abs($c.R - 220) -le 45 -and [Math]::Abs($c.G - 120) -le 45 -and [Math]::Abs($c.B - 32) -le 45) { $orange++ }
            }
        }
        return [pscustomobject]@{
            Ok = $true; Blue = $blue; Orange = $orange
            NonWhiteFraction = [Math]::Round($nonWhite / [Math]::Max(1, $total), 5); Samples = $total
            Rect = ("{0},{1} {2}x{3}" -f $x0, $y0, ($x1 - $x0 + 1), ($y1 - $y0 + 1))
        }
    } finally { $bmp.Dispose() }
}

# ------------------------------------------------------------------ 0. 预检
Write-Host ''
Write-Host "NetWatcher 2.1 QA verify  ($RunTag)" -ForegroundColor White
Write-Host ("repo    = {0}" -f $RepoRoot)
Write-Host ("exe     = {0}" -f $Exe)
Write-Host ("data    = {0}" -f $DataDir)
Write-Host ("gui data= {0}" -f $GuiDataDir)
Write-Host ("out     = {0}" -f $OutDir)

Write-Section '0. 预检 / 环境隔离'
$envRows = New-Object System.Collections.ArrayList
[void]$envRows.Add([pscustomobject]@{ Item = 'time'; Value = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz') })
[void]$envRows.Add([pscustomobject]@{ Item = 'user'; Value = [Security.Principal.WindowsIdentity]::GetCurrent().Name })
$shellAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
[void]$envRows.Add([pscustomobject]@{ Item = 'shellAdmin'; Value = $shellAdmin })
[void]$envRows.Add([pscustomobject]@{ Item = 'os'; Value = [Environment]::OSVersion.VersionString })
[void]$envRows.Add([pscustomobject]@{ Item = 'ps'; Value = $PSVersionTable.PSVersion.ToString() })
[void]$envRows.Add([pscustomobject]@{ Item = 'dataDir'; Value = $DataDir })
[void]$envRows.Add([pscustomobject]@{ Item = 'seconds'; Value = $Seconds })
if (Test-Path $Exe) { [void]$envRows.Add([pscustomobject]@{ Item = 'exeHash'; Value = (Get-Sha256 $Exe).Substring(0, 16) }) }
try {
    Push-Location $RepoRoot
    $git = & git rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { [void]$envRows.Add([pscustomobject]@{ Item = 'gitHead'; Value = $git }) }
    $dirty = @(& git status --porcelain 2>$null)
    [void]$envRows.Add([pscustomobject]@{ Item = 'gitDirty'; Value = ($dirty.Count -gt 0) })
} catch { } finally { Pop-Location }
$envRows | Format-Table -AutoSize | Out-String | Write-Host

if (-not (Test-Path $Exe)) { Fail 'PRE_EXE' "找不到 $Exe（是否编译过？）" }

# 数据目录安全检查
$insideRepo = $DataDir.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)
$insideReal = $DataDir.StartsWith($RealDataDir, [StringComparison]::OrdinalIgnoreCase)
if ($insideRepo -or $insideReal) { Fail 'PRE_DATADIR' "数据目录不安全（在仓库或用户真实数据目录内）: $DataDir" }
if (Test-Path $DataDir) {
    $isDefaultTemp = $DataDir.StartsWith((Join-Path $env:TEMP 'ipmon-qa'), [StringComparison]::OrdinalIgnoreCase)
    if ($isDefaultTemp -or $ForceClean) { Remove-Item $DataDir -Recurse -Force }
    else { Fail 'PRE_DATADIR' "数据目录已存在且非默认 temp 目录，拒绝清理（加 -ForceClean 强制）: $DataDir" }
}
New-Item -ItemType Directory -Path $DataSubDir -Force | Out-Null
New-Item -ItemType Directory -Path $GuiDataSubDir -Force | Out-Null
$cfgText = '{"ScanIntervalSeconds":10,"AutoStart":false,"RetentionDays":0,"StartMinimized":false,"GeoEnabled":true,"GeoApi":"http://ip-api.com/json/{0}?fields=status,message,country,regionName,city,isp,lat,lon&lang=zh-CN","NewIpAlert":true,"ShowLocalIp":true}'
[IO.File]::WriteAllText((Join-Path $DataDir 'config.json'), $cfgText, (New-Object System.Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $GuiDataDir 'config.json'), $cfgText, (New-Object System.Text.UTF8Encoding($false)))

# 用户真实数据快照（size+mtime+SHA256）
$realSnapBefore = Get-DirSnapshot $RealDataDir
Add-Info 'REALDATA_SNAPSHOT' ("{0} 个文件已记录 size+mtime+SHA256" -f $realSnapBefore.Count)

# 注意：脚本不按进程名批量结束 NetWatcher！只结束自己通过 Win32_Process.Create 启动并记录 PID 的进程。
# 若已有 NetWatcher 在运行（可能是 Lead 的 GUI 验收实例），只报告、绝不结束；本脚本启动的进程带独立 --mutex-tag。
$existing = @(Get-Process -Name 'NetWatcher' -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) {
    $existingInfo = @()
    foreach ($p in $existing) {
        $ci = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $p.Id) -ErrorAction SilentlyContinue
        $existingInfo += ("{0}:{1}" -f $p.Id, $(if ($ci) { $ci.ExecutablePath } else { '?' }))
    }
    Warn 'PRE_EXISTING_PROC' ("检测到 {0} 个已在运行的 NetWatcher（不结束；可能是用户的 2.0 管理员实例 PID 10856，或 Lead 的验收实例）: {1}；2.1 数据写锁按绝对 datadir 派生，本脚本所有实例均用独立 --datadir，另带 --mutex-tag {2}" -f $existing.Count, ($existingInfo -join ', '), $MutexTag)
} else {
    Pass 'PRE_EXISTING_PROC' '无其它 NetWatcher 在运行'
}

$script:Screenshots = New-Object System.Collections.ArrayList
$tabExpected = @('实时连接', '进程视图', '按日统计', '趋势', '历史概览')

try {
    # -------------------------------------------------------------- 1. 编译
    Write-Section '1. 编译 (build.bat)'
    if ($SkipBuild) {
        Add-Info 'BUILD' '已跳过 (-SkipBuild)'
    } else {
        $buildLog = Join-Path $OutDir ("build_{0}.log" -f $RunTag)
        Push-Location $RepoRoot
        try {
            $out = @(& cmd /c "build.bat" 2>&1 | ForEach-Object { [string]$_ })
            $code = $LASTEXITCODE
        } finally { Pop-Location }
        $out | Set-Content -Path $buildLog -Encoding UTF8
        $errors = @($out | Where-Object { $_ -match '(?i)\berror\s+[A-Z]+\d+' })
        $warns = @($out | Where-Object { $_ -match '(?i)\bwarning\s+[A-Z]+\d+' })
        if ($code -ne 0 -or $errors.Count -gt 0) {
            Fail 'BUILD' ("exit={0} errors={1} log={2}" -f $code, $errors.Count, $buildLog)
            $errors | Select-Object -First 8 | ForEach-Object { Write-Host ("      " + $_) -ForegroundColor Red }
            if ($errors.Count -eq 0) { $out | Select-Object -First 8 | ForEach-Object { Write-Host ("      " + $_) -ForegroundColor Red } }
        } elseif ($warns.Count -gt 0) {
            $msg = ("exit=0 warnings={0} log={1}" -f $warns.Count, $buildLog)
            if ($AllowWarnings) { Warn 'BUILD' $msg } else { Fail 'BUILD' ($msg + '（design §8 要求干净编译；可用 -AllowWarnings 降级）') }
            $warns | Select-Object -First 8 | ForEach-Object { Write-Host ("      " + $_) -ForegroundColor Yellow }
        } else {
            Pass 'BUILD' ("exit=0, 0 warning  bin\\NetWatcher.exe = {0:N0} bytes" -f (Get-Item $Exe).Length)
        }
    }

    # -------------------------------------------------------------- 1b. 复制 exe 到 temp 运行（规避本环境从仓库路径启动被秒杀的问题）
    Write-Section '1b. 运行副本'
    if (Test-Path $Exe) {
        if (Test-Path $RunDir) { Remove-Item $RunDir -Recurse -Force }
        New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
        Copy-Item $Exe $RunExe -Force
        $h1 = Get-Sha256 $Exe
        $h2 = Get-Sha256 $RunExe
        if ($h1 -eq $h2) { Pass 'RUN_EXE' ("已复制到 {0}（SHA256={1}...）" -f $RunExe, $h1.Substring(0, 16)) }
        else { Fail 'RUN_EXE' '运行副本 SHA256 与被测 exe 不一致' }
    } else { Fail 'RUN_EXE' "被测 exe 不存在: $Exe" }

    # -------------------------------------------------------------- 2. --selftest
    Write-Section '2. 自检 (--selftest)'
    $selfLogPath = Join-Path $DataDir 'selftest.log'
    Remove-Item $selfLogPath -ErrorAction SilentlyContinue
    $selfText = ''
    $selfPid = 0
    if (Test-Path $RunExe) {
        try {
            $selfPid = Start-WmiProcess -FilePath $RunExe -Arguments @('--selftest', '--datadir', $DataDir, '--mutex-tag', $MutexTag) -WorkingDirectory $RunDir
            $exited = Wait-ProcessExit -ProcessId $selfPid -TimeoutSec 180
            if (-not $exited) { [void](Stop-QaProcess -ProcessId $selfPid); Fail 'SELFTEST_EXIT' '180 秒内未退出（已强制结束）' }
            else { Pass 'SELFTEST_EXIT' '进程正常退出' }
        } catch { Fail 'SELFTEST_EXIT' ("启动失败: " + $_.Exception.Message) }
    }
    if (Test-Path $selfLogPath) {
        $selfText = [IO.File]::ReadAllText($selfLogPath, [Text.Encoding]::UTF8)
        Copy-Item $selfLogPath (Join-Path $OutDir ("selftest_{0}.log" -f $RunTag)) -Force
        $logBytes = (Get-Item $selfLogPath).Length
        if ($logBytes -gt 0) { Pass 'SELFTEST_LOG' ("selftest.log {0:N0} bytes" -f $logBytes) }
        else { Fail 'SELFTEST_LOG' 'selftest.log 为空' }

        $m = [regex]::Match($selfText, '管理员权限[:：]\s*(是|否)')
        if ($m.Success) {
            $script:SelftestAdmin = ($m.Groups[1].Value -eq '是')
            Pass 'SELFTEST_ADMIN' ("管理员权限: " + $m.Groups[1].Value)
        } else { Fail 'SELFTEST_ADMIN' '缺少 "管理员权限:" 行' }
        $isAdmin = $script:SelftestAdmin

        # EStats 结论行（design §6 唯一判据）
        $mc = [regex]::Match($selfText, 'EStats\s*结论[:：]\s*([^\r\n]*)')
        if ($mc.Success) {
            $conclusion = $mc.Groups[1].Value.Trim()
            if ($isAdmin) {
                if ($conclusion -match '不可用') { Fail 'SELFTEST_ESTATS_CONCLUSION' ("管理员模式 EStats 结论: " + $conclusion) }
                elseif ($conclusion -match '可用') { Pass 'SELFTEST_ESTATS_CONCLUSION' ("管理员模式 EStats 结论: " + $conclusion) }
                else { Fail 'SELFTEST_ESTATS_CONCLUSION' ("无法解析结论: " + $conclusion) }
            } else {
                if ($conclusion -match '不可用') { Pass 'SELFTEST_ESTATS_CONCLUSION' ("非管理员预期不可用: " + $conclusion) }
                elseif ($conclusion -match '可用') { Warn 'SELFTEST_ESTATS_CONCLUSION' ("非管理员却报告可用（需人工确认）: " + $conclusion) }
                else { Fail 'SELFTEST_ESTATS_CONCLUSION' ("无法解析结论: " + $conclusion) }
            }
        } else { Fail 'SELFTEST_ESTATS_CONCLUSION' '缺少 "EStats 结论:" 行（design §6 硬要求）' }

        # EStats 诊断矩阵：design §6 要求给出 rw(1/4) × rod(48/16/1024) 的 rc/winerr 诊断组合。
        # 注意：自检按「失败连接」分行输出，每行含 6 个 rw×rod 组合；行数 = 自检时的远端连接数（会随环境变化），
        # 用行数 >=5 判定会把「连接少」误报成 WARN（2.2.0 收口：改为校验组合数，判据更贴 design §6，不削弱）。
        $estatsDiag = @([regex]::Matches($selfText, '(?im)^.*(rc\s*=\s*\d+|winerr\s*=\s*-?\d+|set\s*=\s*\d+).*$') | ForEach-Object { $_.Value.Trim() })
        $estatsCombos = @([regex]::Matches($selfText, 'rw\s*=\s*\d+\s*\([^)]*\)\s*rod\s*=\s*\d+')).Count
        if ($estatsCombos -ge 6) { Pass 'SELFTEST_ESTATS_DIAG' ("{0} 个 rw×rod 诊断组合（design §6 矩阵 rw 1/4 × rod 48/16/1024；来源于 {1} 个失败连接的诊断行）" -f $estatsCombos, $estatsDiag.Count) }
        elseif ($estatsCombos -ge 1) { Warn 'SELFTEST_ESTATS_DIAG' ("只有 {0} 个 rw×rod 诊断组合（design §6 期望完整 6 组矩阵）" -f $estatsCombos) }
        elseif ($estatsDiag.Count -ge 1) { Warn 'SELFTEST_ESTATS_DIAG' ("有 {0} 行 rc/winerr 诊断但未解析出 rw×rod 组合" -f $estatsDiag.Count) }
        else { Fail 'SELFTEST_ESTATS_DIAG' '缺少 EStats rc/winerr 诊断行（design §6）' }
        foreach ($l in ($estatsDiag | Select-Object -First 6)) { Add-Info 'ESTATS_DIAG' $l }

        if ([regex]::IsMatch($selfText, '(原子写/读|存储读写)[:：]\s*OK')) { Pass 'SELFTEST_STORAGE' '存储 原子写/读: OK' }
        else { Fail 'SELFTEST_STORAGE' '缺少 "原子写/读: OK" / "存储读写: OK"' }

        # 开机自启注册表读写（2.1 P0-3：必须只写/删临时值名，绝不改真实 Run 值）
        $mregTemp = [regex]::Match($selfText, '临时值写入后[^\r\n]*')
        $mregReal = [regex]::Match($selfText, '注册表写入后[^\r\n]*')
        if ($mregTemp.Success -and $mregTemp.Value -match '写入后\s*=\s*True[^\r\n]*删除后\s*=\s*False') {
            Pass 'SELFTEST_AUTOSTART' ("临时值名测试: " + $mregTemp.Value.Trim())
        } elseif ($mregReal.Success) {
            Fail 'SELFTEST_AUTOSTART' ("2.1 要求用临时值名测试自启，但日志出现真实值名结果行: " + $mregReal.Value.Trim())
        } elseif ([regex]::IsMatch($selfText, '开机自启')) {
            Warn 'SELFTEST_AUTOSTART' '有「开机自启」段但缺少「临时值写入后=…」结果行'
        } else {
            Fail 'SELFTEST_AUTOSTART' '缺少「开机自启」注册表读写检查（design §6）'
        }

        # GeoIP：允许 cache / 直连成功；直连受网络波动影响，首次失败时重跑一次自检再判定
        $geoPattern = 'GeoIP\(\s*8\.8\.8\.8\s*\)[:：]\s*([^\r\n]*)'
        $mg = [regex]::Match($selfText, $geoPattern)
        if ($mg.Success -and ($mg.Groups[1].Value -match '未知' -or $mg.Groups[1].Value -match '(?i)error|失败') -and (Test-Path $RunExe)) {
            Add-Info 'SELFTEST_GEOIP_RETRY' '首次 GeoIP 直连失败，重跑一次 --selftest 复核（网络波动，非代码判据）'
            try {
                $retryPid = Start-WmiProcess -FilePath $RunExe -Arguments @('--selftest', '--datadir', $DataDir, '--mutex-tag', $MutexTag) -WorkingDirectory $RunDir
                [void](Wait-ProcessExit -ProcessId $retryPid -TimeoutSec 120)
                if (Test-Path $selfLogPath) {
                    $selfText = [IO.File]::ReadAllText($selfLogPath, [Text.Encoding]::UTF8)
                    Copy-Item $selfLogPath (Join-Path $OutDir ("selftest_retry_{0}.log" -f $RunTag)) -Force
                }
            } catch { }
            $mg = [regex]::Match($selfText, $geoPattern)
        }
        if ($mg.Success) {
            $geoLine = $mg.Groups[1].Value.Trim()
            if ($geoLine -match '未知' -or $geoLine -match '(?i)error|失败') { Fail 'SELFTEST_GEOIP' ("GeoIP(8.8.8.8) 解析失败（不能是 error/未知，已重试）: " + $geoLine) }
            else { Pass 'SELFTEST_GEOIP' ("GeoIP(8.8.8.8): " + $geoLine) }
        } else { Fail 'SELFTEST_GEOIP' '缺少 GeoIP(8.8.8.8) 行' }

        if ([regex]::IsMatch($selfText, '网卡') -or ([regex]::IsMatch($selfText, '(?i)loopback') -and [regex]::IsMatch($selfText, '(?i)tunnel'))) {
            Pass 'SELFTEST_NIC_DETAIL' '含网卡明细 / Loopback+Tunnel 排除说明'
        } else { Fail 'SELFTEST_NIC_DETAIL' '缺少网卡逐项统计与 Loopback/Tunnel 排除说明（design §6）' }

        if ([regex]::IsMatch($selfText, '自检结束')) { Pass 'SELFTEST_TAIL' '含 "自检结束"' }
        else { Warn 'SELFTEST_TAIL' '缺少 "自检结束"（可能中途异常）' }

        # 2.2.0 收口：selftest 新增「趋势绘制 1440 点 × N 次：平均 X ms/次」性能行
        #（只画到内存位图，不写数据目录、不弹窗；design 要求 1440 点绘制 <100ms 量级）
        $perfMatch = [regex]::Match($selfText, '趋势绘制\s*1440\s*点\s*[×xX]\s*(\d+)\s*次[：:]\s*平均\s*([0-9.]+)\s*ms')
        if (-not $perfMatch.Success) {
            Fail 'SELFTEST_TREND_PERF' '缺少「趋势绘制 1440 点 × N 次：平均 X ms/次」性能自检行（2.2.0 收口新增）'
        } else {
            $perfRuns = [int]$perfMatch.Groups[1].Value
            $perfMs = [double]$perfMatch.Groups[2].Value
            if ($perfRuns -lt 1) { Fail 'SELFTEST_TREND_PERF' ("自测次数异常: {0}" -f $perfRuns) }
            elseif ($perfMs -gt 100.0) { Fail 'SELFTEST_TREND_PERF' ("1440 点绘制平均 {0:0.0} ms/次 > 100ms（性能回归）" -f $perfMs) }
            else { Pass 'SELFTEST_TREND_PERF' ("趋势绘制 1440 点 × {0} 次：平均 {1:0.0} ms/次（阈值 <100ms）" -f $perfRuns, $perfMs) }
        }
    } else {
        Fail 'SELFTEST_LOG' "未生成 $selfLogPath"
        $crash = Join-Path $env:TEMP 'NetWatcher-crash.log'
        if (Test-Path $crash) {
            $c = [IO.File]::ReadAllText($crash, [Text.Encoding]::UTF8)
            Fail 'SELFTEST_CRASH' ($c.Substring(0, [Math]::Min(300, $c.Length)))
        }
    }
    # 2.1 P0-2：selftest 必须不写 data\ 当天数据。若仍出现数据文件 -> 记录 WARN（不掩盖），再清理以免干扰 daemon 采集校验
    if (Test-Path $DataSubDir) {
        $selfData = @(Get-ChildItem $DataSubDir -File -ErrorAction SilentlyContinue)
        if ($selfData.Count -gt 0) {
            Warn 'SELFTEST_DATA_WRITE' ("selftest 后 data\ 出现 {0} 个文件（2.1 要求 selftest 不写当天数据）: {1}" -f $selfData.Count, (($selfData | Select-Object -First 5 | ForEach-Object { $_.Name + '(' + $_.Length + 'B)' }) -join ','))
            $selfData | Remove-Item -Force -ErrorAction SilentlyContinue
            Add-Info 'DATA_RESET' ("已清理 selftest 产生的 {0} 个数据文件（避免干扰后续 daemon 校验）" -f $selfData.Count)
        }
    }

    # -------------------------------------------------------------- 3. --daemon 采集（数据链路主验收）
    Write-Section '3. 引擎采集 (--daemon)'
    $daemonPid = 0
    if (Test-Path $RunExe) {
        try {
            $daemonPid = Start-WmiProcess -FilePath $RunExe -Arguments @('--daemon', "$Seconds", '--datadir', $DataDir, '--mutex-tag', $MutexTag) -WorkingDirectory $RunDir
            Add-Info 'DAEMON' ("pid={0} 采集 {1}s" -f $daemonPid, $Seconds)
            $exited = Wait-ProcessExit -ProcessId $daemonPid -TimeoutSec ($Seconds + 120)
            if (-not $exited) { [void](Stop-QaProcess -ProcessId $daemonPid); Fail 'DAEMON_EXIT' ("{0}s 内未退出" -f ($Seconds + 120)) }
            else { Pass 'DAEMON_EXIT' ("--daemon {0} 正常退出" -f $Seconds) }
        } catch { Fail 'DAEMON_EXIT' ("启动失败: " + $_.Exception.Message) }
    }

    # -------------------------------------------------------------- 3b. --mutex-tag 并发隔离（不同 tag 的两个 daemon 应都成功）
    Write-Section '3b. 并发隔离（不同 datadir + 不同 --mutex-tag）'
    $mutexSecs = 10
    $mutexDirA = Join-Path $DataDir 'mutex-a'
    $mutexDirB = Join-Path $DataDir 'mutex-b'
    foreach ($md in @($mutexDirA, $mutexDirB)) {
        New-Item -ItemType Directory -Path (Join-Path $md 'data') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $md 'config.json'), $cfgText, (New-Object System.Text.UTF8Encoding($false)))
    }
    $mA = 0; $mB = 0
    if (Test-Path $RunExe) {
        try {
            $mA = Start-WmiProcess -FilePath $RunExe -Arguments @('--daemon', "$mutexSecs", '--datadir', $mutexDirA, '--mutex-tag', ($MutexTag + '-a')) -WorkingDirectory $RunDir
            $mB = Start-WmiProcess -FilePath $RunExe -Arguments @('--daemon', "$mutexSecs", '--datadir', $mutexDirB, '--mutex-tag', ($MutexTag + '-b')) -WorkingDirectory $RunDir
            Add-Info 'MUTEX_TAG' ("并发启动 pidA={0}(tag={1}-a) pidB={2}(tag={1}-b)" -f $mA, $MutexTag, $mB)
            Start-Sleep -Seconds 1
            $aliveA = [bool](Get-Process -Id $mA -ErrorAction SilentlyContinue)
            $aliveB = [bool](Get-Process -Id $mB -ErrorAction SilentlyContinue)
            $exitA = Wait-ProcessExit -ProcessId $mA -TimeoutSec ($mutexSecs + 45)
            $exitB = Wait-ProcessExit -ProcessId $mB -TimeoutSec ($mutexSecs + 45)
            if (-not $exitA) { [void](Stop-QaProcess -ProcessId $mA) }
            if (-not $exitB) { [void](Stop-QaProcess -ProcessId $mB) }
            $filesA = @()
            $filesB = @()
            if (Test-Path (Join-Path $mutexDirA 'data')) { $filesA = @(Get-ChildItem (Join-Path $mutexDirA 'data') -Filter '*.json' -File -ErrorAction SilentlyContinue) }
            if (Test-Path (Join-Path $mutexDirB 'data')) { $filesB = @(Get-ChildItem (Join-Path $mutexDirB 'data') -Filter '*.json' -File -ErrorAction SilentlyContinue) }
            if ($aliveA -and $aliveB -and $exitA -and $exitB -and $filesA.Count -gt 0 -and $filesB.Count -gt 0) {
                Pass 'MUTEX_TAG_DIFF' ("不同 datadir + 不同 --mutex-tag 的两个 --daemon {0} 并发均成功（{1}-a / {1}-b，各写出数据文件；2.1 单写锁按绝对 datadir 派生，必须 datadir 不同才允许并发）" -f $mutexSecs, $MutexTag)
            } else {
                Fail 'MUTEX_TAG_DIFF' ("并发隔离异常：aliveA={0} aliveB={1} exitA={2} exitB={3} dataA={4} dataB={5}" -f $aliveA, $aliveB, $exitA, $exitB, $filesA.Count, $filesB.Count)
            }
        } catch { Fail 'MUTEX_TAG_DIFF' ("启动失败: " + $_.Exception.Message) }
    }

    # -------------------------------------------------------------- 4. 引擎数据校验
    Write-Section '4. 采集数据校验 (data\*.json)'
    $dataFiles = Get-DataFiles -Dir $DataSubDir
    $tmpFiles = @()
    if (Test-Path $DataSubDir) { $tmpFiles = @(Get-ChildItem $DataSubDir -Filter '*.tmp' -File -ErrorAction SilentlyContinue) }
    if ($dataFiles.Count -gt 0) { Pass 'DATA_FILE' ("{0} 个数据文件，最新 {1} ({2:N0} bytes)" -f $dataFiles.Count, $dataFiles[0].Name, $dataFiles[0].Length) }
    else { Fail 'DATA_FILE' ("{0} 下没有 data\\*.json" -f $DataDir) }
    if ($tmpFiles.Count -gt 0) { Fail 'DATA_ATOMIC' ("残留 {0} 个 .tmp 文件（原子写失败?）: {1}" -f $tmpFiles.Count, (($tmpFiles | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ',')) }
    else { Pass 'DATA_ATOMIC' '无残留 .tmp 文件' }

    $day = $null
    if ($dataFiles.Count -gt 0) {
        try { $day = Read-JsonFile $dataFiles[0].FullName; Pass 'DATA_JSON' ("JSON 可解析: " + $dataFiles[0].Name) }
        catch { Fail 'DATA_JSON' ("JSON 解析失败: " + $_.Exception.Message) }
    }

    if ($day) {
        $ips = $day['ips']; $procs = $day['procs']; $samples = $day['samples']
        $ipCount = 0; $procCount = 0; $sampleListCount = 0
        $sumIp = [double]0; $sumProc = [double]0
        $maxConn = 0; $maxConnName = ''
        $sumIpIn = [double]0; $sumIpOut = [double]0
        $procNameEmpty = 0; $procPathEmpty = 0
        if ($ips) {
            $ipCount = $ips.Count
            foreach ($k in $ips.Keys) {
                $v = $ips[$k]
                $sumIpIn += [double]$v['bytesIn']
                $sumIpOut += [double]$v['bytesOut']
                $sumIp += [double]$v['bytesIn'] + [double]$v['bytesOut']
            }
        }
        if ($procs) {
            $procCount = $procs.Count
            foreach ($k in $procs.Keys) {
                $v = $procs[$k]
                $sumProc += [double]$v['bytesIn'] + [double]$v['bytesOut']
                if ([int]$v['connCount'] -gt $maxConn) { $maxConn = [int]$v['connCount']; $maxConnName = $k }
                $nm = [string]$v['name']; $pp = [string]$v['path']
                if ([string]::IsNullOrWhiteSpace($nm)) { $procNameEmpty++ }
                if ([string]::IsNullOrWhiteSpace($pp)) { $procPathEmpty++ }
            }
        }
        if ($samples) { $sampleListCount = $samples.Count }
        $rawSamples = 0
        try { $rawSamples = [int]$day['sampleCount'] } catch { }
        $dayIn = [double]$day['bytesIn']; $dayOut = [double]$day['bytesOut']
        $totalBytes = $dayIn + $dayOut
        $precise = $false
        try { $precise = [bool]$day['bytesPrecise'] } catch { }
        $isAdmin = $script:SelftestAdmin

        Add-Info 'DATA_SUMMARY' ("date={0} 总字节={1:N0} (in {2:N0}/out {3:N0}) IP={4} 进程={5} 分钟桶={6} 原始采样={7} bytesPrecise={8}" -f $day['date'], $totalBytes, $dayIn, $dayOut, $ipCount, $procCount, $sampleListCount, $rawSamples, $precise)

        # 采样：2.0 是“每分钟一个桶”，45s 只有 1 个桶是正常的；多采样看 sampleCount
        if ($rawSamples -ge 2 -or $sampleListCount -ge 2) { Pass 'DATA_SAMPLES' ("原始采样 sampleCount={0}，分钟桶 samples={1}（多采样已生效）" -f $rawSamples, $sampleListCount) }
        elseif ($sampleListCount -eq 1) { Warn 'DATA_SAMPLES' ("原始采样 sampleCount={0}，分钟桶 samples=1（观察时长/间隔偏短）" -f $rawSamples) }
        else { Fail 'DATA_SAMPLES' ("分钟桶 samples={0}，原始采样 sampleCount={1}" -f $sampleListCount, $rawSamples) }
        if ($sampleListCount -ge 1 -and $sampleListCount -le 1440) { Pass 'DATA_SAMPLES_CAP' ("分钟桶 samples={0}（1..1440，符合 design §2 分钟聚合上限）" -f $sampleListCount) }
        else { Fail 'DATA_SAMPLES_CAP' ("分钟桶 samples={0}，期望 1..1440" -f $sampleListCount) }

        if ($totalBytes -gt 0) { Pass 'DATA_TOTAL_BYTES' ("当日总流量 {0:N0} B" -f $totalBytes) }
        else { Fail 'DATA_TOTAL_BYTES' '当日总流量为 0' }

        if ($ipCount -gt 0) { Pass 'DATA_IP_COUNT' ("{0} 个远端 IP" -f $ipCount) }
        else { Warn 'DATA_IP_COUNT' '0 个远端 IP（本次运行期间可能没有 ESTABLISHED 远端连接）' }

        if ($sumIp -gt 0) {
            $modeText = if ($precise) { '精确模式' } else { '估算模式' }
            Pass 'DATA_IP_BYTES' ("逐 IP 字节合计 {0:N0} B（{1}，要求 >0）" -f $sumIp, $modeText)
        } else {
            if ($precise) { Fail 'DATA_IP_BYTES' '逐 IP 字节合计=0 但 bytesPrecise=true（假精确！design §0.1/§1）' }
            else { Fail 'DATA_IP_BYTES' ("逐 IP 字节合计=0（{0}；估算模式也应 >0）" -f $(if ($isAdmin) { '管理员模式' } else { '非管理员估算模式' })) }
        }

        # 分方向余数分配：sum(ips.bytesIn) 应精确等于 day.bytesIn（误差 0，浮点容差 0.5B）
        if ($ipCount -gt 0) {
            $diffIn = [Math]::Abs($sumIpIn - $dayIn)
            $diffOut = [Math]::Abs($sumIpOut - $dayOut)
            if ($diffIn -le 0.5 -and $diffOut -le 0.5) {
                Pass 'DATA_IP_BALANCE' ("sum(ips.bytesIn)={0:N0} == day.bytesIn={1:N0}；sum(ips.bytesOut)={2:N0} == day.bytesOut={3:N0}" -f $sumIpIn, $dayIn, $sumIpOut, $dayOut)
            } else {
                Fail 'DATA_IP_BALANCE' ("分方向合计与 day 不符：in diff={0:N0} out diff={1:N0}（余数应分配给最后一条连接，误差应为 0）" -f $diffIn, $diffOut)
            }
        } else { Warn 'DATA_IP_BALANCE' '无 ips，跳过' }

        # bytesPrecise 诚实性：非管理员 / EStats 不可用时绝不能 true
        if (-not $isAdmin -and $precise) { Fail 'DATA_PRECISE_HONESTY' '非管理员却 bytesPrecise=true（谎报精确模式）' }
        elseif ($precise -and $sumIp -le 0) { Fail 'DATA_PRECISE_HONESTY' 'bytesPrecise=true 但逐 IP 字节为 0，假精确' }
        else { Pass 'DATA_PRECISE_HONESTY' ("bytesPrecise={0}（与当前模式一致）" -f $precise) }

        if ($maxConn -ge $MaxConnCount) { Fail 'DATA_CONNCOUNT' ("进程最大 connCount={0} ({1})，>= {2} 视为采样累计而非真实出现次数（design §2）" -f $maxConn, $maxConnName, $MaxConnCount) }
        else { Pass 'DATA_CONNCOUNT' ("进程最大 connCount={0} ({1})，< {2}" -f $maxConn, $maxConnName, $MaxConnCount) }

        if ($ipCount -gt 0 -and $procCount -gt 0) {
            $diff = [Math]::Abs($sumIp - $sumProc)
            $tol = [Math]::Max(1.0, $sumIp * 0.02)
            if ($diff -le $tol) { Pass 'DATA_IP_PROC_CONSISTENCY' ("逐IP合计 {0:N0} ≈ 逐进程合计 {1:N0}" -f $sumIp, $sumProc) }
            else { Warn 'DATA_IP_PROC_CONSISTENCY' ("逐IP合计 {0:N0} 与逐进程合计 {1:N0} 差异过大（容差 {2:N0}）" -f $sumIp, $sumProc, $tol) }
        } else { Add-Info 'DATA_IP_PROC_CONSISTENCY' 'IP/进程为空，跳过' }

        if ($procCount -gt 0) {
            Add-Info 'DATA_PROC_FIELDS' ("进程 name 非空 {0}/{1}，path 非空 {2}/{3}（沙箱内部分为空属正常，仅记录）" -f ($procCount - $procNameEmpty), $procCount, ($procCount - $procPathEmpty), $procCount)
        }

        if ($precise) { Add-Info 'DATA_MODE' '字节来源=精确（bytesPrecise=true）' }
        else { Add-Info 'DATA_MODE' ("字节来源=估算（bytesPrecise=false；{0}）" -f $(if ($isAdmin) { '管理员但无 EStats 成功连接' } else { '非管理员，符合 design §1 估算模式' })) }
    }

    # -------------------------------------------------------------- 5. GUI 冒烟
    Write-Section '5. GUI 冒烟（标签页 / 列头 / 截图）'
    $mainHwnd = [IntPtr]::Zero
    $guiPid = 0
    $seedPath = ''
    $seedHashBefore = ''
    $seedMtimeBefore = [DateTime]::MinValue
    $script:SeedRowCount = 0
    if ($SkipGui) { Add-Info 'GUI' '已跳过 (-SkipGui：Lead 独占 GUI 验收，本脚本只做无界面链路)' }
    if (-not $SkipGui -and (Test-Path $RunExe)) {
        try {
            # 2.2.0：趋势页断言需要「可绘制的分钟桶数据」。在脚本自己的 %TEMP%\<tag>\gui\data 下
            # 预置一条当日数据（绝不写 %APPDATA%\NetWatcher），由 GUI 启动时加载；
            # GUI_DATADIR 断言同时要求「该预置文件被 GUI 启动后重写」，不因预置而放水。
            # 2.2.0 收口后趋势页对「相邻分钟桶间隔 >5 分钟」断开不连线，所以种子必须密集（5 分钟一桶），
            # 才能验证真实折线路径（含分段/排序/去重逻辑），而不是只画孤立点。
            $seedDate = Get-Date -Format 'yyyy-MM-dd'
            $seedPath = Join-Path $GuiDataSubDir ($seedDate + '.json')
            $seedMidnightUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind((Get-Date).Date, [DateTimeKind]::Unspecified))
            $seedEpochUtc = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            $seedMidnightUnix = [long]($seedMidnightUtc - $seedEpochUtc).TotalSeconds
            $seedNowMin = [int][Math]::Floor(((Get-Date).TimeOfDay).TotalMinutes)
            $seedEndMin = [Math]::Max(2, $seedNowMin - 1)
            $seedInterval = 5
            $seedWant = 24
            $seedFirstMin = [Math]::Max(1, $seedEndMin - ($seedWant - 1) * $seedInterval)
            $seedRows = New-Object System.Collections.ArrayList
            $seedIn = [long]0; $seedOut = [long]0; $seedMaxIn = [long]0; $seedMaxOut = [long]0
            for ($k = 0; $k -lt $seedWant; $k++) {
                $m = $seedFirstMin + $k * $seedInterval
                if ($m -gt $seedEndMin) { break }
                $vin = [long](300000 + (($k * 37) % 13) * 210000)
                $vout = [long](150000 + (($k * 53) % 11) * 95000)
                [void]$seedRows.Add(@([long]($seedMidnightUnix + $m * 60), $vin, $vout))
                $seedIn += $vin; $seedOut += $vout
                if ($vin -gt $seedMaxIn) { $seedMaxIn = $vin }
                if ($vout -gt $seedMaxOut) { $seedMaxOut = $vout }
            }
            $script:SeedRowCount = $seedRows.Count
            $seedObj = [ordered]@{
                date = $seedDate
                bytesIn = $seedIn
                bytesOut = $seedOut
                peakInBps = $seedMaxIn
                peakOutBps = $seedMaxOut
                firstSampleUnix = [long]$seedRows[0][0]
                lastSampleUnix = [long]$seedRows[$seedRows.Count - 1][0]
                sampleCount = ($seedRows.Count + 30)
                bytesPrecise = $false
                ips = @{}
                procs = @{}
                samples = @($seedRows)
            }
            [IO.File]::WriteAllText($seedPath, ($seedObj | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
            $seedHashBefore = Get-Sha256 $seedPath
            $seedMtimeBefore = (Get-Item $seedPath).LastWriteTimeUtc
            Add-Info 'GUI_SEED' ("趋势页测试数据已预置（{0} 个分钟桶、间隔 {1} 分钟，验证折线而非孤立点；{2}）；启动后必须被 GUI 重写" -f $seedRows.Count, $seedInterval, $seedPath)
        } catch { Fail 'GUI_SEED' ("预置趋势页测试数据失败: " + $_.Exception.Message) }
        try {
            $guiPid = Start-WmiProcess -FilePath $RunExe -Arguments @('--datadir', $GuiDataDir, '--mutex-tag', $MutexTag) -WorkingDirectory $RunDir
            $script:GuiPid = $guiPid
            $deadline = (Get-Date).AddSeconds($StartTimeoutSec)
            while ((Get-Date) -lt $deadline -and $mainHwnd -eq [IntPtr]::Zero) {
                if (-not (Get-Process -Id $guiPid -ErrorAction SilentlyContinue)) { break }
                foreach ($h in [QaWin]::TopWindows([uint32]$guiPid)) {
                    $hi = [IntPtr]$h
                    if (-not [QaWin]::IsWindowVisible($hi)) { continue }
                    $cls = [QaWin]::Class($hi)
                    $txt = [QaWin]::Text($hi)
                    if ($cls.StartsWith('WindowsForms10.Window') -and $txt -match 'NetWatcher') { $mainHwnd = $hi; break }
                }
                if ($mainHwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 250 }
            }
            if ($mainHwnd -eq [IntPtr]::Zero) { Fail 'GUI_WINDOW' ("{0}s 内未找到可见主窗口（pid={1}）" -f $StartTimeoutSec, $guiPid) }
            else {
                $r = [QaWin]::Rect($mainHwnd)
                Pass 'GUI_WINDOW' ("pid={0} title='{1}' window={2}x{3}" -f $guiPid, [QaWin]::Text($mainHwnd), ($r.Right - $r.Left), ($r.Bottom - $r.Top))
            }
        } catch { Fail 'GUI_WINDOW' ("启动失败: " + $_.Exception.Message) }
    }

    if ($mainHwnd -ne [IntPtr]::Zero) {
        # 数据目录守卫：必须在 N 秒内看到 GUI 把预置的 data\*.json 重写（证明程序真的用了 --datadir），
        # 而不是「只要文件存在就算过」。预置文件只在本脚本 %TEMP% 的 gui datadir 内，不涉及用户真实数据。
        $waitDeadline = (Get-Date).AddSeconds($DataWaitSec)
        $guiDataFiles = @()
        $guiDataWritten = $false
        while ((Get-Date) -lt $waitDeadline) {
            $guiDataFiles = @(Get-DataFiles -Dir $GuiDataSubDir)
            if ($guiDataFiles.Count -gt 0) {
                foreach ($f in $guiDataFiles) {
                    if ($f.FullName -ne $seedPath) { $guiDataWritten = $true; break }
                    if ($f.LastWriteTimeUtc -gt $seedMtimeBefore) { $guiDataWritten = $true; break }
                    try { if ((Get-Sha256 $f.FullName) -ne $seedHashBefore) { $guiDataWritten = $true; break } } catch { }
                }
            }
            if ($guiDataWritten) { break }
            if (-not (Get-Process -Id $guiPid -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 300
        }
        if ($guiDataWritten) { Pass 'GUI_DATADIR' ("--datadir 生效：{0}s 内 GUI 已重写预置日文件（{1} 个数据文件，趋势页数据链可用）" -f $DataWaitSec, $guiDataFiles.Count) }
        else {
            Fail 'GUI_DATADIR' ("{0}s 内 GUI 未重写 {1} 下的数据文件（预置文件仍原样或不存在），怀疑程序未使用 --datadir 或未落盘；立即结束进程" -f $DataWaitSec, $GuiDataDir)
            [void](Stop-QaProcess -ProcessId $guiPid)
            $mainHwnd = [IntPtr]::Zero
        }
    }

    if ($mainHwnd -ne [IntPtr]::Zero) {
        $guiObserve = [Math]::Max(6, [Math]::Min(12, $Seconds))
        Start-Sleep -Seconds $guiObserve

        # 5.0 控件树快照
        $treePath = Join-Path $OutDir ("controls_{0}.txt" -f $RunTag)
        $treeJsonPath = Join-Path $OutDir ("controls_{0}.json" -f $RunTag)
        $dump = [QaWin]::Descendants($mainHwnd)
        $dump | ForEach-Object { $_.ToString() } | Set-Content -Path $treePath -Encoding UTF8
        $dump | Select-Object Hwnd, Parent, Class, Text, X, Y, W, H, Visible, Enabled, Style |
            ConvertTo-Json -Depth 3 | Set-Content -Path $treeJsonPath -Encoding UTF8
        Add-Info 'GUI_TREE' ("{0} 个控件，证据: {1}" -f $dump.Count, (Split-Path $treePath -Leaf))

        if (-not [bool](Get-Process -Id $guiPid -ErrorAction SilentlyContinue)) { Fail 'GUI_ALIVE' 'GUI 进程在冒烟期间退出/崩溃' }
        else { Pass 'GUI_ALIVE' ("GUI 进程存活 {0}s" -f $guiObserve) }

        # 5.1 主窗口截图
        if ($Screenshot) {
            $mainShot = Join-Path $OutDir ("gui_main_{0}.png" -f $RunTag)
            try {
                $shot = Save-WindowShot -Hwnd $mainHwnd -Path $mainShot
                if ($shot) {
                    [void]$script:Screenshots.Add($shot)
                    $chk = Test-ImageNotBlank -Path $mainShot
                    if ($chk.Ok) { Pass 'GUI_SCREENSHOT' ("{0} {1}x{2} colors={3} nonWhite={4}" -f (Split-Path $mainShot -Leaf), $chk.Width, $chk.Height, $chk.UniqueColors, $chk.NonWhiteFraction) }
                    else { Fail 'GUI_SCREENSHOT' ("截图疑似空白/纯色: {0}" -f $mainShot) }
                } else { Fail 'GUI_SCREENSHOT' '窗口矩形无效，无法截图' }
            } catch { Fail 'GUI_SCREENSHOT' ("截图失败: " + $_.Exception.Message) }
        } else { Add-Info 'GUI_SCREENSHOT' '已跳过 (-Screenshot:$false)' }

        # 5.2 标签页
        #   跨进程约束：只读/只发“纯整数”消息（TCM_GETITEMCOUNT/GETCURSEL）；TCM_GETITEMW/GETITEMRECT/
        #   TCM_HITTEST 都带指针，跨进程发送会让目标进程解引用本进程地址而崩溃，禁止使用。
        #   标签文本通过“切页后读 TabPage 窗口标题（WM_GETTEXT，系统自动跨进程编组）”获得。
        $tabWnd = $dump | Where-Object { $_.Class -like '*SysTabControl32*' } | Select-Object -First 1
        if (-not $tabWnd) { Fail 'GUI_TABS_FOUND' '控件树中找不到 TabControl' }
        else {
            $tabHwnd = [IntPtr]$tabWnd.Hwnd
            $tabCount = [QaWin]::TabCount($tabHwnd)
            $tr = [QaWin]::Rect($tabHwnd)
            $tabW = $tr.Right - $tr.Left
            $tabH = $tr.Bottom - $tr.Top
            if ($tabCount -eq $tabExpected.Count) { Pass 'GUI_TABS_FOUND' ("TabControl 有 {0} 个标签页" -f $tabCount) }
            else { Fail 'GUI_TABS_FOUND' ("TabControl 标签页数量={0}，期望 {1}" -f $tabCount, $tabExpected.Count) }

            $headerFrac = [QaWin]::VisibleBand($tabHwnd, 26)
            if ($headerFrac -ge 0.95) { Pass 'GUI_TABHEADER_VISIBLE' ("标签栏可见比例 {0:P0}（TabControl {1}x{2}）" -f $headerFrac, $tabW, $tabH) }
            else { Fail 'GUI_TABHEADER_VISIBLE' ("标签栏被遮挡/裁剪，可见比例仅 {0:P0}（TabControl @{1},{2} {3}x{4}）" -f $headerFrac, $tr.Left, $tr.Top, $tabW, $tabH) }

            # 用 PostMessage 点击扫出每个标签的起点（纯整数坐标，跨进程安全；只读到“选中索引”）
            $tabStarts = @{}
            for ($x = 2; $x -lt $tabW - 2; $x += 4) {
                [QaWin]::ClickTabAt($tabHwnd, $x, 12)
                Start-Sleep -Milliseconds 30
                $hit = [QaWin]::TabCurSel($tabHwnd)
                if ($hit -ge 0 -and $hit -lt $tabCount -and -not $tabStarts.ContainsKey($hit)) { $tabStarts[$hit] = $x }
                if ($tabStarts.Count -eq $tabCount) { break }
            }
            $tabRanges = @{}
            if ($tabStarts.Count -eq $tabCount) {
                $gaps = @()
                for ($i = 1; $i -lt $tabCount; $i++) {
                    if ($tabStarts.ContainsKey($i) -and $tabStarts.ContainsKey($i - 1)) { $gaps += ($tabStarts[$i] - $tabStarts[$i - 1]) }
                }
                $itemW = if ($gaps.Count -gt 0) { ($gaps | Measure-Object -Minimum).Minimum } else { 54 }
                if ($itemW -lt 20) { $itemW = 54 }
                for ($i = 0; $i -lt $tabCount; $i++) {
                    if ($tabStarts.ContainsKey($i)) { $tabRanges[$i] = @{ Min = $tabStarts[$i]; Max = $tabStarts[$i] + $itemW - 1 } }
                }
                Pass 'GUI_TABS_LAYOUT' ("扫出 {0} 个标签起点: {1}（估算项宽 {2}px）" -f $tabStarts.Count, (($tabStarts.Keys | Sort-Object | ForEach-Object { "[{0}]x={1}" -f $_, $tabStarts[$_] }) -join ' '), $itemW)
            } else {
                Fail 'GUI_TABS_LAYOUT' ("只扫出 {0}/{1} 个标签的可点击起点（标签栏不可见/不可点）" -f $tabStarts.Count, $tabCount)
            }

            # 2.2.0：5 标签页预期按「标签名」而不是下标索引，避免标签顺序变化时张冠李戴。
            # DataGridView 数量按页区分；「趋势」页是自绘 Panel（不是 DataGridView），单独用 GUI_TREND_* 断言。
            $gridExpectedByName = @{
                '实时连接' = 2   # 各 IP 连接摘要 + 当前连接明细
                '进程视图' = 0   # TreeView
                '按日统计' = 1
                '趋势'     = 0   # 自绘 Panel + 汇总标签（无 DataGridView）
                '历史概览' = 1
            }
            foreach ($tn in $tabExpected) {
                if (-not $gridExpectedByName.ContainsKey($tn)) { Fail 'GUI_TABS_EXPECT_MAP' ("预期表缺少标签页「{0}」的 DataGridView 数量配置" -f $tn) }
            }
            $labels = @()
            $mechOk = $true
            $realOk = $true
            $tabProblems = New-Object System.Collections.ArrayList
            $gridFoundPerTab = New-Object System.Collections.ArrayList
            $realNotes = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt [Math]::Min($tabExpected.Count, $tabCount); $i++) {
                if (-not $tabRanges.ContainsKey($i)) {
                    $labels += ''
                    $mechOk = $false
                    [void]$tabProblems.Add(("标签[{0}]: 无法定位标签栏可点击区间" -f $i))
                    continue
                }
                $tabName = $tabExpected[$i]
                $cx = [int](($tabRanges[$i].Min + $tabRanges[$i].Max) / 2)
                # (a) 机械切换（PostMessage；证明控件逻辑可切，但不代表用户点得到）
                [QaWin]::ClickTabAt($tabHwnd, $cx, 12)
                $selDeadline = (Get-Date).AddSeconds(3)
                $sel = -1; $pageText = ''
                while ((Get-Date) -lt $selDeadline) {
                    $sel = [QaWin]::TabCurSel($tabHwnd)
                    $pages = @([QaWin]::Descendants($tabHwnd) | Where-Object { $_.Parent -eq $tabWnd.Hwnd -and $_.Visible -and $_.Class -like 'WindowsForms10.Window*' -and $_.Text -ne '' })
                    if ($sel -eq $i -and $pages.Count -ge 1) { $pageText = $pages[0].Text; break }
                    Start-Sleep -Milliseconds 120
                }
                $labels += $pageText
                if ($sel -ne $i) { $mechOk = $false; [void]$tabProblems.Add(("标签[{0}]: 机械切换失败 sel={1}" -f $i, $sel)); continue }

                # (b) 真实鼠标点击（用户视角）：先切到别的页，再真实点击本页标签
                $other = ($i + 1) % [Math]::Max(1, $tabCount)
                if ($tabRanges.ContainsKey($other)) {
                    [QaWin]::ClickTabAt($tabHwnd, [int](($tabRanges[$other].Min + $tabRanges[$other].Max) / 2), 12)
                    Start-Sleep -Milliseconds 250
                }
                $pt = [QaWin]::ClientPointToScreen($tabHwnd, $cx, 12)
                # 最多 3 次真实点击：本机可能同时有用户 2.0 实例或其它 NetWatcher GUI（并行验收/开发）抢前台，
                # 抢不到前台会让真实点击落到别人窗口上。重试并记录实际前台窗口；3 次都不行才判 FAIL（判据不变）。
                $realSel = -1
                $realAttempts = 0
                $fgNote = ''
                for ($try = 1; $try -le 3; $try++) {
                    $realAttempts = $try
                    [void][QaWin]::SetForegroundWindow($mainHwnd)
                    Start-Sleep -Milliseconds 200
                    $fg = [QaWin]::ForegroundWindow()
                    $fgNote = ('第{0}次点击时前台 hwnd={1}（被测主窗口={2}）' -f $try, $fg, $mainHwnd)
                    [QaWin]::RealClick($pt.X, $pt.Y)
                    $realDeadline = (Get-Date).AddSeconds(2)
                    while ((Get-Date) -lt $realDeadline) {
                        $realSel = [QaWin]::TabCurSel($tabHwnd)
                        if ($realSel -eq $i) { break }
                        Start-Sleep -Milliseconds 120
                    }
                    if ($realSel -eq $i) { break }
                    Start-Sleep -Milliseconds 150
                }
                if ($realSel -ne $i) { $realOk = $false; [void]$realNotes.Add(("标签[{0}] {1}: 真实点击未切换(sel={2}，尝试 {3} 次；{4})" -f $i, $pageText, $realSel, $realAttempts, $fgNote)) }
                if ($realSel -ne $i) { [QaWin]::ClickTabAt($tabHwnd, $cx, 12); Start-Sleep -Milliseconds 250 }
                Start-Sleep -Milliseconds 250
                $tabShotPath = ''
                if ($Screenshot) {
                    $p = Join-Path $OutDir ("gui_tab{0}_{1}_{2}.png" -f ($i + 1), $tabExpected[$i], $RunTag)
                    try { $s = Save-WindowShot -Hwnd $mainHwnd -Path $p; if ($s) { [void]$script:Screenshots.Add($s); $tabShotPath = $p } } catch { }
                }
                # 趋势页：先定位「自绘 Panel」——它不是 DataGridView，计数时剔除，后面单独做 GUI_TREND_* 断言
                $desc = @([QaWin]::Descendants($mainHwnd))
                $visDesc = @($desc | Where-Object { $_.Visible })
                $tp = $null
                if ($tabName -eq '趋势') {
                    $childParentSet = New-Object 'System.Collections.Generic.HashSet[long]'
                    foreach ($w0 in $desc) { [void]$childParentSet.Add([long]$w0.Parent) }
                    $trPanels = @($visDesc | Where-Object {
                        $_.Class -like 'WindowsForms10.Window*' -and [string]::IsNullOrEmpty($_.Text) -and
                        $_.W -ge 600 -and $_.H -ge 150 -and -not $childParentSet.Contains([long]$_.Hwnd)
                    })
                    if ($trPanels.Count -ge 1) { $tp = $trPanels | Sort-Object { $_.W * $_.H } -Descending | Select-Object -First 1 }
                }
                # DataGridView 计数：容器候选里剔除趋势页自绘 Panel，数量必须与预期「相等」
                $gridExp = if ($gridExpectedByName.ContainsKey($tabName)) { [int]$gridExpectedByName[$tabName] } else { 0 }
                $grids = @([QaWin]::GridCandidates($mainHwnd))
                if ($tp) { $grids = @($grids | Where-Object { [long]$_.Hwnd -ne [long]$tp.Hwnd }) }
                [void]$gridFoundPerTab.Add($grids.Count)
                if ($grids.Count -ne $gridExp) { [void]$tabProblems.Add(("标签[{0}] {1}: DataGridView 数量={2}，期望 {3}" -f $i, $pageText, $grids.Count, $gridExp)) }
                foreach ($g in $grids) {
                    $frac = [QaWin]::VisibleBand([IntPtr]$g.Hwnd, 24)
                    if ($frac -lt 0.95) { [void]$tabProblems.Add(("标签[{0}] {1}: 列头被遮挡/裁剪 可见比例 {2:P0} 网格@({3},{4}) {5}x{6}" -f $i, $pageText, $frac, $g.X, $g.Y, $g.W, $g.H)) }
                }
                if ($tabName -eq '进程视图') {
                    $tv = @([QaWin]::Descendants($mainHwnd) | Where-Object { $_.Visible -and $_.Class -like '*SysTreeView32*' })
                    if ($tv.Count -lt 1) { [void]$tabProblems.Add('标签[进程视图]: 未见可见 TreeView') }
                    else {
                        $tvFrac = [QaWin]::VisibleBand([IntPtr]$tv[0].Hwnd, 24)
                        if ($tvFrac -lt 0.95) { [void]$tabProblems.Add(("标签[进程视图]: TreeView 顶部被遮挡 可见比例 {0:P0}" -f $tvFrac)) }
                    }
                }

                # 2.2.0 新增断言 A：实时连接页隐藏日期行、改用「活动筛选」下拉
                if ($tabName -eq '实时连接') {
                    $visLive = @([QaWin]::Descendants($mainHwnd) | Where-Object { $_.Visible })
                    $ldl = @($visLive | Where-Object { $_.Text -eq '查看日期:' })
                    $ldb = @($visLive | Where-Object { $_.Text -eq '今天' -or $_.Text -eq '昨天' -or $_.Text -eq '前天' })
                    if ($ldl.Count -eq 0 -and $ldb.Count -eq 0) { Pass 'GUI_LIVE_DATEROW_HIDDEN' '实时连接页日期行已隐藏（2.2.0 日期行按页生效）' }
                    else { Fail 'GUI_LIVE_DATEROW_HIDDEN' ("实时连接页仍显示日期行: 查看日期标签={0} 快捷按钮={1}" -f $ldl.Count, $ldb.Count) }
                    $lcbo = @($visLive | Where-Object { $_.Class -like '*COMBOBOX*' })
                    if ($lcbo.Count -ge 1) { Pass 'GUI_LIVE_ACTIVITY_FILTER' ("实时连接页活动筛选下拉可见（{0} 个 COMBOBOX，首个 {1}x{2}）" -f $lcbo.Count, $lcbo[0].W, $lcbo[0].H) }
                    else { Fail 'GUI_LIVE_ACTIVITY_FILTER' '实时连接页未见可见的「活动筛选」下拉框（期望至少 1 个 COMBOBOX）' }
                }

                # 2.2.0 新增断言 B：趋势页 = 汇总标签 + 自绘曲线 Panel（不是 DataGridView）
                if ($tabName -eq '趋势') {
                    # (1) 真实汇总标签（不是「加载中…」）
                    $trSummary = @($visDesc | Where-Object { $_.Class -like '*STATIC*' -and $_.Text -match '^趋势' }) | Select-Object -First 1
                    if (-not $trSummary) { Fail 'GUI_TREND_SUMMARY' '趋势页未找到可见的「趋势 · …」汇总标签' }
                    elseif ($trSummary.Text -match '加载中') { Fail 'GUI_TREND_SUMMARY' ("趋势页汇总仍停在加载态: {0}" -f $trSummary.Text) }
                    elseif ($trSummary.Text -match '趋势 · ' -and ($trSummary.Text -match '当日总量' -or $trSummary.Text -match '无数据')) { Pass 'GUI_TREND_SUMMARY' ("{0}" -f $trSummary.Text) }
                    else { Fail 'GUI_TREND_SUMMARY' ("趋势汇总文本不符合预期: {0}" -f $trSummary.Text) }
                    # (2) 预置的分钟桶必须被读到（证明趋势页真的加载并会绘制数据）
                    $seedExpect = [int]$script:SeedRowCount
                    if ($trSummary -and $trSummary.Text -match '分钟桶 (\d+) 条') {
                        $trBuckets = [int]$Matches[1]
                        if ($trBuckets -ge $seedExpect) { Pass 'GUI_TREND_SEED_LOADED' ("趋势页读到预置分钟桶: 分钟桶 {0} 条（预置 {1} 条）" -f $trBuckets, $seedExpect) }
                        else { Fail 'GUI_TREND_SEED_LOADED' ("趋势页只读到 {0} 个分钟桶（预置 {1} 个，期望 >={1}；加载/归并逻辑可能未生效）" -f $trBuckets, $seedExpect) }
                    } else { Fail 'GUI_TREND_SEED_LOADED' '趋势页汇总未出现「分钟桶 N 条」，无法确认预置数据被加载' }
                    # (2b) 2.2.0 收口：相邻分钟桶间隔 <=5 分钟应连成 1 段曲线（种子按 5 分钟一桶），
                    #      若断点判据把正常连续数据也断开，汇总会显示「曲线 N 段」（N>1）→ 判 FAIL。
                    if ($trSummary -and $trSummary.Text -match '曲线 (\d+) 段') {
                        $segCount = [int]$Matches[1]
                        if ($segCount -eq 1) { Pass 'GUI_TREND_SEGMENTS' ("密集分钟桶（间隔 5 分钟）连成 1 段曲线（汇总: 曲线 {0} 段）" -f $segCount) }
                        else { Fail 'GUI_TREND_SEGMENTS' ("密集分钟桶本应连成 1 段，实际 {0} 段（断点判据可能误断正常数据）" -f $segCount) }
                    } else { Fail 'GUI_TREND_SEGMENTS' '趋势汇总未出现「曲线 N 段」，无法确认断点逻辑输出' }
                    # (3) 自绘曲线 Panel（前面已定位）：断言可见性，并用像素证据证明曲线真的画出来了
                    if (-not $tp) { Fail 'GUI_TREND_PANEL' '趋势页未找到可见的自绘曲线 Panel（可见/空文本/>=600x150/无子窗口）' }
                    else {
                        $tpFrac = [QaWin]::VisibleBand([IntPtr]$tp.Hwnd, [Math]::Min(24, $tp.H))
                        if ($tpFrac -ge 0.95) { Pass 'GUI_TREND_PANEL' ("自绘曲线 Panel @({0},{1}) {2}x{3}，顶部可见比例 {4:P0}" -f $tp.X, $tp.Y, $tp.W, $tp.H, $tpFrac) }
                        else { Fail 'GUI_TREND_PANEL' ("自绘曲线 Panel 被遮挡/裁剪，可见比例 {0:P0} @({1},{2}) {3}x{4}" -f $tpFrac, $tp.X, $tp.Y, $tp.W, $tp.H) }
                        # (4) 像素证据：截图曲线区（裁掉顶部 50px 图例区）必须出现下载蓝线 + 上传橙线
                        if ($Screenshot -and $tabShotPath -and (Test-Path $tabShotPath)) {
                            $wr = [QaWin]::Rect($mainHwnd)
                            $rx = [int]($tp.X - $wr.Left + 6); $ry = [int]($tp.Y - $wr.Top + 50)
                            $rw = [int]($tp.W - 12); $rh = [int]($tp.H - 56)
                            $curve = Test-ImageRegionCurve -Path $tabShotPath -X $rx -Y $ry -W $rw -H $rh
                            if (-not $curve.Ok) { Fail 'GUI_TREND_CURVE' '趋势曲线区截图裁剪失败（区域无效）' }
                            elseif ($curve.Blue -ge 30 -and $curve.Orange -ge 30) { Pass 'GUI_TREND_CURVE' ("曲线区像素证据: 下载蓝线 {0} px / 上传橙线 {1} px / 非白占比 {2:P2}（区域 {3}）" -f $curve.Blue, $curve.Orange, $curve.NonWhiteFraction, $curve.Rect) }
                            else { Fail 'GUI_TREND_CURVE' ("曲线区未见完整蓝/橙曲线: 蓝 {0} px / 橙 {1} px / 非白 {2:P2}（区域 {3}）；可能只画了坐标轴/文字" -f $curve.Blue, $curve.Orange, $curve.NonWhiteFraction, $curve.Rect) }
                        } else { Fail 'GUI_TREND_CURVE' '趋势页截图缺失，无法做曲线像素证据' }
                    }
                    # (5) 2.2.0 日期行在非实时页生效：趋势页应有「查看日期:」+ 今天/昨天/前天
                    $tdl = @($visDesc | Where-Object { $_.Text -eq '查看日期:' })
                    $tdb = @($visDesc | Where-Object { $_.Text -eq '今天' -or $_.Text -eq '昨天' -or $_.Text -eq '前天' })
                    if ($tdl.Count -ge 1 -and $tdb.Count -ge 3) { Pass 'GUI_DATEBAR_TREND' ("趋势页日期行可见（查看日期: + 今天/昨天/前天 {0} 个按钮）" -f $tdb.Count) }
                    else { Fail 'GUI_DATEBAR_TREND' ("趋势页日期行未按设计显示: 查看日期标签={0} 快捷按钮={1}（期望 >=1 / >=3）" -f $tdl.Count, $tdb.Count) }
                }
            }
            $labelsJoined = ($labels -join ' / ')
            if (($labels -join '|') -eq ($tabExpected -join '|')) { Pass 'GUI_TABS_TEXT' ("标签页文本(页面窗口标题): " + $labelsJoined) }
            elseif ((@($labels | Sort-Object) -join '|') -eq (@($tabExpected | Sort-Object) -join '|')) { Warn 'GUI_TABS_TEXT' ("标签页文本存在但顺序不同: " + $labelsJoined) }
            else { Fail 'GUI_TABS_TEXT' ("期望 {0} 个标签页 '{1}'，实际: {2}" -f $tabExpected.Count, ($tabExpected -join ' / '), $labelsJoined) }

            if ($mechOk) { Pass 'GUI_TAB_SWITCH_LOGIC' '所有标签页均可切换（TCM_GETCURSEL 与页面窗口一致）' }
            else { Fail 'GUI_TAB_SWITCH_LOGIC' (($tabProblems | Where-Object { $_ -match '机械切换失败' }) -join '; ') }
            if ($realOk) { Pass 'GUI_TAB_CLICK_REAL' '所有标签页均可被真实鼠标点击切换（用户可点）' }
            else { Fail 'GUI_TAB_CLICK_REAL' ('真实鼠标点击无法切换：' + (($realNotes | Select-Object -First 4) -join '; ')) }

            if ($tabProblems.Count -eq 0) { Pass 'GUI_GRID_HEADERS' ("各页 DataGridView 列头均可见（每页 DataGridView 数（已剔除趋势页自绘 Panel）: {0}；趋势页由 GUI_TREND_* 单独断言）" -f ($gridFoundPerTab -join ',')) }
            else { Fail 'GUI_GRID_HEADERS' (($tabProblems | Select-Object -First 6) -join '; ') }

            if ($tabRanges.ContainsKey(0)) { [QaWin]::ClickTabAt($tabHwnd, [int](($tabRanges[0].Min + $tabRanges[0].Max) / 2), 12) }
            Start-Sleep -Milliseconds 400

            # 5.3 统计标签可见性
            $stats = @($dump | Where-Object { $_.Visible -and $_.Text -match '^(↓ 下载速度|↑ 上传速度|今日下载|今日上传)' })
            if ($stats.Count -ge 4) {
                $bad = @()
                foreach ($s in $stats) { $f = [QaWin]::VisibleBand([IntPtr]$s.Hwnd, [Math]::Min(19, $s.H)); if ($f -lt 0.95) { $bad += $s.Text } }
                if ($bad.Count -eq 0) { Pass 'GUI_LIVE_STATS' '4 个速度/今日统计标签均可见' }
                else { Fail 'GUI_LIVE_STATS' ("统计标签被遮挡: " + ($bad -join ' | ')) }
            } else { Fail 'GUI_LIVE_STATS' ("只找到 {0}/4 个统计标签（↓ 下载速度 / ↑ 上传速度 / 今日下载 / 今日上传）" -f $stats.Count) }

            # 5.4 通用遮挡审计（Tab/列头类缺陷的通用兜底）
            $occluded = New-Object System.Collections.ArrayList
            foreach ($w in $dump) {
                if (-not $w.Visible) { continue }
                if ($w.W -lt 120 -or $w.H -lt 20) { continue }
                $f = [QaWin]::VisibleBand([IntPtr]$w.Hwnd, [Math]::Min(24, $w.H))
                if ($f -lt 0.95) { [void]$occluded.Add(($w.ToString() + (" bandVis={0:P0}" -f $f))) }
            }
            if ($occluded.Count -eq 0) { Pass 'GUI_LAYOUT_OCCLUSION' '无可见控件的顶部区域被上层窗口遮挡' }
            else { Fail 'GUI_LAYOUT_OCCLUSION' ("{0} 个可见控件的顶部区域被遮挡，例: {1}" -f $occluded.Count, (($occluded | Select-Object -First 4) -join ' ;; ')) }

            # 5.5 关闭窗口 -> 托盘（真实点击右上角 X；外部 PostMessage WM_CLOSE 的 CloseReason 不是 UserClosing，会直接退出）
            try {
                $wr = [QaWin]::Rect($mainHwnd)
                $origin = [QaWin]::ClientPointToScreen($mainHwnd, 0, 0)
                $captionH = $origin.Y - $wr.Top
                $borderLeft = $origin.X - $wr.Left
                $clientW = $wr.Right - $wr.Left - 2 * $borderLeft
                $closeX = $wr.Right - $borderLeft - 22
                $closeY = $wr.Top + [int]($captionH / 2)
                [void][QaWin]::SetForegroundWindow($mainHwnd)
                Start-Sleep -Milliseconds 200
                [QaWin]::RealClick($closeX, $closeY)
                Start-Sleep -Milliseconds 1800
                $procAlive = [bool](Get-Process -Id $guiPid -ErrorAction SilentlyContinue)
                $winVisible = if ($procAlive) { [QaWin]::IsWindowVisible($mainHwnd) } else { $false }
                if ($procAlive -and -not $winVisible) { Pass 'GUI_TRAY_HIDE' ("真实点击窗口 X 后进程存活且主窗口隐藏（最小化到托盘，X@{0},{1}）" -f $closeX, $closeY) }
                else { Fail 'GUI_TRAY_HIDE' ("点击 X@{0},{1} 后 processAlive={2} windowVisible={3}（期望 True/False）" -f $closeX, $closeY, $procAlive, $winVisible) }
            } catch { Fail 'GUI_TRAY_HIDE' ("测试异常: " + $_.Exception.Message) }
        }
    }

    # 结束 GUI（只结束本脚本记录的 PID；绝不按进程名批量杀，避免误杀 Lead 的验收实例）
    if ($script:GuiPid -gt 0) {
        $killed = Stop-QaProcess -ProcessId $script:GuiPid
        if (-not $killed) { Fail 'CLEANUP_GUI' ("无法结束本脚本启动的 GUI 进程 pid={0}" -f $script:GuiPid) }
        else { Pass 'CLEANUP_GUI' ("已结束本脚本启动的 GUI 进程 pid={0}" -f $script:GuiPid) }
    } else {
        Add-Info 'CLEANUP_GUI' '未启动 GUI（或已跳过）'
    }

    # -------------------------------------------------------------- 6. 用户真实数据零改动（size+mtime+SHA256）
    Write-Section '6. 用户真实数据保护'
    $realSnapAfter = Get-DirSnapshot $RealDataDir
    $changes = Compare-Snapshot -Before $realSnapBefore -After $realSnapAfter
    if ($changes.Count -eq 0) { Pass 'REALDATA_UNTOUCHED' ("{0} 与运行前完全一致（{1} 个文件, size+mtime+SHA256）" -f $RealDataDir, $realSnapAfter.Count) }
    else { Fail 'REALDATA_UNTOUCHED' ("用户真实数据目录被改动 {0} 处: {1}" -f $changes.Count, (($changes | Select-Object -First 8) -join '; ')) }

    if ($AuditRealData -and (Test-Path $RealDataDir)) {
        $realFiles = @(Get-ChildItem (Join-Path $RealDataDir 'data') -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($rf in ($realFiles | Select-Object -First 2)) {
            try {
                $rd = Read-JsonFile $rf.FullName
                $ripSum = [double]0; $rMax = 0; $rMaxName = ''
                if ($rd['ips']) { foreach ($k in $rd['ips'].Keys) { $ripSum += [double]$rd['ips'][$k]['bytesIn'] + [double]$rd['ips'][$k]['bytesOut'] } }
                if ($rd['procs']) { foreach ($k in $rd['procs'].Keys) { if ([int]$rd['procs'][$k]['connCount'] -gt $rMax) { $rMax = [int]$rd['procs'][$k]['connCount']; $rMaxName = $k } } }
                Add-Info ("AUDIT_REAL_" + $rf.BaseName) ("bytesIn={0:N0} 逐IP字节合计={1:N0} bytesPrecise={2} maxConn={3} ({4})" -f $rd['bytesIn'], $ripSum, $rd['bytesPrecise'], $rMax, $rMaxName)
            } catch { Add-Info ("AUDIT_REAL_" + $rf.BaseName) ("解析失败: " + $_.Exception.Message) }
        }
    }
} catch {
    Fail 'UNEXPECTED' ("脚本异常: " + $_.Exception.Message + " @ line " + $_.InvocationInfo.ScriptLineNumber)
} finally {
    # 兜底：只结束本脚本启动的 GUI PID（不按进程名批量杀）
    if ($script:GuiPid -gt 0) { [void](Stop-QaProcess -ProcessId $script:GuiPid) }
}

# ------------------------------------------------------------------ 7. 汇总报告
Write-Section '7. PASS/FAIL 汇总'
$passCount = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
$failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count

$table = $script:Results | Format-Table -AutoSize Status, Check, Detail | Out-String -Width 240
Write-Host $table
Write-Host ''
Write-Host ("RESULT: {0}   PASS={1}  FAIL={2}  WARN={3}" -f $(if ($failCount -gt 0) { 'FAIL' } else { 'PASS' }), $passCount, $failCount, $warnCount) -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Green' })
Write-Host ("data dir : {0}" -f $DataDir)
Write-Host ("run exe  : {0}" -f $RunExe)
Write-Host ("evidence : {0}" -f $OutDir)
if ($script:Screenshots.Count -gt 0) { Write-Host 'screenshots:'; foreach ($s in $script:Screenshots) { Write-Host ("  - " + $s.Path) } }

$reportTxt = Join-Path $OutDir ("report_{0}.txt" -f $RunTag)
$reportJson = Join-Path $OutDir ("report_{0}.json" -f $RunTag)
$meta = [pscustomobject]@{
    time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
    result = $(if ($failCount -gt 0) { 'FAIL' } else { 'PASS' })
    pass = $passCount; fail = $failCount; warn = $warnCount
    dataDir = $DataDir; guiDataDir = $GuiDataDir; outDir = $OutDir; exe = $Exe; runExe = $RunExe
    seconds = $Seconds; screenshot = [bool]$Screenshot; skipBuild = [bool]$SkipBuild
    selftestAdmin = $script:SelftestAdmin
    screenshots = @($script:Screenshots | ForEach-Object { $_.Path })
    checks = @($script:Results)
    info = @($script:ExtraInfo)
}
$meta | ConvertTo-Json -Depth 5 | Set-Content -Path $reportJson -Encoding UTF8
$txt = @()
$txt += "NetWatcher 2.1 QA report  $RunTag"
$txt += ("result: {0}  PASS={1} FAIL={2} WARN={3}" -f $meta.result, $passCount, $failCount, $warnCount)
$txt += ("dataDir: {0}" -f $DataDir)
$txt += ("guiDataDir: {0}" -f $GuiDataDir)
$txt += ('runExe: {0}' -f $RunExe)
$txt += ''
foreach ($r in $script:Results) { $txt += ("[{0}] {1,-26} {2}" -f $r.Status, $r.Check, $r.Detail) }
$txt += ''
$txt += '-- info --'
foreach ($r in $script:ExtraInfo) { $txt += ("[INFO] {0,-26} {1}" -f $r.Check, $r.Detail) }
$txt | Set-Content -Path $reportTxt -Encoding UTF8
Write-Host ("report   : {0}" -f $reportTxt)
Write-Host ("machine  : {0}" -f $reportJson)

if ($failCount -gt 0) { exit 1 } else { exit 0 }
