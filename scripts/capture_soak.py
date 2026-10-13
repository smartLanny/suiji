#!/usr/bin/env python3
"""Collect one local snapshot from a paired Suiji app and build a privacy-reduced report."""

from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BUNDLE_ID = "com.lann.suiji"
DEFAULT_MANIFEST_SOURCE = "Library/Application Support/Suiji/recordings.json"
DEFAULT_DIAGNOSTICS_SOURCE = "Library/Application Support/Suiji/capture-diagnostics.json"
UUID_PATTERN = re.compile(
    r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"
)
WATCH_UDID_PATTERN = re.compile(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{16}\b")
LONG_HEX_ID_PATTERN = re.compile(r"(?i)\b[0-9a-f]{24,40}\b")


class SoakError(Exception):
    pass


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _user_output_path(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        raise SoakError("输出路径必须是绝对路径，请选择本机的临时目录或个人目录。")
    resolved = path.resolve()
    if _inside(resolved, PROJECT_ROOT):
        raise SoakError("为避免把长测数据写入代码库，请将输出路径放在工程目录之外。")
    if resolved.exists():
        raise SoakError(f"输出路径已存在，请换一个新路径：{resolved.name}")
    resolved.parent.mkdir(parents=True, exist_ok=True)
    return resolved


def _parse_timestamp(value: Any) -> datetime | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        numeric = float(value)
        try:
            # Swift JSONEncoder's default Date representation is seconds since 2001.
            if numeric < 1_000_000_000:
                return datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=numeric)
            return datetime.fromtimestamp(numeric, timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except ValueError:
        return None


def _number(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    result = float(value)
    return result if math.isfinite(result) else None


def _bool(value: Any) -> bool | None:
    return value if isinstance(value, bool) else None


def _nonnegative_integer(value: Any) -> int | None:
    number = _number(value)
    if number is None or number < 0 or not number.is_integer():
        return None
    return int(number)


def _activation_state(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.lower().replace(".", "").replace("_", "").replace("-", "").strip()
    for state in ("notactivated", "inactive", "activated"):
        if normalized.endswith(state):
            return state
    return None


def _clean_label(label: str) -> str:
    value = UUID_PATTERN.sub("[已省略标识]", label.strip())
    value = WATCH_UDID_PATTERN.sub("[已省略设备标识]", value)
    value = LONG_HEX_ID_PATTERN.sub("[已省略设备标识]", value)
    return value[:160]


def _run_devicectl_copy(
    device: str,
    bundle_id: str,
    remote_source: str,
    destination: Path,
    timeout: int,
) -> tuple[int | None, str]:
    command = [
        "xcrun", "devicectl", "device", "copy", "from",
        "--device", device,
        "--source", remote_source,
        "--domain-type", "appDataContainer",
        "--domain-identifier", bundle_id,
        "--destination", str(destination),
        "--timeout", str(timeout),
        "--quiet",
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout + 15, check=False)
        return result.returncode, ""
    except subprocess.TimeoutExpired:
        return None, "timeout"
    except OSError:
        return None, "unavailable"


def _load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SoakError(f"无法读取 JSON 文件：{path.name}") from exc


def collect_snapshot(
    device: str,
    output: Path,
    bundle_id: str = DEFAULT_BUNDLE_ID,
    diagnostics_source: str = DEFAULT_DIAGNOSTICS_SOURCE,
    skip_diagnostics: bool = False,
    timeout: int = 90,
) -> None:
    if not device.strip():
        raise SoakError("必须通过 --device 在运行时指定设备标识。")
    if output.exists():
        raise SoakError("快照输出文件已存在；请指定一个新路径。")

    with tempfile.TemporaryDirectory(prefix="suiji-soak-") as temporary_directory:
        temporary = Path(temporary_directory)
        manifest_path = temporary / "recordings.json"
        status, failure = _run_devicectl_copy(
            device, bundle_id, DEFAULT_MANIFEST_SOURCE, manifest_path, timeout
        )
        if status != 0:
            reason = "超时" if failure == "timeout" else "devicectl 无法读取"
            raise SoakError(f"{reason} recordings.json；请确认设备已连接并解锁。")
        manifest = _load_json(manifest_path)
        if not isinstance(manifest, dict) or not isinstance(manifest.get("recordings"), list):
            raise SoakError("recordings.json 格式无法识别。")

        diagnostics: Any = None
        diagnostics_status = "not_requested" if skip_diagnostics else "unavailable"
        if not skip_diagnostics:
            diagnostics_path = temporary / "capture-diagnostics.json"
            diag_result, diag_failure = _run_devicectl_copy(
                device, bundle_id, diagnostics_source, diagnostics_path, timeout
            )
            if diag_result == 0:
                try:
                    diagnostics = _load_json(diagnostics_path)
                    diagnostics_status = "captured" if isinstance(diagnostics, dict) else "invalid_format"
                    if diagnostics_status != "captured":
                        diagnostics = None
                except SoakError:
                    diagnostics_status = "invalid_json"
            else:
                diagnostics_status = "copy_timeout" if diag_failure == "timeout" else "unavailable"

        snapshot = {
            "schemaVersion": 1,
            "capturedAtUTC": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "acquisition": {
                "method": "xcrun devicectl device copy from",
                "appBundleIdentifier": bundle_id,
                "manifestStatus": "captured",
                "diagnosticsStatus": diagnostics_status,
            },
            "manifest": manifest,
            "diagnostics": diagnostics,
        }
        output.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _safe_mode(recording: dict[str, Any]) -> str:
    mode = recording.get("mode")
    if mode == "continuous":
        return "continuous"
    if mode == "quick":
        return "quick"
    if mode is None:
        return "legacy_default_quick"
    return "unknown"


def _manifest_summary(
    manifest: dict[str, Any],
    window_start: datetime | None = None,
    window_end: datetime | None = None,
) -> dict[str, Any]:
    recordings = manifest.get("recordings")
    if not isinstance(recordings, list):
        recordings = []
    modes: dict[str, int] = {}
    states: dict[str, int] = {}
    sources: dict[str, int] = {}
    saved_durations: list[tuple[dict[str, Any], float]] = []
    missing_mode = 0
    for item in recordings:
        if not isinstance(item, dict):
            continue
        mode = _safe_mode(item)
        modes[mode] = modes.get(mode, 0) + 1
        if "mode" not in item:
            missing_mode += 1
        state_value = item.get("captureState")
        state = state_value if isinstance(state_value, str) and state_value in {"recording", "ready", "interrupted"} else "unknown"
        states[state] = states.get(state, 0) + 1
        source_value = item.get("source")
        source = source_value if isinstance(source_value, str) and source_value in {"watch", "phone"} else "unknown"
        sources[source] = sources.get(source, 0) + 1
        duration = _number(item.get("duration"))
        if duration is not None and duration > 0 and state != "recording":
            saved_durations.append((item, duration))

    start_times: list[datetime] = []
    end_times: list[datetime] = []
    for item, duration in saved_durations:
        start = _parse_timestamp(item.get("recordedAt"))
        if start:
            start_times.append(start)
            end_times.append(start + timedelta(seconds=duration))
    span_minutes = None
    if start_times and end_times:
        span_minutes = round((max(end_times) - min(start_times)).total_seconds() / 60, 2)

    total_duration = sum(duration for _, duration in saved_durations)
    continuous_duration = sum(
        duration for item, duration in saved_durations if _safe_mode(item) == "continuous"
    )
    watch_duration = sum(
        duration for item, duration in saved_durations if item.get("source") == "watch"
    )
    watch_continuous_duration = sum(
        duration for item, duration in saved_durations
        if item.get("source") == "watch" and _safe_mode(item) == "continuous"
    )
    crossing_end_count = sum(
        1 for item, duration in saved_durations
        if window_end is not None
        and (start := _parse_timestamp(item.get("recordedAt"))) is not None
        and start <= window_end < start + timedelta(seconds=duration)
    )
    duration_meaning = (
        "已完成或中断片段的 manifest duration 字段求和；按 recordedAt 起点纳入，时长按整段计入、不按窗口边界裁切；"
        "不等同于窗口内完整音频时长或文件解码验证。"
    )
    if window_end is not None:
        duration_meaning += "跨终点片段仍整段计入并单独标记。"
    return {
        "recordCount": sum(1 for item in recordings if isinstance(item, dict)),
        "sourceCounts": dict(sorted(sources.items())),
        "modeCounts": dict(sorted(modes.items())),
        "captureStateCounts": dict(sorted(states.items())),
        "rowsMissingModeField": missing_mode,
        "savedSegmentDurationSeconds": round(total_duration, 2),
        "continuousSegmentDurationSeconds": round(continuous_duration, 2),
        "watchSavedSegmentDurationSeconds": round(watch_duration, 2),
        "watchContinuousSegmentDurationSeconds": round(watch_continuous_duration, 2),
        "windowBoundaryCrossingSegmentCount": crossing_end_count,
        "selectedSegmentSpanMinutes": span_minutes,
        "durationMeaning": duration_meaning,
        "testWindowMinutes": round((window_end - window_start).total_seconds() / 60, 2)
        if window_start is not None and window_end is not None else None,
    }


def _diagnostic_samples(diagnostics: Any) -> list[dict[str, Any]]:
    if not isinstance(diagnostics, dict) or not isinstance(diagnostics.get("samples"), list):
        return []
    normalized = []
    for source_order, raw in enumerate(diagnostics["samples"]):
        if not isinstance(raw, dict):
            normalized.append({"sourceOrder": source_order, "timestamp": None})
            continue
        timestamp = _parse_timestamp(raw.get("timestamp"))
        normalized.append({
            "sourceOrder": source_order,
            "timestamp": timestamp,
            "currentSegmentUUID": raw.get("currentSegmentUUID") if isinstance(raw.get("currentSegmentUUID"), str) else None,
            "recorderCurrentTime": _number(raw.get("recorderCurrentTime")),
            "meterLevel": _number(raw.get("meterLevel")),
            "recorderIsRecording": _bool(raw.get("recorderIsRecording")),
            "logicalIsRecording": _bool(raw.get("logicalIsRecording")),
            "elapsedEstimate": _number(raw.get("elapsedEstimate")),
            "accumulatedDuration": _number(raw.get("accumulatedDuration")),
            "batteryLevel": _number(raw.get("batteryLevel")),
            "batteryState": raw.get("batteryState"),
            "scenePhase": raw.get("scenePhase"),
            "isLuminanceReduced": _bool(raw.get("isLuminanceReduced")),
            "watchConnectivityReachable": _bool(raw.get("watchConnectivityReachable")),
            "watchConnectivityActivationState": _activation_state(raw.get("watchConnectivityActivationState")),
            "watchOutstandingFileTransfers": _nonnegative_integer(raw.get("watchOutstandingFileTransfers")),
        })
    return normalized


def _recorder_clock_stall_summary(samples: list[dict[str, Any]]) -> dict[str, Any]:
    candidates: list[tuple[float, int]] = []
    continuity_group: list[dict[str, Any]] = []

    def close_group() -> None:
        if len(continuity_group) < 3:
            continuity_group.clear()
            return

        start = 0
        candidate_end = -1
        candidate_best: tuple[float, int] | None = None
        for end, sample in enumerate(continuity_group):
            while (
                max(item["recorderCurrentTime"] for item in continuity_group[start:end + 1])
                - min(item["recorderCurrentTime"] for item in continuity_group[start:end + 1])
                > 0.05
            ):
                start += 1

            window = continuity_group[start:end + 1]
            span = (window[-1]["timestamp"] - window[0]["timestamp"]).total_seconds()
            if len(window) < 3 or span < 120:
                continue

            measured_candidate = (span, len(window))
            if candidate_best is None:
                candidate_best = measured_candidate
            elif candidate_end >= start:
                if measured_candidate > candidate_best:
                    candidate_best = measured_candidate
            else:
                candidates.append(candidate_best)
                candidate_best = measured_candidate
            candidate_end = end

        if candidate_best is not None:
            candidates.append(candidate_best)
        continuity_group.clear()

    for sample in sorted(samples, key=lambda item: item["sourceOrder"]):
        timestamp = sample.get("timestamp")
        segment_id = sample.get("currentSegmentUUID")
        recorder_time = sample.get("recorderCurrentTime")
        eligible = (
            isinstance(timestamp, datetime)
            and isinstance(segment_id, str)
            and bool(segment_id.strip())
            and sample.get("recorderIsRecording") is True
            and sample.get("logicalIsRecording") is True
            and recorder_time is not None
            and recorder_time >= 0
        )
        if not eligible:
            close_group()
            continue

        if continuity_group:
            previous = continuity_group[-1]
            gap = (timestamp - previous["timestamp"]).total_seconds()
            if (
                segment_id != previous["currentSegmentUUID"]
                or gap <= 0
                or gap > 150
            ):
                close_group()
        continuity_group.append(sample)
    close_group()

    longest_candidate = max(candidates, default=(0.0, 0), key=lambda item: (item[0], item[1]))

    return {
        "candidateCount": len(candidates),
        "longestSpanSeconds": round(longest_candidate[0], 1),
        "longestSampleCount": longest_candidate[1],
        "interpretation": (
            "仅提示 recorderCurrentTime 采样平台疑点，仍需实际文件解码或内容证据；"
            "0 个候选也不代表连续录音通过。"
        ),
    }


def _diagnostic_summary(samples: list[dict[str, Any]], event_count: int) -> dict[str, Any]:
    clock_stall = _recorder_clock_stall_summary(samples)
    samples = sorted(
        (sample for sample in samples if isinstance(sample.get("timestamp"), datetime)),
        key=lambda item: item["timestamp"],
    )
    if not samples:
        return {
            "available": False,
            "sampleCount": 0,
            "eventCount": event_count,
            "recorderClockStall": clock_stall,
            "watchConnectivity": {
                "availableSamples": 0,
                "reachableSamples": 0,
                "currentlyUnreachableSamples": 0,
                "falseMeaning": "当前不可达；不等同于无线断连。",
                "activationStateCounts": {},
                "outstandingFileTransfersMin": None,
                "outstandingFileTransfersMax": None,
            },
            "interpretation": "没有可用的 recorder 样本；缺少心跳或样本不能证明录音已停止。",
        }
    origin = samples[0]["timestamp"]
    gaps = [
        (right["timestamp"] - left["timestamp"]).total_seconds()
        for left, right in zip(samples, samples[1:])
    ]
    recorder_values = [sample["recorderIsRecording"] for sample in samples]
    logical_values = [sample["logicalIsRecording"] for sample in samples]
    transitions = []
    previous = None
    for sample in samples:
        value = sample["recorderIsRecording"]
        if value is None:
            continue
        if previous is None or previous != value:
            transitions.append({
                "minuteFromFirstSample": round((sample["timestamp"] - origin).total_seconds() / 60, 2),
                "recorderIsRecording": value,
                "logicalIsRecording": sample["logicalIsRecording"],
            })
        previous = value
    phases = sorted({
        sample["scenePhase"] for sample in samples
        if isinstance(sample["scenePhase"], str) and sample["scenePhase"] in {"active", "inactive", "background"}
    })
    activation_counts: dict[str, int] = {}
    for sample in samples:
        state = sample["watchConnectivityActivationState"]
        if state is not None:
            activation_counts[state] = activation_counts.get(state, 0) + 1
    reachable_values = [sample["watchConnectivityReachable"] for sample in samples]
    transfer_counts = [sample["watchOutstandingFileTransfers"] for sample in samples
                       if sample["watchOutstandingFileTransfers"] is not None]
    connectivity_samples = sum(
        sample["watchConnectivityReachable"] is not None
        or sample["watchConnectivityActivationState"] is not None
        or sample["watchOutstandingFileTransfers"] is not None
        for sample in samples
    )
    return {
        "available": True,
        "sampleCount": len(samples),
        "eventCount": event_count,
        "sampleWindowMinutes": round((samples[-1]["timestamp"] - origin).total_seconds() / 60, 2),
        "recorderTrueSamples": sum(value is True for value in recorder_values),
        "recorderFalseSamples": sum(value is False for value in recorder_values),
        "logicalTrueSamples": sum(value is True for value in logical_values),
        "logicalFalseSamples": sum(value is False for value in logical_values),
        "maxSampleGapMinutes": round(max(gaps, default=0) / 60, 2),
        "gapsOverTwoMinutes": sum(gap > 120 for gap in gaps),
        "maxRecorderCurrentTimeSeconds": _max_optional(sample["recorderCurrentTime"] for sample in samples),
        "maxMeterLevel": _max_optional(
            sample["meterLevel"] for sample in samples
            if sample["meterLevel"] is not None and 0 <= sample["meterLevel"] <= 1
        ),
        "maxElapsedEstimateSeconds": _max_optional(sample["elapsedEstimate"] for sample in samples),
        "recorderClockStall": clock_stall,
        "stateTransitions": transitions[:100],
        "observedScenePhases": phases,
        "luminanceReducedSamples": sum(sample["isLuminanceReduced"] is True for sample in samples),
        "watchConnectivity": {
            "availableSamples": connectivity_samples,
            "reachableSamples": sum(value is True for value in reachable_values),
            "currentlyUnreachableSamples": sum(value is False for value in reachable_values),
            "falseMeaning": "当前不可达；不等同于无线断连。",
            "activationStateCounts": dict(sorted(activation_counts.items())),
            "outstandingFileTransfersMin": min(transfer_counts) if transfer_counts else None,
            "outstandingFileTransfersMax": max(transfer_counts) if transfer_counts else None,
        },
        "interpretation": (
            "仅代表采样时刻的 recorder/logical 状态；样本间隔、心跳缺失或亮度降低状态都不能证明录音停止、息屏或断连。"
        ),
    }


def _max_optional(values: Any) -> float | None:
    valid = [value for value in values if value is not None]
    return round(max(valid), 2) if valid else None


def _battery_state(value: Any) -> str | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return {1: "unplugged", 2: "charging", 3: "full"}.get(value)
    if not isinstance(value, str):
        return None
    normalized = value.lower().replace(".", "").replace("_", "").replace("-", "").strip()
    if normalized.endswith("unplugged"):
        return "unplugged"
    if normalized.endswith("charging"):
        return "charging"
    if normalized.endswith("full"):
        return "full"
    return None


def _battery_summary(samples: list[dict[str, Any]]) -> dict[str, Any]:
    if not samples:
        return {
            "status": "unavailable",
            "validSampleCount": 0,
            "dropPercentagePointsPerHour": None,
            "enduranceProjection": "未做续航外推或 24 小时达标预测。",
        }

    normalized = []
    charging_seen = False
    unknown_state_seen = False
    for sample in samples:
        level = sample["batteryLevel"]
        state = _battery_state(sample["batteryState"])
        if state in {"charging", "full"}:
            charging_seen = True
        elif (level is not None and 0 <= level <= 1) and state != "unplugged":
            unknown_state_seen = True
        normalized.append((sample["timestamp"], level, state))

    if charging_seen:
        status = "invalid_charging_sample"
    elif unknown_state_seen:
        status = "invalid_or_unknown_battery_state"
    else:
        status = "insufficient_samples"

    runs: list[list[tuple[datetime, float]]] = []
    current: list[tuple[datetime, float]] = []
    for timestamp, level, state in normalized:
        valid = state == "unplugged" and level is not None and 0 <= level <= 1
        if valid and current and (timestamp - current[-1][0]).total_seconds() > 150:
            runs.append(current)
            current = []
        if valid:
            current.append((timestamp, level))
        elif current:
            runs.append(current)
            current = []
    if current:
        runs.append(current)
    run = max(runs, key=lambda items: (items[-1][0] - items[0][0]).total_seconds(), default=[])

    result: dict[str, Any] = {
        "status": status,
        "validSampleCount": len(run),
        "intervalMinutes": None,
        "startBatteryPercent": None,
        "endBatteryPercent": None,
        "consumedPercentagePoints": None,
        "dropPercentagePointsPerHour": None,
        "enduranceProjection": "未做续航外推或 24 小时达标预测。",
    }
    if charging_seen or unknown_state_seen:
        return result
    if len(run) < 2:
        return result
    span_seconds = (run[-1][0] - run[0][0]).total_seconds()
    if span_seconds <= 0:
        return result
    drop_points = (run[0][1] - run[-1][1]) * 100
    result.update({
        "status": "valid_unplugged_interval" if span_seconds >= 3600 else "valid_unplugged_interval_under_60m",
        "intervalMinutes": round(span_seconds / 60, 2),
        "startBatteryPercent": round(run[0][1] * 100, 2),
        "endBatteryPercent": round(run[-1][1] * 100, 2),
        "consumedPercentagePoints": round(drop_points, 2),
    })
    if span_seconds >= 3600:
        result["dropPercentagePointsPerHour"] = round(drop_points / (span_seconds / 3600), 3)
    return result


def _parse_since_argument(value: str | None) -> datetime | None:
    if value is None:
        return None
    parsed = _parse_timestamp(value)
    if parsed is None or "T" not in value.upper():
        raise SoakError("--since 必须是包含时间的 ISO8601 时间戳，例如 2026-10-13T09:00:00+08:00。")
    return parsed


def _iso_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _filter_window(
    items: Any,
    since: datetime | None,
    until: datetime | None,
    timestamp_key: str,
    preserve_excluded_sample_breaks: bool = False,
) -> tuple[list[Any], int, int]:
    if not isinstance(items, list):
        return [], 0, 0
    if since is None and until is None:
        return items, 0, 0
    included = []
    excluded = 0
    excluded_crossing_start = 0
    for item in items:
        timestamp = _parse_timestamp(item.get(timestamp_key)) if isinstance(item, dict) else None
        if timestamp is None:
            excluded += 1
            if preserve_excluded_sample_breaks:
                included.append({"timestamp": None})
            continue
        if since is not None and timestamp < since:
            excluded += 1
            duration = _number(item.get("duration")) if isinstance(item, dict) else None
            if duration is not None and duration > 0 and timestamp + timedelta(seconds=duration) > since:
                excluded_crossing_start += 1
            if preserve_excluded_sample_breaks:
                included.append({"timestamp": None})
            continue
        if until is not None and timestamp > until:
            excluded += 1
            if preserve_excluded_sample_breaks:
                included.append({"timestamp": None})
            continue
        if timestamp is not None:
            included.append(item)
    return included, excluded, excluded_crossing_start


def build_report(
    snapshot: dict[str, Any],
    labels: list[str] | None = None,
    since: str | None = None,
) -> dict[str, Any]:
    manifest = snapshot.get("manifest")
    if not isinstance(manifest, dict) or not isinstance(manifest.get("recordings"), list):
        raise SoakError("快照中缺少有效 manifest。")
    diagnostics = snapshot.get("diagnostics")
    explicit_since = _parse_since_argument(since)
    diagnostics_test = diagnostics.get("test") if isinstance(diagnostics, dict) else None
    diagnostic_start = _parse_timestamp(diagnostics_test.get("startedAt")) if isinstance(diagnostics_test, dict) else None
    cutoff = explicit_since or diagnostic_start
    cutoff_source = "explicit_since" if explicit_since else "diagnostics_test_startedAt" if diagnostic_start else "all_history"
    window_end = None
    end_source = "none_explicit_since_lower_bound" if explicit_since else None
    if explicit_since is None and diagnostic_start and isinstance(diagnostics_test, dict):
        completed_at = _parse_timestamp(diagnostics_test.get("completedAt"))
        deadline = _parse_timestamp(diagnostics_test.get("deadline"))
        if completed_at and completed_at > diagnostic_start:
            window_end = completed_at
            end_source = "diagnostics_test_completedAt"
        elif deadline and deadline > diagnostic_start:
            window_end = deadline
            end_source = "diagnostics_test_deadline"

    filtered_recordings, excluded_recordings, excluded_crossing_start = _filter_window(
        manifest.get("recordings"), cutoff, window_end, "recordedAt"
    )
    filtered_manifest = dict(manifest)
    filtered_manifest["recordings"] = filtered_recordings
    filtered_diagnostics = dict(diagnostics) if isinstance(diagnostics, dict) else {}
    filtered_samples, excluded_samples, _ = _filter_window(
        filtered_diagnostics.get("samples"), cutoff, window_end, "timestamp",
        preserve_excluded_sample_breaks=True,
    )
    filtered_events, excluded_events, _ = _filter_window(
        filtered_diagnostics.get("events"), cutoff, window_end, "timestamp"
    )
    filtered_diagnostics["samples"] = filtered_samples
    filtered_diagnostics["events"] = filtered_events
    samples = _diagnostic_samples(filtered_diagnostics)
    battery_samples = sorted(
        (sample for sample in samples if isinstance(sample.get("timestamp"), datetime)),
        key=lambda item: item["timestamp"],
    )
    return {
        "schemaVersion": 1,
        "reportScope": "仅汇总所选快照可见证据；未对音频、设备连接或后台运行进行额外检测。",
        "scope": {
            "kind": "bounded" if cutoff else "all_history",
            "sinceUTC": _iso_utc(cutoff) if cutoff else None,
            "untilUTC": _iso_utc(window_end) if window_end else None,
            "source": cutoff_source,
            "endSource": end_source,
            "windowPolicy": "按 recordedAt 起点纳入；片段时长不裁切，跨边界片段单独计数。",
            "excludedOutsideWindowOrWithoutTimestamp": {
                "manifestRecords": excluded_recordings,
                "diagnosticSamples": excluded_samples,
                "diagnosticEvents": excluded_events,
            },
            "excludedRecordsCrossingStart": excluded_crossing_start,
        },
        "manifest": _manifest_summary(filtered_manifest, cutoff, window_end),
        "recorderSamples": _diagnostic_summary(samples, len(filtered_events)),
        "fileDecodeEvidence": {
            "status": "not_collected",
            "description": "快照未复制或解码音频文件；实际文件可读性仍待验证。",
        },
        "battery": _battery_summary(battery_samples),
        "scenarioLabels": [
            {"label": _clean_label(label), "source": "user_asserted"}
            for label in (labels or []) if label.strip()
        ],
    }


def _markdown(report: dict[str, Any]) -> str:
    manifest = report["manifest"]
    samples = report["recorderSamples"]
    battery = report["battery"]
    clock_stall = samples["recorderClockStall"]
    connectivity = samples.get("watchConnectivity") or {
        "availableSamples": 0,
        "reachableSamples": 0,
        "currentlyUnreachableSamples": 0,
        "falseMeaning": "当前不可达；不等同于无线断连。",
        "activationStateCounts": {},
        "outstandingFileTransfersMin": None,
        "outstandingFileTransfersMax": None,
    }
    lines = [
        "# 随记录音长测离线报告",
        "",
        "本报告只汇总用户指定快照中的记录索引和诊断样本；未进行真机持续轮询。",
        "",
        "## 报告范围",
        "",
        f"- scope：{report['scope']['kind']}",
        f"- 起点（UTC）：{report['scope']['sinceUTC'] or '无，使用快照中的全部历史记录'}",
        f"- 终点（UTC）：{report['scope']['untilUTC'] or ('无；显式 --since 仅作下界' if report['scope']['source'] == 'explicit_since' else '无')}",
        f"- 测试窗口长度：{_format_minutes(manifest['testWindowMinutes'])}",
        f"- 边界来源：起点 {report['scope']['source']}；终点 {report['scope']['endSource'] or '未设'}",
        f"- 片段纳入规则：{report['scope']['windowPolicy']}",
        f"- 起点前开始但延伸至窗口内、因此按 start-time 规则排除的片段：{report['scope']['excludedRecordsCrossingStart']}",
        f"- 因时间窗过滤或缺少时间戳而排除：{json.dumps(report['scope']['excludedOutsideWindowOrWithoutTimestamp'], ensure_ascii=False)}",
        "",
        "## 记录索引",
        "",
        f"- 记录条数：{manifest['recordCount']}",
        f"- 来源计数：{json.dumps(manifest['sourceCounts'], ensure_ascii=False)}",
        f"- 模式计数：{json.dumps(manifest['modeCounts'], ensure_ascii=False)}",
        f"- 状态计数：{json.dumps(manifest['captureStateCounts'], ensure_ascii=False)}",
        f"- 缺少 mode 字段的旧记录：{manifest['rowsMissingModeField']}",
        f"- 已保存片段时长合计：{manifest['savedSegmentDurationSeconds']} 秒",
        f"- continuous 模式片段时长合计：{manifest['continuousSegmentDurationSeconds']} 秒",
        f"- Watch 已保存片段时长合计：{manifest['watchSavedSegmentDurationSeconds']} 秒",
        f"- Watch continuous 片段时长合计：{manifest['watchContinuousSegmentDurationSeconds']} 秒",
        f"- 跨窗口终点的已选片段：{manifest['windowBoundaryCrossingSegmentCount']} 段（整段时长已计入）",
        f"- 已选片段记录起止跨度（包含整段跨界片段）：{_format_minutes(manifest['selectedSegmentSpanMinutes'])}",
        f"- 时长口径：{manifest['durationMeaning']}",
        "",
        "## Recorder 采样",
        "",
    ]
    if samples.get("available"):
        lines.extend([
            f"- 有效时间戳样本：{samples['sampleCount']}；诊断事件：{samples['eventCount']}",
            f"- recorder 为 true/false 的样本：{samples['recorderTrueSamples']} / {samples['recorderFalseSamples']}",
            f"- logical 状态为 true/false 的样本：{samples['logicalTrueSamples']} / {samples['logicalFalseSamples']}",
            f"- 采样窗口：{_format_minutes(samples['sampleWindowMinutes'])}；最大样本间隔：{_format_minutes(samples['maxSampleGapMinutes'])}",
            f"- 超过 2 分钟的采样间隔数：{samples['gapsOverTwoMinutes']}",
            f"- 最大 recorderCurrentTime：{_format_seconds(samples['maxRecorderCurrentTimeSeconds'])}",
            f"- 最大 meterLevel 采样：{samples['maxMeterLevel']}",
            f"- 最大 elapsedEstimate：{_format_seconds(samples['maxElapsedEstimateSeconds'])}",
            f"- 观测到的 scenePhase：{', '.join(samples['observedScenePhases']) or '无'}；luminance reduced 样本：{samples['luminanceReducedSamples']}",
        ])
        if connectivity["availableSamples"]:
            transfer_range = (
                f"{connectivity['outstandingFileTransfersMin']}–{connectivity['outstandingFileTransfersMax']}"
                if connectivity["outstandingFileTransfersMin"] is not None else "未知"
            )
            lines.append(
                f"- WatchConnectivity 样本：reachable true {connectivity['reachableSamples']}，"
                f"当前不可达 {connectivity['currentlyUnreachableSamples']}；"
                f"activationState 计数 {json.dumps(connectivity['activationStateCounts'], ensure_ascii=False)}；"
                f"待传文件数范围 {transfer_range}。"
            )
            lines.append(f"- 可达性边界：{connectivity['falseMeaning']}")
        else:
            lines.append("- 无 WatchConnectivity 采样（例如 iPhone 端该字段为 null）。")
        if samples["stateTransitions"]:
            lines.append("- recorder 状态首样本/变化采样：" + "; ".join(
                f"+{item['minuteFromFirstSample']} 分钟={str(item['recorderIsRecording']).lower()}"
                for item in samples["stateTransitions"]
            ))
    else:
        lines.append("- 没有可用诊断样本；不能据此判断录音器在测试窗口内的运行状态。")
    lines.extend([
        f"- 解读边界：{samples['interpretation']}",
        "",
        "## Recorder 时钟平台疑点",
        "",
        f"- 候选数：{clock_stall['candidateCount']}",
        f"- 最长候选：{clock_stall['longestSpanSeconds']} 秒、{clock_stall['longestSampleCount']} 个样本",
        f"- {clock_stall['interpretation']}",
        "",
        "## 文件解码证据",
        "",
        f"- {report['fileDecodeEvidence']['description']}",
        "",
        "## 电量",
        "",
    ])
    if battery["status"] == "valid_unplugged_interval":
        lines.append(
            f"- 未充电且数值有效样本：{battery['validSampleCount']}；区间 {battery['intervalMinutes']} 分钟，"
            f"起止 {battery['startBatteryPercent']}% → {battery['endBatteryPercent']}%，"
            f"净消耗 {battery['consumedPercentagePoints']} 个百分点；"
            f"观测掉电速率 {battery['dropPercentagePointsPerHour']} 个百分点/小时。"
        )
    elif battery["status"] == "valid_unplugged_interval_under_60m":
        lines.append(
            f"- 未充电且数值有效样本：{battery['validSampleCount']}；区间 {battery['intervalMinutes']} 分钟，"
            f"起止 {battery['startBatteryPercent']}% → {battery['endBatteryPercent']}%，"
            f"净消耗 {battery['consumedPercentagePoints']} 个百分点；区间短于 60 分钟，不换算每小时速率。"
        )
    elif battery["status"] == "invalid_charging_sample":
        lines.append("- 样本中混有充电或满电状态，本次掉电速率无效。")
    elif battery["status"] == "invalid_or_unknown_battery_state":
        lines.append("- 有效电量样本缺少可确认的未充电状态，本次掉电速率无效。")
    else:
        lines.append("- 未获得足够的未充电有效电量样本，无法计算掉电速率。")
    lines.extend([f"- {battery['enduranceProjection']}", ""])
    labels = report["scenarioLabels"]
    lines.extend(["## 场景注记", ""])
    if labels:
        lines.extend(f"- {item['label']}（user asserted）" for item in labels)
    else:
        lines.append("- 未提供用户自述场景标签。")
    lines.extend([
        "- scenePhase 和亮度降低值不等于自动检测到锁屏、断连或息屏。",
        "",
    ])
    return "\n".join(lines)


def _format_minutes(value: Any) -> str:
    return "未知" if value is None else f"{float(value):g} 分钟"


def _format_seconds(value: Any) -> str:
    return "未知" if value is None else f"{value} 秒"


def write_report(
    snapshot_path: Path,
    output: Path,
    labels: list[str] | None = None,
    since: str | None = None,
) -> tuple[Path, Path]:
    if output.exists():
        raise SoakError("报告输出路径已存在；请指定新路径。")
    if output.suffix.lower() == ".md":
        markdown_path = output
        json_path = output.with_suffix(".json")
    elif output.suffix.lower() == ".json":
        json_path = output
        markdown_path = output.with_suffix(".md")
    else:
        markdown_path = output.with_suffix(".md")
        json_path = output.with_suffix(".json")
    if markdown_path.exists() or json_path.exists():
        raise SoakError("Markdown 或 JSON 报告已存在；请指定新的输出名。")
    snapshot = _load_json(snapshot_path)
    if not isinstance(snapshot, dict):
        raise SoakError("快照文件格式无法识别。")
    report = build_report(snapshot, labels, since)
    markdown_path.write_text(_markdown(report), encoding="utf-8")
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return markdown_path, json_path


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="采集随记单次长测快照并生成隐私精简离线报告。")
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot", help="通过 devicectl 单次复制 manifest 和可选 diagnostics。")
    snapshot.add_argument("--device", required=True, help="运行时提供的设备标识；不会写入快照。")
    snapshot.add_argument(
        "--out", required=True,
        help="快照 JSON 的本机绝对路径，必须位于工程目录之外；原始 manifest 可能含转写和记录 ID，请留在本机。",
    )
    snapshot.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    snapshot.add_argument("--diagnostics-source", default=DEFAULT_DIAGNOSTICS_SOURCE)
    snapshot.add_argument("--skip-diagnostics", action="store_true")
    snapshot.add_argument("--timeout", type=int, default=90, help="每次 devicectl 读取的超时秒数。")

    report = subparsers.add_parser("report", help="从本机快照生成 Markdown 与 JSON 汇总。")
    report.add_argument("--snapshot", required=True, help="snapshot 子命令生成的本机 JSON 文件。")
    report.add_argument("--out", required=True, help="报告路径或 .md/.json 路径；必须位于工程目录之外。")
    report.add_argument("--label", action="append", default=[], help="用户自述场景标签；可重复指定。")
    report.add_argument("--since", help="ISO8601 起点；未指定时优先用 diagnostics.test.startedAt，否则使用全部历史。")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        output = _user_output_path(args.out)
        if args.command == "snapshot":
            if args.timeout < 1:
                raise SoakError("--timeout 必须大于 0。")
            collect_snapshot(
                args.device, output, bundle_id=args.bundle_id,
                diagnostics_source=args.diagnostics_source,
                skip_diagnostics=args.skip_diagnostics, timeout=args.timeout,
            )
            print(f"快照已写入：{output}")
        else:
            markdown_path, json_path = write_report(Path(args.snapshot).expanduser(), output, args.label, args.since)
            print(f"报告已写入：{markdown_path}\n{json_path}")
    except SoakError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
