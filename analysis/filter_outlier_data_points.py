#!/usr/bin/env python
import pandas as pd
import numpy as np
import argparse
import os
import sys

# Set up argument parser for command-line options
parser = argparse.ArgumentParser(description='Generate a signal coverage map from a CSV file.')
parser.add_argument('csv_file', type=str, help='Path to the input CSV file')
# Flag to keep all original data
parser.add_argument('--keep-all', action='store_true', help='Keep all columns from the input CSV instead of just timestamp, lat, and lon')
args = parser.parse_args()

input_file = args.csv_file

# Check if the provided file exists
if not os.path.isfile(input_file):
    print(f"Error: The file '{input_file}' was not found.", file=sys.stderr)
    sys.exit(1)


def haversine(lat1, lon1, lat2, lon2):
    """Calculate the great-circle distance between two points in meters."""
    R = 6371000  
    phi_1 = np.radians(lat1)
    phi_2 = np.radians(lat2)
    delta_phi = np.radians(lat2 - lat1)
    delta_lambda = np.radians(lon2 - lon1)
    
    a = np.sin(delta_phi / 2.0) ** 2 + \
        np.cos(phi_1) * np.cos(phi_2) * \
        np.sin(delta_lambda / 2.0) ** 2
    c = 2 * np.arctan2(np.sqrt(a), np.sqrt(1 - a))
    return R * c

def process_and_filter_data(csv_path, max_speed_kmh=30.0, max_accel_mps2=3.0, keep_all=False):
    """
    Extracts time, lat, lon and filters out GPS outliers using 
    both max speed AND max acceleration thresholds.
    """
    df = pd.read_csv(csv_path)
    
    # We always need timestamp, lat, and lon for the math, 
    # but we decide what the 'data' dataframe looks like based on keep_all
    if keep_all:
        data = df.copy()
    else:
        data = df[['timestamp', 'lat', 'lon']].copy()
    
    # Add the human readable time (useful in both modes)
    data['datetime_cet'] = pd.to_datetime(
        data['timestamp'], unit='ms', utc=True
    ).dt.tz_convert('Europe/Amsterdam')
    
    # Clean and sort (important for sequential physics calculations)
    data = data.dropna(subset=['lat', 'lon']).sort_values('timestamp').reset_index(drop=True)
    
    # Convert speed from km/h to m/s
    max_speed_mps = max_speed_kmh / 3.6 
    
    valid_indices = [0]
    last_valid_speed = 0.0
    
    for i in range(1, len(data)):
        prev_idx = valid_indices[-1]
        
        lat1, lon1 = data.loc[prev_idx, ['lat', 'lon']]
        lat2, lon2 = data.loc[i, ['lat', 'lon']]
        
        t1 = data.loc[prev_idx, 'timestamp']
        t2 = data.loc[i, 'timestamp']
        
        dist = haversine(lat1, lon1, lat2, lon2)
        time_diff = (t2 - t1) / 1000.0
        
        if time_diff > 0:
            current_speed = dist / time_diff
            accel = abs(current_speed - last_valid_speed) / time_diff
            
            # Both speed and acceleration must be physically possible
            if current_speed <= max_speed_mps and accel <= max_accel_mps2:
                valid_indices.append(i)
                last_valid_speed = current_speed
                
        elif dist == 0: 
            valid_indices.append(i)
            
    clean_data = data.iloc[valid_indices].copy()
    
    # Logic for column ordering
    if not keep_all:
        # If not keeping all, return the specific subset you requested
        clean_data = clean_data[['timestamp', 'datetime_cet', 'lat', 'lon']]
    else:
        # If keeping all, we move the new datetime_cet to the second position for convenience
        cols = clean_data.columns.tolist()
        if 'datetime_cet' in cols:
            cols.insert(1, cols.pop(cols.index('datetime_cet')))
            clean_data = clean_data[cols]
    
    print(f"Original locations: {len(data)}", file=sys.stderr)
    print(f"Points after filtering: {len(clean_data)}", file=sys.stderr)
    print(f"Removed {len(data) - len(clean_data)} outliers.", file=sys.stderr)
    
    return clean_data

if __name__ == "__main__":
    # Pass the 'keep_all' flag from the command line into the function
    cleaned_df = process_and_filter_data(input_file, keep_all=args.keep_all)
    
    # Save the output to a new CSV file
    cleaned_df.to_csv(sys.stdout, index=False)