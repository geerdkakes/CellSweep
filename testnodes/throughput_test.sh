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

HAS_NANOSECONDS=true
if ! date +%N | grep -E '^[0-9]+$' >/dev/null 2>&1; then
    HAS_NANOSECONDS=false
fi

IPERF_FLAGS="-J -t $DURATION -p $PORT"
[ "$DIRECTION" == "download" ] && IPERF_FLAGS="$IPERF_FLAGS -R"

echo "timestamp,lat,lon,direction,bitrate_bps"

while true; do
    # Timestamp at start of burst
    if [ "$HAS_NANOSECONDS" = true ]; then
        timestamp=$(($(date +%s%N)/1000000))
    else
        timestamp=$(($(date +%s)*1000))
    fi

    # GPS fix at start of burst
    lat_lon=$(timeout 0.5s gpspipe -w -n 10 2>/dev/null | grep TPV | grep -om1 "[-]\?[[:digit:]]\{1,3\}\.[[:digit:]]\+" | tr '\n' ',')
    [ -z "$lat_lon" ] && lat_lon=","

    # Run iperf3 burst
    result=$($IPERF_BIN -c "$SERVER" $IPERF_FLAGS 2>/dev/null)

    if [ $? -eq 0 ]; then
        if [ "$DIRECTION" == "download" ]; then
            bitrate=$(echo "$result" | jq '.end.sum_received.bits_per_second // 0')
        else
            bitrate=$(echo "$result" | jq '.end.sum_sent.bits_per_second // 0')
        fi
        # Append compact JSON with timestamp and direction added for correlation
        if [ -n "$JSON_LOG" ]; then
            echo "$result" | jq -c ". + {burst_timestamp: $timestamp, direction: \"$DIRECTION\"}" >> "$JSON_LOG"
        fi
    else
        bitrate=0
    fi

    echo "${timestamp},${lat_lon}${DIRECTION},${bitrate}"

    sleep "$INTERVAL"
done
