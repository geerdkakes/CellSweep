#!/usr/bin/env bash

# Initialize a keep_running flag
KEEP_RUNNING=1

# Signal handler: instead of exiting, just flip the flag
cleanup() {
    echo "Signal received. Finishing current record before exit..." >&2
    KEEP_RUNNING=0
}

# Trap SIGTERM (pkill) and SIGINT (Ctrl+C)
trap cleanup SIGTERM SIGINT

echo "Starting GPS Logger. JSON output on stdout. Status on stderr." >&2

# We use a subshell or direct pipe, but check the flag inside the loop
# Note: gpspipe -w | while read... creates a subshell, so we monitor the flag there
gpspipe -w | grep --line-buffered '"class":"TPV"' | while [ $KEEP_RUNNING -eq 1 ] && read -r line; do
    
    OS_MS=$(date +%s%3N)

    # Process the line. Because this is a single command string, 
    # it completes the write to stdout before the loop checks the flag again.
    echo "$line" | jq -c --argjson os_ts "$OS_MS" '. + {os_timestamp_ms: $os_ts}'

    # If cleanup was triggered during the jq execution, 
    # the 'while' condition will catch it on the next check.
done

echo "Logger stopped cleanly." >&2