#!/bin/bash
set -e
cd "$(dirname "$0")"
SKYNET="./skynet/skynet"
CONF="config/config.game"
PID="skynet.pid"

if [ ! -f "$SKYNET" ]; then
    echo "[ERROR] skynet binary not found. Run: cd skynet && make linux"
    exit 1
fi

if [ -f "$PID" ] && kill -0 "$(cat $PID)" 2>/dev/null; then
    echo "[WARN] Already running (PID: $(cat $PID)). Run ./stop.sh first."
    exit 1
fi

echo "Starting Skynet Game Server..."
$SKYNET $CONF &
echo $! > "$PID"
echo "[OK] PID: $(cat $PID) — port 8888"
