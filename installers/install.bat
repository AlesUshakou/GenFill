@echo off
rem Install the current build from this repo into Nuke (runs tests first).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"  %*
set GENFILL_EXIT=%ERRORLEVEL%
echo.
pause
exit /b %GENFILL_EXIT%
