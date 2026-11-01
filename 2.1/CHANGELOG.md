# 变更记录（CHANGELOG）

本文件记录每个可交付版本的关键变化、对应提交与验证结果。
格式参考 Keep a Changelog；日期为本机验证日期（2026-11-01，北京时间）。

> **分支说明**：2.0.x 的历史记录是 Gitee 仓库根目录（`NetWatcher/`）的冻结交付。
> 2.1 从 2.0.2 复制出独立文件夹 `2.1/`，版本号统一 **2.1.x → 2.2.1**（当前 **2.2.1 定版**）；本文件位于 `2.1/` 内，记录 2.1/2.2 的变更。

---

## [2.2.1] - 2026-11-01（进程视图刷新保持展开/选中）

> **状态：定版（2.2.1.0）。** 补丁版：修复进程视图每 5 秒自动刷新时丢失"展开状态/选中行"的问题，
> 并纠正"用户主动全部折叠被误判为首次构建而自动全部展开"的行为。

### 修复
- **进程视图刷新后展开状态丢失**：树每次刷新（≥5 秒）整体重建；旧实现用 `FullPath`（含动态字节数文本）判断展开节点，
  重建后文本随数据变化导致匹配失败，用户展开的节点被收起。现在节点改用**稳定业务 key**（`ProcNodeKey/ProcPidKey/ProcIpKey`：
  进程名 / PID / 远端 IP，**不掺动态字节数等文本**），重建后仍能匹配同一节点。
- **"全部折叠"被误判为"首次构建"**：旧逻辑 `!procTreeBuilt || expanded.Count == 0` 会在"用户主动全部折叠"时触发 `ExpandAll()`，
  下次刷新又自动全展开。现在刷新后**默认全部折叠**，只恢复用户展开过的节点；**首次构建、新出现的节点也默认折叠**。
- **选中行与滚动位置丢失**：刷新前记录选中节点 key 与 `TopNode` key，刷新后恢复选中行与滚动位置；
  选中节点若因父节点折叠而不可见，**不强行展开父节点**（避免"刷新又把树撑开"）。
- **切页保持**：切到其它标签页再切回、以及停留本页的自动刷新，展开/选中状态都保持；隐藏页时由 `HandleCreated` /
  `VisibleChanged` 兜底应用展开状态（`ApplyTreeExpansion`）。版本资源升到 **2.2.1.0**。

### 验证（QA 回归 `6dffea3`，2026-11-01）
被测构建：`6dffea3` 源码编译（0 error / 0 warning）；发布前用 2.0 同一张证书重签——**135,056 B / 2.2.1.0 / Authenticode `Valid` / SHA256 `DE0A2B20…`**（`CN=NSYBdeDFY NetWatcher`）。回归在签名前对同源构建执行，完整报告见 `_analysis\v221-验收\01-回归.md`。

| 套件 | 结果 | run tag / 临时目录 |
|---|---|---|
| `regression-p0.ps1` | **PASS=30 / FAIL=0 / WARN=0**（真实数据静止后干净复跑；首个 run 因 Lead `--quit` 用户实例触发 R5 环境性 FAIL，已复跑洗清、报告保留） | `20261101-165800` |
| `regression-p1.ps1` | **PASS=38 / FAIL=0 / WARN=0**（**R9=2.2.1.0**） | `20261101-165628` |
| `regression-activation.ps1` | **PASS=9 / FAIL=0** | `nw21-act-48473a39` |
| `regression-quit.ps1` | **PASS=6 / FAIL=0** | `nw21-quit-5b863180` |
| `verify.ps1 -SkipGui -Seconds 30 -AuditRealData` | **PASS=29 / FAIL=0 / WARN=0**（`SELFTEST_GEOIP` 首连失败、自动重试后 PASS，环境性） | `20261101-165840` |
| `verify.ps1 -Seconds 20 -MutexTag v221`（5 标签 GUI） | **PASS=52 / FAIL=0 / WARN=0** | `20261101-165935` |
| **合计** | **164 项全 PASS，0 FAIL / 0 WARN**（与 2.2.0 定版逐项一致，补丁无回归） | |

- **真机 UI 手测（task-8，最终签名 exe）**：**PASS=40 / FAIL=0 / WARN=0**，5 个必测场景全过、无产品问题、达到可发布 UI 门槛——S1 首次进入进程视图**默认全部折叠**（TVM 总节点 40 / 根 8 / 可见行 8 / 展开 0）；S2 展开 1 进程+PID 并选中 1 条远端 IP，等 **12s（≥2 个 5s 刷新）**状态签名完全一致（展开 2/40、选中索引 2），无 ExpandAll；S3 全部折叠后等 **7s**：展开仍 0、可见行=根节点数、选中保持；S4 实时连接↔进程视图往返后再等 6s 仍保持；S5 新进程节点出现后默认折叠（根 8→9、展开数 2→2 不变）；S6 5 标签可用 / `--quit` / 真实数据零改动。透明说明：本机 WinForms TreeView 的 UIA 桥不暴露 TreeItem，最终以 **Win32 TVM 纯整数消息 + 截图人工复核**（7 张）等价验证，属读取限制非产品缺陷。报告：`_analysis\v221-验收\02-进程树状态验证.md`。
- 版本 2.2.1.0；编译 0 error / 0 warning；签名后 Authenticode `Valid`。
- 提交：`6dffea3`（fix(2.2.1): 进程视图刷新保持展开/选中状态，默认全部折叠）；tag `v2.2.1`。

### 限制（沿用 2.2.0，不变）
- EStats 精确模式本机不可用（`rc=50 / winerr=122`），只能估算；UDP/QUIC 无法逐 IP 归因；IPv6 不在精确覆盖。
- `MainForm` 未拆 partial；150% DPI、真实午夜跨日未实测；DST 25 小时日第 25 小时桶按 >1439 丢弃（中国无 DST）。
- 伪造未来日期 JSON 时历史概览首行被"今天内存汇总"覆盖（不崩溃、非 2.2.x 引入，下版本再改进）。

---

## [2.2.0] - 2026-11-01（智能日期行 + 活动筛选 + 趋势页）

> **状态：定版（2.2.0.0，已签名）。** 用户反馈"今天/昨天/前天没有作用"，本次把日期行做成**按页生效**，
> 实时连接页改为**活动筛选**，并新增第 5 个标签页 **「趋势」**（使用已有 `samples` 分钟桶画 24h 曲线）；
> 发布前完成趋势样本归一化/断点/Y 轴/悬停、筛选语义澄清、5 标签布局等收口修复。

### 修复 / 改进（A：日期行不再"没作用"）
- **日期行按标签页显示**：实时连接页隐藏日期行（该页固定显示今天实时数据）、改用「活动筛选」；进程视图/按日统计/趋势页显示日期行；历史概览列表本身始终列出所有天，不受日期选择过滤（双击某行跳到该日按日统计）。
- **选中态与无数据置灰**：当前日期对应按钮高亮；「今天」恒可选（当天数据可能仅在内存未落盘）；没有数据文件的"昨天/前天"自动置灰；日历 `MaxDate=今天`（禁止选择未来日期）；跨日由 1 秒定时器自动跟随刷新。
- **日期标签与空态**：标题显示 `2026-11-01（今天）` 形式；按日统计无数据时显示"该日期没有采集数据"空态；历史双击跳转、设置窗口关闭返回、托盘隐藏→显示后日期行都会重排（不残留错位）。
- **实时连接页新增「活动筛选」下拉**（替代日期行，与搜索、双击 IP 筛选叠加）：全部 / 今天新出现(NEW) / 仅活跃(ESTABLISHED) / **当前速度 Top20** / 仅公网 IP / 长连接(>60 秒)；两个表格标题显示当前筛选与命中数量，空结果时追加"无匹配结果（当前条件…）；切回「全部」/清空搜索/点「刷新」即可恢复"。
- **筛选语义（最终实现）**：
  - 「今天新出现（NEW）」= 该 IP 在**本地日界当天数据**里出现过（`firstSeenUnix` 落在今天）；重启后按当天数据重建，同日断线重连不重复标 NEW；运行满一天后该筛选约等于「全部」。
  - 「当前速度 Top20」= 按本次采样速率（`SpeedInBps + SpeedOutBps`）排序取前 20 个 IP，**不是历史累计**；IP 汇总表与连接明细使用同一 IP 集合，口径一致。
  - 「仅公网 IP」在设置里关闭「显示内网地址」（`ShowLocalIp=false`）时与「全部」等效，标题会注明"设置已隐藏内网/本机地址"，无副作用。
- **布局**：活动筛选下拉宽 180→214；5 个标签在 900×620 最小窗口实测不挤压/不遮挡。

### 新增（B：「趋势」标签页）
- 第 5 个标签页 **趋势**：自绘 24 小时上下行曲线（数据源 = 每日 JSON 的 `samples` 分钟桶）。
- **数据归一化**：按本地日界换算成 0..1439 分钟序号，跨日/异常分钟丢弃，同一分钟多条**求和合并**并升序排序；标题显示"分钟桶 N 条（原始 X 条，已归并/过滤）（合并重复 Y 条）（忽略跨日/异常 Z 条）"。
- **断点**：相邻分钟桶间隔 **>5 分钟**断开不连线（正好 5 分钟不断）；标题显示"曲线 N 段（空档 >5 分钟断开）"，程序未运行的时段留空、不伪造流量。
- **Y 轴**：1/2/2.5/5×10^n 取整上限（标签如 0/1.00/2.00/3.00/4.00 MB/分）；**真实峰值仍显示在标题**，取整不篡改峰值语义。
- **悬停读数**：鼠标移到绘图区 → 十字线 + "HH:mm 这一分钟 ↓X ↑Y" 读数。
- 顶部汇总：当日总量、分钟桶数量、峰值/分钟、平均/分钟；3 小时网格，图例区分下载/上传。
- 日期行在该页生效：切换日期查看对应日期的曲线；无数据时显示"该日期暂无可绘制的分钟采样数据 / 程序需在该日运行满 1 分钟并已落盘"。
- 刷新策略：趋势页随选中页每 ≥15 秒刷新一次（与历史概览一致）；`--selftest` 输出"趋势绘制 1440 点 × 20 次：平均 X ms/次"性能自测行。
- 绘制：自绘 Panel（双缓冲、无第三方库）；Font/Pen/Brush 缓存在 `TrendGdiCache` 字段，避免每次 Paint 分配。

### 验证（最终全量回归 `1369c0b`，2026-11-01）
被测构建：`1369c0b` 源码编译（0 error / 0 warning）；发布前用同一源码重新签名——**134,032 B / 2.2.0.0 / Authenticode `Valid` / SHA256 `8C3BBD86…`**（`CN=NSYBdeDFY NetWatcher`）。回归在签名前对同源构建执行，完整报告见 `_analysis\v220-验收\02-最终回归.md`。

| 套件 | 结果 | run tag |
|---|---|---|
| `regression-p0.ps1` | **PASS=30 / FAIL=0 / WARN=0** | `20261101-133014` |
| `regression-p1.ps1` | **PASS=38 / FAIL=0 / WARN=0**（R9=2.2.0.0） | `20261101-133052` |
| `regression-activation.ps1` | **PASS=9 / FAIL=0** | 临时目录 `nw21-act-6a773f3a` |
| `regression-quit.ps1` | **PASS=6 / FAIL=0** | 临时目录 `nw21-quit-022f7319` |
| `verify.ps1 -SkipGui -Seconds 30 -AuditRealData` | **PASS=29 / FAIL=0 / WARN=0** | `20261101-133936` |
| `verify.ps1 -Seconds 20 -MutexTag v220-final`（5 标签 GUI） | **PASS=52 / FAIL=0 / WARN=0** | `20261101-134025` |
| **合计** | **164 项全 PASS，0 FAIL / 0 WARN** | |

- GUI 专项（5 标签）：`GUI_TABS_FOUND` / `GUI_TABS_TEXT`（实时连接/进程视图/按日统计/趋势/历史概览）、`GUI_TAB_CLICK_REAL` 5/5、`GUI_LIVE_DATEROW_HIDDEN`（实时页日期行隐藏）、`GUI_DATEBAR_TREND`（趋势页日期行生效）、`GUI_TREND_SUMMARY`（分钟桶/曲线段/悬停提示）、`GUI_TREND_SEGMENTS`（密集 5 分钟桶连成 1 段）、`GUI_TREND_CURVE`（曲线真实像素）全 PASS。
- 趋势性能：`--selftest` 输出「趋势绘制 1440 点 × 20 次：平均 **2.4–2.7 ms/次**」，`SELFTEST_TREND_PERF` 断言 <100ms PASS。
- 修复合并前基线（`d13f110`）：P0 30/30、P1 38/38、activation 9/9、quit 6/6、verify headless 28/28、GUI 5 标签 50/50（`01-基线回归.md`）；定版为 29/52，差异是新增真实断言（`SELFTEST_TREND_PERF`、`GUI_TREND_SEGMENTS`），无 FAIL 新增、无判据削弱。
- 环境波动（已留证，非产品缺陷）：执行中 3 次 `SELFTEST_GEOIP` 因本机到 `ip-api.com` 间歇超时被判 FAIL/WARN，对照组确认网络恢复后 PASS；最终 run 全部消除，失败 run 报告保留未删除。
- **真机 UI 手测（2026-11-01，最终签名 exe）**：8 轮共 **PASS=419 / FAIL=0 / WARN=0**，达到可发布 UI 门槛。覆盖：活动筛选 6 项逐项 + 搜索叠加 + pinnedIp + 空结果可读反馈；日期行按页显示/今天高亮/无数据置灰/日历禁未来/跨日伪造；历史双击跳转；趋势 288/1440/1/2/空数据/断点（354 条 2 段）/Y 轴取整/悬停读数，1440 点重绘平均 14ms；900×620 不挤压不遮挡；托盘隐藏/二次启动唤出/`--quit`/自启项只读；真实数据目录零改动。未测项：150% DPI（不改系统显示设置）、"只有内网 IP"场景（不改系统网络）、托盘图标肉眼可见性（人工项）。详见 `_analysis\v220-验收\03-手工验收.md` §9。
- **发布截图**：`docs/screenshots/` 下 6 张 2.2.0 真机图——`tab1-live.png`、`tab2-proc.png`、`tab3-date.png`、`tab4-trend.png`、`tab5-history.png`、`settings.png`（03 §9.3 交付并人工复核；`tab4-trend.png` 为 288 条/每 5 分钟覆盖全 24h）。

### 限制（如实记录）
- `MainForm` 未拆分 partial（本轮收口不承担重构风险），留待下个版本。
- 150% DPI 未实测（本机 100%）；真实午夜跨日未实测（用伪造多日 datadir 验证跨日状态）。
- DST 25 小时日：第 25 小时的分钟桶按 >1439 丢弃（中国无 DST，影响面可忽略）。
- 边界（非 2.2.0 引入，如实记录）：伪造"未来日期"的 JSON 时，历史概览首行会被"今天内存汇总"覆盖（不显示未来日行），程序不崩溃；仅伪造/系统时间回拨场景触发，正常使用不会出现，下版本再改进。
- EStats 精确模式本机不可用（`rc=50 / winerr=122`），只能估算；UDP/QUIC 无法逐 IP 归因；IPv6 不在精确覆盖。

- 提交：`232810a`（samples 分钟桶保持升序唯一；isNew 恢复「当天」语义）、`1369c0b`（收口：趋势页/活动筛选/日期行/5 标签布局）；2.2.0 定版提交与 tag 见版本发布记录。

---

## [2.1.1] - 2026-10-31（托盘修复 / 优雅退出）

> **状态：定版并签名（2.1.1.0）。** 基于 2.1.0，修复真机使用中发现的托盘图标重复问题，并新增 `--quit`。

### 修复

- **通知区域出现重复/幽灵图标（鼠标划过才消失）**：根因是 `MainForm.EnsureTray()` 用
  `tray.Visible=false; tray.Visible=true` 反复重加托盘图标——`--background`/`StartMinimized` 启动后
  30 秒内每 3 秒一次（共 10 次），每次二次启动、每次 `TaskbarCreated` 也会再重加一次；
  另外 `ExitApp()` 没有停掉托盘补偿定时器，退出过程中定时器还可能 `BuildTray()` 留下"幽灵图标"。
  修复：启动后只重建一次（3 秒时）并立即停止定时器；`EnsureTray()` 只在图标不存在时创建、
  不可见时补一次，不再反复 toggle；`ExitApp()` 先停定时器再释放图标；`BuildTray()` 增加单实例保护。
- 新增 **`--quit` / `--exit`**：请求已运行实例**优雅退出**（保存数据、移除托盘图标、正常结束），
  便于脚本/自动化停止程序，不再需要 `Stop-Process` 强杀（强杀也是幽灵图标的常见来源）。

### 验证

- 新增 `tools/qa/regression-quit.ps1`：**PASS=6 / FAIL=0**（隐藏启动 → `--quit` 0.2s 退出 →
  `startup.log` 有 `Application.Run 退出` → 数据已落盘且 JSON 可解析 → 无 ui-error/crash → 进程清理）。
- 复跑 `regression-p0.ps1` **30/30**、`regression-p1.ps1` **38/38**、`regression-activation.ps1` **9/9**，全 PASS。
- 本机实测：`--quit` 退出后通知区域不再新增残影；此前由测试强杀/反复 toggle 造成的残留图标
  会像 Windows 常见幽灵图标一样，鼠标划过即被系统清理。

---

## [2.1.0] - 2026-10-31（定版）

> **状态：定版（2.1.0.0）。** P0 四项 + P1 八项修复已落地并冻结，经两轮独立回归验收
> （`regression-p0.ps1` 29/29、`regression-p1.ps1` 38/38、P1 后 P0 复跑 29/29，均 0 FAIL/0 WARN），
> GUI 冒烟产品检查全 PASS（39 PASS，2 项 FAIL 为环境归因，见「验证」）。
> **定位**：2.0.2 的小规模迭代修复版（用户原话："版本迭代就是把不够好的地方一点点修到可用"），
> 与 2.0 在 Gitee 仓库里**并列成两个文件夹**交付，根目录的 2.0 文件一律不改。

### 命名与位置（2.1 决定）

| 项 | 2.0 | 2.1 |
|---|---|---|
| 程序名 | IP监控2.0 | **IP监控2.1** |
| exe | `NetWatcher.exe` | `NetWatcher.exe`（不变） |
| 安装目录 | `%LOCALAPPDATA%\Programs\NetWatcher` | **`%LOCALAPPDATA%\Programs\NetWatcher2.1`** |
| HKCU Run 值名 | `NetWatcher` | **`NetWatcher2.1`** |
| 桌面快捷方式 | `IP监控.lnk` | **`IP监控2.1.lnk`** |
| 数据目录 | `%APPDATA%\NetWatcher` | **不变（历史连续，升级不迁移）** |
| 单实例互斥量 | `NetWatcher_SingleInstance_Mutex` | **`NetWatcher2.1_SingleInstance_Mutex`** |
| 数据写锁 | 无 | **`NetWatcher2.1_DataLock_<MD5(数据目录绝对路径小写)>`** |
| 程序集版本 | 2.0.2.0 | **2.1.0.0**（FileVersion / ProductVersion） |

### 已修复（P0，已验证）

- **同日重启恢复当天数据**：程序启动时读取当天已有的 `data\<今天>.json` 并继续累加，
  不再把"重启前当天的数据"当成空白重写（2.0 的缺陷：重启后当天历史丢失）。
  *回归证据 R1*：同一天两次 `--daemon` 同一临时 datadir，`sampleCount` **6 → 12**、
  `firstSampleUnix` 前后不变、`bytesIn 3,117 → 4,086` / `bytesOut 15,189 → 27,426` 不回退。
- **`--selftest` 不再写/覆盖当天数据**：自检对 `data\` 只读，不再创建或覆盖 `data\<今天>.json`；
  存储读写测试改在 `<datadir>\selftest-store\` 临时子目录进行，用后删除。
  *边界*：自检仍会在 `<datadir>` 下写 `selftest.log`（自检自身输出）与一次 GeoIP 查询产生的
  `geocache.json` 缓存，但**不写 `data\`**。
  *回归证据 R2*：预置当天数据哨兵（233 B / `bytesIn=123456` / `sampleCount=42`），
  `--selftest` 前后 SHA256 `9D6138A9…` 与 size 完全一致、`data\` 文件集合不变。
- **`--selftest` 不再篡改 HKCU 开机自启**：自检不再写/删真实的 `Run\NetWatcher2.1` 或 `Run\NetWatcher`；
  注册表往返测试改用临时值名 `NetWatcher2.1_SelfTest_<PID>`，测完删除。
  *回归证据 R3*：`Run\NetWatcher2.1` 与 2.0 的 `Run\NetWatcher` 前后值完全一致、
  无 `*SelfTest*` 临时值残留；`selftest.log` 中有「临时值写入后=True 删除后=False」证据行。
- **同一数据目录只允许一个写入实例**：GUI 与 `--daemon` 启动时抢同一个按数据目录命名的锁
  `NetWatcher2.1_DataLock_<MD5(数据目录绝对路径小写)>`；`--selftest` 只读、不抢锁。
  - `--daemon` 抢不到 → **退出码 2**（0.2s 内退出，`daemon.log` 记录冲突原因）；
  - GUI 抢不到 → 弹标题为 **「IP监控2.1」** 的提示框（MessageBox `#32770`）后退出，不会两个窗口同时写；
  - `--mutex-tag` 只改单实例互斥量名字，**不能**绕过数据写锁（并发测试必须用不同 `--datadir`）。
  *回归证据 R4 / R10*：GUI 占住 datadir 后 daemon exit=2、GUI 存活、数据完好；
  GUI-GUI 同 datadir 冲突时第二个 GUI 弹出「IP监控2.1」提示框、第一个 GUI 仍存活。
- **Store 临时文件唯一名**：原子写盘的临时文件改为 **PID 后缀**（`<文件名>.<进程PID>.tmp`），
  并发或上次崩溃残留的 `.tmp` 不会互相覆盖。
- **单实例/唤出事件 2.1 化**：互斥量 `NetWatcher2.1_SingleInstance_Mutex`、
  唤出事件 `NetWatcher2.1_SingleInstance_Mutex_Activate`；`--mutex-tag X` 时二者都追加 `_X`。
  与 2.0 不同名，两个版本可以并存调试（但数据目录共用，正式使用不要同时运行）。
- **版本资源与标题 2.1 化**：`2.1/src/AssemblyInfo.cs` 提供 2.1.0.0 版本资源
  （ProductName=`IP监控2.1 (NetWatcher)`）；主窗口标题 `IP监控2.1 · 网络连接监控 (NetWatcher)`、
  设置窗口标题 `设置 · IP监控2.1`。

### 已修复（P1，已验证）

- **P1-5 自启状态对账**：打开设置前用 `Startup.IsEnabled()` 读 HKCU 实际值覆盖 `cfg.AutoStart`；
  保存后先写注册表、再回读校准，避免 install / msconfig 改动后被界面误显示、误删自启项。
  *证据*：静态检查 `S_P1_5` PASS；回归 R11（启动流程不误删已存在的 `Run\NetWatcher2.1` sentinel）。
- **P1-6 启动最小化生效**：`startHidden = --background || (cfg.StartMinimized && !--show)`；
  开机自启/最小化场景只驻留托盘，`--show` 可强制显示窗口。
  *回归证据 R6*：隐藏实例 `MainWindowHandle=0`、可见窗口数=0；`--show` 实例主窗口可见。
- **P1-7 管理员重启保留 `--datadir`**：点「以管理员身份重启」时把当前数据目录拼进提权命令行。
  *证据*：静态检查 `S_P1_7` PASS（UAC 交互本机无法自动化）。
- **P1-8 归属地开关即时生效**：设置保存后立即 `GeoIp.SetEnabled(cfg.GeoEnabled)`，无需重启。
  *证据*：静态检查 `S_P1_8` PASS。
- **P1-9 旧 1.0 数据不再假精确**：读取到"`bytesPrecise=true` 但逐 IP 字节合计=0"的 1.0 历史数据时，
  自动降级为估算（`bytesPrecise=false`，逐 IP 同步降级），界面不再显示「逐IP精确」。
  *回归证据 R7*：预置 legacy 数据（`bytesPrecise=True`、逐 IP 全 0）→ `--daemon` 后
  `bytesPrecise False`、`sampleCount 10 → 14`（累积未重置）、`bytes` 不回退。
- **P1-10 精确模式 tooltip 说明仅 IPv4 TCP**：运行模式悬浮提示明确
  「精确字节仅覆盖 IPv4 TCP 连接；IPv6 / UDP 只计入总流量，无法逐 IP 归因」。
  *证据*：静态检查 `S_P1_10` PASS。
- **P1-11 非实时页刷新节流**：实时连接页每次采样刷新；进程视图 / 按日统计页 **≥5 秒**、
  历史概览页 **≥15 秒** 才重建表格，降低采样时的 UI 开销。
  *证据*：静态检查 `S_P1_11` PASS（**动态计时未做，仅静态证据**）。
- **P1-12 EStats 错误可观测与清除**：EStats 首次失败写 `monitor.log`（含 rc/winerr 与诊断）；
  精确模式恢复后清空 `LastEStatsError`，状态栏不再一直标红。
  *证据*：静态检查 `S_P1_12` PASS（本机非管理员无法触发成功路径）。

### 变更（安装 / 卸载脚本 2.1 化）

- `2.1/install.ps1`：安装到 `%LOCALAPPDATA%\Programs\NetWatcher2.1`；
  HKCU Run 值 `NetWatcher2.1`；桌面快捷方式 `IP监控2.1.lnk`；数据目录默认仍 `%APPDATA%\NetWatcher`；
  快捷方式 `WorkingDirectory` 指向程序实际所在目录（`-Portable` 时为 `2.1\bin`）；
  保持幂等与 `-NoShortcut` / `-Portable` / `-DataDir` 语义不变。
- `2.1/uninstall.ps1`：只结束/卸载 2.1 自己的实例、自启值、快捷方式、安装目录；
  默认保留数据；`-KeepBinary` / `-DeleteData` / `-DataDir` 语义不变；
  `-DeleteData` 会二次警告"与 2.0 共用数据目录，2.0 历史也会删"。
- **脚本与 2.0 的边界（硬约束）**：绝不删除或改写 2.0 的 `IP监控.lnk`、`Run\NetWatcher`、
  `%LOCALAPPDATA%\Programs\NetWatcher`；安装时只**只读提示** 2.0 的自启项/运行实例，不替用户动 2.0。
- 两个脚本含中文，均为 **UTF-8 with BOM**，并通过 **Windows PowerShell 5.1 Parser 校验（0 error）**。
- **限制**（已解除）：~~安装/卸载只做静态审查~~ → **2026-10-31 已完成真机安装/卸载验收**（见 `docs/2.1-真机验收补记.md`）。
  升级前仍须先退出 2.0（数据目录共用）。

### 文档

- `2.1/README.md`、`CHANGELOG.md`（本文件）、`docs/START-HERE.md`、`docs/design-2.1.md`
  （由 design-2.0 更新，design-2.0 保留）、`docs/用户手册.md`、`docs/开发与维护指南.md`、
  `docs/踩坑与决策记录.md`（追加 2.1 新坑 §八）、`docs/2.1-交接说明.md`、
  `tools/qa/README.md` 全部 2.1 化；版本号统一 **2.1.0**；截图仍沿用 2.0 真机截图并标注。

### 验证（两轮独立验收，p0-verifier）

被测构建：源码冻结时 `2.1\bin\NetWatcher.exe` 113,664 B / 16:31:07 / SHA256 `F876F10B…`；
版本资源 2.1.0.0；定版发布前用 2.0 旧证书重新签名（签名后哈希会变，以 `verify-sign.ps1` 为准）。

| 验收项 | 命令 | 结果 |
|---|---|---|
| P0 回归 | `regression-p0.ps1` | **PASS=29 FAIL=0 WARN=0**（run tag `20261031-162506`） |
| P1 回归 | `regression-p1.ps1` | **PASS=38 FAIL=0 WARN=0**（run tag `20261031-163501`，含 8 项静态检查） |
| P1 后 P0 复跑 | `regression-p0.ps1` | **PASS=29 FAIL=0 WARN=0**（run tag `20261031-163540`，无回归） |
| 无界面验收 | `verify.ps1 -SkipGui -Seconds 30` | PASS=24 FAIL=2 WARN=2（run tag `20261031-163622`） |
| GUI 冒烟 | `verify.ps1 -Seconds 20 -MutexTag p1qa` | **PASS=39** FAIL=2 WARN=2（run tag `20261031-163730`） |
| 启动顺序回归（新增） | `regression-activation.ps1` | **PASS=9 FAIL=0 WARN=0**（二次启动唤出 / 不同 tag 冲突 / daemon exit=2） |
| 修正后 P0/P1 复跑 | `regression-p0.ps1`、`regression-p1.ps1` | **PASS=30/30、38/38**（2026-10-31 21:42~21:43） |
| 真机安装/卸载 | `install.ps1` → 启动/数据续接 → `uninstall.ps1`（保留数据）→ 重装 → 启动 | **全通过**（见 `docs/2.1-真机验收补记.md`） |

- 无界面 + GUI 共 4 个 FAIL **全部为环境归因，不是产品缺陷**（脚本判据未削弱、未改判）：
  1. `SELFTEST_GEOIP`：本机到 `ip-api.com` 间歇不可达（脚本已自动重试一次仍失败；
     同批 GUI run 该检查曾 PASS：`美国 弗吉尼亚州 Ashburn · Google LLC`）；
  2. `REALDATA_UNTOUCHED`：用户 2.0 管理员实例 **PID 10856** 实时写真实数据目录；
     45 秒闲置、不启动任何被测进程的对照组实验证明变化来自该实例
     （`tools/qa/out/control_realdata_p2*.txt`），被测 2.1 实例全部使用独立 `%TEMP%` datadir。
- 产品检查全 PASS：编译 0 warning、自检、daemon 数据链路、逐 IP 对账误差 0、`bytesPrecise=false`、
  分钟桶上限、真实点击四标签 4/4、列头 100% 可见、轨迹托盘隐藏、截图非白屏等。
- 证据：`2.1\tools\qa\out\`（`report_*.txt`、`regression_*.txt`、`gui_*.png` 等）；
  验收报告 `D:\IP监控2.1版\_analysis\2.1-P0-验收.md`、`2.1-P1-验收.md`。
- 2.0 基线（供对照）：headless 回归 **PASS=27 / FAIL=0**；真实数据 `REALDATA_UNTOUCHED` 通过。

### 限制（如实记录）

- **EStats 精确模式**：本机实测不可用（管理员 `rc=50 / winerr=122`），2.1 只能诚实降级为「估算」；
  P1-12 的 EStats 成功路径无法在本机触发（仅静态证据）。
- **UDP/QUIC** 无法逐 IP 归因；**IPv6** 不在精确字节覆盖范围（tooltip 已说明）。
- P1-7（管理员重启/UAC）无法自动化、P1-11 刷新节流未做动态计时，均为静态检查。
- ~~安装/卸载脚本尚未真机执行~~ **已真机验收通过**（2026-10-31：install → 启动/数据续接 → uninstall 保留数据 → 重装；2.0 目录/自启/快捷方式零改动，见 `2.1-真机验收补记.md`）。
- **P2 体验项未做**（见下）。

### 待办（P2 / 交付）

- **P2 体验项**：列宽记忆、历史趋势图（`samples` 分钟桶已在 JSON 里）、CSV 导出范围选择等。
- **交付**：~~真机安装/卸载验证~~ 已完成（2026-10-31）→ 发布包 `IP监控2.1-发布包.zip` 已重建；
  已推送 Gitee + GitHub（2026-10-31，两远端 main 一致）。
- 提交：已推送 Gitee + GitHub（两远端 main 一致；最新提交见远端）。

---

### 真机验收与启动顺序修正（2026-10-31 21:4x，定版后补记）

- **启动顺序修正（P0-4 回归）**：GUI 的数据写锁改为在「单实例唤出判断」之后才抢，避免 2.1 已在运行时
  再次双击/`--show` 先弹“数据目录被占用”而无法唤出窗口；`--daemon` 仍在启动早期抢锁。
  二次启动等待窗口出现的时间由 1.5s 放宽为最多 5s。新增回归脚本 `tools/qa/regression-activation.ps1`（9/9 PASS）。
- **真机安装/卸载验收通过**：install → 启动 → 真实数据续接（`sampleCount 144→148`、`firstSampleUnix` 不变）→
  `uninstall.ps1`（保留数据，2.0 目录/快捷方式零改动）→ 重装 → 启动（`151→155`）。
  2.0 的 `Run\NetWatcher` 按升级流程停用（保留程序与快捷方式，可手动回退），只保留 `Run\NetWatcher2.1`。
- 修正发生在定版后，`2.1/bin/NetWatcher.exe` 已重新编译并用同一张 2.0 证书重新签名（Authenticode `Valid`）。


## [2.0.2] - 2026-10-31

### 修复（重要）
- **安装到 `%LOCALAPPDATA%\Programs\NetWatcher` 再运行**（`install.ps1`）。
  原因：从 agent 工作区等"受限目录"直接运行程序时，运行环境会把进程限制为**只能写工作区**，
  导致 `%APPDATA%\NetWatcher` 写入失败。表现：进程存在、托盘异常、**没有数据**、IP 列表很少，
  开机自启后看起来"没启动"。
- 退出时的进程识别同时兼容「安装目录」与「仓库 bin」两种路径。
- 所有中文 PowerShell 脚本补齐 **UTF-8 BOM**（PowerShell 5.1 下缺 BOM 会解析失败）。

### 新增
- `install.ps1 -Portable`：绿色模式，不复制程序、原地运行。
- `uninstall.ps1 -KeepBinary`：卸载时保留程序文件。
- `tools/fix-smartscreen.ps1`：检查/解除 Mark-of-the-Web，打印签名与 SmartScreen 设置。
- `docs/` 全套文档：用户手册、开发维护指南、踩坑与决策记录、交接说明、截图。
- 发布包 `IP监控2.0-发布包.zip`（exe + 安装/卸载脚本 + 文档）。

### 验证
- 安装 → 启动 → 数据正常落盘 → 卸载（自启键/快捷方式/安装目录清空、数据保留）→ 重装 → 正常。
- 45 秒覆盖对照：`netstat` 观测 12 个远端 IP，程序记录 14 个，**漏记 0**。

- 提交：`6fd31c7`

---

## [2.0.1] - 2026-10-31

### 修复（可用性）
- **引擎与界面解耦**：监控引擎在创建窗口之前启动（`Program.Main`），UI/托盘异常不再导致"进程活着但不采集"。
- **第二次启动唤出已有窗口**（不再只弹"已经在运行"）；已有实例无响应时给出可操作提示（任务管理器结束进程）。
  实现：命名互斥量 + 命名事件 `..._Activate`，第二实例 `Set()` 后退出。
- **托盘自愈**：响应资源管理器重启（`TaskbarCreated` 广播）重建图标；`--background` 启动后 30 秒内每 3 秒重试。
- 新增 `startup.log`（启动时间线）、崩溃日志改写到数据目录（`crash.log` / `ui-error.log`）。
  （原因：WMI 启动的进程 `%TEMP%` 可能为空且不可写，早期崩溃日志丢失、表现为"静默退出"。）

### 改进（覆盖率）
- 记录**所有有远端地址的 TCP 状态**（ESTABLISHED / SYN_SENT / FIN_WAIT / TIME_WAIT / CLOSE_WAIT…），只排除 LISTEN；
  字节差分仍只对 ESTABLISHED，避免估算失真。
- 采样间隔新增 **1 秒**档，默认从 5 秒改为 **2 秒**。

### 新增
- `--mutex-tag <tag>`：多实例并行测试（互斥名加后缀）。
- `--show`：唤出已运行实例窗口（与普通启动等价）。
- 提交：`8b9a9ae`、`bbff3bc`（文档）

---

## [2.0.0] - 2026-10-31

基于 IP监控1.0（`cfe5597`）整体重写。核心目标是修掉 1.0 的核心缺陷并把界面做成可用。

### 修复（1.0 的真实缺陷，均有实测证据）
- **逐 IP / 逐进程字节恒为 0**：1.0 在管理员分支无条件 `bytesPrecise = true`，而 EStats 读取失败被静默吞掉。
  2.0 改为按实际返回值判断，失败写日志并在状态栏/tooltip 标注，**不再谎报精确**。
- **总流量口径不一致**：排除 Loopback / Tunnel 网卡，使"逐 IP 合计"与"总流量"对得上（估算模式误差 0）。
- **"连接次数"语义错误**：1.0 每采样累加（一个 PID 能到 585 次），2.0 改为真实新增连接数。
- **进程合并错误**：进程键加入进程启动时间，避免 PID 复用被合并；同时记录进程完整路径。
- **界面不可用**：1.0 的 TabControl 与列头被 Top Panel 遮挡（四个标签页只能看到一个）。
  2.0 改用 `TableLayoutPanel` 三行布局（header/tabs/footer），四个标签页可见可点。
- **数据写入脆弱**：1.0 每采样重写整天 JSON、无原子写。2.0 改为原子写（tmp → Replace）+ 15 秒落盘节流 + 分钟桶（≤1440/天）。
- **IP 归属地超时**：本机系统代理不可用会导致查询必然超时，2.0 显式 `Proxy = null` 直连。

### 新增
- 四个标签页（实时连接 / 进程视图 / 按日统计 / 历史概览）、列头排序、搜索过滤、`Ctrl+C` 复制、
  双击 IP 筛选、`NEW` 标记与托盘气泡、1 秒刷新、设置页重做（1/2/5/10/30/60 秒、保留天数、自启、最小化、Geo、新 IP 提醒、显示内网）。
- EStats 参数**运行时自动探测**（rw=1/4 × rod=48/16/1024），并把 rc/winerr 打进 `--selftest` 日志。
- `--selftest` 内置 EStats 诊断矩阵（判断"精确模式是否可用"的唯一依据）。
- 工具链：`install.ps1` / `uninstall.ps1`（幂等）、`tools/sign`（自签名）、`tools/qa/verify.ps1`（一键验收）、
  `build-and-sign.bat`、`docs/design-2.0.md`（设计契约）。
- 提交：`c969b5d`

### 已知限制（2.0.0 起，长期有效）
- 逐 IP 精确流量依赖 Windows `GetPerTcpConnectionEStats`；**开发机实测不可用**
  （非管理员 `rc=50` + `1784`；管理员 `rc=50` + `winerr=122`；三种封送方式结果一致），
  因此本机只能提供"估算"。
- UDP / QUIC 无法逐 IP 归因（Windows 接口不提供 UDP 远端地址）。
- 采样是离散的：短于采样间隔的连接可能漏，想更全调到 1 秒。

---

## [1.0.0] - 2026-10-31（历史基线）

- 从 FileAudit（PowerShell 文件审计，v1）整体替换为 C# WinForms 网络连接监控 NetWatcher。
- 提交：`cfe5597`。存在上述多项缺陷，**不建议继续使用**，仅作为数据/行为对照基线。
