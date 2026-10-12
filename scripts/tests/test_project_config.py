import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import generate_project


class BackgroundAudioConfigurationTests(unittest.TestCase):
    def test_regeneration_preserves_supported_watch_audio_background_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            with patch.object(generate_project, "CONFIG_DIR", output):
                generate_project.write_info_plists()
            generated = plistlib.loads((output / "Info-watchOS.plist").read_bytes())
        committed = plistlib.loads((generate_project.ROOT / "Config/Info-watchOS.plist").read_bytes())
        for info in (generated, committed):
            self.assertIn("audio", info.get("UIBackgroundModes", []))
            self.assertNotIn("audio", info.get("WKBackgroundModes", []))


if __name__ == "__main__":
    unittest.main()
