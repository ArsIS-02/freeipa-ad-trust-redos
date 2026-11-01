@echo off
rem Launcher: double-click to run Manage-AdDomain.ps1 (keep both files in the same folder).
rem ExecutionPolicy Bypass applies to this process only; system settings are not changed.
if not exist "%~dp0Manage-AdDomain.ps1" (
  echo Manage-AdDomain.ps1 not found next to this file: %~dp0
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-AdDomain.ps1" %*
echo.
echo Exit code: %errorlevel%
pause
