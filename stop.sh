#!/bin/bash
cd "$(dirname "$0")"
PID="skynet.pid"
if [ -f "$PID" ]; then
    kill "$(cat $PID)" 2>/dev/null && echo "Stopped." || echo "Not running."
    rm -f "$PID"
else
    pkill -f "skynet.*config.game" 2>/dev/null || echo "Not running."
fi
