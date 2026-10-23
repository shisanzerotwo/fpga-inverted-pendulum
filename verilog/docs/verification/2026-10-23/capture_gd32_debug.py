"""Read CN1 application debug UART; wait on an open port for normal reset."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import statistics
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "_tools"))
import serial


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--seconds", type=float, default=8)
    parser.add_argument("--wait", type=float, default=0, help="seconds to wait for first Axxxx line")
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    if not 0 < args.seconds <= 30:
        raise ValueError("capture must be 0..30 seconds")
    if not 0 <= args.wait <= 180:
        raise ValueError("wait must be 0..180 seconds")
    port = serial.Serial("COM7", 115200, parity=serial.PARITY_NONE, timeout=0.1)
    raw = bytearray()
    started = time.monotonic()
    try:
        if args.wait:
            print("WAITING_FOR_APP: COM7 open @115200 8N1; tap SW4 only (not SW5)", flush=True)
            deadline = time.monotonic() + args.wait
            while time.monotonic() < deadline:
                raw.extend(port.read(max(1, port.in_waiting)))
                if re.search(rb"A[0-9]{4}\r\n", raw):
                    print("Application debug line received; capturing", flush=True)
                    break
        started = time.monotonic()
        while time.monotonic() - started < args.seconds:
            raw.extend(port.read(max(1, port.in_waiting)))
    finally:
        port.close()
        args.output.write_bytes(raw)
    adc = [int(value) for value in re.findall(rb"A([0-9]{4})\r\n", raw)]
    adc = [value for value in adc if value <= 4095]
    result = dict(file=args.output.name, bytes=len(raw), valid_lines=len(adc),
        elapsed_s=time.monotonic() - started, flash_written=False,
        sha256=hashlib.sha256(raw).hexdigest(), adc_min=min(adc) if adc else None,
        adc_max=max(adc) if adc else None, adc_median=statistics.median(adc) if adc else None)
    Path(str(args.output) + ".json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2), flush=True)
    return 0 if adc else 1


if __name__ == "__main__":
    sys.exit(main())
