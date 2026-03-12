#!/usr/bin/env bash

KEEP_RUNNING=1
cleanup() { 
    echo -e "\nStopping safely..." >&2
    KEEP_RUNNING=0
}
trap cleanup SIGTERM SIGINT

echo "Starting Lean GPS Logger. (Adding Track/Heading)" >&2

gpspipe -w | grep --line-buffered -E '"class":"(TPV|SKY)"' | while [ $KEEP_RUNNING -eq 1 ] && read -r line; do
    
    OS_MS=$(date +%s%3N)

    echo "$line" | jq -c --unbuffered --argjson ts "$OS_MS" '
      {
        os_timestamp_ms: $ts,
        class: .class,
        device: .device,
        # TPV Fields
        fix_status: (if .class == "TPV" then (if .mode == 3 then "3D" elif .mode == 2 then "2D" else "No Fix" end) else null end),
        lat: (.lat // null),
        lon: (.lon // null),
        alt: (.alt // null),
        speed: (.speed // null),
        track: (.track // null),
        # SKY Fields
        sats_used: (if .class == "SKY" then [.satellites[]? | select(.used == true)] | length else null end),
        sats_visible: (if .class == "SKY" then [.satellites[]?] | length else null end),
        hdop: (.hdop // null),
        vdop: (.vdop // null)
      } 
      | with_entries(select(.value != null))
    '
done