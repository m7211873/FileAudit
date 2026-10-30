# FileAudit —— Windows 文件访问记录器

> 常驻后台，记录**「哪个程序、在何时、读取/写入/创建/删除了哪个文件」**，自动排除 Windows 系统动作与 Steam（含其游戏库）。
> 基于 Windows 原生 NTFS 对象访问审计（内核级），无需自己写内核驱动。

## ✨ 功能特性

- **五类操作归类**：`读取(Read)` / `写入(Write)` / `创建(Create)` / `删除(Delete)` / `其他(Other)`
- **进程归因**：每条记录带发起程序的**完整路径**、PID、账户
- **创建关联**：新建文件时，自动关联出**具体的新文件名**（而非只显示父目录）
- **图形界面**：顶部汇总栏（条数/进程数/时间范围/报告路径/防绕开时间）+ 按程序分组可折叠 + 一键复制
- **防绕开**：记录“谁关了审计”、每 5 分钟自动补回被删的审计规则、以 SYSTEM 权限运行
- **自动排除**：`C:\Windows`、Steam 及游戏库、Windows Defender / 搜索索引等系统进程

## 🔍 工作原理

```
auditpol 启用「对象访问 > 文件系统」成功审计（用 GUID，跨语言）
        │
        ▼
对 C:/D: 数据目录设置 SACL（Everyone · 成功审计，排除 Windows/Steam）
        │
        ▼
内核在「安全」日志生成 4663 事件
        │
        ▼
计划任务（SYSTEM，每 5 分钟）读取 4663 → 过滤 → 导出 CSV
        │
        ▼
查看器读取 CSV → 生成自包含 HTML 图形界面
```

## 🖥 环境要求

- **Windows 10 / 11 专业版、企业版、教育版**（家庭版不支持本地安全策略/auditpol）
- 安装需要**管理员权限**（会弹出 UAC）

## 🚀 安装

1. 双击 `install.cmd`，弹出 UAC 时点“是”
2. 等待脚本跑完，看到“安装完成”即可

安装后自动运行，重启电脑也会自动恢复记录。默认安装目录为 `D:\FileAudit`。

## 📖 使用

- 双击桌面 **「文件监控·查看」** 打开图形界面（只有手动关闭浏览器才退出）
- 记录文件：`D:\FileAudit\events\*.csv`；防绕开事件：`D:\FileAudit\tamper\*.csv`
- 查看器命令行高级用法：

```powershell
.\view.ps1 -Process notepad          # 只看某个程序
.\view.ps1 -Path "D:\资料"           # 只看某个目录
.\view.ps1 -Operation Create         # Read/Write/Create/Delete/Other
.\view.ps1 -Since 2026-10-30         # 按日期范围
.\view.ps1 -NoOpen                   # 只生成不打开浏览器
.\view.ps1 -Console                  # 纯文本表格（后备）
```

## 📁 目录结构

| 文件 | 作用 |
|------|------|
| `install.ps1` / `install.cmd` | 安装（提权、开审计、设 SACL、注册计划任务、建快捷方式） |
| `export.ps1` | 导出器（SYSTEM 定时读取 4663 → CSV，含创建关联与补审计） |
| `view.ps1` / `view.cmd` | 查看器（生成 HTML 图形界面） |
| `sacl.ps1` | 目录审计(SACL) 公共逻辑（幂等、每轮自愈） |
| `common.ps1` | 权限码 `%%NNNN` 解析与操作归类 |
| `uninstall.ps1` | 卸载（关审计、移除 SACL、删计划任务） |

## ⚠️ 已知限制（欢迎 PR 改进）

- **创建 vs 写入**：Windows 审计把“新建文件”记录在**父目录**（`AddFile` 权限位与 `WriteData` 共用 0x2），本工具用「目标是否为目录 + 是否带添加动作」判定创建，再用**同进程 3 秒内、直接子文件**的写入事件关联出具体文件名；新建**子目录**时（目录内无文件写入）仍显示父目录。
- 无法区分「覆写已有文件」与「新建文件」（两者审计权限位完全相同）。
- 直接读写磁盘原始扇区（`\\.\C:`、`\Device\HarddiskVolumeN`）或内核级 rootkit 可完全绕过；需内核 minifilter 驱动或 EDR。
- 默认安装路径硬编码为 `D:\FileAudit`（`install.ps1` / `sacl.ps1` 中）。
- 界面与文档目前为中文。
- “记录文件被修改了哪些内容（前后 diff）”尚未实现（需 VSS 卷影副本）。

## 🛡 安全说明

本工具定位是**“可见性 + 归因”**，不是“不可篡改的安全控制”。要对抗内核级恶意软件，请配合正规 EDR（Windows Defender / 火绒 / 卡巴斯基等），并把日志**异地转发**（Windows 事件转发 WEF）防止本地被删。

## 📜 License

[MIT](LICENSE)
