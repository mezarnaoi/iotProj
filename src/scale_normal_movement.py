import pandas as pd
import numpy as np
from scipy.signal import butter, filtfilt

def apply_velocity_scaling(data, current_speed_kmh, target_speed_kmh):
    scale_factor = (target_speed_kmh / current_speed_kmh) ** 1.5
    data[['ax_g', 'ay_g', 'az_g']] *= scale_factor
    return data

def butter_lowpass_filter(data, cutoff, fs, order=4):
    nyq = 0.5 * fs
    normal_cutoff = cutoff / nyq
    b, a = butter(order, normal_cutoff, btype='low', analog=False)
    filtered_data = filtfilt(b, a, data)
    return filtered_data

def remove_engine_vibrations(data, fs=100):
    for axis in ['ax_g', 'ay_g', 'az_g']:
        data[axis] = butter_lowpass_filter(data[axis], cutoff=20.0, fs=fs)
    return data

def filter_pothole_anomalies(data, threshold_g=3.0):
    window_size = 5
    for axis in ['ax_g', 'ay_g', 'az_g']:
        rolling_mean = data[axis].rolling(window=window_size, center=True).mean()
        spike_mask = np.abs(data[axis] - rolling_mean) > threshold_g
        data.loc[spike_mask, axis] = rolling_mean[spike_mask]
    return data.dropna()

def process_motorcycle_telemetry(input_file, output_file):
    df = pd.read_csv(input_file)
    
    df = apply_velocity_scaling(df, current_speed_kmh=15.0, target_speed_kmh=40.0)
    df = remove_engine_vibrations(df, fs=100)
    df = filter_pothole_anomalies(df, threshold_g=2.5)
    
    df.to_csv(output_file, index=False)

if __name__ == "__main__":
    process_motorcycle_telemetry('motorcycle_raw_log.csv', 'raw_data_label0.csv')
