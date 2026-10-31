@echo off
rem ============================================================
rem  IP监控2.0 一键编译 + 自签名
rem  说明：build.bat 会覆盖 bin\NetWatcher.exe，签名必须在编译之后做。
rem  自签名证书保存在当前用户证书库，首次运行会自动创建并导入信任存储。
rem ============================================================
setlocal
cd /d "%~dp0"

call "%~dp0build.bat"
if errorlevel 1 (
    echo [ERROR] 编译失败，未执行签名。
    exit /b 1
)

echo.
echo >> 开始自签名...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\sign\sign.ps1" -Exe "%~dp0bin\NetWatcher.exe"
if errorlevel 1 (
    echo [WARN] 签名失败，程序本身仍可运行（只是会显示"未知发布者"）。
    exit /b 0
)

echo.
echo [OK] 编译 + 签名完成: bin\NetWatcher.exe
