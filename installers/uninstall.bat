@echo off
rem Remove GenFill from Nuke (keeps API keys and generated images).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"  %*
set GENFILL_EXIT=%ERRORLEVEL%
echo.
pause
exit /b %GENFILL_EXIT%
