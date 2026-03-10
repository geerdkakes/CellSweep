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

# Parse Ports
# Default to 5201 if not set. If "5201,5202", split them.
PORT_DOWN=$(echo "${IPERF_PORTS:-5201}" | cut -d',' -f1)
PORT_UP=$(echo "${IPERF_PORTS:-5201}" | cut -d',' -f2)
# If only one port provided, both use the same
[ -z "$PORT_UP" ] && PORT_UP=$PORT_DOWN

# --- Helper Functions ---

run_cmd() {
    local node_user=$1
    local addr=$2
    local cmd=$3
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] ssh ${node_user}@${addr} '$cmd'" >&2
    else
        ssh "${node_user}@${addr}" "$cmd"
    fi
}

# Fire-and-forget: runs cmd in a background subshell whose stdin/stdout/stderr
# are redirected away from the SSH pipe before the subshell starts. This means
# sshd sees zero pipe references when the SSH shell exits and returns promptly.
# Inner redirections inside $cmd (e.g. >/log 2>&1 </dev/null) still apply
# correctly to the nohup'd process and override the outer /dev/null for it.
run_bg_cmd() {
    local node_user=$1
    local addr=$2
    local cmd=$3
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] ssh -n ${node_user}@${addr} '{ $cmd; } </dev/null &>/dev/null &'" >&2
    else
        ssh -n "${node_user}@${addr}" "{ $cmd; } </dev/null &>/dev/null &"
    fi
}

get_node_name() { echo "${1%%|*}"; }
get_node_ip()   { local tmp="${1#*|}"; echo "${tmp%%|*}"; }
get_node_user() { echo "${1##*|}"; }

get_node_addr() {
    local entry=$1
    local name=$(get_node_name "$entry")
    local ip=$(get_node_ip "$entry")
    if [ "$DRY_RUN" = "true" ]; then echo "$name"; return; fi
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

    # Unique ports to authorize
    local unique_ports=$(echo "$PORT_DOWN $PORT_UP" | tr ' ' '\n' | sort -u)

    for entry in "${NODES[@]}"; do
        local name=$(get_node_name "$entry")
        local user=$(get_node_user "$entry")
        local addr=$(get_node_addr "$entry")
        
        echo "[$name] Fetching public IP..."
        local public_ip=$(run_cmd "$user" "$addr" "curl -s https://ifconfig.me")
        [ "$DRY_RUN" = "true" ] && public_ip="1.2.3.4"
        
        if [[ $public_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            for p in $unique_ports; do
                echo "[$name] Authorizing port $p for $public_ip in AWS SG $AWS_SECURITY_GROUP_ID..."
                local cmd_tcp="aws ec2 authorize-security-group-ingress --group-id \"$AWS_SECURITY_GROUP_ID\" --protocol tcp --port \"$p\" --cidr \"${public_ip}/32\" --region \"$AWS_REGION\""
                local cmd_udp="aws ec2 authorize-security-group-ingress --group-id \"$AWS_SECURITY_GROUP_ID\" --protocol udp --port \"$p\" --cidr \"${public_ip}/32\" --region \"$AWS_REGION\""

                if [ "$DRY_RUN" = "true" ]; then
                    echo "[DRY-RUN] $cmd_tcp"
                    echo "[DRY-RUN] $cmd_udp"
                else
                    eval "$cmd_tcp" 2>/dev/null || echo "[$name] Port $p TCP already authorized or error."
                    eval "$cmd_udp" 2>/dev/null || echo "[$name] Port $p UDP already authorized or error."
                fi
            done
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
        local remote_dir=${REMOTE_BASE_DATADIR}/${session_id}
        local log_file=${remote_dir}/sweep_${name}.csv

        echo "[$name] Starting at ${user}@${addr}..."
        run_bg_cmd "$user" "$addr" "mkdir -p $remote_dir && nohup $REMOTE_SIGNAL_SCRIPT > $remote_dir/signal_${name}.csv 2>&1 < /dev/null"

        # 2. Start Throughput Testing if role is assigned
        if [ "$name" == "$DOWNLINK_NODE" ]; then
            echo "[$name] Starting DOWNLINK tests against $IPERF_SERVER on port $PORT_DOWN..."
            run_bg_cmd "$user" "$addr" "nohup $REMOTE_THROUGHPUT_SCRIPT download $IPERF_SERVER $BURST_DURATION $PORT_DOWN ${BURST_INTERVAL:-1} > $remote_dir/throughput_down_${name}.csv 2>&1 < /dev/null"
        elif [ "$name" == "$UPLINK_NODE" ]; then
            echo "[$name] Starting UPLINK tests against $IPERF_SERVER on port $PORT_UP..."
            run_bg_cmd "$user" "$addr" "nohup $REMOTE_THROUGHPUT_SCRIPT upload $IPERF_SERVER $BURST_DURATION $PORT_UP ${BURST_INTERVAL:-1} > $remote_dir/throughput_up_${name}.csv 2>&1 < /dev/null"
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
        run_cmd "$user" "$addr" "pkill -f logsignalstrength.sh; pkill -f throughput_test.sh; pkill -f iperf3; pkill -f gpspipe; pkill -f atinout"
    done
}

check_status() {
    for entry in "${NODES[@]}"; do
        local name=$(get_node_name "$entry")
        local user=$(get_node_user "$entry")
        local addr=$(get_node_addr "$entry")
        local sig_pid=$(run_cmd "$user" "$addr" "pgrep -f logsignalstrength.sh")
        local thr_pid=$(run_cmd "$user" "$addr" "pgrep -f throughput_test.sh")
        # In dry run, these will be empty strings because run_cmd redirects to stderr
        printf "[%-10s] Signal: %-15s Throughput: %s\n" "$name" "${sig_pid:+RUNNING ($sig_pid)}${sig_pid:-STATUS_UNKNOWN}" "${thr_pid:+RUNNING ($thr_pid)}${thr_pid:-STATUS_UNKNOWN}"
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
            
            # List remote sessions for today
            local remote_sessions=$(run_cmd "$user" "$addr" "ls -1 $REMOTE_BASE_DATADIR 2>/dev/null | grep '^${date_filter}_'")
            
            for s_id in $remote_sessions; do
                local local_dir="${LOCAL_BASE_DATADIR}/${s_id}"
                mkdir -p "$local_dir"
                echo "[$name] Fetching session $s_id..."
                if [ "$DRY_RUN" = "true" ]; then
                    echo "[DRY-RUN] rsync -az ${user}@${addr}:${REMOTE_BASE_DATADIR}/${s_id}/ $local_dir/" >&2
                else
                    rsync -az "${user}@${addr}:${REMOTE_BASE_DATADIR}/${s_id}/" "$local_dir/"
                fi
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
            if [ "$DRY_RUN" = "true" ]; then
                echo "[DRY-RUN] rsync -az ${user}@${addr}:${REMOTE_BASE_DATADIR}/${target_session}/ $local_dir/" >&2
            else
                rsync -az "${user}@${addr}:${REMOTE_BASE_DATADIR}/${target_session}/" "$local_dir/"
            fi
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
