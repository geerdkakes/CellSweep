#!/usr/bin/env bash

# --- Configuration ---
MODEM_PORT=${MODEM_PORT:-/dev/ttyUSB2}
GPS_STATE="/dev/shm/gps_state.json"
ERROR_LOG="${LOG_FILE:-/tmp/signal_error_$(date +%s)}.err"

# Ensure log directory exists for error log
mkdir -p "$(dirname "$ERROR_LOG")"
exec 2>>"$ERROR_LOG"

log_err() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >&2; }

# Dependency check
if ! pgrep -f "gps_daemon.sh" > /dev/null; then
    log_err "Starting gps_daemon.sh..."
    $(dirname "$0")/gps_daemon.sh >/dev/null 2>&1 &
fi

get_ns_timestamp() {
    local t=$(date +%s%N 2>/dev/null)
    if [[ "$t" == *N* || -z "$t" ]]; then
        t=$(python3 -c 'import time; print(int(time.time() * 1e9))' 2>/dev/null)
    fi
    echo "$t"
}

# --- Robust JQ Logic ---
JQ_FILTER='
def parse_modem(lines):
  (lines | map(split(",") | map(gsub("\"|\\r"; "")))) as $rows |
  reduce $rows[] as $f ({};
    if $f[1] == "LTE" then 
        .lte = {mcc: $f[3], mnc: $f[4], cellid: $f[5], rsrp: ($f[12]|tonumber? // null), rsrq: ($f[13]|tonumber? // null), sinr: ($f[14]|tonumber? // null)}
    elif $f[1] == "NR5G-NSA" then 
        .nr5g = {mcc: $f[2], mnc: $f[3], rsrp: ($f[5]|tonumber? // null), sinr: ($f[7]|tonumber? // null), arfcn: ($f[8]|tonumber? // null)}
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

while true; do
    sys_ns=$(get_ns_timestamp)
    gps_data=$(cat "$GPS_STATE" 2>/dev/null)
    [[ ! "$gps_data" =~ ^\{.*\}$ ]] && gps_data='{"error":"no_gps_json"}'

    # Improved Modem Capture: Use a temporary variable to hold raw output
    # The "servingcell" command often returns multiple +QENG lines.
    raw_response=$(timeout 1.5s atinout - "$MODEM_PORT" - <<<'AT+QENG="servingcell"' 2>/dev/null | grep '+QENG:')
    
    if [ -z "$raw_response" ]; then
        m_json="[]"
        m_status="empty_or_timeout"
        log_err "Modem query failed or timed out."
    else
        # Convert to JSON array: each line becomes an entry in the array
        m_json=$(echo "$raw_response" | jq -R . | jq -s . 2>/dev/null)
        m_status="ok"
    fi

    # Output to stdout (captured by signal_apu3.json)
    jq -n -c \
       --arg sys_ns "$sys_ns" \
       --argjson gps "$gps_data" \
       --argjson m_raw "$m_json" \
       --arg m_status "$m_status" \
       "$JQ_FILTER"

    sleep 0.2
done