import tempfile
import unittest
import json
import hashlib
from pathlib import Path

import numpy as np
import cv2
from PIL import Image

try:
    import demo
except ModuleNotFoundError:
    demo = None


class DemoTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(demo, "The folder inference runner has not been implemented")

    def test_discovery_supports_images_video_case_and_nested_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "nested").mkdir()
            for name in ("a.JPG", "b.MP4", "ignore.txt", "nested/c.png"):
                (root / name).touch()
            self.assertEqual([p.relative_to(root).as_posix() for p in demo.discover(root)],
                             ["a.JPG", "b.MP4", "nested/c.png"])

    def test_frame_step_caps_inference_rate_without_skipping_output_frames(self):
        self.assertEqual(demo.frame_step(30, 2), 15)
        self.assertEqual(demo.frame_step(6, 20), 1)
        with self.assertRaises(ValueError):
            demo.frame_step(30, 0)

    def test_no_detection_overlay_does_not_invent_class_or_box(self):
        frame = np.zeros((240, 320, 3), dtype=np.uint8)
        result = {"status": "NO_MANGO_DETECTED", "objects": []}
        rendered = demo.annotate(frame, result)
        self.assertEqual(rendered.shape, frame.shape)
        self.assertGreater(int(rendered.sum()), 0)
        self.assertEqual(result["objects"], [])

    def test_annotation_keeps_input_unchanged_and_writes_unicode_path(self):
        frame = np.zeros((240, 320, 3), dtype=np.uint8)
        result = {"status": "OK", "objects": [{"box_xyxy": [60, 70, 180, 200],
                  "class_id": 2, "score": .9}]}
        rendered = demo.annotate(frame, result)
        self.assertEqual(int(frame.sum()), 0)
        self.assertGreater(int(rendered.sum()), 0)
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "xoài thử.png"
            demo.save_rgb(target, rendered)
            with Image.open(target) as image:
                self.assertEqual(image.size, (320, 240))

    def test_odd_video_dimensions_are_padded_not_cropped(self):
        self.assertTrue(callable(getattr(demo, "pad_even", None)), "Odd-dimension video padding is not implemented")
        frame = np.full((241, 319, 3), 100, dtype=np.uint8)
        padded = demo.pad_even(frame)
        self.assertEqual(padded.shape, (242, 320, 3))
        np.testing.assert_array_equal(padded[:241, :319], frame)
        self.assertEqual(int(padded[-1].sum()), 0)

    def test_video_keeps_all_frames_and_logs_sampled_timestamps(self):
        # Only the slow GPU call is substituted; media decoding, scheduling,
        # annotation, MP4 encoding and JSONL output all use the real runner.
        class NoDetectionInference:
            def infer(self, rgb, mask_path):
                return {"status": "NO_MANGO_DETECTED", "objects": []}

        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            source = target / "fixture.mp4"
            writer = cv2.VideoWriter(str(source), cv2.VideoWriter_fourcc(*"mp4v"), 30., (320, 240))
            self.assertTrue(writer.isOpened())
            for index in range(150):
                writer.write(np.full((240, 320, 3), index % 255, dtype=np.uint8))
            writer.release()
            result = demo.process_video(source, target, NoDetectionInference(), 2)
            self.assertEqual(result["frames_written"], 150)
            self.assertEqual(result["inference_frames"], 10)
            rows = [json.loads(line) for line in (target / "predictions.jsonl").read_text().splitlines()]
            self.assertEqual(rows[1]["frame"], 15)
            self.assertEqual(rows[1]["time_seconds"], .5)
            capture = cv2.VideoCapture(str(target / "annotated.mp4"))
            decoded = 0
            while capture.read()[0]:
                decoded += 1
            self.assertEqual(decoded, 150)
            self.assertEqual(capture.get(cv2.CAP_PROP_FPS), 30.)
            capture.release()

    def test_artifact_validation_rejects_lfs_pointer_with_actionable_message(self):
        import importlib.util
        file = Path(__file__).parent / "prepare_models.py"
        self.assertTrue(file.is_file(), "Portable model preparation is missing")
        spec = importlib.util.spec_from_file_location("prepare_models_test", file)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            artifact = Path(tmp) / "checkpoint.pt"
            artifact.write_text("version https://git-lfs.github.com/spec/v1\noid sha256:123\nsize 500\n")
            with self.assertRaisesRegex(RuntimeError, "Git LFS pointer.*complete project asset"):
                module.check_artifact(artifact, "0000")
            artifact.write_bytes(b"known weights")
            module.check_artifact(artifact, hashlib.sha256(b"known weights").hexdigest())
            with self.assertRaisesRegex(RuntimeError, "SHA-256"):
                module.check_artifact(artifact, "0000")


if __name__ == "__main__":
    unittest.main()
