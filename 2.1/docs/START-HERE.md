# START HERE · IP监控2.1 项目起点（给下一个智能体/接手者）

> 归档时间：2026-10-31（北京时间）。**先读完这一页再动手**，可以省掉几小时试错。
> 当前版本：**2.1.0（定版，2.1.0.0）**；2.1 是 2.0.2 的迭代修复版，代码/脚本/文档在 `2.1/` 子目录、
> **尚未 git 提交**（提交号待 Lead push 后补 `待补`）。
> 2.0 基线：Gitee `main` = `b7b3720`（2.0.2，冻结，不再改）。

---

## 0. 你从哪里接手

| 入口 | 地址 |
|---|---|
| **Gitee 仓库（权威）** | `https://gitee.com/NSYBdeDFY/FileAudit`（分支 `main`） |
| GitHub 镜像 | `https://github.com/m7211873/FileAudit` |
| 本机仓库（2.0 + 新增 2.1 工作区） | `D:\IP监控2.1版\NetWatcher`（main = `b7b3720`） |
| **2.1 源码/文档/脚本（本版交付物）** | `D:\IP监控2.1版\NetWatcher\2.1\`（与根目录 2.0 并列） |
| 已安装的 2.0 程序（用户机上） | `%LOCALAPPDATA%\Programs\NetWatcher\NetWatcher.exe`（桌面「IP监控」快捷方式） |
| 2.1 安装后的预期位置 | `%LOCALAPPDATA%\Programs\NetWatcher2.1\NetWatcher.exe`（桌面「IP监控2.1」快捷方式） |
| 2.1 验收证据 | `2.1\tools\qa\out\`；详细报告 `D:\IP监控2.1版\_analysis\2.1-P0-验收.md`、`2.1-P1-验收.md` |

> 记牢仓库结构：**根目录 = 冻结的 2.0，`2.1/` = 新版本**。2.0 的一切文件（`src/`、`docs/`、`README.md`、
> `install.ps1`、`bin/`…）一律**不许改**；2.1 只在 `2.1/` 里改。

---

## 1. 30 秒确认环境

```powershell
cd D:\IP监控2.1版\NetWatcher\2.1

# 1) 编译（产出 2.1\bin\NetWatcher.exe，版本资源 2.1.0.0）
cmd /c build.bat
# 期望：[OK] bin\NetWatcher.exe built.（0 error / 0 warning）

# 2) P0 回归（29/29 PASS）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-p0.ps1

# 3) P1 回归（38/38 PASS）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-p1.ps1

# 4) 无界面整体验收
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -SkipGui -Seconds 30
# 2.1 定版实测：PASS=24 FAIL=2 WARN=2；2 个 FAIL 为环境归因（见 §5），产品检查全 PASS
```

> **任何测试/截图/自检都必须带绝对 `--datadir <临时目录>`**，绝不写用户真实数据目录
> `%APPDATA%\NetWatcher`（2.1 与 2.0 共用该目录，写坏影响两个版本）。

---

## 2. 必读顺序

1. **`docs/2.1-交接说明.md`** —— 2.1 现状、改了什么、验收证据、待办、下次怎么继续（最短路径）
2. **`docs/踩坑与决策记录.md`** —— 症状→根因→处理→证据 + ADR 决策表；**§八 是 2.1 新增的坑**
3. **`docs/design-2.1.md`** —— 2.1 设计契约（已实现：数据模型/API/UI/单写锁/selftest/与 2.0 差异）
4. **`docs/开发与维护指南.md`** —— 代码地图、启动顺序、数据模型、构建/签名/验收、扩展点
5. `README.md`（功能与限制总览）、`CHANGELOG.md`（[2.1.0] 定版与两轮验收结果）
6. 改 UI 时看 `docs/用户手册.md`（含截图与文案对照；截图暂用 2.0，已标注）

---

## 3. 一句话现状

IP监控2.1 **已定版（2.1.0）**：2.0 的能力（单 exe、四标签页、按日原子落盘、诚实降级、托盘自启）全部保留；
P0 四项与 P1 八项修复全部落地并冻结，两轮独立回归验收通过
（P0 29/29、P1 38/38、P1 后 P0 复跑 29/29，0 FAIL/0 WARN；GUI 冒烟 39 PASS，2 项 FAIL 为环境归因）。
版本 2.1.0.0、标题 `IP监控2.1`、已用 2.0 同一张证书签名（Authenticode `Valid`）。
**唯一能力缺口仍是"逐 IP 精确流量"**（依赖 Windows `GetPerTcpConnectionEStats`，开发机实测不可用，
程序诚实降级为「估算」并标注，不会谎报精确；精确只覆盖 IPv4 TCP，IPv6/UDP 只计总流量）。
**剩下的是交付动作**：真机安装/卸载、Gitee push、P2 体验项（见 §6）。

---

## 4. 硬性约束（违反会重复踩坑）

1. **测试绝不能写用户真实数据目录**：所有测试/截图/自检都传**绝对 `--datadir <临时目录>`**；
   真实目录 `%APPDATA%\NetWatcher` 的 size+mtime+SHA256 必须零变化（`verify.ps1` 有守卫）。
2. **2.1 与 2.0 共用数据目录，绝不能同时运行**：2.1 的写锁
   `NetWatcher2.1_DataLock_<MD5(数据目录绝对路径小写)>` 只约束 2.1 自己（GUI/daemon 抢），
   管不到 2.0。升级/测试前先确认没有 2.0 实例在写数据（用户机上仍有 2.0 管理员实例 PID 10856）。
3. **同一数据目录只允许一个 2.1 写入实例**：GUI/daemon 抢同一把锁；daemon 抢不到 → 退出码 2；
   GUI 抢不到 → 弹「IP监控2.1」提示后退出。`--selftest` 不抢锁；`--mutex-tag` **不影响**写锁
   （并发测试必须用不同 `--datadir`）。
4. **不要从 agent 工作区目录运行 exe 做长期服务**：该目录下进程可能被限制为"只能写工作区"，
   表现为"进程在、没数据、托盘异常"。用 `2.1\install.ps1` 复制到 `%LOCALAPPDATA%\Programs\NetWatcher2.1` 再运行。
5. **启动 GUI 用** `Invoke-CimMethod -ClassName Win32_Process -MethodName Create`（或 redirect stdio），
   直接 `Start-Process` 会被 GUI 常驻进程的 stdio 句柄挂住。
6. **结束进程只按自己记录的 PID**，禁止 `Stop-Process -Name NetWatcher` 批量杀（会误杀用户/其它 agent 的实例，
   尤其用户机上还有 2.0 实例）。
7. **含中文的 `.ps1` 必须 UTF-8 with BOM**（PowerShell 5.1 否则解析失败）。
8. **改 UI 必须真机截图验收**；管理员窗口无法被非管理员模拟点击（UIPI），截可用非管理员 + `--mutex-tag` 实例。
9. **签名必须在编译之后**：`2.1\build-and-sign.bat`；**复用 2.0 的证书** `CN=NSYBdeDFY NetWatcher`（2029 到期），
   不要新建证书，`.pfx` 绝不入库。
10. **根目录 2.0 文件一律不许改**（本轮只允许动 `2.1/`）；不 git commit/push 由 Lead 统一做。
11. **REALDATA/进程守卫不许削弱**：若 `REALDATA_UNTOUCHED` FAIL 是用户 2.0 实例在写，按环境归因并保留 FAIL，
    不要改判、不要按进程名杀进程。
12. **提交信息中文、说明"为什么"**；行为变化同步 `README.md` / `CHANGELOG.md` / `docs/`。

---

## 5. 已知限制（不要当 bug 修）

- **EStats 精确模式不可用**（本机）：非管理员 `rc=50` + `1784`；管理员 `rc=50` + `winerr=122`。
  `--selftest`（管理员）看 `EStats 结论:` 一行；要覆盖需 ETW 方案（含 UDP/QUIC）。
- **UDP/QUIC 无远端 IP**：系统接口限制，只能计入总流量，无法逐 IP 归因。
- **IPv6 不精确**：精确字节只覆盖 IPv4 TCP；运行模式 tooltip 已说明。
- **离散采样**：默认 2 秒（可调 1/2/5/10/30/60），短于间隔的连接可能漏。
- **SmartScreen**：自签名对 SmartScreen 无效；下载副本带 MotW 会被拦，用 `2.1\tools\fix-smartscreen.ps1` 解除。
- **第三方 HIPS（火绒等）**：即使签名也可能提示，需在安全软件里加信任区。
- **4 个环境类 FAIL 是已知现象**：`SELFTEST_GEOIP`（ip-api.com 间歇不可达）与 `REALDATA_UNTOUCHED`
  （用户 2.0 实例实时写真实目录），证据与对照组见 §8；不是产品缺陷。

---

## 6. 待办（按价值排序，详见 `docs/2.1-交接说明.md` §六）

1. **真机安装/卸载验证**（需用户先退出 2.0）：`install.ps1` → 启动 → 数据落盘 → `uninstall.ps1`（保留数据）→ 重装；
   并确认 2.0 的目录/自启/快捷方式/数据零变化（脚本目前仅静态审查 + PS 5.1 Parser 0 error）。
2. **Gitee 提交/push**（Lead）：`git add 2.1 && git commit`，补提交号；GitHub 镜像视网络。
3. **P2 体验项**：列宽记忆、历史趋势图（`samples` 分钟桶已在 JSON 里）、CSV 导出范围选择。
4. **长期**：ETW 逐 IP/逐进程统计（覆盖 UDP/QUIC）；对外分发签名（SignPath / Certum）。
5. **可选**：重截 2.1 真机截图替换 `docs/screenshots/`（当前仍是 2.0 截图并已标注）。

---

## 7. 关键路径

```
NetWatcher/                     # Gitee 仓库根（2.0 冻结）
├── src/ docs/ bin/ ...         # 2.0（不许改）
└── 2.1/                        # 本版：IP监控2.1（2.1.0 定版）
    ├── src/                    9 个 C# 源文件 + AssemblyInfo.cs（2.1.0.0）
    ├── bin/NetWatcher.exe      产物（已编译 + 用 2.0 证书签名）
    ├── build.bat / build-and-sign.bat
    ├── install.ps1 / uninstall.ps1   （2.1 化：只动 NetWatcher2.1 的目录/Run 值/快捷方式）
    ├── README.md / CHANGELOG.md
    ├── docs/                   START-HERE / design-2.1 / 用户手册 / 开发与维护指南 /
    │                           踩坑与决策记录 / 2.1-交接说明 / design-2.0（历史）/ screenshots
    └── tools/                  sign（自签名，复用 2.0 证书）/ qa（verify.ps1 + regression-p0/p1.ps1）/ fix-smartscreen.ps1
```

数据目录（2.0/2.1 共用）：`%APPDATA%\NetWatcher\`——`data\YYYY-MM-DD.json`、`geocache.json`、`config.json`、
`startup.log`、`crash.log`、`ui-error.log`、`monitor.log`、`selftest.log`、`daemon.log`。

2.1 安装位置：`%LOCALAPPDATA%\Programs\NetWatcher2.1`；Run 值名 `NetWatcher2.1`；快捷方式 `IP监控2.1.lnk`。

---

## 8. 验收证据（可复核）

| 证据 | 位置 |
|---|---|
| P0 回归 **PASS=29 / FAIL=0 / WARN=0**（tag `20261031-162506`；P1 后复跑 `20261031-163540` 仍 29/29） | `2.1\tools\qa\out\regression_*.txt` |
| P1 回归 **PASS=38 / FAIL=0 / WARN=0**（tag `20261031-163501`，R6~R11 + 8 项静态检查） | `2.1\tools\qa\out\regression_p1_*.txt` |
| 无界面验收 PASS=24 / FAIL=2 / WARN=2（tag `20261031-163622`） | `2.1\tools\qa\out\report_20261031-163622.txt` |
| GUI 冒烟 **PASS=39** / FAIL=2 / WARN=2（tag `20261031-163730`；标题 2.1、4 标签真实点击 4/4、列头 100%） | `2.1\tools\qa\out\report_20261031-163730.txt`、`gui_*_20261031-163730.png` |
| 4 个 FAIL 的环境归因（GEOIP 网络间歇 / 用户 2.0 实例 PID 10856 写真实数据） | `report_*.txt` 的 FAIL 行、`control_realdata_p2*.txt` 对照组 |
| 详细验收报告 | `D:\IP监控2.1版\_analysis\2.1-P0-验收.md`、`2.1-P1-验收.md` |
| 2.0 基线 headless PASS=27 / FAIL=0（历史对照） | `tools/qa/out/report_*.txt`（2.0 时期） |
| 安装/卸载边界静态审查 | `2.1\install.ps1` / `2.1\uninstall.ps1`（PS 5.1 Parser 0 error、UTF-8 BOM） |
| 签名 | `2.1\bin\NetWatcher.exe` Authenticode `Valid`（`CN=NSYBdeDFY NetWatcher`） |

---

## 9. 版本与提交

| 提交 | 内容 |
|---|---|
| `cfe5597` | IP监控1.0（历史基线，缺陷多，仅对照） |
| `c969b5d` | IP监控2.0 整体重写 |
| `8b9a9ae` | 2.0.1 可用性（引擎解耦/二次启动唤出/托盘自愈） |
| `bbff3bc` | 文档（2 秒默认、全状态、`--show`） |
| `454f4be` | 签名流水线 `tools/sign` |
| `375f97d` | SmartScreen 处理 |
| `6fd31c7` | **2.0.2** 安装到 LocalAppData（修复受限目录写盘） |
| `251ea45` | 文档归档（用户手册/开发指南/踩坑记录/交接说明/截图） |
| `b7b3720` | **2.0 最新**：START-HERE 起点说明（当前 main） |
| `待补` | **IP监控2.1（2.1.0 定版）**：`2.1/` 独立文件夹 + P0/P1 修复 + 脚本/文档 2.1 化（Lead push 后补） |
