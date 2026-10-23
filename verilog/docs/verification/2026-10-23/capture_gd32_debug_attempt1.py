"""Start the already verified application via ROM GO, then read CN1 debug UART."""
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
from gd32_isp import BL
import serial


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--seconds", type=float, default=8)
    parser.add_argument("--go", action="store_true", help="ROM GO only; no Flash writes")
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    if not 0 < args.seconds <= 30:
        raise ValueError("capture must be 0..30 seconds")
    bl = BL("COM7", timeout=0.2)
    raw = bytearray()
    started = time.monotonic()
    try:
        if args.go:
            synced = bl.sync()
            pid = bl.get_id()  # Also works when ROM was already synced by prior readback.
            print(f"ROM ID=0x{pid:04X}; sync={synced}; GO verified application @0x08000000", flush=True)
            if pid != 0x0414:
                raise RuntimeError("unexpected device ID")
            bl.go(0x08000000)
        bl.ser.baudrate = 115200
        bl.ser.parity = serial.PARITY_NONE
        bl.ser.timeout = 0.1
        started = time.monotonic()
        while time.monotonic() - started < args.seconds:
            raw.extend(bl.ser.read(max(1, bl.ser.in_waiting)))
    finally:
        bl.ser.close()
        args.output.write_bytes(raw)
    adc = [int(value) for value in re.findall(rb"A([0-9]{4})\r\n", raw)]
    adc = [value for value in adc if value <= 4095]
    result = dict(file=args.output.name, bytes=len(raw), valid_lines=len(adc),
        elapsed_s=time.monotonic() - started, flash_written=False, go_requested=args.go,
        sha256=hashlib.sha256(raw).hexdigest(), adc_min=min(adc) if adc else None,
        adc_max=max(adc) if adc else None, adc_median=statistics.median(adc) if adc else None)
    Path(str(args.output) + ".json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2), flush=True)
    return 0 if adc else 1


if __name__ == "__main__":
    sys.exit(main())
