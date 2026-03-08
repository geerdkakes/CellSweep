# GEMINI.md

## Project Overview
CellSweep is a toolset for tracing signal strength and up/downlink speeds across different geographic areas. It uses a set of shell scripts designed to run on a machine (the "test node") equipped with a modem and a GPS receiver, typically running Ubuntu.

## Architecture
The system is divided into two parts:
1.  **Controller Node:** A script (intended to run on a laptop/control machine) to start and stop the logging process remotely.
2.  **Test Nodes:** Scripts running on the machine with the modem and GPS, continuously logging signal data and GPS coordinates.

## Key Technologies
- **Shell Scripts (Bash):** For automation and logging.
- **atinout:** For sending AT commands to the modem (specifically targeted at Quectel modems).
- **Quectel Drivers (`qmi_wwan_q`):** For modem communication.
- **gpsd / gpspipe:** For capturing GPS data.

## Project Structure
- `controllernode/`: Contains scripts for managing the logging process (currently empty).
- `testnodes/`: Contains scripts for logging signal strength and GPS data.
    - `logsignalstrength.sh`: A script that outputs signal and GPS data in CSV format to stdout.
- `README.md`: Basic project overview and dependency information.

## Building and Running
As this is a shell-script-based project, there is no build step.

### Prerequisites
The following tools must be installed on the test node:
- `atinout` (source: https://github.com/beralt/atinout)
- Quectel drivers `qmi_wwan_q`
- `gpsd` (source: https://gpsd.gitlab.io/gpsd/)

### Running the Logging Script
To start logging on a test node:
```bash
./testnodes/logsignalstrength.sh
```
The script will output data in the following format:
`timestamp,lat,lon,cell_type,state,technology,duplex_mode,mcc,mnc,cellid,pcid,tac,arfcn,band,ns_dl_bw,rsrp,rsrq,sinr,scs,srxlev`

## Development Conventions
- **Language:** Bash (`#!/usr/bin/env bash`).
- **Data Format:** CSV-style output with headers.
- **Modem Interface:** Uses `/dev/ttyUSB2` for AT commands by default.
- **GPS Interface:** Uses `gpspipe -w -n 8` to capture TPV data.
- **Looping:** Scripts typically run in an infinite `while true` loop with a small `sleep` interval (e.g., 0.1s).
