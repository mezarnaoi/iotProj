import sys
import time
import serial
import csv
import argparse
 
PORT = "COM8"   # <-- put your Sparrow port here
BAUD = 115200
 
def parse_args():
    p = argparse.ArgumentParser(description="Collect Sparrow IMU data with a fixed label.")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("-stationary", "--stationary", action="store_true",
                   help="Use the 'stationary' label")
    g.add_argument("-shaking", "--shaking", action="store_true",
                   help="Use the 'shaking' label")
 
    # Optional niceties (you can delete these if you don't need them)
    p.add_argument("--string-label", action="store_true",
                   help="Write string labels ('stationary'/'shaking') instead of 0/1")
    p.add_argument("--port", default=PORT, help=f"Serial port (default: {PORT})")
    p.add_argument("--baud", type=int, default=BAUD, help=f"Baud rate (default: {BAUD})")
    return p.parse_args()
 
args = parse_args()
PORT = args.port
BAUD = args.baud
 
# Map flags -> name/id
if args.stationary:
    LABEL_NAME, LABEL_ID = "stationary", 0
else:
    LABEL_NAME, LABEL_ID = "shaking", 1
 
# Choose what to store in the CSV's label column
LABEL_CONST = LABEL_NAME if args.string_label else LABEL_ID
 
# Nice, unambiguous filenames
OUTFILE = f"raw_data_label{LABEL_NAME if args.string_label else LABEL_ID}.csv"
 
def open_serial():
    ser = serial.Serial(PORT, BAUD, timeout=0.1)
    time.sleep(2.0)  # Give ESP32 time to reboot after opening port
    ser.reset_input_buffer()
    return ser
 
def main():
    try:
        ser = open_serial()
    except serial.SerialException as e:
        print(f"Could not open {PORT}: {e}")
        sys.exit(1)
 
    f = open(OUTFILE, "w", newline="")
    writer = csv.writer(f)
    writer.writerow(["timestamp_ms", "ax_g", "ay_g", "az_g", "label"])
 
    print()
    print(f"Recording with FIXED label={LABEL_CONST} ({LABEL_NAME}, id={LABEL_ID})")
    print("Press Ctrl+C when you've collected ~10 seconds.")
    print(f"Saving to {OUTFILE}")
    print()
 
    buf = ""
    try:
        while True:
            try:
                chunk = ser.read(1024).decode("utf-8", errors="ignore")
            except serial.SerialException as e:
                print(f"[Serial error] {e}")
                break
 
            if not chunk:
                continue
 
            buf += chunk
            lines = buf.split("\n")
            buf = lines.pop()
 
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                if line.startswith("#"):
                    print(line)
                    continue
 
                parts = line.split(",")
                if len(parts) != 5:
                    continue
 
                try:
                    t_ms = int(parts[0].strip())
                    ax_g = float(parts[1].strip())
                    ay_g = float(parts[2].strip())
                    az_g = float(parts[3].strip())
                except ValueError:
                    continue
 
                writer.writerow([t_ms, ax_g, ay_g, az_g, LABEL_CONST])
                f.flush()
                print(f"{t_ms},{ax_g:.4f},{ay_g:.4f},{az_g:.4f},{LABEL_CONST}")
 
    except KeyboardInterrupt:
        print("\nStopping capture...")
 
    f.close()
    try:
        ser.close()
    except Exception:
        pass
 
    print(f"Saved {OUTFILE}")
 
if __name__ == "__main__":
    main()
