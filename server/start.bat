@echo off
setlocal

set "MINGW_BIN=C:\msys64\mingw64\bin"

set "PATH=%MINGW_BIN%;%PATH%"

cd /d %~dp0

if not exist log_game mkdir log_game


..\runtime\skynet.exe skynet_config

pause
endlocal