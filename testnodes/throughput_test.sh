#!/usr/bin/env bash

# Usage: ./throughput_test.sh <download|upload> <server> <duration> [port]

DIRECTION=$1
SERVER=$2
DURATION=${3:-10}
PORT=${4:-5201}

IPERF_BIN="/usr/local/iperf3/src/iperf3"

# Dependencies: iperf3, jq
if [ ! -x "$IPERF_BIN" ] && ! command -v iperf3 >/dev/null 2>&1; then
    echo "Error: iperf3 not found at $IPERF_BIN or in PATH." >&2
    exit 1
fi

# Use the specific binary if it exists, otherwise fallback to PATH
[ -x "$IPERF_BIN" ] || IPERF_BIN="iperf3"

IPERF_FLAGS="-J -t $DURATION -p $PORT"
[ "$DIRECTION" == "upload" ] && IPERF_FLAGS="$IPERF_FLAGS" # default is upload (sender to receiver)
[ "$DIRECTION" == "download" ] && IPERF_FLAGS="$IPERF_FLAGS -R" # reverse mode for download

echo "timestamp,direction,bitrate_bps"

while true; do
    # Time before test
    timestamp=$(($(date +%s%N)/1000000))
    
    # Run iperf3 and capture JSON
    result=$($IPERF_BIN -c "$SERVER" $IPERF_FLAGS 2>/dev/null)
    
    if [ $? -eq 0 ]; then
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
