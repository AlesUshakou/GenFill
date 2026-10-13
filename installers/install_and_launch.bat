@echo off
rem Install the current build, then start the newest Nuke.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Launch %*
set GENFILL_EXIT=%ERRORLEVEL%
echo.
pause
exit /b %GENFILL_EXIT%
