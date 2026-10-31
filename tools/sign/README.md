# NetWatcher 代码签名工具（tools/sign）

> 目标：解决 `bin\NetWatcher.exe` 没有签名、启动时被提示「未知发布者 / 风险」的问题。
>
> 本目录是**本机立刻可用**的自签名流水线，同时附 2026 年各条正规签名途径的调研结论（§6）。
> 只依赖 Windows 自带的 PowerShell 5.1 + .NET Framework，**不需要 signtool、不需要 Windows SDK、不需要管理员权限**。

---

## 0. 一句话结论

| 场景 | 方案 | 效果 |
| --- | --- | --- |
| 只给自己用 / 自己几台机器用 | ✅ 本目录自签名 | 本机不再显示「未知发布者」，`Get-AuthenticodeSignature` = `Valid` |
| 发给别人（他们愿意装一次证书） | 自签名 + 分发 `NetWatcher.cer` | 装证书后不再显示「未知发布者」，但 SmartScreen **仍可能**警告 |
| 发给别人（不想让人装证书） | ❌ 自签名无解，必须走 §6 的受信任 CA / 云签名 | 显示真实发布者名；SmartScreen 需靠下载量积累信誉 |
| 通过 Microsoft Store 分发 | 免费，商店重签名 | 唯一「下载后永远不警告」的路径 |

**必须知道**：自签名证书不会让 SmartScreen / Smart App Control 放行。微软官方明确写了「自签名证书 = 与未签名相同的 SmartScreen 行为」，并且 **EV 证书自 2024 年起也不再秒过 SmartScreen**（以前可以，现在不行）。详见 §5、§6。

---

## 1. 文件清单

```
tools/sign/
├─ sign.ps1                     # 主脚本：建证书 / 签名 / 导入信任 / 导出 cer+pfx
├─ verify-sign.ps1              # 验证：签名状态、证书链、是否在本机信任存储
├─ README.md                    # 本文件
├─ test/NetWatcher-test.exe     # 签名验证样本（真实 bin\NetWatcher.exe 的副本，留着方便复测，可删）
└─ out/                         # 运行后生成
   ├─ NetWatcher.cer            # 公钥证书（可安全分发）
   └─ NetWatcher.pfx            # 带私钥（⚠ 绝对不能外传，等同于你的发布者身份）
```

当前本机已创建的证书：

- Subject：`CN=NSYBdeDFY NetWatcher`
- Thumbprint：`DD40E3E2A683CB7923472EB56844379359092CF4`
- 有效期至：`2029-10-31`
- 存储：`Cert:\CurrentUser\My`（私钥可导出），已导入 `CurrentUser\Root` 与 `CurrentUser\TrustedPublisher`
- 签名后 `bin\NetWatcher.exe` 的 SHA256：`AD7D38125FEFA05F9B0347CE01F9C533359F0D4254AFBC5D2749DAF1CA423CC1`

---

## 2. 快速使用

Windows 默认执行策略是 `Restricted`，直接 `.\sign.ps1` 会报「未对文件进行数字签名」。用下面任一方式运行：

```powershell
# 方式 A：进程级绕过（推荐，不改系统设置）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\sign\sign.ps1

# 方式 B：当前会话放开一次
Set-ExecutionPolicy -Scope Process Bypass
.\tools\sign\sign.ps1
```

常用调用：

```powershell
cd <仓库根>
# 1) 默认：签 bin\NetWatcher.exe，复用已有证书，导入本机信任，导出 out\*.cer/*.pfx（会提示输入 pfx 密码）
.\tools\sign\sign.ps1

# 2) 只签名、不动本机信任存储（例如给 CI/临时测试机用）
.\tools\sign\sign.ps1 -InstallTrusted $false

# 3) 指定 pfx 路径与密码（非交互）
.\tools\sign\sign.ps1 -PfxPath D:\keys\NetWatcher.pfx -PfxPassword 'your-password'

# 4) 换一张新证书（⚠ 发布者身份变了，已签名的旧版本不会继承信誉）
.\tools\sign\sign.ps1 -ForceNew

# 5) 验证
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\sign\verify-sign.ps1
```

参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Exe` | `<仓库根>\bin\NetWatcher.exe` | 要签名的文件 |
| `-Subject` | `CN=NSYBdeDFY NetWatcher` | 证书主题；同一 Subject 会被复用 |
| `-PfxPath` | `tools\sign\out\NetWatcher.pfx` | pfx 导出路径 |
| `-PfxPassword` | 交互式提示 / 非交互随机生成并打印 | pfx 密码 |
| `-InstallTrusted` | `$true` | 是否导入 `CurrentUser\Root` + `CurrentUser\TrustedPublisher` |
| `-ExportDir` | `tools\sign\out` | `.cer`/`.pfx` 输出目录 |
| `-ForceNew` | 关 | 强制新建证书而不是复用 |

脚本是**幂等**的：重复运行会复用同一张证书、重新签名，产出的 exe 字节完全一致（实测 110480 字节不变、SHA256 不变），可以放心在每次构建后调用。

`verify-sign.ps1` 退出码：`0`=Valid 且本机信任；`1`=未签名/签名损坏；`2`=Valid 但本机未导入证书；`3`=签名者与 `-Thumbprint` 不符。

---

## 3. 为什么没有时间戳（RFC3161）

时间戳的作用是证明「签名发生在某个时刻」，让**证书过期后**旧签名仍可验证。自签名场景刻意跳过，原因：

1. 自签名的信任来源是「目标机器手工导入了这个根证书」，时间戳无法把它变成受信任根，也不会让别的机器少一次警告；
2. 依赖公网 TSA，离线/内网构建直接失败，部分 TSA 也拒绝对自签证书的时间戳请求；
3. 自签根证书有效期（本脚本 3 年）完全由你控制，到期重新签一张即可，「过期后仍有效」意义有限。

> 将来若换成 OV/EV/云签名，**务必**加时间戳（`signtool sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 ...`）。没有时间戳的商业签名，在证书到期/吊销后旧版本会变成「签名无效」。

---

## 4. 别的机器怎么信任这张证书

`.cer` 是**公钥**，可以随便分发；`.pfx` 含**私钥**，绝对不要发给别人。

### 方式 A：当前用户（每台一次，无需管理员）

把 `out\NetWatcher.cer` 拷到目标机器，在该机器上执行：

```powershell
Import-Certificate -FilePath .\NetWatcher.cer -CertStoreLocation Cert:\CurrentUser\Root
Import-Certificate -FilePath .\NetWatcher.cer -CertStoreLocation Cert:\CurrentUser\TrustedPublisher
```

（等价于双击 `.cer` → 安装证书 → 分别装到「受信任的根证书颁发机构」和「受信任的发布者」。）

### 方式 B：给本机所有用户（需要管理员）

```powershell
Import-Certificate -FilePath .\NetWatcher.cer -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath .\NetWatcher.cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
```

### 验证对方机器是否生效

```powershell
powershell -ExecutionPolicy Bypass -File .\verify-sign.ps1 -Exe .\NetWatcher.exe
# 或直接看
Get-AuthenticodeSignature .\NetWatcher.exe | Format-List Status, StatusMessage, SignerCertificate
```

### 卸载证书

```powershell
$tp = 'DD40E3E2A683CB7923472EB56844379359092CF4'
Remove-Item "Cert:\CurrentUser\Root\$tp" -Force -ErrorAction SilentlyContinue
Remove-Item "Cert:\CurrentUser\TrustedPublisher\$tp" -Force -ErrorAction SilentlyContinue
# 管理员卸载 LocalMachine：
# Remove-Item "Cert:\LocalMachine\Root\$tp" -Force -ErrorAction SilentlyContinue
# Remove-Item "Cert:\LocalMachine\TrustedPublisher\$tp" -Force -ErrorAction SilentlyContinue
# 删除签名证书本体（连同私钥，删了就再也签不出同一发布者）
Remove-Item "Cert:\CurrentUser\My\$tp" -Force -ErrorAction SilentlyContinue
```

> 卸载 `CurrentUser\Root` 可能弹出「删除根证书」确认框，确认即可。
> 注意：删除 `CurrentUser\My` 里的证书 = 丢失私钥，之后签名会变成另一个发布者身份。

---

## 5. 自签名的真实边界（实测 + 官方说明）

| 环境 / 机制 | 自签名表现 | 说明 |
| --- | --- | --- |
| **本机**（证书已导入 Root+TrustedPublisher） | ✅ 不再显示「未知发布者」，`Get-AuthenticodeSignature` = `Valid` | 已实测 |
| 别人机器（**未导入**证书） | ⚠️ 仍提示「未知发布者」，与未签名一样 | 证书未被信任 |
| 别人机器（**已导入**证书） | ✅ 不再显示「未知发布者」 | 但需要人工装证书 |
| **Microsoft Defender SmartScreen**（下载来的文件） | ⚠️ **仍可能拦**，行为等同未签名 | 官方定义：`Self-signed Certificate → Same behavior as no signature` |
| **Smart App Control**（Win11 全新安装才可能开启） | ⚠️ **会拦**（无信誉的未受信任文件） | Win10 19045 不涉及；发给 Win11 新机器可能中招 |
| 第三方杀软 / HIPS（本机 `HipsDaemon`） | ⚠️ 与签名无关 | 本机 `HipsDaemon` 实测是**火绒**（`C:\Program Files\Huorong\Sysdiag\bin\HipsDaemon.exe`，Beijing Huorong，v6.0.0.2），联想预装组件；要它不提示，得在火绒「信任区」把 exe 加白，签名不解决 HIPS 规则 |
| 从网盘/浏览器下载后首次运行 | ⚠️ 带「下载标记（Mark-of-the-Web）」，SmartScreen 更容易触发 | 可让用户右键 → 属性 → 解除锁定 |
| exe 被重新构建/修改后 | ❌ 签名失效（哈希变了） | 每次 `build.bat` 之后要重跑 `sign.ps1` |

官方依据：

- [SmartScreen reputation for Windows app developers](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)（2026-05 更新：明确「自签名=未签名」「EV 不再秒过 SmartScreen」）
- [Code signing options for Windows app developers](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)（2026-08 更新：各方案费用/SmartScreen 对比表）

---

## 6. 想「别人机器也不报警」：2026 年现状与推荐顺序

### 6.1 各途径对比

| 途径 | 费用（参考） | 申请门槛 | 对 SmartScreen | 私钥存储 | 中国大陆个人可行？ |
| --- | --- | --- | --- | --- | --- |
| 自签名（本目录） | 0 | 无 | ❌ 无帮助（=未签名） | 本机 PFX/证书存储 | ✅ 本机可用，分发需对方装证书 |
| **Certum 个人版**（国内代理，云签名） | 约 **600 元/年** | 自然人 + 身份证明；无需营业执照 | ⚠️ 不再显示「未知发布者」，首下载仍可能提示，靠下载量积累 | SimplySign 云 HSM（无需 USB 令牌） | ✅ 最便宜的「正规」路径 |
| Certum 标准（组织）版 | 约 880 元/年 | 企业/组织 + 统一社会信用代码 + 电话回拨 | 同上 | 云 HSM / 硬件令牌 | ✅（需有主体） |
| **Certum 开源版**（Open Source） | €329/年（约 2600 元） | 开源项目；GitHub ≥1k star 且申请人中国国籍可**免费**申请 | 同上 | 云 HSM（SimplySign） | ✅ |
| 沃通 WoSign 标准/ EV | ¥3588–4888 / ¥4288–6888 每年 | 企业/组织；EV 核验更严 | 同上 | 硬件 Key 邮寄 | ✅（贵） |
| DigiCert / Sectigo OV | 约 $150–300/年 | 组织身份验证（CA 政策收紧，个人较难） | 同上 | HSM/令牌 | ⚠️ 门槛与价格都高 |
| EV（任意 CA） | $400+/年（国内约 2300–6900 元） | 组织 + 扩展验证 | ⚠️ **自 2024 年起不再秒过 SmartScreen** | 硬件令牌 / 云 HSM | 仅驱动签名、WHQL、企业采购才值得 |
| **Azure Artifact Signing**（原 Trusted Signing） | **$9.99/月**（5000 签名/月）/ Premium $99.99/月 | 需 Entra 租户 + Azure 订阅 + 身份验证（1–20 工作日）；**Public Trust 地区限制** | ⚠️ 需积累信誉；但微软推荐的非商店方案 | 全托管 FIPS 140-3 L3 HSM，CI 集成 | ❌ **个人仅限美国/加拿大**（中国大陆主体不在 Public Trust 地区名单） |
| SignPath Foundation | **免费** | 开源项目 + 申请审核 + CI 集成（GitHub/GitLab 流水线） | ⚠️ 同上（OV 级签名） | 托管签名 | ✅ 项目符合 OSS 条件即可 |
| Microsoft Store（MSIX） | 免费 | 开发者账号（Store） | ✅ **商店重签名，永不警告** | 微软 | ✅（需改分发形态，MSIX 打包） |

关键事实（官方来源）：

- **EV 不再秒过 SmartScreen**：2024 年已移除该行为，EV 与 OV 现在一样走「信誉积累」。见 [SmartScreen 文档](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation) 与 [签名方案对比](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)。
- **OV/EV 私钥必须硬件保护**：2023-06 起 CA/B Forum 要求私钥存 HSM/硬件令牌 → 所以现在多是「云签名（SimplySign）」或「USB 令牌邮寄」。
- **代码签名证书最长有效期 460 天**（2026-03-01 起，CA/B 新规）→ 每年要重新签发，务必加时间戳。
- **Artifact Signing 地区限制**：Public Trust 组织仅限美国/加拿大/EU/英国（[quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart) 另列澳大利亚/新西兰/日本/韩国/新加坡/瑞士/挪威/以色列），**个人开发者仅限美国/加拿大**；中国大陆个人/企业均不符合 Public Trust 条件，Azure 中国区也没有该服务。价格见 [SKU 文档](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-change-sku) / [定价页](https://azure.microsoft.com/pricing/details/artifact-signing/)。
- **SignPath Foundation**：开源项目免费签名，需申请与 CI 集成，见 [signpath.org](https://signpath.org/)。
- **Certum 开源云签名**：€329/年；GitHub ≥1k star + 中国国籍可免费申请（代理商页面：[certumcodesign.cn](http://certumcodesign.cn/shop/product/open-source-code-signing-cloud/)）。
- **国内价格参考**（代理商页面，实际以报价为准）：[Certum 个人/组织/EV 选型与价格](https://www.certumca.cn/news-list/68.html)、[沃通代码签名价格](https://buy.wosign.com/CodeSigning)。

### 6.2 推荐顺序（针对本项目）

1. **现在就用：自签名（零成本，已交付）** —— 本机/内网/自己几台机器立刻解决「未知发布者」。
2. **要免费又正规：SignPath Foundation**（或 Certum 开源免费名额）—— NetWatcher 是开源项目，把仓库镜像到 GitHub/GitLab 后申请；一旦通过，签名由 OV 级证书完成，别人机器显示真实发布者。前提：接受「用第三方 CI 出包」的流程改动。
3. **要便宜且省事（不接受 CI 改造）：Certum 个人版云签名 ≈600 元/年** —— 国内代理可办、自然人身份即可、云 HSM 不用寄令牌、Win10 可用；这是「个人开发者能买到的最便宜的正规签名」，也是**现实最低成本、能让别人机器不再显示「未知发布者」的组合**（再配 `-TimestampServer` 时间戳）。
4. **有企业主体/要签驱动/客户要求 EV：EV（约 2300 元/年 Certum，或沃通 4288–6888 元/年）** —— 但别指望它让 SmartScreen 立刻闭嘴；EV 的价值现在主要是驱动签名、WHQL 与企业采购。
5. **有海外主体再考虑 Azure Artifact Signing（$9.99/月）** —— 技术和价格都很好（云 HSM + CI 集成 + 自动轮换），但 **Public Trust 的地区限制把中国大陆个人/企业排除在外**；Private Trust 虽无地区限制，但对 SmartScreen 无意义（只用于内部分发）。
6. **想要「下载后永远不警告」：Microsoft Store（MSIX）** —— 免费且唯一彻底方案，但需要改分发形态与商店审核。

### 6.3 诚实结论：没有任何证书能「立刻让所有人不报警」

SmartScreen 是「发布者信誉 + 文件哈希信誉」双信号，新文件即使有 OV 证书也可能提示「未识别的应用」。要让它消失：

- 用**同一张证书**（同一发布者身份）持续签名每一个版本；
- 让用户从你的发布页下载（而不是到处转发附件），积累干净下载量（通常要数周、数百次安装）；
- 商业证书签名**必须加时间戳**；
- 驱动/内核组件只能走 EV + WHQL；
- 别给会被判定为 PUA 的程序签名，否则证书会积累**负信誉**。

---

## 7. 与 `build.bat` 的关系（重要）

`build.bat` 每次都会重新生成 `bin\NetWatcher.exe`，**新文件没有签名**。因此：

- 每次构建后重跑 `tools\sign\sign.ps1`（幂等，复用同一证书）；
- 不要改 `build.bat` 去自动签名（构建环境可能没有证书私钥/密码）；
- 交给别人之前，用 `verify-sign.ps1` 确认 `Status = Valid` 且 SHA256 与发布清单一致；
- 签名之后**不要**再改 exe（改任何字节都会让签名失效）。

---

## 8. 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| 「未对文件…进行数字签名，无法运行脚本」 | 执行策略。用 `powershell -ExecutionPolicy Bypass -File .\sign.ps1`，或 `Set-ExecutionPolicy -Scope Process Bypass` |
| 「文件被占用」 | NetWatcher 正在运行，或构建还没结束。关掉进程再签 |
| 导入 Root 没反应/被策略拦 | 公司域策略可能禁止用户根证书；改用管理员导入 `LocalMachine\Root`，或让 IT 用 Intune/GPO 部署 |
| `Status = UnknownError`，但证书在存储里 | 终端缓存/证书链未刷新；重开 PowerShell 再跑 `verify-sign.ps1`；确认 `.pfx/.cer` 证书确实同一 Thumbprint |
| 别的机器 `verify` 返回 2 | 对方没导入 `.cer`，按 §4 导入 Root + TrustedPublisher |
| 签名后文件变大 | 正常：Authenticode 会把证书+签名附加进 PE 的证书表（本 exe 105984 → 110480 字节） |
| 想回退成未签名 exe | 从 git 恢复：`git checkout -- bin/NetWatcher.exe`（注意：这会丢掉签名；`bin` 是否被跟踪以仓库为准） |

---

## 9. 安全提醒

- `out\NetWatcher.pfx` 含**私钥**，拿到它就能以你的发布者身份签任意程序。不要提交到 git、不要发网盘/邮件；`tools/sign/out/` 建议加入 `.gitignore`（本任务未改动 `.gitignore`，如需请自行添加）。
- 私钥泄露后唯一补救：吊销/删除证书（`Remove-Item Cert:\CurrentUser\My\<thumbprint>`），换新证书重新签名，并通知用户。
- `.cer` 是公钥，可以公开分发。
