#!/usr/bin/env bash

# Usage: ./throughput_test.sh <download|upload> <server> <duration>

DIRECTION=$1
SERVER=$2
DURATION=${3:-10}

# Dependencies: iperf3, jq
if ! command -v iperf3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "Error: iperf3 and jq are required." >&2
    exit 1
fi

IPERF_FLAGS="-J -t $DURATION"
[ "$DIRECTION" == "upload" ] && IPERF_FLAGS="$IPERF_FLAGS" # default is upload (sender to receiver)
[ "$DIRECTION" == "download" ] && IPERF_FLAGS="$IPERF_FLAGS -R" # reverse mode for download

echo "timestamp,direction,bitrate_bps"

while true; do
    # Time before test
    timestamp=$(($(date +%s%N)/1000000))
    
    # Run iperf3 and capture JSON
    result=$(iperf3 -c "$SERVER" $IPERF_FLAGS 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        # Extract bits per second from the 'end' summary
        # If download, we want 'receiver' stats; if upload, we want 'sender' or 'receiver' from server.
        # iperf3 -J output format varies slightly between -R and normal.
        if [ "$DIRECTION" == "download" ]; then
            bitrate=$(echo "$result" | jq '.end.sum_received.bits_per_second')
        else
            bitrate=$(echo "$result" | jq '.end.sum_sent.bits_per_second')
        fi
        
        echo "${timestamp},${DIRECTION},${bitrate}"
    else
        echo "${timestamp},${DIRECTION},0"
    fi
    
    sleep 1
done
