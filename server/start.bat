@echo off
setlocal

set "MINGW_BIN=C:\msys64\mingw64\bin"
set "PATH=%MINGW_BIN%;%PATH%"

cd /d %~dp0

if not exist log_game mkdir log_game


set "GAME_SERVER_ID=1"
set "GAME_WS_PORT=9948"

set "MONGO_HOST=118.89.55.243"
set "MONGO_PORT=27017"
set "MONGO_DB=game"
set "MONGO_AUTHDB=admin"
set "MONGO_USERNAME=root"
set "MONGO_PASSWORD=xiaweiye123"

..\runtime\skynet.exe skynet_config

pause
endlocal