#!/usr/bin/env bash

# Configure the port. Default to /dev/ttyUSB2 if not provided.
MODEM_PORT=${MODEM_PORT:-/dev/ttyUSB2}

# --- JQ Logic: Multi-Tech & Order Independent ---
JQ_FILTER='
def parse_modem(lines):
  (lines | map(split(",") | map(gsub("\"|\\r| "; "")))) as $rows |
  reduce $rows[] as $f ({};
    # Match the State/Servingcell row (Present in all modes)
    if ($f[0] | contains("servingcell")) then
        .state = $f[1] |
        # Logic for Single-Line Technologies (SA, Standalone LTE, WCDMA)
        if ($f[2] == "NR5G-SA") then
            .nr5g_sa = { mcc: $f[4], mnc: $f[5], pcid: $f[7], rsrp: ($f[11]|tonumber? // null), rsrq: ($f[12]|tonumber? // null), sinr: ($f[13]|tonumber? // null) }
        elif ($f[2] == "LTE") then
            .lte_standalone = { mcc: $f[4], mnc: $f[5], rsrp: ($f[12]|tonumber? // null), rsrq: ($f[13]|tonumber? // null), sinr: ($f[15]|tonumber? // null) }
        elif ($f[2] == "WCDMA") then
            .wcdma = { mcc: $f[3], mnc: $f[4], rscp: ($f[10]|tonumber? // null), ecio: ($f[11]|tonumber? // null) }
        else . end
    
    # Logic for Multi-Line Technology (NSA Anchor & NR Component)
    elif ($f[0] | contains("LTE")) then
        .lte_anchor = { mcc: $f[2], mnc: $f[3], rsrp: ($f[11]|tonumber? // null), rsrq: ($f[12]|tonumber? // null), sinr: ($f[14]|tonumber? // null) }
    elif ($f[0] | contains("NR5G-NSA")) then
        .nr5g_nsa = { mcc: $f[1], mnc: $f[2], pcid: $f[3], rsrp: ($f[4]|tonumber? // null), sinr: ($f[5]|tonumber? // null), rsrq: ($f[6]|tonumber? // null), arfcn: ($f[7]|tonumber? // null) }
    else . end
  );

($sys_ms | tonumber) as $now_ms |
{
  timestamp_ms: $now_ms,
  modem: parse_modem($m_raw),
  status: { modem: $m_status }
}'

# Main Loop
while true; do
    sys_ms=$(date +%s%3N)

    # 1. Query modem. socat -t1 ensures we wait for the full response. 
    # This also makes the response comes every second. No need for an explicit sleep.
    # We grep for lines starting with +QENG: to handle any echo/OK noise.
    m_raw_lines=$(echo 'AT+QENG="servingcell"' | sudo socat -t1 - "$MODEM_PORT",b115200,crnl 2>/dev/null | grep '^\+QENG:')
    
    if [ -z "$m_raw_lines" ]; then
        m_json="[]"
        m_status="timeout"
    else
        # Convert raw multiline string into a JSON array of strings
        m_json=$(echo "$m_raw_lines" | jq -R . | jq -s .)
        m_status="ok"
    fi

    # 2. Process and output the JSON. 
    # Use stdbuf to ensure output is flushed immediately for piping to files or logs.
    stdbuf -oL jq -n -c \
       --arg sys_ms "$sys_ms" \
       --argjson m_raw "$m_json" \
       --arg m_status "$m_status" \
       "$JQ_FILTER"

done