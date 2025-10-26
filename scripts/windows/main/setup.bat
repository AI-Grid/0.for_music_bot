@echo off
setlocal
echo Launching PowerShell setup script...
echo.

REM --- Resolve PS1 path next to this BAT ---
set "PS1=%~dp0setup-windows.ps1"
if not exist "%PS1%" (
  echo ERROR: PowerShell script not found at "%PS1%".
  echo Make sure setup-windows.ps1 is in the same folder as this BAT.
  pause
  endlocal & exit /b 1
)

REM --- Elevate this BAT if not already admin ---
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges...
  REM Relaunch this same BAT elevated; the elevated instance will continue below.
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  REM Important: exit the non-elevated instance cleanly.
  endlocal & exit /b
)

REM --- Prefer pwsh.exe if available; else Windows PowerShell ---
set "PS="
for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do set "PS=%%I"
if not defined PS set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

REM --- Run PowerShell setup; pass through any args (%*) ---
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "rc=%ERRORLEVEL%"

if not "%rc%"=="0" (
  echo.
  echo Setup exited with code %rc%.
  echo Check logs under: "%~dp0logs"
  echo Press any key to close...
  pause >nul
)

endlocal & exit /b %rc%
