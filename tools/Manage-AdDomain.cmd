@echo off
rem Launcher: double-click to run Manage-AdDomain.ps1 (keep both files in the same folder).
rem ExecutionPolicy Bypass applies to this process only; system settings are not changed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0Manage-AdDomain.ps1" %*
