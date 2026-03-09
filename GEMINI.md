# GEMINI.md

## Project Overview
CellSweep is a toolset for tracing signal strength and up/downlink speeds across different geographic areas. It uses a set of shell scripts designed to run on a machine (the "test node") equipped with a modem and a GPS receiver, typically running Ubuntu.

## Architecture
The system is divided into two parts:
1.  **Controller Node:** Manages remote nodes via SSH. Handles deployment, session control, and data fetching.
2.  **Test Nodes:** Run continuous logging and throughput testing scripts.

## Key Technologies
- **Shell Scripts (Bash 3.2+):** For automation and logging.
- **atinout:** For sending AT commands to the modem (Quectel).
- **iperf3 / jq:** For throughput testing and JSON result parsing.
- **gpsd / gpspipe:** For capturing GPS data.
- **AWS CLI:** On the controller, for managing server firewall rules.

## Project Structure
- `controllernode/`:
    - `sweep_control.sh`: Main management script.
    - `config.env`: (Private) Node and AWS configuration.
    - `session.env`: (Private) Throughput test roles and parameters.
- `testnodes/`:
    - `logsignalstrength.sh`: Continuous signal and GPS logging.
    - `throughput_test.sh`: Continuous iperf3 burst testing.
- `README.md`: Basic project overview and dependency information.

## Usage

### 1. Preparation
Copy the `.env.example` files to `.env` in `controllernode/` and `testnodes/` and fill in your specific node details, AWS Security Group, and server IP.

### 2. Configure Firewall (Optional)
If using an AWS-based iperf server, update the firewall to allow your modems' current IPs:
```bash
./controllernode/sweep_control.sh prepare_server
```

### 3. Start a Test Session
```bash
./controllernode/sweep_control.sh start [session_name_suffix]
```
This starts both signal logging and throughput tests (based on roles in `session.env`).

### 4. Stop and Fetch Data
```bash
./controllernode/sweep_control.sh stop
./controllernode/sweep_control.sh fetch remaining
```
Data is stored locally in `~/datadir/<session_id>/`.

## Development Conventions
- **Language:** Bash (`#!/usr/bin/env bash`).
- **Data Format:** Millisecond-timestamped CSVs for temporal correlation across different logs.
- **Configuration:** All environment-specific variables must be in `*.env` files (ignored by Git).
- **Sub-agents:** Use `codebase_investigator` for architectural questions.
