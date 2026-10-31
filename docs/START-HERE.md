# START HERE · IP监控2.0 项目起点（给下一个智能体）

> 归档时间：2026-10-31（北京时间）。**先读完这一页再动手**，可以省掉几小时试错。
> 当前版本：**2.0.2**，最新提交 **`251ea45`**。

---

## 0. 你从哪里接手

| 入口 | 地址 |
|---|---|
| **Gitee 仓库（权威，最新）** | `https://gitee.com/NSYBdeDFY/FileAudit`（分支 `main`，提交 `251ea45`） |
| GitHub 镜像（同提交） | `https://github.com/m7211873/FileAudit` |
| 本机完整归档 | `C:\Users\m7211\Desktop\IP监控2.0-完整归档-20261031\` |
| 本机 git 历史包（离线可 clone） | 归档目录 `04-仓库历史包\IP监控2.0-仓库.bundle` |
| 已安装运行的程序 | `%LOCALAPPDATA%\Programs\NetWatcher\NetWatcher.exe`（桌面「IP监控」快捷方式） |

> 如果网络可用：`git clone https://gitee.com/NSYBdeDFY/FileAudit.git`
> 如果只有归档：`git clone "…\04-仓库历史包\IP监控2.0-仓库.bundle" IP监控2.0 && cd IP监控2.0`（bundle 含全部历史）

---

## 1. 30 秒确认环境

```powershell
cd <仓库目录>
cmd /c build.bat
# 期望：[OK] bin\NetWatcher.exe built.

powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -SkipGui -Seconds 45 -AuditRealData
# 期望：RESULT: PASS   PASS=27  FAIL=0，且 REALDATA_UNTOUCHED 通过
```

---

## 2. 必读顺序

1. **`docs/交接说明.md`** —— 现状、提交表、待办、验收证据（最短路径）
2. **`docs/踩坑与决策记录.md`** —— 症状→根因→处理→证据 + ADR 决策表（**最省时间**）
3. **`docs/开发与维护指南.md`** —— 代码地图、启动顺序、数据模型、构建/签名/验收、扩展点
4. `README.md`（功能与限制总览）、`CHANGELOG.md`（版本变更）
5. 改 UI 时看 `docs/用户手册.md`（含真机截图与文案对照）

---

## 3. 一句话现状

IP监控2.0 **已可用**：单个 exe、四个标签页（实时连接/进程视图/按日统计/历史概览）、按日原子落盘、
安装到 `%LOCALAPPDATA%\Programs\NetWatcher`、桌面快捷方式 + 开机自启 + 托盘常驻；
**唯一能力缺口**是"逐 IP 精确流量"——依赖 Windows `GetPerTcpConnectionEStats`，开发机实测不可用
（管理员 `rc=50 / winerr=122`），程序已诚实降级为「估算」并在界面标注，不会谎报精确。

---

## 4. 硬性约束（违反会重复踩坑）

1. **测试绝不能写用户真实数据目录**：所有测试/截图/自检都传**绝对 `--datadir <临时目录>`**；
   真实目录 `%APPDATA%\NetWatcher` 的 size+mtime+SHA256 必须零变化（`verify.ps1 -AuditRealData` 有守卫）。
2. **不要从 agent 工作区目录运行 exe 做长期服务**：该目录下进程可能被限制为"只能写工作区"，
   表现为"进程在、没数据、托盘异常"。用 `install.ps1` 复制到 `%LOCALAPPDATA%\Programs\NetWatcher` 再运行。
3. **启动 GUI 用** `Invoke-CimMethod -ClassName Win32_Process -MethodName Create`（或 redirect stdio），
   直接 `Start-Process` 会被 GUI 常驻进程的 stdio 句柄挂住。
4. **结束进程只按自己记录的 PID**，禁止 `Stop-Process -Name NetWatcher` 批量杀（会误杀用户/其它 agent 的实例）。
5. **含中文的 `.ps1` 必须 UTF-8 with BOM**（PowerShell 5.1 否则解析失败）。
6. **改 UI 必须真机截图验收**；管理员窗口无法被非管理员程序模拟点击（UIPI），截可用非管理员 + `--mutex-tag` 实例。
7. **签名必须在编译之后**：`build-and-sign.bat`；自签名 `.pfx` 绝不入库（已 gitignore）。
8. **提交信息中文、说明"为什么"**；行为变化同步 `README.md` / `CHANGELOG.md`。

---

## 5. 已知限制（不要当 bug 修）

- **EStats 精确模式不可用**（本机）：`--selftest`（管理员）看 `EStats 结论:` 一行；若要覆盖，需 ETW 方案（含 UDP/QUIC）。
- **UDP/QUIC 无远端 IP**：系统接口限制，只能计入总流量，无法逐 IP 归因。
- **离散采样**：默认 2 秒（可调 1 秒），短于间隔的连接可能漏。
- **SmartScreen**：自签名对 SmartScreen 无效；下载副本带 MotW 会被拦，用 `tools\fix-smartscreen.ps1` 解除。
- **第三方 HIPS（火绒等）**：即使签名也可能提示，需在安全软件里加信任区。

---

## 6. 待办（按价值排序，详见交接说明 §五）

1. **ETW 逐 IP/逐进程统计**（可覆盖 UDP/QUIC），约 0.5~1 天，建议单独排期。
2. **对外分发签名**：SignPath Foundation（开源免费）或 Certum 个人版 ≈600 元/年；EV 已无性价比；Azure Trusting Signing 对大陆主体不开放。
3. 体验项：列宽记忆、历史趋势图（`samples` 分钟桶数据已在 JSON 里）。
4. GitHub 远端同步（若网络不通，稍后 `git push origin main`）。

---

## 7. 关键路径

```
NetWatcher/
├── src/                    9 个 C# 源文件（C# 5 / .NET Framework 4.8 / WinForms）
├── bin/NetWatcher.exe      产物（约 110KB，已自签）
├── build.bat / build-and-sign.bat
├── install.ps1 / uninstall.ps1
├── README.md / CHANGELOG.md
├── docs/                   design-2.0 / 用户手册 / 开发与维护指南 / 踩坑与决策记录 / 交接说明 / screenshots
├── tools/sign/             自签名 + 2026 证书调研
├── tools/qa/               verify.ps1 一键验收（PASS/FAIL + 真实数据守卫）
└── tools/fix-smartscreen.ps1
```

数据目录：`%APPDATA%\NetWatcher\`（`data\YYYY-MM-DD.json`、`geocache.json`、`config.json`、
`startup.log`、`crash.log`、`ui-error.log`；历史数据归档在 `archive\`）。

---

## 8. 验收证据（可复核）

| 证据 | 位置 |
|---|---|
| headless 回归 PASS=27 / FAIL=0 | `tools/qa/out/report_*.txt`（本地生成，gitignore） |
| 四标签页 / 列头 / 排序 / 筛选 / CSV / 托盘截图 | `docs/screenshots/` |
| 逐 IP 合计 == 总流量（误差 0） | `verify.ps1` 的 `DATA_IP_BYTES` |
| 45 秒覆盖对照"漏记 0" | `docs/交接说明.md` §四 |
| 真实数据零改动 | `verify.ps1 -AuditRealData` 的 `REALDATA_UNTOUCHED` |

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
