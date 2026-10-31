# IP监控2.0 · 设计契约（冻结版 v1）

> 本文件是 IP监控2.0 的开发契约。**任何文件改动都必须遵守本契约**，改契约要 Lead 同意。
> 基线：仓库 `NetWatcher/`（IP监控1.0，commit cfe5597）。技术约束：C# 5 语法、.NET Framework 4.8、WinForms、
> 系统自带 `csc.exe` 编译、**零 NuGet 依赖**、单个 `bin\NetWatcher.exe`。

## 0. 为什么做 2.0（实测依据）

1. 1.0 的逐 IP / 逐进程字节全为 0（`%APPDATA%\NetWatcher` 真实数据：10-30 / 10-31 两天，全体 `bytesIn/bytesOut = 0`，
   而当日总流量 276MB）。`precise=true` 是**假标记**：admin 分支无条件置 true，EStats 失败被静默吞掉。
2. 探针实测（非管理员）：`SetPerTcpConnectionEStats` 返回 `rc=50 ERROR_NOT_SUPPORTED` → 需要提权确认正确参数。
3. 1.0 界面：标签页栏不可见、第一个表格列头被遮挡、无搜索/排序、60 秒采样太慢。
4. 1.0 数据层：每 60s 重写整天 JSON、无原子写、`samples` 无上限、"连接次数"实为采样累计。
5. `GetTotalBytes` 把 Loopback/Tunnel 也算进总流量 → 与逐 IP 对不上。

## 1. 运行模式与诚实标注（硬要求）

| 模式 | 条件 | 逐 IP 字节来源 | UI 标注 |
|---|---|---|---|
| 精确 | 管理员 且 至少一条连接 EStats 成功 | `GetPerTcpConnectionEStats` 逐连接差分 | `逐IP精确（管理员）` |
| 估算 | 其它情况 | 按 ESTABLISHED TCP 连接数均分总流量 | `逐IP估算（非管理员）` |

- **禁止**在没有一条 EStats 成功时显示"精确"。
- EStats 首次失败要把 `rc / winerr` 写进 `monitor.log`，便于诊断。
- UDP/QUIC 无法归因（系统表不提供 UDP 远端），UI 与 README 必须明确写出来。

## 2. 数据模型（src/Storage.cs）

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
                List<long[]> samples; }                // [minuteUnix, bytesIn, bytesOut]，按分钟聚合，最多 1440 条
```

语义修正：
- `IpAggregate.sessionCount`：**真实会话数**（该 IP 由"无连接"变"有连接"的次数），不是采样次数。
- `IpAggregate.sampleCount`：出现过的采样次数。
- `ProcAgg.connCount`：**本次连接出现次数**（每个连接只计一次，用连接 key 集合去重），不再每采样累加。
- `ProcAgg` 的 key 含进程启动时间，避免 PID 复用合并。
- 旧数据（1.0 格式，`procs` key 为 `name|pid`）必须**仍能读出来**（字段缺失取默认值）。

`Store` API（原子写）：
```csharp
static void Init(string dir);
static DayData LoadDay(string date);       // 不存在返回空 DayData
static void SaveDay(DayData d);            // 写 data\<date>.json.tmp → File.Replace/Move 覆盖
static List<string> ListDates();           // 倒序
static void EnforceRetention(int days);
static string DataDir { get; }
```

## 3. 采集引擎（src/Monitor.cs + src/NativeMethods.cs）

### NativeMethods（公共）
```csharp
class ConnEntry { string RemoteIp, ProcessName, ProcessPath, State, Proto;
                  int RemotePort, LocalPort, Pid;
                  uint StateNum, LocalAddrRaw, RemoteAddrRaw, LocalPortRaw, RemotePortRaw;
                  long ProcessStartUnix; }

List<ConnEntry> EnumTcpConnections();          // TCP4 + TCP6；含 PID、进程名、进程路径、启动时间
void GetTotalBytes(out long in, out long out); // 只统计 Up 状态、非 Loopback、非 Tunnel 的网卡
bool IsAdministrator();

// EStats：三条 API，参数按探针结论（见 §0.2）。返回 rc/winerr 供日志。
bool EStatsEnable(ConnEntry c, out uint rc, out int winerr);
bool EStatsRead(ConnEntry c, out ulong bytesOut, out ulong bytesIn, out uint rc, out int winerr);
```

### Monitor（公共）
```csharp
class Snapshot { List<LiveConn> Conns; List<LiveIp> LiveIps;
                 long TotalInBps, TotalOutBps, TodayInBytes, TodayOutBytes, PeakInBps, PeakOutBps;
                 bool BytesPrecise, IsAdmin; DateTime LastScan; string LastError;
                 int EstablishedCount, PreciseConnCount; }

class LiveConn { string Ip, ProcessName, ProcessPath, State, Proto, City, Region, Country, Isp, Hostname;
                 int Pid, RemotePort, LocalPort;
                 long BytesIn, BytesOut, SpeedInBps, SpeedOutBps, DurationSeconds, FirstSeenUnix;
                 bool Precise, IsNew; }

class LiveIp { string Ip, City, Region, Country, Isp, Hostname, Processes;
               int ConnCount; long BytesIn, BytesOut, SpeedInBps, SpeedOutBps;
               bool Precise, IsNew, IsLocal; }

class Monitor {
    Monitor(AppConfig cfg);
    void Start(); void Stop();
    Snapshot GetSnapshot();                 // 线程安全，UI 每 1s 取
    DayData GetDay(string date);            // 今天=内存副本；历史=Store.LoadDay
    List<IpAggregate> GetDayIps(string date);
    List<ProcAgg> GetDayProcs(string date);
    List<DayData> GetHistory();
    DayData TodaySnapshot();
    string LastEStatsError { get; }
}
```

采样策略：
- 采样间隔 `cfg.ScanIntervalSeconds`（默认 5s，可选 2/5/10/30/60）。
- 落盘节流：至少间隔 15s，或跨日/退出时强制写。
- EStats：连接首次出现时 `EStatsEnable`，成功后每采样 `EStatsRead` 求差分；连接消失后清理。
- 总量差分算速率；`elapsed` 用真实经过秒数，最小 1。
- UDP：不采集远端（系统不支持），总量仍计入总流量。

## 4. 配置（src/Config.cs）

新增/变更字段（JSON 键名保持），并保持旧 config.json 兼容：
`ScanIntervalSeconds`(默认 5)、`AutoStart`、`RetentionDays`、`StartMinimized`、
`GeoEnabled`、`GeoApi`、`NewIpAlert`(默认 true)、`ShowLocalIp`(默认 true)。

## 5. 界面（src/MainForm.cs + src/SettingsForm.cs）

布局硬要求（用 TableLayoutPanel/Dock 正确顺序，**必须截图验收**）：
1. 标题栏区域：标题、运行模式（精确/估算着色）、最近扫描时间、扫描间隔。
2. 日期行：今天 / 昨天 / 前天 / DateTimePicker + **搜索框**（IP/进程/城市/域名过滤）+ 刷新按钮。
3. **四个标签页必须可见可点**：`实时连接`、`进程视图`、`按日统计`、`历史概览`。
4. 实时连接：顶部 4 个统计（↓速度 / ↑速度 / 今日↓ / 今日↑）+ 上表（IP、城市/地区、运营商、连接数、↓速度、↑速度、标记）+ 下表（IP、地址、应用程序、PID、端口、协议、上传、下载、总流量、时长、标记）。
5. **列头可排序**（点列头切换升降序，刷新后保持）；行可复制（Ctrl+C 或右键菜单）。
6. 新 IP 用颜色/`NEW` 标记；进程视图树形「进程 → PID → IP」，双击 IP 行可筛选。
7. 底部：设置 / 导出CSV / 打开数据目录 / 以管理员身份重启。
8. 高 DPI 友好（AutoScaleMode.Dpi），微软雅黑 9pt，最小 900×620，默认 1180×780。
9. 托盘：显示主窗口 / 刷新 / 退出；关闭窗口最小化到托盘。
10. 新公网 IP 首次出现可弹托盘气泡（`NewIpAlert` 开关）。

## 6. 自检（src/Program.cs）

`--selftest` 必须输出到 `<datadir>\selftest.log`：
- 管理员状态、进程位数、OS 版本
- 网卡统计（含每个网卡名与收发字节，单列 Loopback/Tunnel 是否被排除）
- TCP 连接总数 / ESTABLISHED / 远端连接数（前 15 条）
- **EStats 诊断**：对前 5 条连接尝试 `RwSize=1/4 × RodSize=16/48/1024` 组合，逐条打印 `rc/winerr`，
  并 1.2s 后重读确认字节增长 → **这是管理员精确模式能否工作的唯一判据**
- GeoIP 查询（8.8.8.8 / 192.168.1.1）、存储读写、开机自启注册表、目录列表
- 结论行：`EStats 结论: 可用/不可用(原因)`

命令行保持：`--background|--minimized`、`--daemon <秒>`、`--datadir <路径>`、`--selftest`、`--autostart-on/off`。

## 7. 文件所有权（禁止越界修改）

| 归属 | 文件 |
|---|---|
| Lead | `src/*.cs`、`build.bat`、`.gitignore`、`docs/*` |
| 打包 | `install.ps1`、`uninstall.ps1`、`README.md` |
| QA | `tools/qa/**` |

## 8. 验收标准（今天可用的定义）

- [ ] `build.bat` 干净编译，无 warning 级别错误；`bin\NetWatcher.exe` 可双击运行
- [ ] 四个标签页可见、可切换（截图证明）
- [ ] 普通用户模式：总流量、速率、连接明细、城市、历史均正常；逐 IP 明确标注"估算"
- [ ] 管理员模式 `--selftest` 显示 `EStats 结论: 可用`，且逐 IP/逐进程字节 > 0 且与总流量量级合理
- [ ] 关闭窗口进托盘、自启、单实例、按日切换、CSV 导出、历史概览均可用
- [ ] 数据原子写入，连续运行 10 分钟无异常、无内存暴涨
- [ ] `install.ps1` / `uninstall.ps1` 可重复执行且幂等
- [ ] 提交「IP监控2.0」并推送到 Gitee
