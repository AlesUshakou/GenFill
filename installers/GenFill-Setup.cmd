@echo off
rem GenFill Setup: the graphical installer. Double-click to install, update or uninstall.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0GenFill-Setup.ps1" %*
