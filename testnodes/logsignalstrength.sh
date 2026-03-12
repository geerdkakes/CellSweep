#!/usr/bin/env bash

MODEM_PORT=${MODEM_PORT:-/dev/ttyUSB2}

# --- Full Telemetry JQ Logic ---
JQ_FILTER='
def map_lte_bw(bw):
  ["1.4 MHz", "3 MHz", "5 MHz", "10 MHz", "15 MHz", "20 MHz"][bw|tonumber?] // "Unknown";

def map_nr_bw(bw):
  ["5 MHz", "10 MHz", "15 MHz", "20 MHz", "25 MHz", "30 MHz", "40 MHz", "50 MHz", "60 MHz", "70 MHz", "80 MHz", "90 MHz", "100 MHz", "200 MHz", "400 MHz"][bw|tonumber?] // "Unknown";

def map_scs(s):
  ["15 kHz", "30 kHz", "60 kHz", "120 kHz", "240 kHz"][s|tonumber?] // "Unknown";

def parse_modem(lines):
  (lines | map(split(",") | map(gsub("\"|\\r| "; "")))) as $rows |
  reduce $rows[] as $f ({};
    # --- SA MODE / SERVING CELL HEADER ---
    if ($f[0] | contains("servingcell")) then
        .state = $f[1] |
        if ($f[2] == "NR5G-SA") then
            .nr5g_sa = {
                duplex: $f[3], mcc: $f[4], mnc: $f[5], cellid: $f[6], pcid: $f[7], tac: $f[8], 
                arfcn: $f[9], band: ("n"+$f[10]), dl_bw: map_nr_bw($f[11]),
                rsrp: ($f[12]|tonumber? // null), rsrq: ($f[13]|tonumber? // null), 
                sinr: ($f[14]|tonumber? // null), scs: map_scs($f[15]), srxlev: ($f[16]|tonumber? // null)
            }
        elif ($f[2] == "LTE") then
            .lte_standalone = {
                is_tdd: $f[3], mcc: $f[4], mnc: $f[5], cellid: $f[6], pcid: $f[7], earfcn: $f[8], 
                band: ("B"+$f[9]), ul_bw: map_lte_bw($f[10]), dl_bw: map_lte_bw($f[11]), tac: $f[12],
                rsrp: ($f[13]|tonumber? // null), rsrq: ($f[14]|tonumber? // null), rssi: ($f[15]|tonumber? // null), 
                sinr: ($f[16]|tonumber? // null), cqi: ($f[17]|tonumber? // null), tx_power: ($f[18]|tonumber? // null), srxlev: ($f[19]|tonumber? // null)
            }
        elif ($f[2] == "WCDMA") then
            .wcdma = {
                mcc: $f[3], mnc: $f[4], lac: $f[5], cellid: $f[6], uarfcn: $f[7], psc: $f[8], rac: $f[9],
                rscp: ($f[10]|tonumber? // null), ecio: ($f[11]|tonumber? // null), phych: $f[12], sf: $f[13], 
                slot: $f[14], speech_code: $f[15], commod: $f[16]
            }
        else . end
    
    # --- EN-DC / NSA COMPONENT LINES ---
    elif ($f[0] | contains("LTE")) then
        .lte_anchor = {
            is_tdd: $f[1], mcc: $f[2], mnc: $f[3], cellid: $f[4], pcid: $f[5], earfcn: $f[6], 
            band: ("B"+$f[7]), ul_bw: map_lte_bw($f[8]), dl_bw: map_lte_bw($f[9]), tac: $f[10],
            rsrp: ($f[11]|tonumber? // null), rsrq: ($f[12]|tonumber? // null), rssi: ($f[13]|tonumber? // null), 
            sinr: ($f[14]|tonumber? // null), cqi: ($f[15]|tonumber? // null), tx_power: ($f[16]|tonumber? // null), srxlev: ($f[17]|tonumber? // null)
        }
    elif ($f[0] | contains("NR5G-NSA")) then
        .nr5g_nsa = {
            mcc: $f[1], mnc: $f[2], pcid: $f[3], rsrp: ($f[4]|tonumber? // null), 
            sinr: ($f[5]|tonumber? // null), rsrq: ($f[6]|tonumber? // null), arfcn: $f[7], 
            band: ("n"+$f[8]), dl_bw: map_nr_bw($f[9]), scs: map_scs($f[10])
        }
    else . end
  );

($sys_ms | tonumber) as $now_ms |
{
  timestamp_ms: $now_ms,
  modem: parse_modem($m_raw),
  raw_output: $m_raw_string,
  status: { modem: $m_status }
}'

while true; do
    sys_ms=$(date +%s%3N)
    m_full_output=$(echo 'AT+QENG="servingcell"' | sudo socat -t1 - "$MODEM_PORT",b115200,crnl 2>/dev/null)
    m_raw_lines=$(echo "$m_full_output" | grep '^\+QENG:')
    
    if [ -z "$m_raw_lines" ]; then
        m_json="[]"; m_status="timeout"
    else
        m_json=$(echo "$m_raw_lines" | jq -R . | jq -s .)
        m_status="ok"
    fi

    jq -n -c \
       --arg sys_ms "$sys_ms" \
       --argjson m_raw "$m_json" \
       --arg m_raw_string "$m_full_output" \
       --arg m_status "$m_status" \
       "$JQ_FILTER"

    sleep 0.2
done