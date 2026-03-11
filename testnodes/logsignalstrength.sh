#!/usr/bin/env bash

# --- Configuration ---
MODEM_PORT=${MODEM_PORT:-/dev/ttyUSB2}
GPS_STATE="/dev/shm/gps_state.json"

# Ensure gps_daemon is running
if ! pgrep -f "gps_daemon.sh" > /dev/null; then
    $(dirname "$0")/gps_daemon.sh &
    sleep 1
fi

get_ns_timestamp() {
    local t=$(date +%s%N 2>/dev/null)
    if [[ "$t" == *N* || -z "$t" ]]; then
        t=$(python3 -c 'import time; print(int(time.time() * 1e9))' 2>/dev/null) || \
        t=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1e9' 2>/dev/null)
    fi
    if [ ${#t} -eq 10 ]; then echo "${t}000000000"
    elif [ ${#t} -eq 13 ]; then echo "${t}000000"
    else echo "$t"; fi
}

# --- JQ Logic (v1.5 Compatible) ---
JQ_FILTER='
def parse_modem(lines):
  (lines | map(split(",") | map(gsub("\""; "")))) as $rows |
  reduce $rows[] as $f ({};
    if $f[2] == "LTE" then .lte = {tech: "LTE", mcc: $f[3], mnc: $f[4], cellid: $f[5], pcid: $f[6], rsrp: ($f[12]|tonumber), rsrq: ($f[13]|tonumber), sinr: ($f[14]|tonumber)}
    elif $f[1] == "NR5G-NSA" then .nr5g = {tech: "NR5G-NSA", mcc: $f[2], mnc: $f[3], pcid: $f[4], rsrp: ($f[5]|tonumber), sinr: ($f[7]|tonumber), arfcn: ($f[8]|tonumber)}
    else . end
  );

($sys_ns | tonumber) as $now_ns |
# Handle possible missing GPS time gracefully
(if $gps.time then ($gps.time | fromdateiso8601 * 1e9) else null end) as $gps_ns |

{
  timestamp_ns: $now_ns,
  # Replaced "round" with "floor" for jq 1.5 compatibility
  data_age_ms: (if $gps_ns then (($now_ns - $gps_ns) / 1e6 | floor) else null end),
  location: {
    lat: $gps.lat,
    lon: $gps.lon,
    alt: $gps.alt,
    speed_kmh: (if $gps.speed then ($gps.speed * 3.6) else 0 end),
    accuracy: { h_err: $gps.epx, v_err: $gps.epv, t_err: $gps.ept }
  },
  modem: parse_modem($m_raw),
  raw_modem: $m_raw
}'

while true; do
    sys_ns=$(get_ns_timestamp)
    gps_data=$(cat "$GPS_STATE" 2>/dev/null || echo '{"error":"no_gps_lock"}')
    modem_raw=$(echo 'AT+QENG="servingcell"' | atinout - "$MODEM_PORT" - 2>/dev/null | grep '+QENG:' | jq -R . | jq -s .)

    jq -n -c \
       --arg sys_ns "$sys_ns" \
       --argjson gps "$gps_data" \
       --argjson m_raw "$modem_raw" \
       "$JQ_FILTER"

    sleep 0.2
done