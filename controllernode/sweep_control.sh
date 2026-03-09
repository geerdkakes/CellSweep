#!/usr/bin/env bash

# --- Configuration Loading ---
CONFIG_FILE="$(dirname "$0")/config.env"
[ ! -f "$CONFIG_FILE" ] && { echo "Error: config.env not found."; exit 1; }
source "$CONFIG_FILE"

# Optional Session Configuration
SESSION_FILE="$(dirname "$0")/session.env"
if [ -f "$SESSION_FILE" ]; then
    source "$SESSION_FILE"
fi

# --- Internal Variables ---
REMOTE_SIGNAL_SCRIPT="${REMOTE_REPO_ROOT}/testnodes/logsignalstrength.sh"
REMOTE_THROUGHPUT_SCRIPT="${REMOTE_REPO_ROOT}/testnodes/throughput_test.sh"

# --- Helper Functions ---

get_node_name() { echo "${1%%|*}"; }
get_node_ip()   { local tmp="${1#*|}"; echo "${tmp%%|*}"; }
get_node_user() { echo "${1##*|}"; }

get_node_addr() {
    local entry=$1
    local name=$(get_node_name "$entry")
    local ip=$(get_node_ip "$entry")
    ping -c 1 -W 1 "$name" >/dev/null 2>&1 && echo "$name" || echo "$ip"
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

prepare_server() {
    echo "Preparing AWS server firewall for nodes..."
    if [ -z "$AWS_SECURITY_GROUP_ID" ]; then
        echo "Error: AWS_SECURITY_GROUP_ID not set in config.env."
        exit 1
    fi

    for entry in "${NODES[@]}"; do
        local name=$(get_node_name "$entry")
        local user=$(get_node_user "$entry")
        local addr=$(get_node_addr "$entry")
        
        echo "[$name] Fetching public IP..."
        local public_ip=$(ssh "${user}@${addr}" "curl -s https://ifconfig.me")
        
        if [[ $public_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "[$name] Public IP is $public_ip. Authorizing in AWS SG $AWS_SECURITY_GROUP_ID..."
            
            # Authorize TCP
            aws ec2 authorize-security-group-ingress \
                --group-id "$AWS_SECURITY_GROUP_ID" \
                --protocol tcp \
                --port "${IPERF_PORTS:-5201}" \
                --cidr "${public_ip}/32" \
                --region "$AWS_REGION" 2>/dev/null || echo "[$name] Port already authorized or AWS CLI error."
            
            # Authorize UDP (optional but good for iperf3)
            aws ec2 authorize-security-group-ingress \
                --group-id "$AWS_SECURITY_GROUP_ID" \
                --protocol udp \
                --port "${IPERF_PORTS:-5201}" \
                --cidr "${public_ip}/32" \
                --region "$AWS_REGION" 2>/dev/null
        else
            echo "[$name] Error: Could not fetch valid public IP ($public_ip)."
        fi
    done
}

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
        
        echo "[$name] Initializing at ${user}@${addr}..."
        ssh "${user}@${addr}" "mkdir -p \"$remote_dir\""
        
        # 1. Start Signal Strength Logging
        ssh "${user}@${addr}" "nohup $REMOTE_SIGNAL_SCRIPT > \"$remote_dir/signal_${name}.csv\" 2>&1 &"
        
        # 2. Start Throughput Testing if role is assigned
        if [ "$name" == "$DOWNLINK_NODE" ]; then
            echo "[$name] Starting DOWNLINK tests against $IPERF_SERVER..."
            ssh "${user}@${addr}" "nohup $REMOTE_THROUGHPUT_SCRIPT download $IPERF_SERVER $BURST_DURATION > \"$remote_dir/throughput_down_${name}.csv\" 2>&1 &"
        elif [ "$name" == "$UPLINK_NODE" ]; then
            echo "[$name] Starting UPLINK tests against $IPERF_SERVER..."
            ssh "${user}@${addr}" "nohup $REMOTE_THROUGHPUT_SCRIPT upload $IPERF_SERVER $BURST_DURATION > \"$remote_dir/throughput_up_${name}.csv\" 2>&1 &"
        fi
    done
    echo "$session_id" > "$(dirname "$0")/.current_session"
}

stop_logging() {
    for entry in "${NODES[@]}"; do
        local name=$(get_node_name "$entry")
        local user=$(get_node_user "$entry")
        local addr=$(get_node_addr "$entry")
        echo "[$name] Stopping all CellSweep processes..."
        ssh "${user}@${addr}" "pkill -f logsignalstrength.sh; pkill -f throughput_test.sh; pkill -f iperf3"
    done
}

check_status() {
    for entry in "${NODES[@]}"; do
        local name=$(get_node_name "$entry")
        local user=$(get_node_user "$entry")
        local addr=$(get_node_addr "$entry")
        local sig_pid=$(ssh "${user}@${addr}" "pgrep -f logsignalstrength.sh")
        local thr_pid=$(ssh "${user}@${addr}" "pgrep -f throughput_test.sh")
        printf "[%-10s] Signal: %-15s Throughput: %s\n" "$name" "${sig_pid:+RUNNING ($sig_pid)}${sig_pid:-STOPPED}" "${thr_pid:+RUNNING ($thr_pid)}${thr_pid:-STOPPED}"
    done
}

fetch_logs() {
    local target_session=$1
    local date_filter=$(date +%Y%m%d)

    if [ "$target_session" == "remaining" ] || [ -z "$target_session" ]; then
        for entry in "${NODES[@]}"; do
            local name=$(get_node_name "$entry")
            local user=$(get_node_user "$entry")
            local addr=$(get_node_addr "$entry")
            local remote_sessions=$(ssh "${user}@${addr}" "ls -1 $REMOTE_BASE_DATADIR 2>/dev/null | grep '^${date_filter}_'")
            for s_id in $remote_sessions; do
                local local_dir="${LOCAL_BASE_DATADIR}/${s_id}"
                mkdir -p "$local_dir"
                echo "[$name] Syncing session $s_id..."
                rsync -az "${user}@${addr}:${REMOTE_BASE_DATADIR}/${s_id}/" "$local_dir/"
            done
        done
    else
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
    echo "Usage: $0 {start|stop|status|fetch|prepare_server} [arg]"
    echo "  start [suffix]    - Start a new session"
    echo "  fetch [session]   - Download logs (use 'remaining' for all today's sessions)"
    echo "  prepare_server    - Update AWS firewall with current modem IPs"
    exit 1
}

case "$1" in
    start)  start_logging "$2" ;;
    stop)   stop_logging ;;
    status) check_status ;;
    fetch)  fetch_logs "$2" ;;
    prepare_server) prepare_server ;;
    *)      usage ;;
esac
