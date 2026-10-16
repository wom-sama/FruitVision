import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_models


class DownloadTests(unittest.TestCase):
    def test_verified_download_commits_complete_file(self):
        data = b"independently known model fixture"
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "nested/model.pth"
            with patch("urllib.request.urlopen", return_value=io.BytesIO(data)):
                prepare_models.download_checked("https://download.pytorch.org/models/test.pth", destination, hashlib.sha256(data).hexdigest())
            self.assertEqual(destination.read_bytes(), data)
            self.assertEqual([p.name for p in destination.parent.iterdir()], ["model.pth"])

    def test_hash_mismatch_never_replaces_existing_file(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "model.pth"
            destination.write_bytes(b"preserved")
            with patch("urllib.request.urlopen", return_value=io.BytesIO(b"wrong download")):
                with self.assertRaisesRegex(RuntimeError, "SHA-256"):
                    prepare_models.download_checked("https://download.pytorch.org/models/test.pth", destination, "0" * 64)
            self.assertEqual(destination.read_bytes(), b"preserved")
            self.assertEqual(len(list(destination.parent.iterdir())), 1)

    def test_download_error_cleans_only_owned_partial_file(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "model.pth"
            with patch("urllib.request.urlopen", side_effect=TimeoutError("fixture timeout")):
                with self.assertRaises(TimeoutError):
                    prepare_models.download_checked("https://download.pytorch.org/models/test.pth", destination, "0" * 64)
            self.assertFalse(destination.exists())
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_verified_backbone_is_reused_without_network(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / "model.pth"
            destination.write_bytes(b"already verified")
            with patch("urllib.request.urlopen", side_effect=AssertionError("network must not be used")):
                prepare_models.ensure_backbone(destination, hashlib.sha256(b"already verified").hexdigest())
            self.assertEqual(destination.read_bytes(), b"already verified")


if __name__ == "__main__":
    unittest.main()
