#!/usr/bin/env bash

# --- Environment Checks ---

# 1. Bash Version Check (3.2+ required for read -d heredoc pattern)
if [ "${BASH_VERSINFO:-0}" -lt 3 ] || ([ "${BASH_VERSINFO:-0}" -eq 3 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]); then
    echo "Error: Bash 3.2 or higher is required." >&2
    exit 1
fi

# 2. Dependency Check
REQUIRED_TOOLS=("awk" "atinout" "gpspipe" "grep" "date")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: Required tool '$tool' is not installed." >&2
        exit 1
    fi
done

# 3. GNU Date Check (for %N nanoseconds used in timestamp)
HAS_NANOSECONDS=true
if ! date +%N | grep -E '^[0-9]+$' >/dev/null; then
    HAS_NANOSECONDS=false
fi

# --- Configuration ---

# Default modem port
MODEM_PORT=${1:-/dev/ttyUSB2}

# Define the AWK processor logic separately for readability
# This maps different technology outputs to a common CSV format:
# timestamp,lat,lon,cell_type,state,technology,duplex_mode,mcc,mnc,cellid,pcid,tac,arfcn,band,ns_dl_bw,rsrp,rsrq,sinr,scs,srxlev
read -r -d '' PARSE_MODEM_DATA << 'EOF'
BEGIN { FS=","; OFS="," }

function handle_sa(ts, gps, raw) {
    print ts, gps raw
}

function handle_lte(ts, gps, f) {
    # Header mapping for LTE:
    # duplex=f[4], mcc=f[5], mnc=f[6], cellid=f[7], pcid=f[8]
    # tac=f[13], arfcn=f[9], band=f[10], dl_bw=f[12]
    # rsrp=f[14], rsrq=f[15], sinr=f[17], scs="", srxlev=f[20]
    print ts, gps f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[13], f[9], f[10], f[12], f[14], f[15], f[17], "", f[20]
}

function handle_nsa(ts, gps, f) {
    # Header mapping for NSA component line:
    # tech=f[1], mcc=f[2], mnc=f[3], pcid=f[4], rsrp=f[5], sinr=f[6], rsrq=f[7], arfcn=f[8], band=f[9], bw=f[10], scs=f[11]
    print ts, gps "\"servingcell\"", "\"NSA\"", f[1], "", f[2], f[3], "", f[4], "", f[8], f[9], f[10], f[5], f[7], f[6], f[11], ""
}

{
    # Clean the command prefix
    gsub(/^\+QENG: /, "", $0)
    split($0, f, ",")
    
    # Extract technology and type for routing
    tech = f[3]; type = f[1]
    gsub(/"/, "", tech); gsub(/"/, "", type)

    if (tech == "NR5G-SA") handle_sa(ts, gps, $0)
    else if (tech == "LTE") handle_lte(ts, gps, f)
    else if (type == "NR5G-NSA") handle_nsa(ts, gps, f)
}
EOF

# --- Main Loop ---

echo "timestamp,lat,lon,cell_type,state,technology,duplex_mode,mcc,mnc,cellid,pcid,tac,arfcn,band,ns_dl_bw,rsrp,rsrq,sinr,scs,srxlev"

while true; do
  # calculate timestamp
  if [ "$HAS_NANOSECONDS" = true ]; then
      timestamp=$(($(date +%s%N)/1000000))
  else
      timestamp=$(($(date +%s)*1000))
  fi
  
  # lat lon position from gps
  lat_lon=$(gpspipe -w -n 8 2>/dev/null | grep TPV | grep -om1 "[-]\?[[:digit:]]\{1,3\}\.[[:digit:]]\+" | tr '\n' ',')
  
  # maintain CSV column alignment if GPS is unavailable
  if [ -z "$lat_lon" ]; then
      lat_lon=","
  fi

  # query modem
  modem_output=$(echo 'AT+QENG="servingcell"' | atinout - "$MODEM_PORT" - 2>/dev/null | grep '+QENG:')
  
  if [ -n "$modem_output" ]; then
      echo "$modem_output" | awk -v ts="$timestamp" -v gps="$lat_lon" "$PARSE_MODEM_DATA"
  fi

  sleep 0.1
done
