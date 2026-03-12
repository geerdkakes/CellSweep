#!/usr/bin/env bash

# Usage: ./throughput_test.sh <download|upload> <server> <duration> [port] [interval] [json_log]

DIRECTION=$1
SERVER=$2
DURATION=${3:-10}
PORT=${4:-5201}
INTERVAL=${5:-1}
JSON_LOG=${6:-}

IPERF_BIN="/usr/local/iperf3/src/iperf3"

# Dependencies: iperf3, jq, gpspipe
if [ ! -x "$IPERF_BIN" ] && ! command -v iperf3 >/dev/null 2>&1; then
    echo "Error: iperf3 not found at $IPERF_BIN or in PATH." >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is not installed." >&2
    exit 1
fi
if ! command -v gpspipe >/dev/null 2>&1; then
    echo "Error: gpspipe is not installed." >&2
    exit 1
fi

# Use the specific binary if it exists, otherwise fallback to PATH
[ -x "$IPERF_BIN" ] || IPERF_BIN="iperf3"


IPERF_FLAGS="-J -t $DURATION -p $PORT"
[ "$DIRECTION" == "download" ] && IPERF_FLAGS="$IPERF_FLAGS -R"

echo "timestamp,direction,bitrate_bps,bitrate_mbps"

while true; do
    # Timestamp at start of burst
    sys_ms=$(date +%s%3N)


    # Run iperf3 burst, redirect errors to stderr for visibility, and capture JSON output
    result=$($IPERF_BIN -c "$SERVER" $IPERF_FLAGS 2> >(cat >&2))

    if [ $? -eq 0 ]; then
        if [ "$DIRECTION" == "download" ]; then
            bitrate=$(echo "$result" | jq '.end.sum_received.bits_per_second // 0'  2> >(cat >&2))
        else
            bitrate=$(echo "$result" | jq '.end.sum_sent.bits_per_second // 0'  2> >(cat >&2))
        fi

        # Calculate Mbps (bitrate / 1,000,000)
        mbps=$(echo "$bitrate" | jq '. / 1000000')

        # Append compact JSON with timestamp and direction added for correlation
        if [ -n "$JSON_LOG" ]; then
            echo "$result" | jq -c ". + {burst_timestamp: $sys_ms, direction: \"$DIRECTION\"}" >> "$JSON_LOG"
        fi
    else
        bitrate=0
        mbps=0
    fi

    echo "${sys_ms},${DIRECTION},${bitrate},${mbps}"

    sleep "$INTERVAL"
done
