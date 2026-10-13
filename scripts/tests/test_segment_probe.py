import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import numpy as np
import segment_probe as probe


class SegmentProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reference = probe.make_reference(40).astype("<i2").astype(np.float64)

    def capture(self, start, seconds=10):
        return self.reference[int(start * probe.RATE):int((start + seconds) * probe.RATE)]

    def test_contiguous_files_with_wav_round_trip(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = [Path(folder) / "one.wav", Path(folder) / "two.wav"]
            for path, start in zip(paths, [2, 12]):
                probe.write_wav(path, self.capture(start))
            result = probe.align(self.reference, [probe.read_wav(path) for path in paths])
        self.assertEqual(result["verdict"], "within_tolerance")
        self.assertAlmostEqual(result["boundaries"][0]["aligned_gap_seconds"], 0, places=5)

    def test_missing_reference_interval_is_detected(self):
        result = probe.align(self.reference, [self.capture(2), self.capture(13.5)])
        self.assertEqual(result["verdict"], "discontinuity")
        self.assertEqual(result["boundaries"][0]["status"], "gap")
        self.assertAlmostEqual(result["boundaries"][0]["aligned_gap_seconds"], 1.5, places=5)

    def test_overlap_is_reported_as_duplicate_audio(self):
        result = probe.align(self.reference, [self.capture(2), self.capture(11.75)])
        self.assertEqual(result["boundaries"][0]["status"], "overlap")
        self.assertAlmostEqual(result["boundaries"][0]["aligned_gap_seconds"], -0.25, places=5)

    def test_unrelated_noise_does_not_get_a_false_gap(self):
        noise = np.random.default_rng(912).standard_normal(10 * probe.RATE) * 2000
        result = probe.align(self.reference, [self.capture(2), noise])
        self.assertEqual(result["verdict"], "unknown")
        self.assertIsNone(result["boundaries"][0]["aligned_gap_seconds"])

    def test_silence_and_periodic_ambiguity_are_unknown(self):
        silence = np.zeros(10 * probe.RATE)
        result = probe.align(self.reference, [self.capture(2), silence])
        self.assertEqual(result["verdict"], "unknown")
        tone = np.sin(np.arange(40 * probe.RATE) * 2 * np.pi * 440 / probe.RATE) * 2000
        periodic = probe.align(tone, [tone[:10 * probe.RATE], tone[10 * probe.RATE:20 * probe.RATE]])
        self.assertEqual(periodic["verdict"], "unknown")

    def test_cli_output_has_no_input_paths_and_unknown_exit_code(self):
        with tempfile.TemporaryDirectory() as folder:
            paths = [Path(folder) / name for name in ["private-reference.wav", "private-one.wav", "private-two.wav"]]
            for path, samples in zip(paths, [self.reference, self.capture(2), np.zeros(10 * probe.RATE)]):
                probe.write_wav(path, samples)
            output = io.StringIO()
            with redirect_stdout(output):
                code = probe.main(["align", "--reference", str(paths[0]), "--captures", str(paths[1]), str(paths[2])])
        self.assertEqual(code, 3)
        self.assertEqual(json.loads(output.getvalue())["verdict"], "unknown")
        self.assertNotIn("private-", output.getvalue())


if __name__ == "__main__":
    unittest.main()
