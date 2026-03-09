#!/usr/bin/env bash

# --- Configuration Loading ---
CONFIG_FILE="$(dirname "$0")/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found."
    exit 1
fi
source "$CONFIG_FILE"

# --- Internal Variables ---
# The script is in the testnodes/ subfolder of the repo root
REMOTE_SCRIPT="${REMOTE_REPO_ROOT}/testnodes/logsignalstrength.sh"

# --- Helper Functions ---

# node_entry format: "name|field_ip|user"
get_node_name() { echo "${1%%|*}"; }
get_node_ip()   { local tmp="${1#*|}"; echo "${tmp%%|*}"; }
get_node_user() { echo "${1##*|}"; }

get_node_addr() {
    local entry=$1
    local name=$(get_node_name "$entry")
    local ip=$(get_node_ip "$entry")
    
    if ping -c 1 -W 1 "$name" >/dev/null 2>&1; then
        echo "$name"
    else
        echo "$ip"
    fi
}

generate_session_id() {
    local date_str=$(date +%Y%m%d)
    local seq="01"
    
    if [ -d "$LOCAL_BASE_DATADIR" ]; then
        local last_session=$(ls -1 "$LOCAL_BASE_DATADIR" | grep "^${date_str}_" | sort | tail -n 1)
        if [ -n "$last_session" ]; then
            local last_seq=$(echo "$last_session" | cut -d'_' -f2 | cut -d'-' -f1)
            seq=$(printf "%02d" $((10#$last_seq + 1)))
        fi
    fi
    echo "${date_str}_${seq}"
}

# --- Actions ---

start_logging() {
    local suffix=$1
    local session_id=$(generate_session_id)
    [ -n "$suffix" ] && session_id="${session_id}-${suffix}"
    
    echo "Starting Session: $session_id"
    
    for entry in "${NODES[@]}"; do
        local name=$(get_node_name "$entry")
        local user=$(get_node_user "$entry")
        local addr=$(get_node_addr "$entry")
        local remote_dir="${REMOTE_BASE_DATADIR}/${session_id}"
        local log_file="${remote_dir}/sweep_${name}.csv"

        echo "[$name] Starting at ${user}@${addr}..."
        ssh "${user}@${addr}" "mkdir -p \"$remote_dir\" && nohup $REMOTE_SCRIPT > \"$log_file\" 2>&1 &"
    done
    echo "$session_id" > "$(dirname "$0")/.current_session"
}

stop_logging() {
    for entry in "${NODES[@]}"; do
        local name=$(get_node_name "$entry")
        local user=$(get_node_user "$entry")
        local addr=$(get_node_addr "$entry")
        echo "[$name] Stopping..."
        ssh "${user}@${addr}" "pkill -f logsignalstrength.sh"
    done
}

check_status() {
    for entry in "${NODES[@]}"; do
        local name=$(get_node_name "$entry")
        local user=$(get_node_user "$entry")
        local addr=$(get_node_addr "$entry")
        local pid=$(ssh "${user}@${addr}" "pgrep -f logsignalstrength.sh")
        printf "[%-10s] %s\n" "$name" "${pid:+RUNNING (PID: $pid)}${pid:-STOPPED}"
    done
}

fetch_logs() {
    local target_session=$1
    local date_filter=$(date +%Y%m%d)

    # If 'remaining' or no arg, we sync everything for today
    if [ "$target_session" == "remaining" ] || [ -z "$target_session" ]; then
        echo "Syncing all remaining logs for today ($date_filter)..."
        for entry in "${NODES[@]}"; do
            local name=$(get_node_name "$entry")
            local user=$(get_node_user "$entry")
            local addr=$(get_node_addr "$entry")
            
            # List remote sessions for today
            local remote_sessions=$(ssh "${user}@${addr}" "ls -1 $REMOTE_BASE_DATADIR 2>/dev/null | grep '^${date_filter}_'")
            
            for s_id in $remote_sessions; do
                local local_dir="${LOCAL_BASE_DATADIR}/${s_id}"
                mkdir -p "$local_dir"
                echo "[$name] Fetching session $s_id..."
                # Use rsync if available for efficiency, fallback to scp
                if command -v rsync >/dev/null; then
                    rsync -az "${user}@${addr}:${REMOTE_BASE_DATADIR}/${s_id}/" "$local_dir/"
                else
                    scp -r "${user}@${addr}:${REMOTE_BASE_DATADIR}/${s_id}/*" "$local_dir/" 2>/dev/null
                fi
            done
        done
    else
        # Fetch specific session
        for entry in "${NODES[@]}"; do
            local name=$(get_node_name "$entry")
            local user=$(get_node_user "$entry")
            local addr=$(get_node_addr "$entry")
            local local_dir="${LOCAL_BASE_DATADIR}/${target_session}"
            mkdir -p "$local_dir"
            echo "[$name] Fetching $target_session..."
            scp -r "${user}@${addr}:${REMOTE_BASE_DATADIR}/${target_session}/*" "$local_dir/" 2>/dev/null
        done
    fi
}

usage() {
    echo "Usage: $0 {start|stop|status|fetch} [arg]"
    echo "  start [suffix]    - Start a new session"
    echo "  fetch [session]   - Download logs (use 'remaining' for all today's sessions)"
    exit 1
}

case "$1" in
    start)  start_logging "$2" ;;
    stop)   stop_logging ;;
    status) check_status ;;
    fetch)  fetch_logs "$2" ;;
    *)      usage ;;
esac
