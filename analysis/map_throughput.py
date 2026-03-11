import json
import pandas as pd
import numpy as np
import plotly.express as px
import argparse
import sys

# usage:
# python map_script.py --json throughput_up_apu3lte.json --csv filtered_signal_apu3_interpolated.csv --output my_map.html

def create_map(json_path, csv_path, output_path):
    # 1. Load and Parse JSON iperf data
    # (Handles files containing multiple JSON objects/lines)
    all_intervals = []
    try:
        with open(json_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                    if 'intervals' in data and 'start' in data:
                        start_time_secs = data['start']['timestamp']['timesecs']
                        for interval in data['intervals']:
                            if 'sum' in interval:
                                s = interval['sum']
                                # Use midpoint of interval for location mapping
                                mid_time = start_time_secs + (s['start'] + s['end']) / 2.0
                                all_intervals.append({
                                    'timestamp_ms': mid_time * 1000,
                                    'mbps': s['bits_per_second'] / 1e6
                                })
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        print(f"Error: JSON file '{json_path}' not found.")
        return

    if not all_intervals:
        print("No valid throughput data found in JSON.")
        return

    df_iperf = pd.DataFrame(all_intervals).sort_values('timestamp_ms')

    # 2. Load CSV location data
    try:
        df_loc = pd.read_csv(csv_path).sort_values('timestamp')
    except FileNotFoundError:
        print(f"Error: CSV file '{csv_path}' not found.")
        return

    # 3. Interpolate GPS coordinates for each throughput measurement
    df_iperf['lat'] = np.interp(df_iperf['timestamp_ms'], df_loc['timestamp'], df_loc['lat'])
    df_iperf['lon'] = np.interp(df_iperf['timestamp_ms'], df_loc['timestamp'], df_loc['lon'])

    # 4. Define Color Coding Categories
    def get_category(speed):
        if speed < 30: return '1: < 30 Mbps (red)'
        if speed < 40: return '2: 30 - 40 Mbps (orange)'
        if speed < 50: return '3: 40 - 50 Mbps (yellow)'
        if speed < 60: return '4: 50 - 60 Mbps (light green)'
        return '5: >= 60 Mbps (green)'

    df_iperf['speed_range'] = df_iperf['mbps'].apply(get_category)

    color_discrete_map = {
        '1: < 30 Mbps (red)': 'red',
        '2: 30 - 40 Mbps (orange)': 'orange',
        '3: 40 - 50 Mbps (yellow)': 'yellow',
        '4: 50 - 60 Mbps (light green)': 'lightgreen',
        '5: >= 60 Mbps (green)': 'green'
    }

    # 5. Create Interactive Map using Plotly (OpenStreetMap)
    fig = px.scatter_mapbox(
        df_iperf, 
        lat="lat", 
        lon="lon", 
        color="speed_range",
        color_discrete_map=color_discrete_map,
        category_orders={"speed_range": sorted(color_discrete_map.keys())},
        hover_data={"mbps": ":.2f", "lat": False, "lon": False, "speed_range": False},
        title="Uplink Throughput Map",
        zoom=15
    )

    fig.update_layout(
        mapbox_style="open-street-map",
        margin={"r":0,"t":40,"l":0,"b":0}
    )

    # 6. Save Output
    fig.write_html(output_path)
    print(f"Successfully saved map to: {output_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Map iperf uplink speed onto OpenStreetMap.")
    parser.add_argument("--json", required=True, help="Path to the throughput JSON file")
    parser.add_argument("--csv", required=True, help="Path to the location CSV file")
    parser.add_argument("--output", default="throughput_map.html", help="Output HTML filename")

    args = parser.parse_args()
    create_map(args.json, args.csv, args.output)