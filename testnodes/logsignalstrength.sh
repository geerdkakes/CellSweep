#!/usr/bin/env bash

MODEM_PORT=${MODEM_PORT:-/dev/ttyUSB2}
GPS_STATE="/dev/shm/gps_state.json"
# If LOG_FILE isn't set by sweep_control, default to temp
ERR_LOG="${LOG_FILE%.*}.err"
[ -z "$LOG_FILE" ] && ERR_LOG="/tmp/signal_err.log"

exec 2>>"$ERR_LOG"

# Set serial port to non-blocking mode to prevent atinout hangs
stty -F "$MODEM_PORT" -echo -icanon min 0 time 10 2>/dev/null

get_ns_timestamp() {
    date +%s%N 2>/dev/null | grep -v "N" || python3 -c 'import time; print(int(time.time() * 1e9))'
}

# --- Fixed JQ Logic for your specific +QENG output ---
JQ_FILTER='
def parse_modem(lines):
  (lines | map(split(",") | map(gsub("\"|\\r"; "")))) as $rows |
  reduce $rows[] as $f ({};
    if $f[1] == "LTE" then 
        .lte = {mcc: $f[3], mnc: $f[4], rsrp: ($f[12]|tonumber? // null), rsrq: ($f[13]|tonumber? // null), sinr: ($f[14]|tonumber? // null)}
    elif $f[0] == "+QENG: NR5G-NSA" or $f[1] == "NR5G-NSA" then 
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

    # Query Modem with a local log to avoid subshell pipe clogs
    m_raw_lines=$(timeout 1.2s atinout - "$MODEM_PORT" - <<<'AT+QENG="servingcell"' 2>/dev/null | grep '+QENG:')
    
    if [ -z "$m_raw_lines" ]; then
        m_json="[]"; m_status="timeout"
    else
        m_json=$(echo "$m_raw_lines" | jq -R . | jq -s .)
        m_status="ok"
    fi

    # Force immediate output flush
    stdbuf -oL jq -n -c \
       --arg sys_ns "$sys_ns" \
       --argjson gps "$gps_data" \
       --argjson m_raw "$m_json" \
       --arg m_status "$m_status" \
       "$JQ_FILTER"

    sleep 0.2
done