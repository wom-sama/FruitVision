"""Pure in-process protocol tests with synthetic JPEGs and a fake detector; no ORT/process launch."""
import base64
import io
import json
import unittest

from PIL import Image
import live_worker
import worker


def jpeg(size=(32, 24)):
    stream = io.BytesIO(); Image.new('RGB', size, 'green').save(stream, 'JPEG'); return stream.getvalue()


def packet(identifier, content):
    return json.dumps({'id': identifier, 'imageBase64': base64.b64encode(content).decode('ascii')}) + '\n'


class LiveWorkerTests(unittest.TestCase):
    def test_actual_jpeg_decode_is_upright_bounded_and_rejects_png_large_or_invalid_bytes(self):
        image = live_worker.decode_jpeg(jpeg()); self.assertIsNotNone(image); self.assertEqual(image.size, (32, 24))
        png = io.BytesIO(); Image.new('RGB', (2, 2)).save(png, 'PNG')
        for content in (png.getvalue(), b'bad', jpeg((961, 20)), b'\xff\xd8\xff' + b'x' * 1048576):
            with self.assertRaises(live_worker.LiveFrameError): live_worker.decode_jpeg(content)

    def test_one_detector_is_cached_across_frames_and_bad_image_does_not_restart_it(self):
        calls = []
        class Detector:
            def __init__(self): calls.append('constructed')
            def detect(self, image):
                return [worker.Detection((.1, .2, .7, .8), .9, 1, 0, .9),
                        worker.Detection((.2, .2, .8, .8), .99, 0, 1, .9)], False
        request = packet('a' * 32, jpeg()) + packet('b' * 32, b'bad') + packet('c' * 32, jpeg())
        output = io.StringIO(); live_worker.serve(io.StringIO(request), output, Detector)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(calls, ['constructed']); self.assertEqual([event['type'] for event in events], ['ready', 'frame', 'error', 'frame'])
        self.assertEqual(events[0]['modelSha256'], worker.MODEL_SHA256)
        for event in (events[1], events[3]):
            self.assertEqual(len(event['objects']), 1); self.assertEqual(event['objects'][0]['fruitLabel'], 'Xoài (dự đoán)')
            self.assertEqual(event['objects'][0]['stageCode'], 0); self.assertEqual((event['imageWidth'], event['imageHeight']), (32, 24))
        self.assertEqual(events[2]['code'], 'LIVE_FRAME_INVALID')

    def test_oversized_protocol_line_is_fatal_and_does_not_call_inference(self):
        class Detector:
            def detect(self, image): raise AssertionError('Inference must not run')
        output = io.StringIO(); live_worker.serve(io.StringIO('x' * 1400001), output, Detector)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(events[-1], {'type': 'fatal', 'code': 'LIVE_PROTOCOL_INVALID'})


if __name__ == '__main__':
    unittest.main()
