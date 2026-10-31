# 2.1 验收证据归档

本目录保存 2.1 定版时的独立验收报告与关键证据（由 p0-verifier 执行、Lead 复核），
用于复核「P0/P1 修复确实成立、环境性 FAIL 已归因」：

- `2.1-P0-验收.md`：P0 回归 regression-p0.ps1 结果（PASS=29/29）、headless/GUI 验收与 FAIL 归因
- `2.1-P1-验收.md`：P1 回归 regression-p1.ps1 结果（PASS=38/38）、P1 后 P0 复跑（29/29）、静态检查与限制
- `control_realdata_*.txt`：真实数据 45 秒闲置对照组（证明 `%APPDATA%\NetWatcher` 的变化来自用户正在运行的 2.0 实例，
  不是 2.1 测试实例写入）

复跑方法（仓库 2.1/ 目录）：

```powershell
cmd /c build.bat
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-p0.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\regression-p1.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\qa\verify.ps1 -SkipGui -Seconds 30
```

注意：所有测试必须用绝对 `--datadir <临时目录>`；真实数据目录 `%APPDATA%\NetWatcher` 的
`size+mtime+SHA256` 必须零变化（`verify.ps1 -AuditRealData` 有守卫）。若本机另有 2.0 实例在运行，
`REALDATA_UNTOUCHED` 会因用户实例写盘而变化——用闲置对照组归因，不能改判或掩盖。