#!/usr/bin/env bash

MODEM_PORT=${MODEM_PORT:-/dev/ttyUSB2}
GPS_STATE="/dev/shm/gps_state.json"

# Start daemon if missing (quietly)
if ! pgrep -f "gps_daemon.sh" > /dev/null; then
    $(dirname "$0")/gps_daemon.sh >/dev/null 2>&1 &
    sleep 1
fi

get_ns_timestamp() {
    local t=$(date +%s%N 2>/dev/null)
    if [[ "$t" == *N* || -z "$t" ]]; then
        t=$(python3 -c 'import time; print(int(time.time() * 1e9))' 2>/dev/null) || \
        t=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1e9' 2>/dev/null)
    fi
    # Normalize/Pad to 19 digits
    if [ ${#t} -eq 10 ]; then echo "${t}000000000"
    elif [ ${#t} -eq 13 ]; then echo "${t}000000"
    else echo "$t"; fi
}

# --- JQ Logic (Optimized for Stability) ---
JQ_FILTER='
def parse_modem(lines):
  (lines | map(split(",") | map(gsub("\""; "")))) as $rows |
  reduce $rows[] as $f ({};
    if $f[2] == "LTE" then .lte = {tech: "LTE", mcc: $f[3], mnc: $f[4], cellid: $f[5], pcid: $f[6], rsrp: ($f[12]|tonumber? // null), rsrq: ($f[13]|tonumber? // null), sinr: ($f[14]|tonumber? // null)}
    elif $f[1] == "NR5G-NSA" then .nr5g = {tech: "NR5G-NSA", mcc: $f[2], mnc: $f[3], pcid: $f[4], rsrp: ($f[5]|tonumber? // null), sinr: ($f[7]|tonumber? // null), arfcn: ($f[8]|tonumber? // null)}
    else . end
  );

($sys_ns | tonumber) as $now_ns |
(if $gps.time then ($gps.time | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 * 1e9) else null end) as $gps_ns |

{
  timestamp_ns: $now_ns,
  data_age_ms: (if $gps_ns then (($now_ns - $gps_ns) / 1e6 | floor) else null end),
  location: {
    lat: ($gps.lat // null),
    lon: ($gps.lon // null),
    alt: ($gps.alt // null),
    speed_kmh: (if $gps.speed then ($gps.speed * 3.6) else 0 end),
    accuracy: { h_err: ($gps.epx // null), v_err: ($gps.epv // null) }
  },
  modem: parse_modem($m_raw),
  raw_modem: $m_raw
}'

while true; do
    sys_ns=$(get_ns_timestamp)
    
    # Read GPS state and ensure it is valid JSON before passing to jq
    gps_data=$(cat "$GPS_STATE" 2>/dev/null)
    [[ ! "$gps_data" =~ ^\{.*\}$ ]] && gps_data='{"error":"waiting_for_fix"}'

    # Query Modem
    modem_raw=$(echo 'AT+QENG="servingcell"' | atinout - "$MODEM_PORT" - 2>/dev/null | grep '+QENG:' | jq -R . | jq -s .)
    [ -z "$modem_raw" ] && modem_raw="[]"

    # Execute JQ - Discard stderr to prevent the "invalid JSON text" errors from entering the log
    jq -n -c \
       --arg sys_ns "$sys_ns" \
       --argjson gps "$gps_data" \
       --argjson m_raw "$modem_raw" \
       "$JQ_FILTER" 2>/dev/null

    sleep 0.3
done