#!/usr/bin/env python
import pandas as pd
import folium
import argparse
import os
import sys

# Set up argument parser for command-line options
parser = argparse.ArgumentParser(description='Generate a signal coverage map from a CSV file.')
parser.add_argument('csv_file', type=str, help='Path to the input CSV file')
args = parser.parse_args()

input_file = args.csv_file

# Check if the provided file exists
if not os.path.isfile(input_file):
    print(f"Error: The file '{input_file}' was not found.")
    sys.exit(1)

# 1. Load and prepare the data
df = pd.read_csv(input_file)
df = df.dropna(subset=['lat', 'lon'])
df = df.sort_values('timestamp').reset_index(drop=True)

# 2. Define the ordered signal rules
def get_signal_color(rsrp, rsrq):
    if pd.isna(rsrp) or pd.isna(rsrq):
        return 'gray'
    
    # Evaluated strictly from top to bottom
    if rsrq < -20 or rsrp < -124:
        return 'red'         # Critical
    elif rsrp < -100 or rsrq < -17:
        return 'orange'      # Poor
    elif rsrp < -90 or rsrq < -14:
        return '#FFD700'     # Fair (Gold/Yellow)
    elif rsrp < -80 or rsrq < -10:
        return 'lightgreen'  # Good
    else:
        return 'green'       # Excellent

# Calculate map center
center_lat = df['lat'].mean()
center_lon = df['lon'].mean()

# Initialize the Folium map with OpenStreetMap underlay
# m = folium.Map(location=[center_lat, center_lon], zoom_start=15, tiles='OpenStreetMap')
# Change the map initialization to use Canvas rendering
m = folium.Map(
    location=[center_lat, center_lon], 
    zoom_start=18, 
    tiles='OpenStreetMap',
    prefer_canvas=True  # This often fixes "drifting" markers in Leaflet
)
# 3. Add points in layers to ensure inner dots are ALWAYS on top

# LAYER 1: Draw all the outer circles (Band Indicators) first
for i in range(len(df)):
    curr = df.iloc[i]
    
    # Determine band ring color
    band = curr['nr_band']
    if band == 78:
        band_color = 'black'
    elif band == 1:
        band_color = 'white'
    else:
        band_color = 'blue' # Fallback color
        
    # Draw the outer circle
    folium.CircleMarker(
        location=[round(curr['lat'], 6), round(curr['lon'], 6)],
        radius=7,          # Sit outside the signal dot
        color=band_color,  # Band color
        weight=1.5,        # Thinner line (was 3)
        fill=False,        # Transparent center
        tooltip=f"Band: {band}"
    ).add_to(m)

# LAYER 2: Draw all the inner signal dots (Signal Strength) last so they sit on top
for i in range(len(df)):
    curr = df.iloc[i]
    
    # Draw the inner signal dot
    folium.CircleMarker(
        location=[round(curr['lat'], 6), round(curr['lon'], 6)],
        radius=4,
        color='black',       # Small black border to make the inner dot pop
        weight=0.5,          # Thinner border for the dot itself to reduce clutter
        fill=True,
        fill_color=get_signal_color(curr['nr_rsrp'], curr['nr_rsrq']),
        fill_opacity=1.0,
        tooltip=f"RSRP: {curr['nr_rsrp']}<br>RSRQ: {curr['nr_rsrq']}<br>Band: {curr['nr_band']}"
    ).add_to(m)

# 4. Save the map to an HTML file
base_name = os.path.splitext(os.path.basename(input_file))[0]
output_file = f"{base_name}_map.html"

m.save(output_file)
print(f"Interactive map successfully saved to {output_file}. Open it in your web browser!")