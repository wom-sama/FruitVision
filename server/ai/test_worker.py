"""Small CPU tests; no model download or training."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import sys

import worker


def detection(box, stage=0, confidence=.9, score=.8, species=1):
    return worker.Detection(tuple(box), score, species, stage, confidence)


class WorkerTests(unittest.TestCase):
    def test_select_clips_before_nms_and_duplicates_do_not_consume_limit(self):
        # Original is 480x240 with 120px vertical padding. First two become identical.
        result, limited = worker.select_outputs(
            [[0, 0, 100, 200], [0, 100, 100, 200], [200, 140, 300, 200]],
            [.95, .9, .8], [1, 0, 2], [0, 1, 0],
            [[.9, .1], [.2, .8], [.5, .5]], worker.Transform(480, 240, 0, 120), limit=2)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0].box, (0., 0., 100 / 480, 80 / 240))
        self.assertEqual(result[1].stage, -1)
        self.assertFalse(limited)

    def test_nonfinite_and_invalid_stage_distribution_rejected(self):
        for box, stages in [([0, 0, float('nan'), 20], [.9, .1]),
                            ([0, 0, 20, 20], [.9, .9])]:
            with self.assertRaises(worker.WorkerError):
                worker.select_outputs([box], [.9], [1], [0], [stages],
                                      worker.Transform(480, 480, 0, 0))

    def test_unknown_species_and_weak_stage_are_ungraded(self):
        objects, _ = worker.select_outputs([[0, 0, 100, 100], [200, 200, 300, 300]],
            [.9, .9], [2, 1], [0, 0], [[.5, .5], [.55, .45]],
            worker.Transform(480, 480, 0, 0))
        self.assertEqual([x.as_object()['stageCode'] for x in objects], [-1, -1])

    def test_tracker_confirms_identity_votes_and_crosses_only_once(self):
        tracker = worker.Tracker()
        first = tracker.update(0, [detection([.2, .30, .5, .50])])[0]
        self.assertEqual(tracker.confirmed_count, 0)
        second = tracker.update(100, [detection([.2, .42, .5, .62])])[0]
        self.assertEqual(first.id, second.id)
        self.assertEqual(tracker.confirmed_count, 1)
        self.assertEqual(tracker.line_crossing_count, 1)
        tracker.update(200, [detection([.2, .38, .5, .58], stage=1, confidence=.7)])
        tracker.update(300, [detection([.2, .29, .5, .49], stage=1, confidence=.7)])
        self.assertEqual(tracker.line_crossing_count, 1)
        self.assertEqual(tracker.grade_counts(), {worker.STAGE_LABELS[0]: 1,
            worker.STAGE_LABELS[1]: 0, worker.UNKNOWN_LABEL: 0})

    def test_hungarian_does_not_steal_only_valid_match(self):
        self.assertEqual(worker.joint_assignment([[.9, .8], [.7, .1]], 2), [1, 0])

    def test_tracker_reentry_expires_and_history_limit_fails(self):
        tracker = worker.Tracker(max_history=2)
        a = tracker.update(0, [detection([0, 0, .2, .2])])[0]
        b = tracker.update(2100, [detection([0, 0, .2, .2])])[0]
        self.assertNotEqual(a.id, b.id)
        tracker.update(2200, [detection([0, 0, .2, .2])])
        self.assertEqual(tracker.confirmed_count, 1)
        with self.assertRaises(worker.WorkerError):
            tracker.update(4300, [detection([0, 0, .2, .2])])

    def test_tracker_requires_increasing_time(self):
        tracker = worker.Tracker()
        tracker.update(0, [])
        with self.assertRaises(worker.WorkerError):
            tracker.update(0, [])

    def test_limits_reject_bad_dimensions_fps_duration_and_count(self):
        for values in [(0, 100, 30, 10), (2000, 1080, 30, 10),
                       (640, 480, float('nan'), 10), (640, 480, 0, 10),
                       (640, 480, 1, 121), (640, 480, 60, 3601)]:
            with self.assertRaises(worker.WorkerError):
                worker.validate_video_properties(*values)
        self.assertEqual(worker.validate_video_properties(1080, 1920, 30, 60), 2.)

    def test_malformed_job_outputs_only_ndjson_error(self):
        with tempfile.TemporaryDirectory() as folder:
            job = Path(folder) / 'job.json'
            job.write_text('{"mediaType":"image"}', encoding='utf-8')
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                status = worker.main(['--job', str(job)])
            messages = [json.loads(line) for line in out.getvalue().splitlines()]
            self.assertEqual(status, 1)
            self.assertEqual(len(messages), 1)
            self.assertEqual(messages[0]['type'], 'error')

    def test_image_actual_decode_format_dimensions_and_exif_orientation(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'image.upload'
            image = Image.new('RGB', (30, 10), 'white')
            exif = image.getexif()
            exif[274] = 6
            image.save(path, 'JPEG', exif=exif)
            self.assertEqual(worker.read_image(path).size, (10, 30))
            path.write_bytes(b'not an image')
            with self.assertRaises(worker.WorkerError):
                worker.read_image(path)
            Image.new('RGB', (2, 2)).save(path, 'GIF')
            with self.assertRaises(worker.WorkerError):
                worker.read_image(path)
            Image.new('1', (6001, 4000)).save(path, 'PNG')
            with self.assertRaises(worker.WorkerError):
                worker.read_image(path)

    def test_preprocess_is_center_floor_rgb_and_padding128(self):
        from PIL import Image
        tensor, transform = worker.preprocess(Image.new('RGB', (7, 3), (255, 0, 127)))
        self.assertEqual((transform.width, transform.height, transform.left, transform.top),
                         (480, 205, 0, 137))
        self.assertEqual(tensor.shape, (1, 3, 480, 480))
        self.assertAlmostEqual(float(tensor[0, 0, 137, 0]), 1.)
        self.assertAlmostEqual(float(tensor[0, 1, 137, 0]), 0.)
        self.assertAlmostEqual(float(tensor[0, 2, 0, 0]), 128 / 255, places=7)

    def test_progress_is_finite_and_before_completed(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            worker.emit_progress(150, 3)
        self.assertEqual(json.loads(out.getvalue()),
                         {'type': 'progress', 'progress': 99, 'framesProcessed': 3})

    def test_generic_observation_does_not_inherit_track_stage(self):
        tracker = worker.Tracker()
        tracker.update(0, [detection([0, 0, .2, .2])])
        observed = detection([0, 0, .2, .2], species=2, stage=-1, confidence=.5)
        track = tracker.update(100, [observed])[0]
        self.assertEqual(observed.as_object(track)['stageCode'], -1)

    def test_serialization_preserves_positive_area_after_clipping(self):
        obj = detection([.1, .1, .100000001, .2]).as_object()
        self.assertLess(obj['box'][0], obj['box'][2])

    def test_missing_argument_has_only_protocol_output(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(worker.main([]), 1)
        self.assertEqual(json.loads(out.getvalue())['type'], 'error')
        self.assertEqual(err.getvalue(), '')

    def test_image_and_video_job_decode_all_frames_and_save_preview(self):
        import cv2
        import numpy as np
        from PIL import Image

        class CountingDetector:
            calls = 0

            def detect(self, image):
                CountingDetector.calls += 1
                return [detection([.2, .2, .4, .4])], False

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            image_path = root / 'image.upload'
            Image.new('RGB', (32, 24), 'white').save(image_path, 'PNG')
            with contextlib.redirect_stdout(io.StringIO()):
                result, preview = worker.process_job({'id': 'image-test', 'mediaType': 'image',
                    'inputPath': str(image_path), 'outputDirectory': str(root / 'image-out')}, CountingDetector)
            self.assertEqual((result['framesProcessed'], result['maxVisibleCount'], result['confirmedTrackCount']), (1, 1, 0))
            with Image.open(preview) as rendered:
                self.assertEqual(rendered.format, 'JPEG')
            video_path = root / 'video.upload'
            # Encoder selects format from extension; rename after encoding tests content validation.
            encoded_path = root / 'source.mp4'
            writer = cv2.VideoWriter(str(encoded_path), cv2.VideoWriter_fourcc(*'mp4v'), 10., (32, 24))
            self.assertTrue(writer.isOpened())
            for _ in range(4):
                writer.write(np.zeros((24, 32, 3), np.uint8))
            writer.release()
            encoded_path.rename(video_path)
            CountingDetector.calls = 0
            with contextlib.redirect_stdout(io.StringIO()):
                result, preview = worker.process_job({'id': 'video-test', 'mediaType': 'video',
                    'inputPath': str(video_path), 'outputDirectory': str(root / 'video-out')}, CountingDetector)
            self.assertEqual(CountingDetector.calls, 4)
            self.assertEqual((result['framesProcessed'], result['maxVisibleCount'], result['confirmedTrackCount']), (4, 1, 1))
            self.assertEqual(sum(result['gradeCounts'].values()), 1)
            self.assertEqual(result['objects'][0]['trackId'], 1)
            self.assertTrue(Path(preview).is_file())

            # A valid header with a truncated MP4 body must never return partial counts.
            broken = root / 'truncated.upload'
            broken.write_bytes(video_path.read_bytes()[:64])
            job = root / 'broken-job.json'
            job.write_text(json.dumps({'id': 'bad-video', 'mediaType': 'video',
                'inputPath': str(broken), 'outputDirectory': str(root / 'bad-protocol')}), encoding='utf-8')
            execution = subprocess.run([sys.executable, '-X', 'utf8', '-B', worker.__file__, '--job', str(job)],
                capture_output=True, text=True, encoding='utf-8', timeout=10)
            self.assertEqual(execution.returncode, 1)
            self.assertEqual(execution.stderr, '')
            messages = [json.loads(line) for line in execution.stdout.splitlines()]
            self.assertEqual(messages[-1]['type'], 'error')
            self.assertFalse(any(m['type'] == 'completed' for m in messages))
            self.assertFalse((root / 'bad-protocol/preview.jpg').exists())


if __name__ == '__main__':
    unittest.main()
