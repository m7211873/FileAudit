# IP监控2.1 · 设计契约（v2 · 已实现 · 定版）

> 本文件是 IP监控2.1 的开发契约，**已于 2026-10-31 定版**：P0 四项 + P1 八项修复全部落地并冻结，
> 经两轮独立回归验收（P0 29/29、P1 38/38、P1 后 P0 复跑 29/29，0 FAIL/0 WARN）。
> 基线：IP监控2.0.2（Gitee `main` = `b7b3720`），2.1 从 2.0 复制到 `2.1/` 后迭代。
> 技术约束不变：**C# 5 语法、.NET Framework 4.8、WinForms、系统自带 `csc.exe`、零 NuGet、单个 `NetWatcher.exe`**。
> 历史契约见 `docs/design-2.0.md`（保留，不再维护）；与 2.0 的差异汇总见 §12。

## 0. 为什么做 2.1（实测依据）

2.0.2 已可用，但存在四类"会真的伤到用户"的问题（2.1 的 P0 修复目标）：

1. **同日重启丢当天数据**：程序启动时没有接续当天已有 JSON，重启后当天此前的统计被当作空白重写。
2. **`--selftest` 会写/覆盖当天数据**：2.0 的自检流程会创建/覆盖 `data\<今天>.json`，
   把用户当天的真实数据覆盖成自检样本（有真实数据被覆盖的证据）。
3. **`--selftest` 会篡改 HKCU 开机自启**：2.0 自检会试着写/删 `Run\NetWatcher`，
   用户在设置里开关过的自启状态可能被自检改掉。
4. **同一数据目录可能被多个写入实例同时写**：GUI 与 `--daemon`（或两个 GUI）同时写同一目录会互相覆盖；
   2.0 只有"单实例"（同 exe 路径），没有"单数据目录写者"概念。

2.1 的定位是**小规模迭代修复版**（用户原话："版本迭代就是把不够好的地方一点点修到可用"），
不新增功能大项，只修上述 P0 问题 + 一批 P1 体验/一致性问题（见 §9）。

## 1. 命名与位置（2.1 决定，硬要求）

| 项 | 值 |
|---|---|
| 程序名（界面/文档） | `IP监控2.1` |
| exe 文件名 | `NetWatcher.exe`（不变，降低工具链/文档改动面） |
| 安装目录 | `%LOCALAPPDATA%\Programs\NetWatcher2.1` |
| HKCU Run 值名 | `NetWatcher2.1` |
| 桌面快捷方式 | `IP监控2.1.lnk` |
| 数据目录 | `%APPDATA%\NetWatcher`（**不变**；2.0 与 2.1 共用，保证历史连续） |
| 单实例互斥量 | `NetWatcher2.1_SingleInstance_Mutex`（`--mutex-tag X` → `…_X`） |
| 唤出事件 | `NetWatcher2.1_SingleInstance_Mutex_Activate`（`--mutex-tag X` → `…_X`） |
| 数据写锁 | `NetWatcher2.1_DataLock_<MD5(数据目录绝对路径小写)>`（`--mutex-tag` 不影响） |
| 程序集版本 | `AssemblyVersion` / `AssemblyFileVersion` = `2.1.0.0` |
| 产品/标题文案 | `IP监控2.1 (NetWatcher)` / `IP监控2.1 · 网络连接监控 (NetWatcher)` / `设置 · IP监控2.1` |
| 仓库位置 | Gitee 根目录下的 `2.1/` 子文件夹（与 2.0 并列；根目录 2.0 文件一律不改） |

- 2.0 与 2.1 的单实例名前缀不同 → 两个版本可各自有一个实例同时存在；
  **但共用数据目录，实际使用禁止同时运行**（2.1 的写锁管不到 2.0）。
- 2.0 的 `IP监控.lnk` / `Run\NetWatcher` / `Programs\NetWatcher` 一律由 2.0 自己管理；
  2.1 的安装/卸载脚本**只动自己的**，不清理 2.0/1.0 遗留物。

## 2. 运行模式与诚实标注（硬要求，沿用 2.0 修正）

| 模式 | 条件 | 逐 IP 字节来源 | UI 标注（三种文案） |
|---|---|---|---|
| 精确 | 管理员 且 至少一条连接 EStats 成功 | `GetPerTcpConnectionEStats` 逐连接差分 | `运行模式：逐IP精确（管理员）`（绿色） |
| 估算（管理员） | 管理员，但本次采样无 EStats 数据 | 按 ESTABLISHED 连接数均分总流量 | `运行模式：逐IP估算（管理员，本次采样无 EStats 数据）`（橙色） |
| 估算（普通） | 非管理员 | 按 ESTABLISHED 连接数均分总流量 | `运行模式：逐IP估算（非管理员）`（橙色） |

- **禁止**在没有一条 EStats 成功时显示"精确"。
- **P1-12 已实现**：EStats 首次失败把 `rc / winerr` 写进 `monitor.log`；精确模式恢复后清空 `LastEStatsError`，
  状态栏/tooltip 不再一直标红。
- 精确字节**只覆盖 IPv4 TCP 连接**；IPv6 / UDP / QUIC 只计入整机总流量——运行模式 tooltip 明确写出（P1-10 已实现）。
- UDP/QUIC 无法归因（系统表不提供 UDP 远端），UI 与 README 必须明确写出来。

## 3. 数据模型（src/Storage.cs，沿用 2.0）

```csharp
class IpConnAgg { string ip; long bytesIn, bytesOut; int connCount;
                  List<int> ports; string proto, city, region, country, isp, hostname; long firstSeenUnix; }

class ProcAgg { string name; string path; int pid; long processStartUnix;
                long bytesIn, bytesOut; int connCount; long firstSeenUnix, lastSeenUnix;
                Dictionary<string, IpConnAgg> ips; }   // ip -> agg

class IpAggregate { string ip; long bytesIn, bytesOut, peakInBps, peakOutBps, connectedSeconds;
                    int sampleCount, sessionCount; long firstSeenUnix, lastSeenUnix;
                    Dictionary<string,int> processes; Dictionary<string,int> states; List<int> ports;
                    string city, region, country, isp, hostname; bool bytesPrecise, isNew; }

class DayData { string date; long bytesIn, bytesOut, peakInBps, peakOutBps;
                long firstSampleUnix, lastSampleUnix; int sampleCount; bool bytesPrecise;
                Dictionary<string, IpAggregate> ips;
                Dictionary<string, ProcAgg> procs;     // key = name|pid|processStartUnix
                List<long[]> samples; }                // [minuteUnix, bytesIn, bytesOut]，最多 1440 条
```

语义（沿用 2.0 修正）：
- `IpAggregate.sessionCount`：**真实会话数**（该 IP 由"无连接"变"有连接"的次数），不是采样次数。
- `IpAggregate.sampleCount`：出现过的采样次数。
- `ProcAgg.connCount`：**本次连接出现次数**（每个连接只计一次），不再每采样累加。
- `ProcAgg` 的 key 含进程启动时间，避免 PID 复用合并。
- 旧数据（1.0 格式，`procs` key 为 `name|pid`）必须**仍能读出来**（字段缺失取默认值）。
- **P1-9 已实现**：读取 1.0 旧数据时，若 `bytesPrecise=true` 但逐 IP 字节合计=0
  （1.0 的"假精确"特征），自动把当天与逐 IP 的 `bytesPrecise` 降级为 false，界面按估算显示。

`Store` API（原子写 + 2.1 唯一临时文件）：
```csharp
static void Init(string dir);
static DayData LoadDay(string date);   // 不存在返回空 DayData；存在则完整读回（2.1：今天也要 Load）
static void SaveDay(DayData d);        // 写 data\<date>.json.<进程PID>.tmp → File.Replace/Move 覆盖
static List<string> ListDates();       // 倒序
static void EnforceRetention(int days);
static string DataDir { get; }
static string DataLockName { get; }    // 2.1 数据写锁名
static bool AcquireDataLock();         // 2.1 抢数据写锁（同名进程内幂等）
static void ReleaseDataLock();
```

2.1 已实现要求：
- **同日重启接续**：启动时若 `data\<今天>.json` 存在，读回并在此基础上继续累加（P0-1）。
- **临时文件唯一名**：`.tmp` 文件名为 `<文件名>.<进程PID>.tmp`，并发或上次崩溃残留不会互相覆盖（P0-4 的一部分）。
- 原子替换失败时保留旧文件，写 `monitor.log`，不得让半个 JSON 生效。

## 4. 采集引擎（src/Monitor.cs + src/NativeMethods.cs，沿用 2.0）

### NativeMethods（公共，不变）
```csharp
class ConnEntry { string RemoteIp, ProcessName, ProcessPath, State, Proto;
                  int RemotePort, LocalPort, Pid;
                  uint StateNum, LocalAddrRaw, RemoteAddrRaw, LocalPortRaw, RemotePortRaw;
                  long ProcessStartUnix; }

List<ConnEntry> EnumTcpConnections();          // TCP4 + TCP6；含 PID、进程名、进程路径、启动时间
void GetTotalBytes(out long in, out long out); // 只统计 Up 状态、非 Loopback、非 Tunnel 的网卡
bool IsAdministrator();

bool EStatsEnable(ConnEntry c, out uint rc, out int winerr);
bool EStatsRead(ConnEntry c, out ulong bytesOut, out ulong bytesIn, out uint rc, out int winerr);
```

### Monitor（公共）
```csharp
class Monitor {
    Monitor(AppConfig cfg);
    void Start(); void Stop();
    Snapshot GetSnapshot();
    DayData GetDay(string date);
    List<IpAggregate> GetDayIps(string date);
    List<ProcAgg> GetDayProcs(string date);
    List<DayData> GetHistory();
    DayData TodaySnapshot();
    string LastEStatsError { get; }
}
```

采样策略（2.1 已实现值）：
- 采样间隔 `cfg.ScanIntervalSeconds`：**默认 2s，可选 1/2/5/10/30/60**。
- 落盘节流：至少间隔 15s，或跨日/退出时强制写。
- EStats：连接首次出现时 `EStatsEnable`，成功后每采样 `EStatsRead` 求差分；连接消失后清理；
  首次失败写 `monitor.log`，恢复后清空错误（P1-12）。
- 总量差分算速率；`elapsed` 用真实经过秒数，最小 1。
- UDP：不采集远端（系统不支持），总量仍计入总流量。
- 采样引擎与"数据写锁"生命周期绑定——先抢到写锁才启动 GUI/daemon 的写路径（见 §5）。

## 5. 单实例与数据写锁（2.1 核心新增，src/Program.cs + src/Storage.cs）

### 5.1 单实例（沿用 2.0 语义，名字 2.1 化）
- 互斥量：`NetWatcher2.1_SingleInstance_Mutex`（`--mutex-tag X` 追加 `_X`）；
- 唤出事件：`NetWatcher2.1_SingleInstance_Mutex_Activate`（同样追加 `_X`）；
- 第二实例 → `Set()` 事件后退出；已有实例卡死 → 提示用户到任务管理器结束 `NetWatcher.exe`。
- `--show`：已有实例则唤出窗口；没有实例则以可见窗口启动（P1-6 配合 `StartMinimized`）。
- 该锁**只**决定"同一次启动是否唤出窗口"，**不**决定能否写数据目录。

### 5.2 数据写锁（2.1 新增，已实现）
- 名字：`NetWatcher2.1_DataLock_<MD5(数据目录绝对路径小写)>`（对 `--datadir` 生效；默认目录同样计算）。
- 抢占者：**GUI 与 `--daemon`**。`--selftest` **不抢锁**（只读自检）。
- 抢不到时：
  - `--daemon`：**退出码 2**（0.2s 内退出，`daemon.log` 记录冲突原因）；
  - GUI：弹标题为 **「IP监控2.1」** 的 MessageBox（`#32770`）提示后退出，不得两个实例同时写同一 JSON；
    管理员重启/升级场景下 GUI 最多等 5 秒尝试接管（旧实例正在退出时）。
- `--mutex-tag` **不影响**数据写锁：同一数据目录永远只能一个写入实例。
- 锁覆盖整个"加载当天数据 → 采样 → 落盘"生命周期；进程退出/崩溃时由 OS 释放命名 Mutex
  （`AbandonedMutexException` 视为可接管）。
- 设计意图：测试/截图用 `--datadir <临时绝对目录>` 并行跑多个实例；正式使用同一目录只能一个写者。

### 5.3 启动顺序（2.1 实际顺序）
```
Main(args)
 ├─ 解析参数（--background/--datadir/--mutex-tag/--selftest/--daemon/--autostart-*/--show）
 ├─ --autostart-on/off：只写/删 HKCU Run\NetWatcher2.1 后退出
 ├─ AppConfig.Load(dataDir) → 用 Startup.IsEnabled() 对账 AutoStart（P1-5）→ Store.Init → startup.log
 ├─ --selftest：只读自检（不写 data\、不改自启、不抢写锁）后退出
 ├─ --daemon N：抢数据写锁（失败 exit 2）→ 采集 N 秒 → 退出（写 daemon.log）
 ├─ 单实例：Mutex + 唤出事件；已存在则唤出对方窗口后退出
 ├─ 抢数据写锁（GUI 写者；失败提示后退出；管理员升级时最多重试 5 秒）
 ├─ 加载当天已有 DayData（同日重启接续，P0-1）
 ├─ startHidden = background || (StartMinimized && !--show)（P1-6）
 ├─ Monitor.Start()
 ├─ Application.Run(MainForm(...))
 └─ finally: monitor.Stop()；释放写锁
```

## 6. 配置（src/Config.cs）

字段（JSON 键名保持，兼容旧 config.json）：
`ScanIntervalSeconds`(**默认 2**)、`AutoStart`、`RetentionDays`、`StartMinimized`、
`GeoEnabled`、`GeoApi`、`NewIpAlert`(默认 true)、`ShowLocalIp`(默认 true)。
档位固定为 `1/2/5/10/30/60` 秒（`Config.AllowedIntervals`）。

P1 已实现：
- **P1-5 自启对账**：`Program.Main` 用 `Startup.IsEnabled()` 覆盖 `cfg.AutoStart`；
  设置窗口打开前对账、保存后写注册表并回读校准。
- **P1-6 启动最小化**：`StartMinimized` 在开机自启/后台启动时真正只驻留托盘；`--show` 强制可见。
- **P1-8 归属地即时生效**：设置保存后立即 `GeoIp.SetEnabled(cfg.GeoEnabled)`，无需重启。
- **P1-7 管理员重启保留 `--datadir`**：提权命令行拼接当前数据目录（UAC 交互本机无法自动化，仅静态证据）。

## 7. 界面（src/MainForm.cs + src/SettingsForm.cs）

布局硬要求（沿用 2.0，用 TableLayoutPanel/Dock 正确顺序，**必须截图验收**）：
1. 标题栏区域：标题 `IP监控2.1 · 网络连接监控`、运行模式（三种文案着色）、最近扫描时间、扫描间隔。
2. 日期行：今天 / 昨天 / 前天 / DateTimePicker + **搜索框** + 刷新按钮。
3. **四个标签页必须可见可点**：`实时连接`、`进程视图`、`按日统计`、`历史概览`。
4. 实时连接：顶部 4 个统计（↓速度 / ↑速度 / 今日↓ / 今日↑）+ 上表（IP 汇总）+ 下表（连接明细）。
5. **列头可排序**（点列头切换升降序，刷新后保持）；行可复制（Ctrl+C 或右键菜单）。
6. 新 IP 用颜色/`NEW` 标记；进程视图树形「进程 → PID → IP」，双击 IP 行可筛选。
7. 底部：设置 / 导出CSV / 打开数据目录 / 以管理员身份重启。
8. 高 DPI 友好（AutoScaleMode.Dpi），微软雅黑 9pt，最小 900×620，默认 1180×780。
9. 托盘：显示主窗口 / 刷新 / 退出；关闭窗口最小化到托盘（真实点击 X 后进程存活、窗口隐藏）。
10. 新公网 IP 首次出现可弹托盘气泡（`NewIpAlert` 开关）。

2.1 已实现：
- 主窗口标题 `IP监控2.1 · 网络连接监控 (NetWatcher)`，设置标题 `设置 · IP监控2.1`；
- **GUI 抢不到数据写锁**时给出可操作提示（说明"另一个实例正在写该数据目录"，建议退出或换 `--datadir`），随后退出；
- **P1-10** 运行模式 tooltip 写明"精确字节仅覆盖 IPv4 TCP；IPv6 / UDP 只计入总流量"；
- **P1-11** 刷新节流：实时页每次采样刷新；进程/按日页 **≥5 秒**、历史页 **≥15 秒** 才重建表格；
- 2.1 截图证据在 `tools/qa/out/gui_*_20261031-163730.png`（5 张，标题为 2.1）；
  `docs/screenshots/` 仍是 2.0 截图，文档已标注"暂用 2.0"。

## 8. 自检（src/Program.cs，2.1 新行为，已实现）

`--selftest` 输出到 `<datadir>\selftest.log`：
- 管理员状态、进程位数、OS 版本；
- 网卡统计（每个网卡名与收发字节，标明 Loopback/Tunnel 是否被排除）；
- TCP 连接总数 / ESTABLISHED / 远端连接数（前 15 条）；
- **EStats 诊断**：对前 5 条连接尝试 `RwSize=1/4 × RodSize=16/48/1024` 组合，逐条打印 `rc/winerr`，
  1.2s 后重读确认字节增长 → 管理员精确模式能否工作的唯一判据；
- GeoIP 查询（8.8.8.8 / 192.168.1.1）、存储读写、开机自启注册表、目录列表；
- 结论行：`EStats 结论: 可用/不可用(原因)`。

**2.1 硬约束（P0，已实现）**：
1. 自检**对 `data\` 只读**：不得创建/覆盖 `data\<今天>.json`、不得写采样数据；
   存储读写测试在 `<datadir>\selftest-store\` 临时子目录进行，用后删除；
2. 自检**不得写/删 HKCU 自启项**：`Run\NetWatcher2.1` / `Run\NetWatcher` 只读检查；
   注册表往返测试用临时值名 `NetWatcher2.1_SelfTest_<PID>`，测完删除、无残留；
3. 自检**不抢**数据写锁；
4. 自检允许写 `<datadir>\selftest.log` 与一次 GeoIP 查询的 `geocache.json` 缓存。

命令行（已实现）：`--background|--minimized`、`--show`、`--daemon <秒>`、`--datadir <路径>`、
`--selftest|--test`、`--mutex-tag <标签>`、`--autostart-on/off`。

## 9. P1 已实现项与待办

### 9.1 P1 已实现（回归证据见 CHANGELOG「验证」）

| 编号 | 项 | 实现/证据 |
|---|---|---|
| P1-5 | 自启状态对账 | 设置前对账 + 保存后回读（静态 `S_P1_5`；R11 不误删 sentinel） |
| P1-6 | 启动最小化生效 | `startHidden` 逻辑（R6 隐藏实例 handle=0、`--show` 可见） |
| P1-7 | 管理员重启保留 `--datadir` | 提权命令行拼接（静态 `S_P1_7`） |
| P1-8 | 归属地开关即时生效 | `GeoIp.SetEnabled`（静态 `S_P1_8`） |
| P1-9 | 1.0 旧数据不再假精确 | LoadDay 降级（R7：true→false、sampleCount 10→14、bytes 不回退） |
| P1-10 | 精确 tooltip 仅 IPv4 TCP | `S_P1_10` |
| P1-11 | 非实时页刷新节流 | 5s/15s 阈值（`S_P1_11`，仅静态证据） |
| P1-12 | EStats 首错日志 + 恢复清除 | `monitor.log` + `lastEStatsError=""`（`S_P1_12`，仅静态证据） |

### 9.2 待办（P2 / 交付）

| 编号 | 待办 | 说明 |
|---|---|---|
| P2 | 体验项 | 列宽记忆、历史趋势图（`samples` 分钟桶已在 JSON 里）、CSV 导出范围等 |
| 交付-1 | 真机安装/卸载验证 | 需用户先退出 2.0；脚本目前仅静态审查 + PS 5.1 Parser 0 error |
| 交付-2 | 打包与发布 | `IP监控2.1-发布包.zip`、Gitee 提交/push、GitHub 镜像 |
| 限制-1 | 管理员重启/UAC | P1-7 无法自动化，仅静态检查 |
| 限制-2 | EStats 成功路径 | 本机非管理员不可用（`rc=50/winerr=122`），P1-12 仅静态检查 |
| 限制-3 | 刷新节流动态计时 | P1-11 仅静态阈值检查 |

## 10. 文件所有权（禁止越界修改）

| 归属 | 文件 |
|---|---|
| Lead | `2.1/src/*.cs`、`2.1/build.bat`、`2.1/build-and-sign.bat`、`.gitignore` |
| 文档/脚本 | `2.1/docs/**`、`2.1/install.ps1`、`2.1/uninstall.ps1`、`2.1/README.md`、`2.1/CHANGELOG.md`、`2.1/tools/sign/README.md` |
| QA | `2.1/tools/qa/**` |
| 根目录 2.0 | **全部冻结，任何人不改** |

## 11. 验收标准（2.1 已达成）

- [x] `2.1\build.bat` 干净编译（0 error/0 warning），`bin\NetWatcher.exe` 可双击运行，版本资源 2.1.0.0
- [x] 四个标签页可见、可切换（GUI 冒烟：标签栏 100% 可见、文本正确、真实点击 4/4）
- [x] 普通用户模式：总流量、速率、连接明细、城市、历史均正常；逐 IP 明确标注"估算"
- [x] **P0-1 同日重启**：`sampleCount 6→12`、`firstSampleUnix` 不变、bytes 不回退
- [x] **P0-2 自检只读**：哨兵 SHA256/大小/字段前后完全一致，`data\` 文件集合不变
- [x] **P0-3 自检不动自启**：`Run\NetWatcher2.1` 与 `Run\NetWatcher` 前后一致、无临时值残留
- [x] **P0-4 单写锁**：同 datadir 再起 `--daemon` → 退出码 2；GUI 冲突弹「IP监控2.1」提示框；
      `--selftest` 不被写锁阻塞；`--mutex-tag` 不绕过写锁
- [x] **P1-5~P1-12**：回归 38/38 PASS（P1-7/11/12 为静态证据，已如实记录）
- [x] 数据原子写入；`verify.ps1` 数据链路检查全 PASS（逐 IP 对账误差 0、分钟桶上限、无残留 .tmp）
- [ ] `2.1\install.ps1` / `uninstall.ps1` 可重复执行且幂等；**只动 NetWatcher2.1**（静态审查 + Parser 0 error 已完成；
      **真机安装/卸载待用户退出 2.0 后验证**）
- [x] 签名：`bin\NetWatcher.exe` 用 **2.0 已有证书**签名成功，Authenticode `Valid`
- [x] 文档齐套且版本号统一 2.1.0：README / CHANGELOG / START-HERE / design-2.1 / 用户手册 / 开发与维护指南 / 踩坑记录 / 2.1-交接说明
- [ ] 提交「IP监控2.1」到 Gitee（`2.1/` 文件夹，与 2.0 并列；根目录 2.0 文件不动）——**已推送 Gitee main，提交号 `7b370b7`**

## 12. 与 2.0 的差异（汇总）

| 维度 | 2.0.2 | 2.1.0 |
|---|---|---|
| 程序名 / 版本 | IP监控2.0 / 2.0.2.0 | IP监控2.1 / 2.1.0.0 |
| 安装目录 / 自启值 / 快捷方式 | `Programs\NetWatcher` / `NetWatcher` / `IP监控.lnk` | `Programs\NetWatcher2.1` / `NetWatcher2.1` / `IP监控2.1.lnk` |
| 数据目录 | `%APPDATA%\NetWatcher` | 不变（2.0/2.1 共用，禁止同时运行） |
| 单实例 | `NetWatcher_SingleInstance_Mutex` | `NetWatcher2.1_SingleInstance_Mutex`（+ `_Activate`） |
| 数据写锁 | 无 | `NetWatcher2.1_DataLock_<MD5(datadir)>`（GUI/daemon 抢；daemon exit 2；GUI MessageBox；selftest 不抢） |
| 同日重启 | 当天数据被当空白重写 | 读回当天 JSON 继续累加 |
| `--selftest` | 写/覆盖 `data\<今天>.json`、写/删真实 Run 值 | 对 `data\` 只读（存储测试在 `selftest-store\`）、只读检查 Run、临时值名往返 |
| 临时文件 | 固定 `.tmp` | `<文件名>.<PID>.tmp` |
| 启动最小化 | 开关存在但开机制未生效 | 真正生效（`--show` 强制可见） |
| 自启状态 | 界面/注册表可能不一致 | 打开设置前对账、保存后回读 |
| 归属地开关 | 需重启 | 保存后立即生效 |
| 管理员重启 | 丢失 `--datadir` | 保留 `--datadir` |
| 1.0 旧数据 | 沿用假 `precise=true` | 自动降级为估算 |
| 精确 tooltip | 无 IPv4 限制说明 | 明确"仅 IPv4 TCP；IPv6/UDP 只计总流量" |
| 非实时页刷新 | 每次采样整表重建 | 5s/15s 节流 |
| EStats 错误 | 仅状态栏文案 | 首次失败写 `monitor.log`，恢复后清除 |
| 安装/卸载脚本 | 2.0 命名空间 | 2.1 命名空间，只动自己；2.0 的一切不碰 |
