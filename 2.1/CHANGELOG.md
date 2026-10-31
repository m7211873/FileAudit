# 变更记录（CHANGELOG）

本文件记录每个可交付版本的关键变化、对应提交与验证结果。
格式参考 Keep a Changelog；日期为本机验证日期（2026-10-31，北京时间）。

> **分支说明**：2.0.x 的历史记录是 Gitee 仓库根目录（`NetWatcher/`）的冻结交付。
> 2.1 从 2.0.2 复制出独立文件夹 `2.1/`，版本号统一 **2.1.0**；本文件位于 `2.1/` 内，记录 2.1 的变更。

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
- **限制**：安装/卸载只做了静态审查与 Parser 校验，**尚未真机执行**
  （用户 2.0 管理员实例在跑、数据目录是活的；升级需用户先退出 2.0）。

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
- **安装/卸载脚本尚未真机执行**（用户 2.0 实例在跑）；升级前须先退出 2.0。
- **P2 体验项未做**（见下）。

### 待办（P2 / 交付）

- **P2 体验项**：列宽记忆、历史趋势图（`samples` 分钟桶已在 JSON 里）、CSV 导出范围选择等。
- **交付**：真机安装/卸载验证（需用户先退出 2.0）→ 打发布包 `IP监控2.1-发布包.zip` →
  Gitee 提交/push → GitHub 镜像同步（视网络）。
- 提交：`待补`（Lead push 后补 Gitee 提交号）

---

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
