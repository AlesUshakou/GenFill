@echo off
rem Run the smoke test in Nuke terminal mode; writes test_output\report.json.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_smoke_test.ps1"  %*
set GENFILL_EXIT=%ERRORLEVEL%
echo.
pause
exit /b %GENFILL_EXIT%
