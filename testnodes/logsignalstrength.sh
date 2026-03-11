#!/usr/bin/env bash

# --- Configuration ---
MODEM_PORT=${MODEM_PORT:-/dev/ttyUSB2}
GPS_STATE="/dev/shm/gps_state.json"
# We derive the error log name from the stdout log file if possible
# or default to a generic name
ERROR_LOG="${LOG_FILE:-/tmp/signal_error_$(date +%s)}.err"

# Function to write timestamped errors to stderr
log_err() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2
}

# --- Redirect all stderr for the rest of this script ---
exec 2>>"$ERROR_LOG"

# Check dependencies
if ! pgrep -f "gps_daemon.sh" > /dev/null; then
    log_err "WARNING: gps_daemon.sh not found. Attempting background start."
    $(dirname "$0")/gps_daemon.sh >/dev/null 2>&1 &
fi

get_ns_timestamp() {
    local t=$(date +%s%N 2>/dev/null)
    if [[ "$t" == *N* || -z "$t" ]]; then
        t=$(python3 -c 'import time; print(int(time.time() * 1e9))' 2>/dev/null) || \
        t=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1e9' 2>/dev/null)
    fi
    # Normalize to 19 digits
    if [ ${#t} -eq 10 ]; then echo "${t}000000000"
    elif [ ${#t} -eq 13 ]; then echo "${t}000000"
    else echo "$t"; fi
}

# --- Main Loop ---
while true; do
    sys_ns=$(get_ns_timestamp)
    
    # 1. Fetch GPS Snapshot
    gps_data=$(cat "$GPS_STATE" 2>/dev/null)
    if [[ ! "$gps_data" =~ ^\{.*\}$ ]]; then
        log_err "GPS_IO_ERR: State file empty or invalid JSON."
        gps_data='{"error":"no_valid_json"}'
    fi

    # 2. Query Modem with Timeout
    # If this hangs, the 'timeout' error will be logged via stderr
    modem_raw=$(timeout 1.5s atinout - "$MODEM_PORT" - <<<'AT+QENG="servingcell"' 2>/dev/null | grep '+QENG:')
    
    if [ $? -eq 124 ]; then
        locking_pid=$(fuser "$MODEM_PORT" 2>/dev/null | awk '{print $NF}')
        log_err "MODEM_TIMEOUT: $MODEM_PORT locked by PID ${locking_pid:-unknown}."
        m_json="[]"; m_status="timeout"
    elif [ -z "$modem_raw" ]; then
        log_err "MODEM_EMPTY: No +QENG response."
        m_json="[]"; m_status="empty"
    else
        m_json=$(echo "$modem_raw" | jq -R . | jq -s . 2>/dev/null)
        m_status="ok"
    fi

    # 3. Final JSON Construction
    # JQ errors here (like date parsing) will now flow into $ERROR_LOG
    jq -n -c \
       --arg sys_ns "$sys_ns" \
       --argjson gps "$gps_data" \
       --argjson m_raw "$m_json" \
       --arg m_status "$m_status" \
       '
       def parse_modem(lines):
         (lines | map(split(",") | map(gsub("\""; "")))) as $rows |
         reduce $rows[] as $f ({};
           if $f[2] == "LTE" then .lte = {tech: "LTE", mcc: $f[3], mnc: $f[4], rsrp: ($f[12]|tonumber? // null)}
           elif $f[1] == "NR5G-NSA" then .nr5g = {tech: "NR5G-NSA", mcc: $f[2], mnc: $f[3], rsrp: ($f[5]|tonumber? // null)}
           else . end
         );
       
       ($sys_ns | tonumber) as $now_ns |
       (if $gps.time then ($gps.time | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 * 1e9) else null end) as $gps_ns |

       {
         timestamp_ns: $now_ns,
         data_age_ms: (if $gps_ns then (($now_ns - $gps_ns) / 1e6 | floor) else null end),
         location: { lat: $gps.lat, lon: $gps.lon, speed: ($gps.speed // 0) },
         modem: parse_modem($m_raw),
         status: { modem: $m_status, gps: (if $gps.error then $gps.error else "ok" end) }
       }' 

    sleep 0.2
done