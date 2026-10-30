# ============================================================
#  publish.ps1 —— 一键把当前目录推送到 Gitee / GitHub
#  用法：
#    .\publish.ps1 -Remote "https://gitee.com/你的个人空间地址/FileAudit.git"
#    .\publish.ps1 -Remote "https://github.com/你的用户名/FileAudit.git"
#  说明：
#    - 可重复运行：没有新改动会自动跳过提交
#    - 需要已安装 git，并已设置 user.name / user.email
# ============================================================
param(
    [Parameter(Mandatory = $true)][string]$Remote,
    [string]$CommitMessage = 'Initial commit'
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '未检测到 git。请先安装：在 PowerShell 运行  winget install --id Git.Git -e --source winget' -ForegroundColor Red
    exit 1
}

# 地址校验：必须是 http(s)，且不能带中文 / 全角括号（Gitee 路径里是「个人空间地址」，不是昵称）
if ($Remote -notmatch '^https?://') {
    Write-Host '远程地址应以 https:// 开头。' -ForegroundColor Red
    exit 1
}
if ($Remote -match '[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]') {
    Write-Host '远程地址不合法：里面有中文或全角符号。' -ForegroundColor Red
    Write-Host '请到仓库页面「克隆/下载」复制 HTTPS 地址，例如：https://gitee.com/xxxxxx/FileAudit.git' -ForegroundColor Yellow
    exit 1
}
if (-not $Remote.EndsWith('.git')) {
    Write-Host '提示：地址通常以 .git 结尾，确认没复制漏。' -ForegroundColor Yellow
}

Write-Host '>> 初始化仓库...' -ForegroundColor Cyan
if (Test-Path .git) { Write-Host '   已存在 .git，跳过初始化' } else { git init | Out-Null }

Write-Host '>> 添加所有文件...' -ForegroundColor Cyan
git add .

$staged = @(git diff --cached --name-only)
if ($staged.Count -gt 0) {
    Write-Host ">> 提交 $($staged.Count) 个文件..." -ForegroundColor Cyan
    git commit -m $CommitMessage
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host '提交失败。若是第一次使用，请先设置身份后重试：' -ForegroundColor Yellow
        Write-Host '  git config --global user.name "你的名字"'
        Write-Host '  git config --global user.email "你的邮箱"'
        exit 1
    }
} else {
    Write-Host '   没有新改动，跳过提交' -ForegroundColor DarkGray
}

Write-Host '>> 设置远程仓库...' -ForegroundColor Cyan
# 不要用 `git remote remove origin 2>$null`：在没有 origin 时 git 会写 stderr，
# 配合 $ErrorActionPreference='Stop' 会抛 NativeCommandError，脚本会在这里中断。
$remotes = @(git remote)
if ($remotes -contains 'origin') {
    git remote set-url origin $Remote
} else {
    git remote add origin $Remote
}
Write-Host "   origin = $Remote" -ForegroundColor DarkGray
git branch -M main

Write-Host '>> 推送到远程...' -ForegroundColor Cyan
Write-Host '   提示：弹出登录框时，用户名填平台账号，密码填「私人令牌 / Personal Access Token」。' -ForegroundColor DarkYellow
git push -u origin main
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '推送失败，常见原因：' -ForegroundColor Red
    Write-Host '  1) 地址里的「个人空间地址」写错（不能写中文昵称）' -ForegroundColor Yellow
    Write-Host '  2) 密码填成了登录密码，应该填私人令牌 / PAT' -ForegroundColor Yellow
    Write-Host '  3) 仓库还没在网页上创建' -ForegroundColor Yellow
    Write-Host '  4) GitHub 需要开代理' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host '发布完成！到网页上刷新你的仓库即可看到文件。' -ForegroundColor Green
