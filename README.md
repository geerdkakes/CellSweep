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

Kills all CellSweep processes on all nodes (`logsignalstrength.sh`, `throughput_test.sh`, `iperf3`, `gpspipe`, `atinout`).

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
  signal_apu3lte.csv
  throughput_down_apu3.csv
  throughput_up_apu3lte.csv
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

### Signal log — `signal_<node>.csv`

Logged at ~200 ms intervals. Supports LTE, 5G NSA, and 5G SA automatically.

```
timestamp,lat,lon,cell_type,state,technology,duplex_mode,mcc,mnc,cellid,pcid,tac,arfcn,band,ns_dl_bw,rsrp,rsrq,sinr,scs,srxlev
```

Key columns for mapping: `lat`, `lon`, `rsrp` (signal strength dBm), `rsrq`, `sinr`, `technology` (LTE / NR5G-NSA / NR5G-SA), `band`.

### Throughput log — `throughput_<up|down>_<node>.csv`

One row per completed iperf3 burst. GPS is sampled at the start of each burst.

```
timestamp,lat,lon,direction,bitrate_bps
```

`bitrate_bps = 0` means iperf3 failed to reach the server (firewall, connectivity loss).

---

## Making Maps

The CSVs can be loaded directly into mapping tools:

### QGIS (recommended)

1. **Layer → Add Layer → Add Delimited Text Layer**
2. Select the CSV, set geometry: `lat` = Y field, `lon` = X field, CRS = EPSG:4326
3. Right-click layer → **Properties → Symbology → Graduated**
4. Classify by: `rsrp` (signal map), `bitrate_bps` (throughput maps)
5. Choose a colour ramp (e.g. red–yellow–green) and apply

One layer per CSV gives three maps: signal strength, uplink, downlink.

### Python

```python
import pandas as pd
import folium

df = pd.read_csv("signal_apu3lte.csv").dropna(subset=["lat", "lon"])
m = folium.Map(location=[df.lat.mean(), df.lon.mean()], zoom_start=13)
for _, row in df.iterrows():
    folium.CircleMarker(
        [row.lat, row.lon], radius=4,
        color="red" if row.rsrp < -110 else "orange" if row.rsrp < -95 else "green",
        fill=True
    ).add_to(m)
m.save("signal_map.html")
```

---

## Current Status (March 2026)

All core features implemented and field-tested:

- **SSH backgrounding fixed** — `start` returns immediately; processes run fully detached on nodes
- **Signal logging** — LTE, 5G NSA, 5G SA auto-detected; ~200 ms sample rate
- **Throughput logging** — continuous iperf3 bursts with GPS coordinates per burst
- **GPS in throughput log** — added March 2026; enables direct throughput maps without timestamp joins
- **Session management** — auto-incrementing session IDs, organised by date
- **AWS firewall automation** — `prepare_server` whitelists modem IPs before each drive
- **Reliable fetch** — `rsync` replaces `scp` for robust data retrieval
