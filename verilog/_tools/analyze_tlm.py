#!/usr/bin/env python3
"""Analyze captured 15-byte telemetry; never modify input captures."""
import argparse
import hashlib
import json
import statistics
import struct
from pathlib import Path

FRAME_LEN = 15
MODE = {0: "STOP", 1: "JUDGE", 2: "PUMP", 3: "BAL"}
# arm_adc_link: idle poll + 16 full SCK periods, at 50 MHz.
SPI_PERIOD_S = (2500 + 16 * 2 * 4) / 50_000_000


def decode_frame(raw):
    if len(raw) != FRAME_LEN or raw[0] != 0xA5:
        return None
    seq, flags, alpha, adot, duty, adc, enc, spi = struct.unpack(
        ">BBhhhHhH", raw[1:])
    # bit2 of the mode field carries mode_auto since 2026-10-31 (FSM states
    # only use bit0..1).  Mask with 3 so frames parse identically for old and
    # new captures; the plain (flags & 7) sanity check would reject every
    # AUTO frame (value 4..7).
    if adc > 4095 or abs(duty) > 10000:
        return None
    return dict(seq=seq, mode=flags & 3, auto=(flags >> 2) & 1, wdog=(flags >> 3) & 1,
                link=(flags >> 4) & 1, enable=(flags >> 5) & 1,
                braking=(flags >> 6) & 1, key=(flags >> 7) & 1,
                alpha=alpha, adot=adot, duty=duty, adc=adc, enc=enc, spi=spi)


def parse_capture(raw):
    frames = []
    pos = rejected = skipped = 0
    while pos < len(raw):
        start = raw.find(b"\xa5", pos)
        if start < 0:
            skipped += len(raw) - pos
            pos = len(raw)
            break
        skipped += start - pos
        if start + FRAME_LEN > len(raw):
            pos = start
            break
        frame = decode_frame(raw[start:start + FRAME_LEN])
        if frame is None:
            rejected += 1
            skipped += 1
            pos = start + 1
            continue
        frame["offset"] = start
        frames.append(frame)
        pos = start + FRAME_LEN
    last_end = frames[-1]["offset"] + FRAME_LEN if frames else 0
    return frames, dict(bytes=len(raw), valid_frames=len(frames),
                        skipped_bytes=skipped, rejected_candidates=rejected,
                        trailing_bytes=len(raw) - last_end,
                        partial_frame_bytes=len(raw) - pos)


def signed_delta(a, b):
    return (b - a + 32768) % 65536 - 32768


def analyze(raw):
    frames, result = parse_capture(raw)
    result.update(sha256=hashlib.sha256(raw).hexdigest(), spi_period_s=SPI_PERIOD_S,
                  sequence_breaks=[], timing_breaks=[], adc_jumps=[])
    for k, frame in enumerate(frames):
        frame.update(time_s=0.0, continuous=False)
        if k == 0:
            continue
        prev = frames[k - 1]
        seq_step = (frame["seq"] - prev["seq"]) % 256
        spi_step = (frame["spi"] - prev["spi"]) % 65536
        dt = spi_step * SPI_PERIOD_S
        if seq_step != 1:
            result["sequence_breaks"].append(k)
        contiguous_bytes = frame["offset"] == prev["offset"] + FRAME_LEN
        timing_ok = seq_step == 1 and contiguous_bytes and 0.015 <= dt <= 0.03
        if not timing_ok:
            result["timing_breaks"].append(k)
            dt = 0.021  # Marked display placeholder; gap duration is unknown.
        frame["continuous"] = timing_ok
        frame["time_s"] = prev["time_s"] + dt
        if timing_ok and abs(frame["adc"] - prev["adc"]) > 800:
            result["adc_jumps"].append(k)
    segments = []
    k = 0
    while k < len(frames):
        if frames[k]["mode"] != 3:
            k += 1
            continue
        start = k
        k += 1
        while k < len(frames) and frames[k]["mode"] == 3 and frames[k]["continuous"]:
            k += 1
        end = k - 1
        samples = frames[start:k]
        drift = sum(signed_delta(a["enc"], b["enc"])
                    for a, b in zip(samples, samples[1:]))
        segments.append(dict(start=start, end=end, samples=len(samples),
            start_s=frames[start]["time_s"],
            coverage_s=frames[end]["time_s"] - frames[start]["time_s"],
            alpha_mean_deg=statistics.mean(f["alpha"] for f in samples) / 100,
            alpha_min_deg=min(f["alpha"] for f in samples) / 100,
            alpha_max_deg=max(f["alpha"] for f in samples) / 100,
            enc_drift_counts=drift, watchdog_samples=sum(f["wdog"] for f in samples),
            adc_jumps=sum(start < j <= end for j in result["adc_jumps"]),
            end_observed=(k < len(frames) and frames[k]["continuous"]
                          and frames[k]["mode"] != 3)))
    result.update(segments=segments, sample_span_s=frames[-1]["time_s"] if frames else 0,
                  time_axis_continuous=not result["timing_breaks"],
                  link_bad_samples=sum(not f["link"] for f in frames))
    return frames, result


def write_outputs(source, frames, result, output):
    output.mkdir(parents=True, exist_ok=True)
    stem = output / source.stem
    metadata_path = Path(str(source) + ".meta.json")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8")) if metadata_path.exists() else None
    result["capture_metadata"] = metadata
    stem.with_suffix(".json").write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    lines = [f"# {source.name} 遥测分析", "", f"原件：`{source.resolve()}`",
        f"SHA256：`{result['sha256']}`", "",
        f"- 字节数 {result['bytes']}；有效帧 {result['valid_frames']}；跳过字节 {result['skipped_bytes']}；末帧后尾字节 {result['trailing_bytes']}（其中含帧头残帧 {result['partial_frame_bytes']}）。",
        f"- 非法候选帧 {result['rejected_candidates']}；序号异常 {len(result['sequence_breaks'])}；时间/字节连续性异常 {len(result['timing_breaks'])}。",
        f"- 样本时间轴覆盖 {result['sample_span_s']:.3f}s；SPI 帧周期依据当前 RTL = 52.56us。",
        f"- 连续帧 ADC 跳变（>800 counts）{len(result['adc_jumps'])} 次；link=0 样本 {result['link_bad_samples']}。", "",
        "时间轴只覆盖收到的样本。SPI计数模65536、seq模256；长中断/复位可能混叠。异常边界用21ms占位显示，不代表已测得间隔。协议没有CRC，合法字段不能证明内容未损坏。",
        "单帧覆盖记0秒；仅根据段短不能判定假捕获；末段如缺下一帧则无法证明结束时间。旧文件缺主机时间戳，无法证明主机窗口完整。", "",
        "| BAL段帧索引（0起） | 样本覆盖/s | 平均角度/° | 角度范围/° | enc漂移/counts | 看门狗样本 | ADC跳变 | 已观察退出 |",
        "|---|---:|---:|---|---:|---:|---:|---|"]
    for seg in result["segments"]:
        lines.append(f"| {seg['start']}–{seg['end']} | {seg['coverage_s']:.3f} | {seg['alpha_mean_deg']:.2f} | {seg['alpha_min_deg']:.2f}–{seg['alpha_max_deg']:.2f} | {seg['enc_drift_counts']} | {seg['watchdog_samples']} | {seg['adc_jumps']} | {'是' if seg['end_observed'] else '否'} |")
    if not result["segments"]:
        lines.extend(["", "没有观测到 BAL 样本。"])
    if metadata:
        lines.extend(["", "采集元信息：", "", "```json", json.dumps(metadata, ensure_ascii=False, indent=2), "```"])
    stem.with_suffix(".md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    if not frames:
        return
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    fig, axes = plt.subplots(4, 1, figsize=(13, 9), sharex=True)
    t = [f["time_s"] for f in frames]
    axes[0].plot(t, [f["alpha"] / 100 for f in frames], linewidth=.7, label="控制角度")
    axes[0].plot(t, [(f["adc"] - 2040) * 333 / 4096 for f in frames], alpha=.4, linewidth=.6, label="原始ADC换算（offset=2040）")
    axes[0].set_ylabel("摆角 / °")
    axes[0].legend(loc="upper right")
    axes[1].plot(t, [f["duty"] / 100 for f in frames], linewidth=.7)
    axes[1].set_ylabel("电机占空比 / %")
    axes[2].plot(t, [f["enc"] for f in frames], linewidth=.7)
    axes[2].set_ylabel("enc / counts\n(int16)")
    axes[3].step(t, [f["mode"] for f in frames], where="post", linewidth=.8)
    axes[3].set_yticks(list(MODE), list(MODE.values()))
    axes[3].set_ylabel("控制状态")
    axes[3].set_xlabel("相对板上样本时间 / s（异常间断占位，非主机窗口）")
    for ax in axes:
        ax.grid(alpha=.2)
        for seg in result["segments"]:
            ax.axvspan(seg["start_s"], seg["start_s"] + seg["coverage_s"], color="green", alpha=.1)
        for k in result["timing_breaks"]:
            ax.axvline(t[k], color="red", alpha=.5, linewidth=.6)
    longest = max((s["coverage_s"] for s in result["segments"]), default=0)
    fig.suptitle(f"{source.name} | {len(frames)}帧 | BAL最长样本覆盖 {longest:.2f}s\n"
                 f"序号异常 {len(result['sequence_breaks'])} | 尾字节 {result['trailing_bytes']} | 绿色=BAL")
    fig.tight_layout()
    fig.savefig(stem.with_suffix(".png"), dpi=150)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", nargs="+", type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    for source in args.captures:
        frames, result = analyze(source.read_bytes())
        write_outputs(source, frames, result, args.output_dir)
        print(f"{source.name}: {result['valid_frames']} frames, "
              f"seq_breaks={len(result['sequence_breaks'])}, tail={result['trailing_bytes']}, "
              f"BAL={len(result['segments'])}, span={result['sample_span_s']:.3f}s")


if __name__ == "__main__":
    main()
