@echo off
setlocal

set "CLANG_BIN=C:\msys64\clang64\bin"
set "PATH=%CLANG_BIN%;%PATH%"

cd /d "%~dp0"

echo [*] Starting test with CLANG64 Python...
python Test/test_server.py --test register

pause
endlocal