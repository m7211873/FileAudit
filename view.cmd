@echo off
rem FileAudit viewer: generate the GUI report and open it in the browser.
rem The browser window stays open until you close it manually (no key-to-close).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0view.ps1"
if errorlevel 1 (
  echo.
  echo Failed to generate the report. Please copy the error above and send it to the assistant.
  pause
)
