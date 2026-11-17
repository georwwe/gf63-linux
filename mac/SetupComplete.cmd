@echo off
rem Runs once as SYSTEM at the end of Windows Setup, before the first logon.
set GF63=%SystemDrive%\GF63
if exist "%GF63%\drivers" pnputil /add-driver "%GF63%\drivers\*.inf" /subdirs /install > "%GF63%\drivers-install.log" 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v GF63Optimize /t REG_SZ /d "%GF63%\Optimize.cmd" /f > nul
exit /b 0
