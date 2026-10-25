#!/usr/bin/env python3
"""Read-only serial capture: tlm_live.py [COM9] [seconds] [out.bin].

Preserves raw bytes plus out.bin.meta.json, including failed captures.
KEY1 toggles run; releasing KEY1 does not stop the motor.
"""
import json
import sys
import time
from datetime import datetime
from pathlib import Path

import serial
from analyze_tlm import FRAME_LEN, MODE, decode_frame

# Capture writes caller-supplied paths (bin + meta).  Guard both to stay
# inside the repo: this is a local bench tool, there is no legitimate use for
# writing telemetry outside the project tree.
_REPO = Path(__file__).resolve().parents[1]


def _ensure_repo_path(p):
    rp = Path(p).resolve()
    try:
        rp.relative_to(_REPO)
    except ValueError:
        raise ValueError(f"refusing path outside repo {_REPO}: {p}")
    return rp


def capture(port, duration, output):
    if duration <= 0:
        raise ValueError("采集秒数必须大于0")
    output = _ensure_repo_path(output)
    meta_path = Path(str(output) + ".meta.json")
    if output.exists() or meta_path.exists():
        raise FileExistsError(f"已有实验文件，请换一个输出名：{output}")
    started = datetime.now().astimezone().isoformat()
    t0 = time.monotonic()
    last_data = None
    max_silence = 0.0
    n_ok = n_bytes = seq_breaks = rejected = 0
    expected_seq = None
    last_print = 0.0
    buf = b""
    status = "failed"
    error = None
    print(f"monitoring {port} @ 115200 for {duration:.0f}s -> {output}", flush=True)
    print("KEY1按一次启动，再按一次停止；松开不会停止。采集只读串口。", flush=True)
    try:
        with serial.Serial(port, 115200, timeout=0.1) as ser, output.open("xb") as raw:
            while time.monotonic() - t0 < duration:
                chunk = ser.read(max(1, ser.in_waiting))
                now = time.monotonic() - t0
                if not chunk:
                    continue
                raw.write(chunk)
                n_bytes += len(chunk)
                max_silence = max(max_silence, now - (last_data or 0.0))
                last_data = now
                buf += chunk
                while True:
                    start = buf.find(b"\xa5")
                    if start < 0:
                        buf = b""
                        break
                    buf = buf[start:]
                    if len(buf) < FRAME_LEN:
                        break
                    frame = decode_frame(buf[:FRAME_LEN])
                    if frame is None:
                        rejected += 1
                        buf = buf[1:]
                        continue
                    buf = buf[FRAME_LEN:]
                    if expected_seq is not None and frame["seq"] != expected_seq:
                        seq_breaks += 1
                    expected_seq = (frame["seq"] + 1) % 256
                    n_ok += 1
                    if now - last_print >= 0.2:
                        print(f"[{now:6.1f}s] {MODE[frame['mode']]:5s} "
                              f"a={frame['alpha']:6d} ad={frame['adot']:6d} "
                              f"duty={frame['duty']:6d} adc={frame['adc']:4d} "
                              f"enc={frame['enc']:5d} fr={frame['spi']:5d} "
                              f"lk={frame['link']} en={frame['enable']} "
                              f"brk={frame['braking']} key={frame['key']} wd={frame['wdog']}", flush=True)
                        last_print = now
            status = "completed"
    except KeyboardInterrupt:
        status = "interrupted"
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
        raise
    finally:
        elapsed = time.monotonic() - t0
        trailing_silence = elapsed - (last_data or 0.0)
        max_silence = max(max_silence, trailing_silence)
        metadata = dict(port=port, started_at=started, ended_at=datetime.now().astimezone().isoformat(),
            requested_s=duration, elapsed_s=elapsed, status=status, error=error,
            bytes=n_bytes, valid_frames=n_ok, sequence_breaks=seq_breaks,
            rejected_candidates=rejected, buffered_tail_bytes=len(buf),
            last_data_s=last_data, trailing_silence_s=trailing_silence,
            max_silence_s=max_silence, host_average_hz=n_ok / max(elapsed, .001))
        meta_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"SUMMARY: frames={n_ok} seq_breaks={seq_breaks} "
              f"elapsed={elapsed:.1f}s last_data={last_data} "
              f"tail_silence={trailing_silence:.1f}s status={status}", flush=True)
    return metadata


if __name__ == "__main__":
    capture(sys.argv[1] if len(sys.argv) > 1 else "COM9",
            float(sys.argv[2]) if len(sys.argv) > 2 else 30.0,
            Path(sys.argv[3]) if len(sys.argv) > 3 else "tlm_live.bin")
