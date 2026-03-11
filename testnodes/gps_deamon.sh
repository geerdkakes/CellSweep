#!/usr/bin/env bash
# Shared memory path for atomic updates
STATE_FILE="/dev/shm/gps_state.json"
TMP_FILE="/dev/shm/gps_raw.json.tmp"

# Kill existing instances
pkill -f "gpspipe -w" 2>/dev/null

# Background: Continuous GPS pipe to a temp file
# We grab TPV (Time-Pos-Vel) objects
gpspipe -w | jq --unbuffered -c 'select(.class == "TPV")' > "$TMP_FILE" &

while true; do
    # Atomic move ensures the main script never reads a partial JSON
    [ -f "$TMP_FILE" ] && mv "$TMP_FILE" "$STATE_FILE" 2>/dev/null
    sleep 0.05
done