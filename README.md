# CellSweep

Toolset for tracing cellular signal strength, technology, and up/downlink throughput across geographic areas. All measurements are timestamped to the millisecond and GPS-tagged, enabling spatial maps of signal quality and speed.

---

## Architecture

```
  Laptop (controller)
       │ SSH
  ┌────┴────────────────────────────┐
  │  apu3          apu3lte          │  ← test nodes (Ubuntu + Quectel modem + GPS)
  │  downlink      uplink           │
  └────────────────┬────────────────┘
                   │ iperf3 (TCP)
            AWS EC2 iperf3 server
            3.254.95.210  (eu-west-1)
            port 5201 (downlink), 5202 (uplink)
```

Both test nodes run `logsignalstrength.sh` (signal + GPS, ~200 ms interval) and `throughput_test.sh` (iperf3 bursts with GPS fix) simultaneously.

**Node addressing:**
- At home: reachable by hostname (`apu3`, `apu3lte`)
- In the field: reachable by IP (`192.168.3.2`, `192.168.3.3`)
- `sweep_control.sh` automatically tries the hostname first, falls back to IP

---

## Dependencies

Required on each test node (Ubuntu):

| Tool | Purpose |
|------|---------|
| `atinout` | Send AT commands to Quectel modem ([source](https://github.com/beralt/atinout)) |
| Quectel `qmi_wwan_q` driver | Modem connectivity |
| `gpsd` + `gpspipe` | GPS daemon and data pipe |
| `iperf3` | Throughput testing (expected at `/usr/local/iperf3/src/iperf3` or on PATH) |
| `jq` | Parse iperf3 JSON output |
| `timeout`, `awk` | Standard logging utilities |

Required on the controller (laptop):

- `ssh`, `rsync` — remote management and data fetch
- `aws` CLI — Security Group management (`prepare_server`)

---

## Configuration

Copy and fill in the `.env.example` files — these are git-ignored and never committed:

```bash
cp controllernode/config.env.example controllernode/config.env
cp controllernode/session.env.example controllernode/session.env
cp testnodes/config.env.example testnodes/config.env   # on each test node
```

**`controllernode/config.env`** — node list, directories, AWS settings:
```bash
NODES=("apu3|192.168.3.3|geerd" "apu3lte|192.168.3.2|geerd")
REMOTE_REPO_ROOT="/usr/local/CellSweep"
REMOTE_BASE_DATADIR="$HOME/datadir"
LOCAL_BASE_DATADIR="$HOME/datadir"
AWS_REGION="eu-west-1"
AWS_SECURITY_GROUP_ID="sg-0f2b45cf0e815a2bd"
IPERF_PORTS="5201,5202"
```

**`controllernode/session.env`** — test drive parameters:
```bash
IPERF_SERVER="3.254.95.210"
DOWNLINK_NODE="apu3"
UPLINK_NODE="apu3lte"
BURST_DURATION=10      # seconds per burst; 10s ≈ 140m at 50 km/h
BURST_INTERVAL=1       # pause between bursts in seconds
```

---

## How to Run a Test Drive

### 1. Prepare the AWS firewall

The modems get a new public IP each time they reconnect. Run this before every drive to whitelist the current IPs in the AWS Security Group:

```bash
./controllernode/sweep_control.sh prepare_server
```

### 2. Start a session

```bash
./controllernode/sweep_control.sh start [optional-suffix]
```

This starts on all nodes simultaneously:
- `logsignalstrength.sh` — continuous signal + GPS logging
- `throughput_test.sh` — continuous iperf3 bursts + GPS logging

The session ID is auto-generated (e.g. `20260310_01-highway`). SSH returns immediately; processes run in the background on the nodes.

### 3. Drive

Both nodes log continuously. No action needed while driving.

### 4. Stop

```bash
./controllernode/sweep_control.sh stop
```

Kills all CellSweep processes on all nodes (`logsignalstrength.sh`, `throughput_test.sh`, 'gps_logger.sh' , `iperf3`, `gpspipe`, `socat`).

### 5. Fetch data

```bash
# Fetch all sessions recorded today:
./controllernode/sweep_control.sh fetch remaining

# Or fetch a specific session:
./controllernode/sweep_control.sh fetch 20260310_01-highway
```

Data lands in `LOCAL_BASE_DATADIR/<session_id>/`:

```
20260310_01-highway/
  signal_apu3.csv
  signal_apu3.err
  signal_apu3lte.csv
  signal_apu3lte.err
  gps_apu3lte.json
  gps_apu3lte.err
  gps_apu3.json
  gps_apu3.err
  throughput_down_apu3.csv
  throughput_up_apu3lte.csv
  throughput_down_apu3.json
  throughput_up_apu3lte.json
  throughput_down_apu3.err
  throughput_up_apu3lte.err
```

### 6. Check status (optional)

```bash
./controllernode/sweep_control.sh status
```

### Dry run (preview SSH commands without executing)

```bash
DRY_RUN=true ./controllernode/sweep_control.sh start test
```

---

## Output Data Format

### Signal log — `signal_<node>.json`

Logged at 1 second intervals. Supports LTE, 5G NSA, and 5G SA automatically.

```json
{
  "timestamp_ms": 1773351320485,
  "modem": {
    "state": "NOCONN",
    "lte_anchor": {
      "is_tdd": "FDD",
      "mcc": "204",
      "mnc": "08",
      "cellid": "158110C",
      "pcid": "437",
      "earfcn": "6400",
      "band": "B20",
      "ul_bw": "10 MHz",
      "dl_bw": "10 MHz",
      "tac": "7B0D",
      "rsrp": -97,
      "rsrq": -15,
      "rssi": -65,
      "sinr": 9,
      "cqi": 5,
      "tx_power": 180,
      "srxlev": null
    },
    "nr5g_nsa": {
      "mcc": "204",
      "mnc": "08",
      "pcid": "889",
      "rsrp": -97,
      "sinr": -1,
      "rsrq": -14,
      "arfcn": "154570",
      "band": "n28",
      "dl_bw": "10 MHz",
      "scs": "15 kHz"
    }
  },
  "raw_output": "AT+QENG=\"servingcell\"\n+QENG: \"servingcell\",\"NOCONN\"\n+QENG: \"LTE\",\"FDD\",204,08,158110C,437,6400,20,3,3,7B0D,-97,-15,-65,9,5,180,-\n+QENG: \"NR5G-NSA\",204,08,889,-97,-1,-14,154570,28,1,0\n\nOK",
  "status": {
    "modem": "ok"
  }
}
```

### GPS log — `gps_<node>.json`
Logged at 1 second intervals. Contains the latest GPS fix at the time of logging.

```json
{
  "os_timestamp_ms": 1773351342505,
  "class": "SKY",
  "device": "/dev/ttyS2",
  "sats_used": 5,
  "sats_visible": 12,
  "hdop": 2.13,
  "vdop": 2.74
}
{
  "os_timestamp_ms": 1773351342554,
  "class": "TPV",
  "device": "/dev/ttyS2",
  "fix_status": "3D",
  "lat": 52.002362833,
  "lon": 4.329830333,
  "alt": 24.6,
  "speed": 0.078,
  "track": 0
}
```


### Throughput log — `throughput_<up|down>_<node>.csv`

One row per completed iperf3 burst. 

```
timestamp,direction,bitrate_bps,bitrate_mbps
1773351320485,download,5000000,5.0
```

`bitrate_bps = 0` means iperf3 failed to reach the server (firewall, connectivity loss).

---






