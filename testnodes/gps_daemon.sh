#!/usr/bin/env bash
STATE_FILE="/dev/shm/gps_state.json"
TMP_FILE="/dev/shm/gps_raw.json.tmp"

# Kill only the actual gpspipe stream
pkill -f "gpspipe -w" 2>/dev/null

# Start streaming - Redirect stderr to /dev/null to keep logs clean
gpspipe -w | jq --unbuffered -c 'select(.class == "TPV")' 2>/dev/null > "$TMP_FILE" &

while true; do
    # Only move if the file is not empty and is valid JSON
    if [ -s "$TMP_FILE" ]; then
        mv "$TMP_FILE" "$STATE_FILE" 2>/dev/null
    fi
    sleep 0.05
done