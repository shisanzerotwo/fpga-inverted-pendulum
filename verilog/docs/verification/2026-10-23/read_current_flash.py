"""Bounded, read-only GD32 ROM readback; never erase, write, or GO."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "_tools"))
from gd32_isp import BL, parse_hex, try_handshake


class ReadOnlyBL(BL):
    def cmd(self, command):
        if command not in (0x00, 0x02, 0x11):
            raise RuntimeError("non-read command refused: %02x" % command)
        super().cmd(command)


def main():
    out = Path(__file__).resolve().parent
    bl = ReadOnlyBL("COM7", timeout=0.2)
    result = {"port": "COM7", "address": "0x08000000", "length": 4096,
              "allowed_commands": ["GET", "GET_ID", "READ_MEMORY"],
              "flash_written": False}
    try:
        print("Opened COM7; read-only command allowlist active", flush=True)
        ready = try_handshake(bl, 3, 0.2, "as-is")
        for boot_line in ("rts", "dtr"):
            if ready:
                break
            reset_line = "dtr" if boot_line == "rts" else "rts"
            for level in (True, False):
                setattr(bl.ser, boot_line, level)
                time.sleep(0.05)
                setattr(bl.ser, reset_line, not level)
                time.sleep(0.05)
                setattr(bl.ser, reset_line, level)
                time.sleep(0.05)
                ready = try_handshake(bl, 4, 0.15, "auto")
                if ready:
                    break
                setattr(bl.ser, boot_line, not level)
        if not ready:
            print("WAITING_FOR_BUTTONS: hold SW5, tap SW4, release SW5; port stays open (180 seconds)", flush=True)
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                if bl.sync():
                    ready = True
                    break
                time.sleep(0.2)
        if not ready:
            raise RuntimeError("bootloader handshake timed out; no Flash write attempted")
        result["device_id"] = "0x%04X" % bl.get_id()
        print("GetID " + result["device_id"], flush=True)
        data = b"".join(bl.read_mem(0x08000000 + off, 256) for off in range(0, 4096, 256))
        (out / "gd32_current_flash.bin").write_bytes(data)
        repeat = b"".join(bl.read_mem(0x08000000 + off, 256) for off in range(0, 4096, 256))
        (out / "gd32_current_flash_repeat.bin").write_bytes(repeat)
        if data != repeat:
            raise RuntimeError("two independent read passes differ")
        sp, reset = struct.unpack_from("<II", data)
        if not (0x20000000 <= sp < 0x20020000 and 0x08000001 <= reset < 0x08040000 and reset & 1):
            raise RuntimeError("vector table failed sanity check")
        result.update(sha256=hashlib.sha256(data).hexdigest(), repeat_identical=True,
                      initial_sp=hex(sp), reset_handler=hex(reset))
        comparisons = []
        for candidate in sorted((ROOT / "gd32_fw").rglob("*.hex")):
            expected = {a + i: b for a, block in parse_hex(candidate) for i, b in enumerate(block)}
            covered = all(0x08000000 <= a < 0x08000000 + len(data) for a in expected)
            differences = sum(data[a - 0x08000000] != b for a, b in expected.items()
                              if 0x08000000 <= a < 0x08000000 + len(data))
            comparisons.append({"file": str(candidate.relative_to(ROOT)), "bytes": len(expected),
                                "fully_covered": covered, "different_bytes": differences,
                                "exact_match": covered and bool(expected) and differences == 0})
        result.update(status="ok", comparisons=comparisons)
        print(json.dumps(result, indent=2), flush=True)
    except Exception as exc:
        result.update(status="failed", error=str(exc))
        print("ERROR: " + str(exc), flush=True)
        raise
    finally:
        bl.ser.close()
        (out / "gd32_current_flash.json").write_text(json.dumps(result, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
