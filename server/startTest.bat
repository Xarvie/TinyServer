@echo off
setlocal

set "CLANG_BIN=C:\msys64\clang64\bin"
set "PATH=%CLANG_BIN%;%PATH%"

cd /d "%~dp0"

if not defined GAME_WS_PORT set "GAME_WS_PORT=9948"

echo [*] Starting test (port=%GAME_WS_PORT%)...
python Test/test_server.py --port %GAME_WS_PORT% --test register

pause
endlocal