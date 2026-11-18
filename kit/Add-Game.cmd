@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Add-Game.ps1" %*
pause
