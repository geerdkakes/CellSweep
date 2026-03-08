#!/usr/bin/env bash

# --- Configuration ---
# Define nodes. If you are at home, use the hostname. 
# If in the field, the script will try to reach them by IP.
NODES=("apu3lte" "apu3")

declare -A FIELD_IPS
FIELD_IPS["apu3lte"]="192.168.3.2"
FIELD_IPS["apu3"]="192.168.3.3"

REMOTE_SCRIPT_PATH="/tmp/logsignalstrength.sh"
REMOTE_LOG_DIR="/tmp/cell_sweep_logs"

# --- Helper Functions ---

get_node_addr() {
    local name=$1
    # Try pinging the name first (Home mode)
    if ping -c 1 -W 1 "$name" >/dev/null 2>&1; then
        echo "$name"
    else
        # Fallback to Field IP
        echo "${FIELD_IPS[$name]}"
    fi
}

usage() {
    echo "Usage: $0 {start|stop|status|fetch|deploy} [node_name]"
    echo "Nodes: ${NODES[*]} (or 'all')"
    exit 1
}

run_on_node() {
    local node=$1
    local cmd=$2
    local addr=$(get_node_addr "$node")

    if [ -z "$addr" ]; then
        echo "[$node] Error: Could not resolve address."
        return 1
    fi

    echo "[$node] Executing at $addr..."
    ssh -o ConnectTimeout=2 "$addr" "$cmd"
}

# --- Actions ---

deploy() {
    local node=$1
    local addr=$(get_node_addr "$node")
    echo "[$node] Deploying latest script to $addr..."
    scp -o ConnectTimeout=2 "testnodes/logsignalstrength.sh" "$addr:$REMOTE_SCRIPT_PATH"
    ssh "$addr" "chmod +x $REMOTE_SCRIPT_PATH && mkdir -p $REMOTE_LOG_DIR"
}

start_logging() {
    local node=$1
    local addr=$(get_node_addr "$node")
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="$REMOTE_LOG_DIR/sweep_${node}_${timestamp}.csv"

    # 1. Deploy first to ensure consistency
    deploy "$node"

    echo "[$node] Starting background logging to $log_file..."
    # We use nohup and redirect to a file. 
    # The 'disown' equivalent in a remote shell is ensuring the process is detached.
    ssh "$addr" "nohup $REMOTE_SCRIPT_PATH > $log_file 2>&1 &"
}

stop_logging() {
    local node=$1
    echo "[$node] Stopping logging process..."
    run_on_node "$node" "pkill -f logsignalstrength.sh"
}

check_status() {
    local node=$1
    local addr=$(get_node_addr "$node")
    local pid=$(ssh "$addr" "pgrep -f logsignalstrength.sh")
    if [ -n "$pid" ]; then
        echo "[$node] RUNNING (PID: $pid)"
    else
        echo "[$node] STOPPED"
    fi
}

fetch_logs() {
    local node=$1
    local addr=$(get_node_addr "$node")
    local local_dir="logs/${node}"
    mkdir -p "$local_dir"
    echo "[$node] Fetching logs from $addr..."
    scp "$addr:$REMOTE_LOG_DIR/*.csv" "$local_dir/" 2>/dev/null || echo "[$node] No logs found."
}

# --- Command Routing ---

COMMAND=$1
TARGET_NODE=$2

if [ -z "$COMMAND" ]; then usage; fi

# Determine which nodes to target
if [ -z "$TARGET_NODE" ] || [ "$TARGET_NODE" == "all" ]; then
    TARGETS=("${NODES[@]}")
else
    TARGETS=("$TARGET_NODE")
fi

for node in "${TARGETS[@]}"; do
    case "$COMMAND" in
        deploy) deploy "$node" ;;
        start)  start_logging "$node" ;;
        stop)   stop_logging "$node" ;;
        status) check_status "$node" ;;
        fetch)  fetch_logs "$node" ;;
        *)      usage ;;
    esac
done
