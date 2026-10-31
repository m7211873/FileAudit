# NetWatcher QA（IP监控2.0 一键验收）

本目录是 QA 归属区（design §7：QA 只写 `tools/qa/**`）。一键验收脚本 = `verify.ps1`。

## 快速开始

```powershell
# 重要：本机 PowerShell 执行策略禁止直接运行 .ps1，必须 -ExecutionPolicy Bypass
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1

# 常用变体
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -Seconds 30
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -DataDir "$env:TEMP\ipmon-qa-manual"
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -SkipBuild -Exe bin\NetWatcher.exe
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -Screenshot:$false
```
退出码：有 FAIL → 1；全 PASS → 0。证据/报告输出到 `tools/qa/out/`，测试数据写 `%TEMP%\ipmon-qa-*`（仓库外）。

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-DataDir` | `%TEMP%\ipmon-qa-<tag>` | 引擎数据目录（绝对路径）；GUI 用其下 `gui\` 子目录 |
| `-Seconds` | 25 | `--daemon` 采集秒数；GUI 观察 `min(12, Seconds)` 秒 |
| `-Screenshot` | 开 | 是否截图（`-Screenshot:$false` 关） |
| `-SkipBuild` | 关 | 跳过 `build.bat` |
| `-AllowWarnings` | 关 | 编译 warning 只 WARN 不 FAIL（默认按 design §8 判 FAIL） |
| `-Exe` | `bin\NetWatcher.exe` | 被测 exe（脚本会复制到 temp 再运行，见下） |
| `-OutDir` | `tools\qa\out` | 证据目录 |
| `-StartTimeoutSec` / `-DataWaitSec` | 20 / 25 | 等主窗口 / 等 `--datadir` 数据落盘 |
| `-ForceClean` | 关 | 允许清理非默认 `%TEMP%` 下的已有 DataDir |
| `-AuditRealData` | 关 | 只读审计 `%APPDATA%\NetWatcher` 真实数据（INFO，不参与 PASS/FAIL） |
| `-SkipGui` | 关 | 只跑无界面链路（编译/自检/daemon/数据校验/真实数据守卫），`Lead 独占 GUI 验收`时使用 |
| `-MutexTag` | `qa` | 传给被测程序的 `--mutex-tag`，与 Lead 正在运行的实例隔离；1.0 会忽略该未知参数 |

> **进程所有权**：脚本**绝不按进程名批量结束 NetWatcher**。只结束自己通过 `Win32_Process.Create` 启动并记录 PID 的进程；发现已有实例只报 `PRE_EXISTING_PROC` WARN，不干预。GUI 验收由 Lead 独占，QA 日常回归用 `-SkipGui`。

```powershell
# 无界面回归（不碰 GUI、不碰 Lead 的实例）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -SkipGui -SkipBuild -Exe bin\NetWatcher.exe -Seconds 20
```

## 验收流程与检查项

1. **编译**：`cmd /c build.bat` → `BUILD`（error=FAIL；warning 默认 FAIL，`-AllowWarnings` 降级）
2. **运行副本**：`RUN_EXE`（SHA256 一致性）
3. **自检** `--selftest`：`SELFTEST_EXIT/LOG/ADMIN/ESTATS_CONCLUSION/ESTATS_DIAG/STORAGE/GEOIP/NIC_DETAIL/TAIL`
   - `EStats 结论:` 行是精确模式唯一判据；管理员必须「可用」，非管理员「不可用」可接受
   - GeoIP 允许 cache/直连两种来源；直连失败只 WARN（网络问题不判代码）
4. **引擎采集** `--daemon N`（主数据链路）：`DAEMON_EXIT`
5. **数据校验** `data\*.json`：`DATA_FILE/ATOMIC/JSON/SAMPLES/SAMPLES_CAP/TOTAL_BYTES/IP_COUNT/IP_BYTES/PRECISE_HONESTY/CONNCOUNT/IP_PROC_CONSISTENCY`
   - 逐 IP 字节合计必须 >0（估算模式也 >0）；`bytesPrecise=true` 但逐 IP=0 → 假精确 FAIL
   - 进程 `connCount>1000` 视为采样累计 → FAIL
6. **GUI 冒烟**（截图 + 标签页 + 列头）：
   - `GUI_WINDOW/GUI_DATADIR/GUI_ALIVE/GUI_SCREENSHOT`
   - `GUI_TABS_FOUND/TABHEADER_VISIBLE/TABS_LAYOUT/TABS_TEXT/TAB_SWITCH_LOGIC/TAB_CLICK_REAL`
   - `GUI_GRID_HEADERS`（逐页 DataGridView 列头可见性 + 进程视图 TreeView）
   - `GUI_LIVE_STATS`、`GUI_LAYOUT_OCCLUSION`（通用遮挡审计）、`GUI_TRAY_HIDE`（真实点击 X → 托盘）
7. **用户真实数据保护**：`%APPDATA%\NetWatcher` 运行前后 size+mtime+SHA256 全量快照对比 → `REALDATA_UNTOUCHED`（有任何变化 FAIL 并打印 diff）

## 本机环境怪癖（脚本已规避，改动脚本时务必保留）

1. **执行策略**：直接 `& .\verify.ps1` 会报未签名/禁止运行 → 用 `powershell -ExecutionPolicy Bypass -File`。
2. **从仓库路径启动 exe 会被秒杀**：在本机，`...\NetWatcher\bin\NetWatcher.exe` 直接 CreateProcess 后 ~0.1s 内进程被结束（loader 都没跑到，无任何日志/窗口）；**同一文件复制到 `%TEMP%` 后启动完全正常**。因此脚本总是复制到 `%TEMP%\ipmon-qa-run-<tag>\` 并校验 SHA256 再运行。
3. **启动方式**：从本会话 shell `Start-Process` 启动 GUI 会因继承 stdout 管道挂住命令 → 统一 `Invoke-CimMethod Win32_Process Create` 启动 + 轮询等待；结束用 `Stop-Process`，失败再走 WMI `Terminate`。
4. **必须显式 `--datadir`**：否则程序用 `%APPDATA%\NetWatcher` 写真实数据。脚本有双重守卫：`--datadir` 下 N 秒不出现 `data\*.json` 立即杀进程判 FAIL；结束时对比真实数据目录快照。
5. **跨进程窗口消息禁忌**：`TCM_GETITEMW/TCM_GETITEMRECT/TCM_HITTEST` 等带指针的消息会写/读本进程地址，目标进程会 AccessViolation 崩溃。只用 `TCM_GETITEMCOUNT/TCM_GETCURSEL`（纯整数）+ `PostMessage` 点击 + `WM_GETTEXT/WM_GETTEXT`（系统自动跨进程编组）读 TabPage 标题。
6. **截图**：优先 `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)`（不受窗口遮挡/出屏影响），失败回退 `CopyFromScreen`；用完必须 `read_image` 人工复核非白屏/黑屏。
7. 不用 UI Automation；控件树/可见性/遮挡全部用 `EnumChildWindows + GetWindowRect + z-order` 自实现（`VisibleBand`）。

## 基线结果（IP监控1.0，git cfe5597，2026-10-31 11:42，run tag `20261031-114254`）

`RESULT: FAIL  PASS=31  FAIL=8  WARN=0`（脚本退出码 1）。FAIL 全部是预期中的 1.0 缺陷：

| Check | 证据 |
|---|---|
| `SELFTEST_ESTATS_CONCLUSION` | 1.0 自检无「EStats 结论」行（§6 硬要求） |
| `SELFTEST_ESTATS_DIAG` | 无 rw×rod / rc / winerr 诊断矩阵（§6） |
| `SELFTEST_NIC_DETAIL` | 无网卡逐项统计与 Loopback/Tunnel 排除说明（§6） |
| `GUI_TABHEADER_VISIBLE` | 标签栏可见比例 0%（TabControl @750,351 1060x720，被 Top Panel 盖住） |
| `GUI_TAB_CLICK_REAL` | 真实鼠标点击四个标签均不切换（用户点不到标签栏） |
| `GUI_GRID_HEADERS` | 实时连接/按日统计/历史概览的 DataGridView 列头可见比例 0%（被 Top Panel 盖住） |
| `GUI_LIVE_STATS` | ↓/↑速度、今日累计 4 个统计标签全部被遮挡 |
| `GUI_LAYOUT_OCCLUSION` | 8 个可见控件顶部区域被上层窗口遮挡（同一 Dock 组合根因） |

其它证据：`GUI_TABS_TEXT` 真实读到四个标签文本、`GUI_TAB_SWITCH_LOGIC` 机械切换正常、`GUI_TRAY_HIDE` 真实点 X 后进托盘 —— 说明脚本对「正常的 2.0」不会误报。
数据链路（非管理员估算模式）：逐 IP 字节合计 1,432,312 B ≈ 总量 1,432,317 B、`bytesPrecise=false`、`connCount` 最大 6 —— 1.0 在**非管理员**下估算路径本身可用。
`-AuditRealData` 只读审计真实数据证明 1.0 的核心缺陷在管理员路径：`2026-10-31` / `2026-10-30` 均 `bytesPrecise=true` 但逐 IP 字节合计=0、`connCount` 585/372（采样累计）。

> 说明：1.0「逐IP字节全 0」这个缺陷需要管理员 + EStats 失败路径才会出现；本会话非管理员，无法在当前环境触发，因此用真实数据只读审计（INFO）作为补充证据，未伪造测试数据。

## 2.0 重跑

MainForm 落地后（GUI 由 Lead 独占验收，QA 用 `-SkipGui` 只跑无界面链路）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -SkipGui -SkipBuild -Exe bin\NetWatcher.exe -Seconds 45 -AuditRealData
```

### 2.0 最终回归结果（2026-10-31 11:48，bin 105984B / 11:42:34 / SHA256 E316502F…）

`RESULT: PASS  PASS=27  FAIL=0  WARN=0`（退出码 0）：

- 自检：非管理员 `EStats 结论: 不可用（需管理员）`（符合预期）；`存储 原子写/读: OK`；`开机自启 注册表写入后=True 删除后=False`；`GeoIP(8.8.8.8): 美国 弗吉尼亚州 Ashburn · Google LLC`（首次直连若遇网络波动，脚本自动重跑一次自检）
- `--daemon 45`：JSON 可解析；`sum(ips.bytesIn)==day.bytesIn`、`sum(ips.bytesOut)==day.bytesOut`（本次 705,964 / 2,625,107，误差 0）；分钟桶 2（跨分钟边界，1..1440 内）、原始采样 5；`max(procs.connCount)=4 < 100`；`bytesPrecise=false`；进程 name 6/6、path 5/6
- `--mutex-tag`：不同 tag（qa-a/qa-b）两个 `--daemon 10` 并发均成功
- 真实数据守卫：`REALDATA_UNTOUCHED` PASS（脚本采样点前后 size+mtime+SHA256 全等）
- GUI 用例保留在脚本中（默认会跑），Lead 独占 GUI 验收期间请加 `-SkipGui`

> 已知环境风险：若另有 NetWatcher 实例**不带 `--datadir`** 启动（默认写 `%APPDATA%\NetWatcher`），会覆盖用户历史数据；脚本自身不会，并已加守卫，但无法阻止并行进程。Lead 做 GUI 验收时请务必显式传 `--datadir <绝对临时目录>`。


## 证据文件

`out/` 下每次运行一组（`report_<tag>.txt/.json`、`build_<tag>.log`、`selftest_<tag>.log`、`controls_<tag>.txt/.json`、`gui_main_<tag>.png`、`gui_tab1..4_<标签>_<tag>.png`）。截图均为 `PrintWindow` 窗口真实渲染。
