@echo off
rem Point Nuke straight at this repo (live code, no copy).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Mode dev %*
set GENFILL_EXIT=%ERRORLEVEL%
echo.
pause
exit /b %GENFILL_EXIT%
