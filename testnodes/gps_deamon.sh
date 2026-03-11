#!/usr/bin/env bash
STATE_FILE="/dev/shm/gps_state.json"
TMP_FILE="/dev/shm/gps_raw.json.tmp"

# Kill only the actual gpspipe stream, not this script
pkill -f "gpspipe -w" 2>/dev/null

# Start streaming
gpspipe -w | jq --unbuffered -c 'select(.class == "TPV")' > "$TMP_FILE" &

echo "GPS Daemon started."

while true; do
    if [ -f "$TMP_FILE" ]; then
        mv "$TMP_FILE" "$STATE_FILE" 2>/dev/null
    fi
    sleep 0.05
done