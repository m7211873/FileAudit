@echo off
setlocal
cd /d "%~dp0"

set "FW=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319"
if not exist "%FW%\csc.exe" set "FW=%WINDIR%\Microsoft.NET\Framework\v4.0.30319"
if not exist "%FW%\csc.exe" (
    echo [ERROR] csc.exe not found.
    exit /b 1
)

if not exist bin mkdir bin

"%FW%\csc.exe" /nologo /target:winexe /platform:anycpu /optimize+ /win32icon:app.ico /out:bin\NetWatcher.exe ^
  /r:"%FW%\System.Windows.Forms.dll" ^
  /r:"%FW%\System.Drawing.dll" ^
  /r:"%FW%\System.Web.Extensions.dll" ^
  /r:"%FW%\System.Core.dll" ^
  src\AssemblyInfo.cs src\Config.cs src\GeoIp.cs src\Json.cs src\MainForm.cs src\Monitor.cs src\NativeMethods.cs src\Program.cs src\SettingsForm.cs src\Storage.cs

if errorlevel 1 (
    echo [ERROR] Build failed.
    exit /b 1
)
echo [OK] bin\NetWatcher.exe built.
