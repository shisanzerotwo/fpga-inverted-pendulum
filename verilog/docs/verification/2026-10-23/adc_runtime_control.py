"""Temporary ADC channel 8 -> internal reference 17 -> 8; never write Flash."""
import hashlib
import json
from pathlib import Path
import statistics
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent / "pyocd_lib_offsite" / "pyocd_lib"))
from pyocd.core.helpers import ConnectHelper
from pyocd.core.target import Target

CTL1, SAMPT0, RSQ2 = 0x40012408, 0x4001240C, 0x40012434
RDATA, G_ADC = 0x4001244C, 0x20000016
ADCON, SWRCST, SWICST, TSVREN = 1, 1 << 22, 1 << 21, 1 << 23
COMMAND_BITS = SWRCST | SWICST
OPTIONS = {"target_override": "cortex_m", "frequency": 1000000,
    "connect_mode": "attach", "auto_unlock": False, "resume_on_disconnect": False,
    "cache.enable_memory": False, "cache.read_code_from_elf": False,
    "no_config": True, "project_dir": str(OUT)}


def main():
    destination = OUT / "adc_runtime_control.json"
    if destination.exists():
        raise FileExistsError(destination)
    result = {"options": OPTIONS, "flash_written": False, "samples": [], "restored": False}
    session = ConnectHelper.session_with_chosen_probe(blocking=False, unique_id="012345ABCDEF", options=OPTIONS)
    if session is None:
        raise RuntimeError("known debug probe not found")
    try:
        with session:
            target = session.target

            def write(address, value):
                if address not in (CTL1, SAMPT0, RSQ2):
                    raise RuntimeError("write outside volatile ADC whitelist")
                target.write32(address, value)
                target.flush()

            def capture(phase):
                points = []
                for _ in range(60):
                    if target.get_state() != Target.State.RUNNING:
                        raise RuntimeError("core no longer running")
                    point = dict(phase=phase, host_monotonic_s=time.monotonic(),
                        rdata=target.read32(RDATA) & 4095, g_adc=target.read16(G_ADC))
                    points.append(point)
                    result["samples"].append(point)
                    time.sleep(.01)
                summary = {field: statistics.median(p[field] for p in points) for field in ("rdata", "g_adc")}
                result[phase] = summary
                print(phase + " " + json.dumps(summary), flush=True)

            flash_hash = lambda: hashlib.sha256(bytes(target.read_memory_block8(0x08000000, 4096))).hexdigest()
            result["flash_sha256_before"] = flash_hash()
            expected = hashlib.sha256((OUT / "gd32_current_flash.bin").read_bytes()).hexdigest()
            if result["flash_sha256_before"] != expected:
                raise RuntimeError("runtime Flash does not match current verified readback")
            saved = {address: target.read32(address) for address in (CTL1, SAMPT0, RSQ2)}
            result["saved_registers"] = {hex(a): hex(v) for a, v in saved.items()}
            if saved[RSQ2] & 31 != 8 or not saved[CTL1] & ADCON or saved[CTL1] & 12:
                raise RuntimeError("unexpected angle channel, disabled ADC or calibration in progress")
            try:
                capture("channel8_before")
                write(CTL1, saved[CTL1] & ~(ADCON | COMMAND_BITS))
                write(SAMPT0, (saved[SAMPT0] & ~(7 << 21)) | (7 << 21))
                write(RSQ2, (saved[RSQ2] & ~31) | 17)
                write(CTL1, (saved[CTL1] & ~COMMAND_BITS) | TSVREN)
                time.sleep(.01)
                write(CTL1, target.read32(CTL1) | SWRCST)
                time.sleep(.05)
                capture("internal_reference17")
            except Exception as exc:
                result["probe_error"] = repr(exc)
            finally:
                result["restore_errors"] = []
                for attempt in range(1, 4):
                    try:
                        # Use saved state so a failed read cannot prevent restoration.
                        write(CTL1, saved[CTL1] & ~(ADCON | COMMAND_BITS))
                        write(SAMPT0, saved[SAMPT0])
                        write(RSQ2, saved[RSQ2])
                        write(CTL1, saved[CTL1] & ~COMMAND_BITS)
                        time.sleep(.01)
                        write(CTL1, (saved[CTL1] & ~COMMAND_BITS) | SWRCST)
                        time.sleep(.05)
                        restored = {address: target.read32(address) for address in saved}
                        result["restored_registers"] = {hex(a): hex(v) for a, v in restored.items()}
                        result["restored"] = all((restored[a] & (~COMMAND_BITS if a == CTL1 else 0xFFFFFFFF)) ==
                            (saved[a] & (~COMMAND_BITS if a == CTL1 else 0xFFFFFFFF)) for a in saved)
                        if not result["restored"]:
                            raise RuntimeError("restored ADC registers differ from saved state")
                        break
                    except Exception as exc:
                        result["restore_errors"].append(dict(attempt=attempt, error=repr(exc)))
                        time.sleep(.05)
                if result["restored"]:
                    try:
                        capture("channel8_after")
                    except Exception as exc:
                        result["after_capture_error"] = repr(exc)
                # Attempt both checks independently, including on failed captures/restores.
                result["postcheck_errors"] = []
                result["flash_unchanged"] = result["core_running_after"] = False
                try:
                    result["flash_sha256_after"] = flash_hash()
                    result["flash_unchanged"] = result["flash_sha256_after"] == expected
                except Exception as exc:
                    result["postcheck_errors"].append("Flash: " + repr(exc))
                try:
                    result["core_running_after"] = target.get_state() == Target.State.RUNNING
                except Exception as exc:
                    result["postcheck_errors"].append("core state: " + repr(exc))
            phases = ("channel8_before", "internal_reference17", "channel8_after")
            complete = all(name in result for name in phases)
            result["control_pass"] = bool(complete and result["restored"] and result["flash_unchanged"] and
                result["core_running_after"] and not result["restore_errors"] and not result["postcheck_errors"] and
                "probe_error" not in result and "after_capture_error" not in result and all(
                    abs(result["internal_reference17"][field] - result["channel8_before"][field]) > 500 and
                    abs(result["channel8_after"][field] - result["channel8_before"][field]) < 100
                    for field in ("rdata", "g_adc")))
            print("CONTROL_PASS=" + str(result["control_pass"]), flush=True)
    except Exception as exc:
        result["error"] = str(exc)
        raise
    finally:
        destination.write_text(json.dumps(result, indent=2), encoding="utf-8")
    return 0 if result["control_pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
