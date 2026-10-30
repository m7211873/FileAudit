@echo off
rem FileAudit installer: double-click to request admin rights and run install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0install.ps1'"
echo.
echo If a UAC prompt appears, click "Yes" to continue.
pause
