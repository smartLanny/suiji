import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path

import capture_soak


def timestamp(minutes=0):
    return (datetime(2026, 10, 13, tzinfo=timezone.utc) + timedelta(minutes=minutes)).isoformat().replace("+00:00", "Z")


def sample(minutes=0, **values):
    return {
        "timestamp": timestamp(minutes),
        "recorderCurrentTime": 30.0,
        "recorderIsRecording": True,
        "logicalIsRecording": True,
        "elapsedEstimate": 30.0,
        "accumulatedDuration": 0.0,
        "batteryLevel": None,
        "batteryState": None,
        "scenePhase": "active",
        "isLuminanceReduced": False,
        "currentSegmentUUID": "11111111-2222-3333-4444-555555555555",
        **values,
    }


def snapshot(recordings=None, samples=None, events=None):
    return {
        "schemaVersion": 1,
        "acquisition": {"device": "PRIVATE-DEVICE-ID"},
        "manifest": {"version": 1, "recordings": recordings or []},
        "diagnostics": {"version": 1, "samples": samples or [], "events": events or []},
    }


class CaptureSoakTests(unittest.TestCase):
    def test_legacy_manifest_rows_are_not_misreported_as_explicit_quick(self):
        report = capture_soak.build_report(snapshot(recordings=[{
            "source": "watch",
            "captureState": "ready",
            "duration": 125,
            "recordedAt": 815_443_200,
        }]))

        manifest = report["manifest"]
        self.assertEqual(manifest["modeCounts"], {"legacy_default_quick": 1})
        self.assertEqual(manifest["rowsMissingModeField"], 1)
        self.assertEqual(manifest["watchSavedSegmentDurationSeconds"], 125)
        self.assertEqual(manifest["watchContinuousSegmentDurationSeconds"], 0)

    def test_missing_sample_interval_is_not_interpreted_as_stopped(self):
        report = capture_soak.build_report(snapshot(samples=[
            sample(0), sample(5),
        ]))

        recorder = report["recorderSamples"]
        self.assertEqual(recorder["recorderTrueSamples"], 2)
        self.assertEqual(recorder["recorderFalseSamples"], 0)
        self.assertEqual(recorder["gapsOverTwoMinutes"], 1)
        self.assertIn("不能证明", recorder["interpretation"])

    def test_explicit_false_is_reported_as_a_sample(self):
        report = capture_soak.build_report(snapshot(samples=[
            sample(0), sample(1, recorderIsRecording=False, logicalIsRecording=False),
        ]))

        recorder = report["recorderSamples"]
        self.assertEqual(recorder["recorderFalseSamples"], 1)
        self.assertEqual(recorder["stateTransitions"][-1]["recorderIsRecording"], False)
        self.assertIn("采样时刻", recorder["interpretation"])

    def test_any_charging_sample_invalidates_battery_rate(self):
        report = capture_soak.build_report(snapshot(samples=[
            sample(0, batteryLevel=0.8, batteryState="UIDeviceBatteryState.charging"),
            sample(60, batteryLevel=0.7, batteryState="UIDeviceBatteryState.unplugged"),
        ]))

        self.assertEqual(report["battery"]["status"], "invalid_charging_sample")
        self.assertIsNone(report["battery"]["dropPercentagePointsPerHour"])
        self.assertIn("未做续航外推", report["battery"]["enduranceProjection"])

    def test_short_unplugged_interval_reports_endpoints_but_no_hourly_rate(self):
        samples = [
            sample(minute, batteryLevel=0.8 - (0.05 * minute / 30),
                   batteryState="UIDeviceBatteryState.unplugged")
            for minute in range(31)
        ]
        report = capture_soak.build_report(snapshot(samples=samples))

        battery = report["battery"]
        self.assertEqual(battery["status"], "valid_unplugged_interval_under_60m")
        self.assertEqual(battery["startBatteryPercent"], 80.0)
        self.assertEqual(battery["endBatteryPercent"], 75.0)
        self.assertEqual(battery["consumedPercentagePoints"], 5.0)
        self.assertIsNone(battery["dropPercentagePointsPerHour"])
        self.assertNotIn("hoursRemaining", json.dumps(battery))
        self.assertIn("24 小时", battery["enduranceProjection"])

    def test_sixty_minute_unplugged_interval_is_the_minimum_for_hourly_rate(self):
        samples = [
            sample(minute, batteryLevel=0.8 - (0.05 * minute / 60),
                   batteryState="unplugged")
            for minute in range(61)
        ]
        battery = capture_soak.build_report(snapshot(samples=samples))["battery"]
        self.assertEqual(battery["status"], "valid_unplugged_interval")
        self.assertEqual(battery["dropPercentagePointsPerHour"], 5.0)

    def test_watch_connectivity_false_means_only_currently_unreachable(self):
        report = capture_soak.build_report(snapshot(samples=[
            sample(0, watchConnectivityReachable=False,
                   watchConnectivityActivationState="WCSessionActivationState.activated",
                   watchOutstandingFileTransfers=2),
            sample(1, watchConnectivityReachable=True,
                   watchConnectivityActivationState="activated",
                   watchOutstandingFileTransfers=0),
        ]))

        connectivity = report["recorderSamples"]["watchConnectivity"]
        self.assertEqual(connectivity["currentlyUnreachableSamples"], 1)
        self.assertEqual(connectivity["reachableSamples"], 1)
        self.assertEqual(connectivity["activationStateCounts"], {"activated": 2})
        self.assertEqual(connectivity["outstandingFileTransfersMin"], 0)
        self.assertEqual(connectivity["outstandingFileTransfersMax"], 2)
        self.assertIn("当前不可达", connectivity["falseMeaning"])
        self.assertIn("不等同于无线断连", connectivity["falseMeaning"])

    def test_since_defaults_to_diagnostics_start_and_filters_every_timeline(self):
        raw = snapshot(
            recordings=[
                {"source": "watch", "captureState": "ready", "mode": "continuous",
                 "duration": 100, "recordedAt": timestamp(0)},
                {"source": "watch", "captureState": "ready", "mode": "continuous",
                 "duration": 30, "recordedAt": timestamp(3)},
            ],
            samples=[sample(0), sample(2), sample(3, recorderIsRecording=False)],
            events=[
                {"timestamp": timestamp(1), "event": "lifecycle"},
                {"timestamp": timestamp(3), "event": "lifecycle"},
            ],
        )
        raw["diagnostics"]["test"] = {"startedAt": timestamp(2)}

        report = capture_soak.build_report(raw)

        self.assertEqual(report["scope"]["kind"], "bounded")
        self.assertEqual(report["scope"]["source"], "diagnostics_test_startedAt")
        self.assertEqual(report["manifest"]["recordCount"], 1)
        self.assertEqual(report["manifest"]["watchContinuousSegmentDurationSeconds"], 30)
        self.assertEqual(report["recorderSamples"]["sampleCount"], 2)
        self.assertEqual(report["recorderSamples"]["eventCount"], 1)

    def test_explicit_since_overrides_diagnostics_start(self):
        raw = snapshot(
            recordings=[
                {"source": "watch", "captureState": "ready", "duration": 10, "recordedAt": timestamp(1)},
                {"source": "watch", "captureState": "ready", "duration": 20, "recordedAt": timestamp(3)},
                {"source": "watch", "captureState": "ready", "duration": 30, "recordedAt": timestamp(4)},
            ],
            samples=[sample(1), sample(3), sample(4)],
        )
        raw["diagnostics"]["test"] = {"startedAt": timestamp(3), "completedAt": timestamp(3.5), "deadline": timestamp(5)}
        report = capture_soak.build_report(raw, since=timestamp(1))

        self.assertEqual(report["scope"]["kind"], "bounded")
        self.assertEqual(report["scope"]["source"], "explicit_since")
        self.assertIsNone(report["scope"]["untilUTC"])
        self.assertEqual(report["scope"]["endSource"], "none_explicit_since_lower_bound")
        self.assertEqual(report["manifest"]["recordCount"], 3)
        self.assertEqual(report["recorderSamples"]["sampleCount"], 3)

    def test_automatic_window_falls_back_to_deadline(self):
        raw = snapshot(
            recordings=[
                {"source": "watch", "captureState": "ready", "duration": 10, "recordedAt": timestamp(1)},
                {"source": "watch", "captureState": "ready", "duration": 20, "recordedAt": timestamp(4)},
            ],
            samples=[sample(1), sample(4)],
        )
        raw["diagnostics"]["test"] = {"startedAt": timestamp(0), "deadline": timestamp(3)}

        report = capture_soak.build_report(raw)

        self.assertEqual(report["scope"]["endSource"], "diagnostics_test_deadline")
        self.assertEqual(report["scope"]["untilUTC"], "2026-10-13T00:03:00Z")
        self.assertEqual(report["manifest"]["recordCount"], 1)
        self.assertEqual(report["recorderSamples"]["sampleCount"], 1)

    def test_missing_test_start_reports_all_history_scope(self):
        report = capture_soak.build_report(snapshot())
        self.assertEqual(report["scope"]["kind"], "all_history")
        self.assertIsNone(report["scope"]["sinceUTC"])

    def test_report_omits_ids_transcripts_and_event_details(self):
        secret_id = "12345678-1234-5678-9abc-1234567890ab"
        private_transcript = "PRIVATE TRANSCRIPT: appointment at home"
        raw = snapshot(
            recordings=[{
                "id": secret_id,
                "source": "watch",
                "captureState": "ready",
                "duration": 12,
                "recordedAt": 815_443_200,
                "transcript": private_transcript,
                "fileName": secret_id + ".m4a",
            }],
            samples=[sample(0)],
            events=[{"timestamp": timestamp(), "event": "lifecycle", "details": {"private": private_transcript}}],
        )

        report = capture_soak.build_report(raw)
        serialized = json.dumps(report, ensure_ascii=False)
        markdown = capture_soak._markdown(report)
        self.assertNotIn(secret_id, serialized)
        self.assertNotIn(private_transcript, serialized)
        self.assertNotIn("PRIVATE-DEVICE-ID", serialized)
        self.assertNotIn("currentSegmentUUID", serialized)
        self.assertNotIn(secret_id, markdown)
        self.assertNotIn(private_transcript, markdown)
        self.assertNotIn("PRIVATE-DEVICE-ID", markdown)

    def test_user_labels_are_explicit_and_uuid_scrubbed(self):
        report = capture_soak.build_report(
            snapshot(), ["屏幕熄灭 UUID 12345678-1234-5678-9abc-1234567890ab Watch 00000000-0000000000000001"]
        )

        label = report["scenarioLabels"][0]
        self.assertEqual(label["source"], "user_asserted")
        self.assertNotIn("12345678-1234-5678-9abc-1234567890ab", label["label"])
        self.assertNotIn("00000000-0000000000000001", label["label"])

    def test_file_decode_evidence_is_pending_without_audio_transfer(self):
        report = capture_soak.build_report(snapshot())
        self.assertEqual(report["fileDecodeEvidence"]["status"], "not_collected")
        self.assertIn("待验证", report["fileDecodeEvidence"]["description"])

    def test_report_cli_handles_snapshot_without_diagnostics_samples(self):
        with tempfile.TemporaryDirectory(prefix="suiji-soak-cli-test-") as temporary_directory:
            temporary = Path(temporary_directory)
            snapshot_path = temporary / "snapshot.json"
            snapshot_path.write_text(json.dumps({
                "schemaVersion": 1,
                "manifest": {"version": 1, "recordings": []},
                "diagnostics": None,
            }), encoding="utf-8")
            report_base = temporary / "report"

            with redirect_stdout(io.StringIO()):
                result = capture_soak.main([
                    "report", "--snapshot", str(snapshot_path), "--out", str(report_base),
                    "--since", timestamp(), "--label", "CLI 空诊断快照",
                ])

            self.assertEqual(result, 0)
            report_json = json.loads(report_base.with_suffix(".json").read_text(encoding="utf-8"))
            report_markdown = report_base.with_suffix(".md").read_text(encoding="utf-8")
            self.assertEqual(report_json["scope"]["kind"], "bounded")
            self.assertEqual(report_json["recorderSamples"]["watchConnectivity"]["availableSamples"], 0)
            self.assertIn("没有可用诊断样本", report_markdown)

    def test_report_cli_bounds_auto_window_and_marks_whole_crossing_segments(self):
        with tempfile.TemporaryDirectory(prefix="suiji-soak-window-cli-test-") as temporary_directory:
            temporary = Path(temporary_directory)
            snapshot_path = temporary / "snapshot.json"
            raw = snapshot(
                recordings=[
                    {"source": "watch", "captureState": "ready", "mode": "continuous",
                     "duration": 120, "recordedAt": timestamp(-1)},
                    {"source": "watch", "captureState": "ready", "mode": "continuous",
                     "duration": 30, "recordedAt": timestamp(1)},
                    {"source": "watch", "captureState": "ready", "mode": "continuous",
                     "duration": 180, "recordedAt": timestamp(4)},
                    {"source": "watch", "captureState": "ready", "mode": "continuous",
                     "duration": 20, "recordedAt": timestamp(6)},
                ],
                samples=[sample(0), sample(5), sample(6)],
                events=[
                    {"timestamp": timestamp(2), "event": "lifecycle"},
                    {"timestamp": timestamp(6), "event": "lifecycle"},
                ],
            )
            raw["diagnostics"]["test"] = {
                "startedAt": timestamp(0),
                "completedAt": timestamp(5),
                "deadline": timestamp(10),
            }
            snapshot_path.write_text(json.dumps(raw), encoding="utf-8")
            report_base = temporary / "bounded-report"

            with redirect_stdout(io.StringIO()):
                result = capture_soak.main([
                    "report", "--snapshot", str(snapshot_path), "--out", str(report_base),
                ])

            self.assertEqual(result, 0)
            report_json = json.loads(report_base.with_suffix(".json").read_text(encoding="utf-8"))
            report_markdown = report_base.with_suffix(".md").read_text(encoding="utf-8")
            self.assertEqual(report_json["scope"]["kind"], "bounded")
            self.assertEqual(report_json["scope"]["sinceUTC"], "2026-10-13T00:00:00Z")
            self.assertEqual(report_json["scope"]["untilUTC"], "2026-10-13T00:05:00Z")
            self.assertEqual(report_json["scope"]["endSource"], "diagnostics_test_completedAt")
            self.assertEqual(report_json["scope"]["excludedRecordsCrossingStart"], 1)
            self.assertEqual(report_json["manifest"]["recordCount"], 2)
            self.assertEqual(report_json["manifest"]["watchContinuousSegmentDurationSeconds"], 210)
            self.assertEqual(report_json["manifest"]["windowBoundaryCrossingSegmentCount"], 1)
            self.assertEqual(report_json["manifest"]["testWindowMinutes"], 5)
            self.assertEqual(report_json["manifest"]["selectedSegmentSpanMinutes"], 6)
            self.assertEqual(report_json["recorderSamples"]["sampleCount"], 2)
            self.assertEqual(report_json["recorderSamples"]["eventCount"], 1)
            self.assertIn("跨终点片段仍整段计入并单独标记", report_json["manifest"]["durationMeaning"])
            self.assertIn("终点（UTC）", report_markdown)
            self.assertIn("不等同于窗口内完整音频时长", report_markdown)
            self.assertIn("测试窗口长度：5 分钟", report_markdown)

    def test_output_path_inside_project_is_rejected(self):
        with self.assertRaises(capture_soak.SoakError):
            capture_soak._user_output_path(str(capture_soak.PROJECT_ROOT / "soak-snapshot.json"))


if __name__ == "__main__":
    unittest.main()
