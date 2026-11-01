# NetWatcher QA（IP监控2.1 一键验收 + P0/P1 回归）

本目录是 QA 归属区（design §7：QA 只写 `tools/qa/**`）。一键验收 = `verify.ps1`；
P0 修复回归 = `regression-p0.ps1`；P1 修复回归 = `regression-p1.ps1`。全部脚本 UTF-8 BOM、PS 5.1 Parser 0 错误。
**当前版本：2.2.0（5 标签，含「趋势」页）；定版验收数字见下方「2.2.0 最终验收结果」。**

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

## 2.2.0 最终验收结果（2026-11-01 定版，独立 QA 取证；代码 `1369c0b`）

| 项 | 结果 | 证据 |
|---|---|---|
| 编译 `build.bat` | **0 error / 0 warning**；`bin\NetWatcher.exe` 132,608 B、FileVersion/ProductVersion **2.2.0.0** | `out/build_*.log` |
| P0 回归 `regression-p0.ps1` | **PASS=30 FAIL=0 WARN=0**（tag `20261101-133014`） | `out/regression_20261101-133014.txt/.json` |
| P1 回归 `regression-p1.ps1` | **PASS=38 FAIL=0 WARN=0**（tag `20261101-133052`；R9=2.2.0.0） | `out/regression_p1_20261101-133052.txt/.json` |
| 启动顺序 `regression-activation.ps1` | **PASS=9 FAIL=0**（临时目录 `nw21-act-6a773f3a`） | 同目录脚本输出 |
| 托盘/退出 `regression-quit.ps1` | **PASS=6 FAIL=0**（临时目录 `nw21-quit-022f7319`） | 同目录脚本输出 |
| 无界面 `verify.ps1 -SkipGui -Seconds 30 -AuditRealData` | **PASS=29 FAIL=0 WARN=0**（tag `20261101-133936`） | `out/report_20261101-133936.txt/.json` |
| GUI 5 标签 `verify.ps1 -Seconds 20 -MutexTag v220-final` | **PASS=52 FAIL=0 WARN=0**（tag `20261101-134025`；含全部 2.2.0 GUI/趋势页/日期行/性能断言） | `out/report_20261101-134025.txt/.json`、`out/gui_*_20261101-134025.png` |

- 环境说明（判据未削弱、未改判）：
  1. `SELFTEST_GEOIP`：定版最终 run（13:39/13:40）直连 `ip-api.com` 成功 → PASS。此前 13:32–13:37 的几次尝试该检查间歇超时
     （对照组 `_analysis\v220-验收\raw\final_geoip_control.log`：同一时段 ip-api.com 时通时断、10s 超时，而 `https://www.baidu.com/` 95ms/200 OK），
     属网络波动（2.1.1 亦记录为已知环境性），脚本已内置一次重试；若发布前复跑偶发该 FAIL，按此归因。
  2. `SELFTEST_ESTATS_DIAG`：判据已修正为校验 **rw×rod 诊断组合数 >=6**（design §6 矩阵 rw 1/4 × rod 48/16/1024），
     不再用「诊断行数 >=5」——行数等于自检时远端连接数（3~5 随环境变），会产生假 WARN。最终 run 30 组合 → PASS。
  3. `REALDATA_UNTOUCHED` PASS：所有运行前后 `%APPDATA%\NetWatcher` 9 文件 size+mtime+SHA256 全一致；
     用户 2.0 实例 PID 10856 未运行（严格判定一次通过）。
- 2.2.0 新增 GUI 覆盖（逐项真断言，非“假 PASS”）：
  - 5 标签文本/切换/真实点击全 PASS；每页 DataGridView 数（剔除趋势页自绘 Panel）= `2,0,1,0,1`；
  - 趋势页专项：`GUI_TREND_SUMMARY`（真实汇总文本）、`GUI_TREND_SEED_LOADED`（预置 24 分钟桶、读到 26 条）、
    `GUI_TREND_SEGMENTS`（密集分钟桶连成 1 段，断点判据不误断）、`GUI_TREND_PANEL`（自绘 Panel 1148×534 可见 100%）、
    `GUI_TREND_CURVE`（截图曲线区像素证据：下载蓝线 625 px / 上传橙线 330 px）；
  - 活动筛选/按页日期行：`GUI_LIVE_DATEROW_HIDDEN`、`GUI_LIVE_ACTIVITY_FILTER`、`GUI_DATEBAR_TREND` 全 PASS；
  - 自检性能：`SELFTEST_TREND_PERF` 1440 点×20 次平均 2.4–2.7ms（阈值 <100ms）。
- 详细报告：`D:\IP监控2.1版\_analysis\v220-验收\01-基线回归.md`（WIP d13f110 基线）、`02-最终回归.md`（定版 1369c0b，逐项对比基线）。

### 2.1.1 历史基线（2026-10-31，仅存档）

| 项 | 结果 | 证据 |
|---|---|---|
| `regression-p0.ps1` | PASS=29 FAIL=0 WARN=0 | tag `20261031-162506` |
| `regression-p1.ps1` | PASS=38 FAIL=0 WARN=0 | tag `20261031-163501` |
| `verify.ps1 -SkipGui` | PASS=24 FAIL=2 WARN=2（环境归因） | tag `20261031-163622` |
| `verify.ps1`（GUI，4 标签） | PASS=39 FAIL=2 WARN=2（环境归因） | tag `20261031-163730` |

- 2.1.1 的 4 个 FAIL 全部为环境归因（GEOIP 网络 / 用户 PID 10856 实时写真实目录，对照实验见 `out/control_realdata_p2*.txt`），
  产品检查全 PASS（4 标签、列头 100%、统计标签、托盘、截图非白屏）。
- 详细报告：`D:\IP监控2.1版\_analysis\2.1-P0-验收.md`、`2.1-P1-验收.md`。

## 2.1 P0 修复回归（`regression-p0.ps1`）

```powershell
# 必须 -ExecutionPolicy Bypass；脚本自己会复制 exe 到 %TEMP%、用绝对 %TEMP% datadir、只结束自己记录的 PID
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-p0.ps1
```

- 用例：R1 同日重启累积（daemon 12s×2，sampleCount 递增/firstSampleUnix 不变/bytes 不回退）；R2 selftest 不动当天数据（预置哨兵，SHA256 前后一致）；R3 selftest 不动 HKCU Run 真实值（`Run\NetWatcher2.1`、`Run\NetWatcher` 前后完全一致 + 无临时值残留）；R4 单写实例（GUI 占住 datadir 后 daemon 退出码必须=2、GUI 存活、数据不破坏、daemon.log 有记录）；R5 全程 `%APPDATA%\NetWatcher` size+mtime+SHA256 护栏（用户实例 PID 10856 在写时按 INFO 归因，不算失败）。
- 报告：`out/regression_<tag>.txt/.json`；退出码 0/1。
- 2026-10-31 独立验收基线：`RESULT: PASS  PASS=29 FAIL=0 WARN=0`（run tag `20261031-162506`），详见 `_analysis\2.1-P0-验收.md`。
- **2.2.0 定版（2026-11-01，代码 `1369c0b`）：`RESULT: PASS  PASS=30 FAIL=0 WARN=0`（run tag `20261101-133014`）。**

## 2.1 P1-A/B 修复回归（`regression-p1.ps1`）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-p1.ps1
```

- 用例：R6 StartMinimized 生效 + `--show` 强制可见；R7 1.0 旧数据假精确降级（bytesPrecise true→false、sampleCount 累积、bytes 不回退）；R8 自启 on/off 往返（值含 --background/--datadir/绝对 datadir，2.0 的 Run\NetWatcher 全程不变）；R9 版本资源 `2.x.y.0`（2.2.0 起为 2.2.0.0）；R10 GUI-GUI 同 datadir 冲突（第二个 GUI 弹 title=`IP监控2.1` 提示框、A 仍存活）；R11 启动流程不得误删已存在自启项；另含 P1-5/6/7/8/9/10/11/12 静态源码检查。
- 注册表安全：脚本开始备份 `Run\NetWatcher2.1` 与 `Run\NetWatcher`，各用例 finally + 外层 finally 双重精确恢复（原本不存在→删除），验证值名含点号用 .NET Registry API 按完整值名读写。
- 报告：`out/regression_p1_<tag>.txt/.json`；2026-10-31 独立验收基线：`RESULT: PASS  PASS=38 FAIL=0 WARN=0`（run tag `20261031-163501`），详见 `_analysis\2.1-P1-验收.md`。
- **2.2.0 定版（2026-11-01，代码 `1369c0b`）：`RESULT: PASS  PASS=38 FAIL=0 WARN=0`（run tag `20261101-133052`，R9=2.2.0.0）。**

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
| `-MutexTag` | `qa` | 传给被测程序的 `--mutex-tag`（2.1 单实例名后缀）；**不能绕过数据写锁**——并发测试必须用不同 `-DataDir` |

> **进程所有权**：脚本**绝不按进程名批量结束 NetWatcher**。只结束自己通过 `Win32_Process.Create` 启动并记录 PID 的进程；发现已有实例只报 `PRE_EXISTING_PROC` WARN，不干预。GUI 验收由 Lead 独占，QA 日常回归用 `-SkipGui`。

```powershell
# 无界面回归（不碰 GUI、不碰 Lead 的实例）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -SkipGui -SkipBuild -Exe bin\NetWatcher.exe -Seconds 20
```

## verify.ps1 的 2.1/2.2.0 适配点（改动脚本时务必保留）

- `MUTEX_TAG_DIFF`：2.1 数据写锁按绝对 `--datadir` 派生，**并发必须用不同 datadir**；
  `--mutex-tag` 只隔离单实例互斥量，不能绕过写锁。
- `GUI_LIVE_STATS`：正则改为实际文案「↓ 下载速度 / ↑ 上传速度 / 今日下载 / 今日上传」。
- `SELFTEST_AUTOSTART`：2.1 自检用临时值名做往返，脚本校验「临时值写入后=True 删除后=False」；
  若日志出现真实值名结果行 → 直接 FAIL（防止 selftest 改真实自启）。
- `SELFTEST_DATA_WRITE`（新增 WARN）：自检后若 `data\` 出现文件即告警（2.1 要求 selftest 不写当天数据），
  先告警再清理以免干扰后续 daemon 校验，**不静默掩盖**。
- `PRE_EXISTING_PROC`：检测到用户 2.0 实例（PID 10856）或其它并行 NetWatcher GUI 时只 WARN，不结束、不按进程名杀。
- **2.2.0 五标签/趋势页（2026-11-01 收口，判据已加强，勿回退）**：
  - 期望标签 = `实时连接 / 进程视图 / 按日统计 / 趋势 / 历史概览`；每页 DataGridView 期望数按**标签名**映射
    （`2 / 0 / 1 / 0 / 1`，必须**相等**，不再用下标数组与 `-lt`）。
  - 趋势页是**自绘 Panel（不是 DataGridView）**：计数前先按 HWND 把自绘 Panel 从网格候选剔除，避免“Panel 被当网格”的假 PASS；
    趋势页专项断言 `GUI_TREND_SUMMARY`（真实汇总文本，禁止「加载中…」）、`GUI_TREND_SEED_LOADED`（预置 24 个分钟桶必须被读到）、
    `GUI_TREND_SEGMENTS`（相邻 5 分钟桶必须连成 1 段，断点判据不误断正常数据）、`GUI_TREND_PANEL`（自绘画布可见/不遮挡）、
    `GUI_TREND_CURVE`（截图曲线区像素级证明蓝/橙曲线已绘制，而非只有坐标轴）。
  - 趋势种子：脚本在自己的 `%TEMP%\<tag>\gui\data` 预置 24 个「间隔 5 分钟」的分钟桶（绝不写真实数据目录），
    同时把 `GUI_DATADIR` 守卫加强为**预置文件必须被 GUI 启动后重写**（不能因为预置文件存在就放水）。
  - 2.2.0 按页日期行：`GUI_LIVE_DATEROW_HIDDEN`（实时连接页隐藏日期行）、`GUI_LIVE_ACTIVITY_FILTER`（活动筛选下拉可见）、
    `GUI_DATEBAR_TREND`（趋势页日期行 + 今天/昨天/前天可见）。
  - 自检性能：`SELFTEST_TREND_PERF` 校验「趋势绘制 1440 点 × N 次：平均 X ms/次」存在且 <100ms。
  - `SELFTEST_ESTATS_DIAG`：按 rw×rod 诊断**组合数 >=6** 判定（design §6 矩阵 rw 1/4 × rod 48/16/1024），
    不再用「诊断行数 >=5」——行数 = 自检时远端连接数（随环境 3~5 变），会产生假 WARN。
  - 真实点击 `GUI_TAB_CLICK_REAL` 最多重试 3 次（并行 GUI 可能抢前台；3 次都失败仍判 FAIL）。

## 验收流程与检查项

1. **编译**：`cmd /c build.bat` → `BUILD`（error=FAIL；warning 默认 FAIL，`-AllowWarnings` 降级）
2. **运行副本**：`RUN_EXE`（SHA256 一致性）
3. **自检** `--selftest`：`SELFTEST_EXIT/LOG/ADMIN/ESTATS_CONCLUSION/ESTATS_DIAG/STORAGE/GEOIP/NIC_DETAIL/TAIL`；
   2.1 额外校验 `SELFTEST_AUTOSTART`（临时值名往返）与 `SELFTEST_DATA_WRITE`（自检不得写 `data\`，出现即 WARN）；
   2.2.0 额外校验 `SELFTEST_TREND_PERF`（趋势绘制 1440 点性能行，<100ms）
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
   - 2.2.0 趋势页：`GUI_TREND_SUMMARY/SEED_LOADED/SEGMENTS/PANEL/CURVE`（自绘 Panel，不是 DataGridView）
   - 2.2.0 日期行/筛选：`GUI_LIVE_DATEROW_HIDDEN/GUI_LIVE_ACTIVITY_FILTER/GUI_DATEBAR_TREND`
   - `GUI_LIVE_STATS`、`GUI_LAYOUT_OCCLUSION`（通用遮挡审计）、`GUI_TRAY_HIDE`（真实点击 X → 托盘）
7. **用户真实数据保护**：`%APPDATA%\NetWatcher` 运行前后 size+mtime+SHA256 全量快照对比 → `REALDATA_UNTOUCHED`（有任何变化 FAIL 并打印 diff）

## 本机环境怪癖（脚本已规避，改动脚本时务必保留）

1. **执行策略**：直接 `& .\verify.ps1` 会报未签名/禁止运行 → 用 `powershell -ExecutionPolicy Bypass -File`。
2. **从仓库路径启动 exe 会被秒杀**：在本机，`...\NetWatcher\bin\NetWatcher.exe` 直接 CreateProcess 后 ~0.1s 内进程被结束（loader 都没跑到，无任何日志/窗口）；**同一文件复制到 `%TEMP%` 后启动完全正常**。因此脚本总是复制到 `%TEMP%\ipmon-qa-run-<tag>\` 并校验 SHA256 再运行。
3. **启动方式**：从本会话 shell `Start-Process` 启动 GUI 会因继承 stdout 管道挂住命令 → 统一 `Invoke-CimMethod Win32_Process Create` 启动 + 轮询等待；结束用 `Stop-Process`，失败再走 WMI `Terminate`。
4. **必须显式 `--datadir`**：否则程序用 `%APPDATA%\NetWatcher` 写真实数据。脚本有双重守卫：`--datadir` 下预置的日文件必须在 N 秒内被 GUI **重写**（只“文件存在”不算过），否则杀进程判 FAIL；结束时对比真实数据目录快照。
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

## 2.0 重跑（历史对照）

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

`out/` 下每次运行一组（`report_<tag>.txt/.json`、`build_<tag>.log`、`selftest_<tag>.log`、`controls_<tag>.txt/.json`、`gui_main_<tag>.png`、`gui_tab1..5_<标签>_<tag>.png`）。截图均为 `PrintWindow` 窗口真实渲染。

## 2.1 启动顺序回归（`regression-activation.ps1`）

用于锁定「单实例唤出」与「数据写锁」的先后顺序（P0-4 修正后的行为，2026-10-31 新增）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-activation.ps1
```

- A1~A3：`StartMinimized` 隐藏启动 + `--show` 二次启动 → 唤出窗口、二次进程退出；
- B1~B2：普通二次启动同样唤出并退出；
- C1~C2：不同 `--mutex-tag` 抢同一 datadir → 第二个实例提示“数据目录被占用”、首个实例不受影响；
- D1：GUI 占 datadir 时 `--daemon` 退出码 = 2；
- E1：清理检查。
- 2026-10-31 基线：`RESULT: PASS  PASS=9 FAIL=0 WARN=0`。

## 2.1.1 托盘修复回归（`regression-quit.ps1`）

用于锁定 `--quit` 优雅退出与托盘生命周期修复（2026-10-31 新增）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-quit.ps1
```

- Q1 启动隐藏；Q2 `--quit` 后主实例 10s 内退出；Q3 `startup.log` 有 `Application.Run 退出`；
  Q4 数据已落盘且 JSON 可解析；Q5 无 ui-error/crash；Q6 进程清理。
- 2026-10-31 基线：`RESULT: PASS  PASS=6 FAIL=0`（2.2.0 定版复跑：`RESULT: PASS  PASS=6 FAIL=0`，临时目录 `nw21-quit-022f7319`）。
- 同时 `regression-p1.ps1` 的 R9 版本断言改为接受 `2.x.y.0`（2.1.1 起版本号会变；2.2.0 定版为 2.2.0.0）。
