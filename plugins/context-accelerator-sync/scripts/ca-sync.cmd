@echo off
rem Windows launcher for cmd.exe / PowerShell callers. Same arguments as ca-sync.ps1.
set "CA_DIR=%~dp0"
set "CA_BASE="
if /I "%~1"=="setup" set /p CA_BASE=<"%CA_DIR%server-url"
if /I "%~1"=="reset-token" set /p CA_BASE=<"%CA_DIR%server-url"
if defined CA_BASE (
  echo %* | findstr /C:"--base" >nul && set "CA_BASE="
)
if defined CA_BASE (
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%CA_DIR%ca-sync.ps1" %* --base %CA_BASE%
) else (
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%CA_DIR%ca-sync.ps1" %*
)
exit /b %ERRORLEVEL%
