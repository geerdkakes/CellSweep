# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

CellSweep traces cellular signal strength and up/downlink speeds across geographic areas. It logs data from a Quectel modem (via AT commands) and GPS continuously to CSV files, enabling spatial correlation of signal quality with location and throughput.

## Architecture

The system has three parts:

**Controller** (`controllernode/`) — runs on a laptop:
- `sweep_control.sh`: Manages test nodes over SSH. Handles session lifecycle (`start`/`stop`/`status`/`fetch`), auto-generates timestamped session IDs (e.g., `20260308_01`), and updates the AWS Security Group (`prepare_server`) to whitelist the modems' current public IPs before a test drive.
- Config: `config.env` defines the `NODES` array (format: `"name|ip|user"`), data directories, and AWS settings. `session.env` assigns iperf3 roles (`DOWNLINK_NODE`, `UPLINK_NODE`) and test parameters.

**Test Nodes** (`testnodes/`) — two Ubuntu machines (`apu3`, `apu3lte`), each with a Quectel modem and GPS:
- Reachable by hostname when at home, by field IPs (`192.168.3.2`, `192.168.3.3`) during a test drive.
- `logsignalstrength.sh`: Main logging loop (~200ms interval). Queries modem with `AT+QENG="servingcell"` via `atinout`, fetches GPS via `gpspipe` (0.5s timeout), and parses output with an embedded AWK script handling 5G SA, LTE, and 5G NSA modes. Outputs a unified CSV.
- `throughput_test.sh`: Runs continuous `iperf3` bursts against the AWS server, logging `timestamp,direction,bitrate_bps` per test. Called with `./throughput_test.sh <download|upload> <server> <duration> [port]`.

**AWS iperf3 server** — `3.254.95.210` (eu-west-1), Security Group `sg-0f2b45cf0e815a2bd`, ports 5201 (downlink from `apu3`) and 5202 (uplink from `apu3lte`). The `prepare_server` command must be run before each test drive to whitelist the modems' current public IPs.

**Data flow:** Test nodes write CSVs to `REMOTE_BASE_DATADIR/<session_id>/`. The controller fetches them via `rsync` to `LOCAL_BASE_DATADIR/<session_id>/`. Signal and throughput CSVs share millisecond timestamps for spatial correlation.

## Setup

1. Copy `.env.example` files to `.env` in both `controllernode/` and `testnodes/` — these are git-ignored.
2. `*.env` files are never committed; only `*.env.example` templates are tracked.

## Key Commands (run from repo root on controller)

```bash
# Prepare AWS firewall with current modem public IPs
./controllernode/sweep_control.sh prepare_server

# Start a new logging session (optional suffix appended to session ID)
./controllernode/sweep_control.sh start [suffix]

# Check if logging processes are running on all nodes
./controllernode/sweep_control.sh status

# Stop all CellSweep processes on all nodes
./controllernode/sweep_control.sh stop

# Fetch all today's sessions from all nodes
./controllernode/sweep_control.sh fetch remaining

# Fetch a specific session
./controllernode/sweep_control.sh fetch 20260308_01
```

Set `DRY_RUN=true` in the environment to preview SSH commands without executing them.

## Test Node Dependencies

Required on each test node (Ubuntu):
- `atinout` — sends AT commands to modem serial port
- `gpsd` + `gpspipe` — GPS daemon and pipe utility
- `iperf3` + `jq` — throughput testing and JSON parsing
- Quectel `qmi_wwan_q` driver
- Bash 3.2+, `timeout`, `awk`

`iperf3` is expected at `/usr/local/iperf3/src/iperf3` or on `PATH`.

## CSV Output Schema

Signal log columns (from `logsignalstrength.sh`):
```
timestamp,lat,lon,cell_type,state,technology,duplex_mode,mcc,mnc,cellid,pcid,tac,arfcn,band,ns_dl_bw,rsrp,rsrq,sinr,scs,srxlev
```

Throughput log columns (GPS sampled at burst start):
```
timestamp,lat,lon,direction,bitrate_bps
```
`bitrate_bps=0` means iperf3 failed (not `null`). `jq` uses `// 0` fallback.

## Notes

- `run_bg_cmd` is used for fire-and-forget SSH starts: wraps the remote command in `{ cmd; } </dev/null &>/dev/null &` so the background subshell never holds the SSH pipe FDs open, and sshd returns immediately when the SSH shell exits.
- `fetch` uses `rsync -az` (not `scp`) so remote globs are handled reliably and progress is visible.
- GPS fix absence is rate-limited to one warning per 10 seconds to stderr; missing GPS writes `","` for lat/lon fields.
- Process accumulation can occur if `stop` fails; `stop` runs `pkill` on all relevant process names (`logsignalstrength.sh`, `throughput_test.sh`, `iperf3`, `gpspipe`, `atinout`).
