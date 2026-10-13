#!/usr/bin/env python3
"""File-only segmentation probe; never opens a microphone or plays audio.

Generate a deterministic reference, let a person arrange the recording, then
decode captures locally to mono 16 kHz / 16-bit PCM WAV before alignment:
  python3 scripts/segment_probe.py generate --seconds 180 --out /tmp/reference.wav
  python3 scripts/segment_probe.py align --reference /tmp/reference.wav --captures /tmp/a.wav /tmp/b.wav
Requires NumPy. Correlation thresholds are provisional, not calibrated accuracy.
"""

import argparse
import json
import math
import sys
import wave
from pathlib import Path

try:
    import numpy as np
except ImportError:
    raise SystemExit("需要 NumPy；此工具不会自动安装依赖。") from None

RATE = 16_000
PROJECT_ROOT = Path(__file__).resolve().parents[1]


class ProbeError(ValueError):
    pass


def make_reference(seconds):
    if not 10 <= seconds <= 900:
        raise ProbeError("参考时长必须为 10–900 秒。")
    noise = np.random.default_rng(5339).standard_normal(int(seconds * RATE))
    return np.convolve(noise, [0.25, 0.5, 0.25], mode="same") * 2800


def write_wav(path, samples):
    with wave.open(str(path), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(RATE)
        writer.writeframes(np.clip(samples, -32768, 32767).astype("<i2").tobytes())


def read_wav(path):
    with wave.open(str(path), "rb") as reader:
        if (reader.getnchannels(), reader.getsampwidth(), reader.getframerate()) != (1, 2, RATE):
            raise ProbeError("输入须先解码为单声道、16 kHz、16-bit PCM WAV。")
        return np.frombuffer(reader.readframes(reader.getnframes()), dtype="<i2").astype(np.float64)


def locate(reference, query):
    query = query - query.mean()
    query_energy = float(np.sum(query * query))
    if query_energy <= 0:
        return 0, 0.0, 0.0
    width = len(query)
    size = 1 << (len(reference) + width - 1).bit_length()
    dots = np.fft.irfft(np.fft.rfft(reference, size) * np.conj(np.fft.rfft(query, size)), size)
    prefix = np.concatenate(([0.0], np.cumsum(reference)))
    prefix_squared = np.concatenate(([0.0], np.cumsum(reference * reference)))
    sums = prefix[width:] - prefix[:-width]
    energy = prefix_squared[width:] - prefix_squared[:-width] - sums * sums / width
    scores = np.clip(np.abs(dots[:len(energy)]) / np.sqrt(np.maximum(energy * query_energy, 1.0)), 0, 1)
    index = int(np.argmax(scores))
    best = float(scores[index])
    # Periodic sounds can correlate strongly at many positions; reject ambiguous anchors.
    scores[max(0, index - RATE // 10):index + RATE // 10 + 1] = 0
    return index, best, best - float(np.max(scores))


def align(reference, captures, minimum_correlation=0.35, tolerance_ms=20):
    if len(captures) < 2:
        raise ProbeError("至少需要两个按录制顺序排列的片段。")
    if not 0 < minimum_correlation <= 1 or not math.isfinite(tolerance_ms) or tolerance_ms < 0:
        raise ProbeError("相关度须在 (0, 1]，容差须非负。")
    output = []
    for index, captured in enumerate(captures, 1):
        if len(captured) < RATE * 3 or len(captured) > len(reference):
            raise ProbeError("每段须至少 3 秒，且不能长于参考音轨。")
        head, head_score, head_margin = locate(reference, captured[:RATE])
        tail, tail_score, tail_margin = locate(reference, captured[-RATE:])
        clock_ratio = (tail - head) / (len(captured) - RATE)
        usable = (min(head_score, tail_score) >= minimum_correlation
                  and min(head_margin, tail_margin) >= 0.03 and 0.98 < clock_ratio < 1.02)
        output.append({
            "segment_index": index, "alignment_status": "aligned" if usable else "unknown",
            "head_reference_seconds": head / RATE if usable else None,
            "end_reference_seconds": (tail + RATE * clock_ratio) / RATE if usable else None,
            "head_correlation": head_score, "tail_correlation": tail_score,
            "head_peak_margin": head_margin, "tail_peak_margin": tail_margin,
            "estimated_clock_ratio": clock_ratio if usable else None,
        })
    boundaries = []
    for index, (previous, following) in enumerate(zip(output, output[1:]), 1):
        gap = None
        status = "unknown"
        if previous["alignment_status"] == following["alignment_status"] == "aligned":
            gap = following["head_reference_seconds"] - previous["end_reference_seconds"]
            status = "gap" if gap > tolerance_ms / 1000 else "overlap" if gap < -tolerance_ms / 1000 else "within_tolerance"
        boundaries.append({"boundary_index": index, "aligned_gap_seconds": gap, "status": status})
    statuses = {boundary["status"] for boundary in boundaries}
    verdict = "unknown" if "unknown" in statuses else "discontinuity" if statuses != {"within_tolerance"} else "within_tolerance"
    return {
        "schemaVersion": 1, "sampleRate": RATE, "toleranceMilliseconds": tolerance_ms,
        "verdict": verdict, "segments": output, "boundaries": boundaries,
        "meaning": "正值为相邻锚点间缺失的参考区间，负值为重复参考区间；不使用录音索引时间戳。",
        "limits": "相关度不是准确率；声学路径、AAC 裁切和时钟漂移需实测。边界对齐不验证片段内部连续性。",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description="离线分段参考声源生成与边界对齐；不开麦、不播放。")
    sub = parser.add_subparsers(dest="command", required=True)
    generator = sub.add_parser("generate")
    generator.add_argument("--seconds", type=int, default=180)
    generator.add_argument("--out", required=True)
    alignment = sub.add_parser("align")
    alignment.add_argument("--reference", required=True)
    alignment.add_argument("--captures", nargs="+", required=True)
    alignment.add_argument("--min-correlation", type=float, default=0.35)
    alignment.add_argument("--tolerance-ms", type=float, default=20)
    args = parser.parse_args(argv)
    try:
        if args.command == "generate":
            destination = Path(args.out).expanduser()
            if not destination.is_absolute() or destination.resolve().is_relative_to(PROJECT_ROOT):
                raise ProbeError("参考文件须使用工程外的绝对路径。")
            if destination.exists():
                raise ProbeError("输出已存在，请选择新文件。")
            write_wav(destination, make_reference(args.seconds))
            print(json.dumps({"generatedSeconds": args.seconds, "sampleRate": RATE, "audioDeviceUsed": False}))
            return 0
        report = align(read_wav(args.reference), [read_wav(path) for path in args.captures],
                       args.min_correlation, args.tolerance_ms)
        print(json.dumps(report, ensure_ascii=False))
        return 0 if report["verdict"] == "within_tolerance" else 2 if report["verdict"] == "discontinuity" else 3
    except ProbeError as error:
        print(str(error), file=sys.stderr)
    except (OSError, wave.Error):
        print("无法读写 PCM WAV 文件。", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
