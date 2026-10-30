# ============================================================
#  publish.ps1 —— 一键把当前目录推送到 Gitee / GitHub
#  用法：
#    .\publish.ps1 -Remote "https://gitee.com/你的用户名/FileAudit.git"
#    .\publish.ps1 -Remote "https://github.com/你的用户名/FileAudit.git"
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
if ($Remote -notmatch '^https?://') {
    Write-Host '远程地址应以 https:// 开头，例如 https://gitee.com/你的用户名/FileAudit.git' -ForegroundColor Red
    exit 1
}

Write-Host '>> 初始化仓库...' -ForegroundColor Cyan
if (Test-Path .git) { Write-Host '   已存在 .git，跳过初始化' } else { git init | Out-Null }

Write-Host '>> 添加所有文件...' -ForegroundColor Cyan
git add .

Write-Host '>> 提交...' -ForegroundColor Cyan
git commit -m $CommitMessage 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '提交失败。若是第一次使用，请先设置身份后重试：' -ForegroundColor Yellow
    Write-Host '  git config --global user.name "你的名字"'
    Write-Host '  git config --global user.email "你的邮箱"'
    exit 1
}

Write-Host '>> 设置远程仓库...' -ForegroundColor Cyan
git remote remove origin 2>$null
git remote add origin $Remote
git branch -M main

Write-Host '>> 推送到远程...' -ForegroundColor Cyan
Write-Host '   提示：弹出登录框时，用户名填你的账号，密码填「私人令牌/Personal Access Token」。' -ForegroundColor DarkYellow
git push -u origin main

Write-Host ''
Write-Host '发布完成！到网页上刷新你的仓库即可看到文件。' -ForegroundColor Green
