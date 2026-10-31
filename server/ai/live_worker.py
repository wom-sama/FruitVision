"""One cached pinned Detector, sequential JPEG frames; no image files or model construction on import."""
import base64
import binascii
import io
import json
import math
import sys
import time
import uuid
import warnings
import worker

MAX_BYTES = 1048576
MAX_EDGE = 960
MAX_LINE = 1400000


class LiveFrameError(Exception):
    pass


def decode_jpeg(content):
    from PIL import Image, ImageOps
    if not isinstance(content, bytes) or not 4 <= len(content) <= MAX_BYTES or not content.startswith(b'\xff\xd8\xff'):
        raise LiveFrameError()
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('error', Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(content)) as image:
                if image.format != 'JPEG' or getattr(image, 'n_frames', 1) != 1 or not 1 <= image.width <= MAX_EDGE or not 1 <= image.height <= MAX_EDGE:
                    raise LiveFrameError()
                image.load()
                return ImageOps.exif_transpose(image).convert('RGB')
    except (OSError, ValueError, SyntaxError, Warning, Image.DecompressionBombError) as error:
        raise LiveFrameError() from error


def emit(destination, value):
    destination.write(json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n')
    destination.flush()


def handle(line, detector):
    try:
        request = json.loads(line)
        if not isinstance(request, dict) or set(request) != {'id', 'imageBase64'} or not isinstance(request['id'], str):
            raise ValueError()
        uuid.UUID(request['id'])
        identifier = request['id']
        encoded = request['imageBase64']
        if not isinstance(encoded, str) or len(encoded) > 1398104:
            raise ValueError()
        content = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError, KeyError, binascii.Error):
        return {'type': 'fatal', 'code': 'LIVE_PROTOCOL_INVALID'}
    try:
        started = time.monotonic()
        image = decode_jpeg(content)
        detections, _ = detector.detect(image)
        objects = [detection.as_object() for detection in detections if detection.species == 1]
        elapsed = (time.monotonic() - started) * 1000
        if not math.isfinite(elapsed): raise ValueError()
        value = {'type': 'frame', 'id': identifier, 'imageWidth': image.width, 'imageHeight': image.height,
                 'objects': objects, 'processingMs': round(elapsed, 3)}
        # Force protocol validation before writing a partial line.
        json.dumps(value, allow_nan=False)
        return value
    except LiveFrameError:
        return {'type': 'error', 'id': identifier, 'code': 'LIVE_FRAME_INVALID'}
    except Exception:
        return {'type': 'fatal', 'code': 'LIVE_AI_UNAVAILABLE'}


def serve(source, destination, detector_factory=worker.Detector):
    try:
        detector = detector_factory()
        emit(destination, {'type': 'ready', 'modelSha256': worker.MODEL_SHA256, 'scope': 'predicted-mango-only'})
    except Exception:
        emit(destination, {'type': 'fatal', 'code': 'LIVE_AI_UNAVAILABLE'}); return 1
    while True:
        line = source.readline(MAX_LINE + 1)
        if not line: return 0
        if len(line) > MAX_LINE or not line.endswith('\n'):
            emit(destination, {'type': 'fatal', 'code': 'LIVE_PROTOCOL_INVALID'}); return 1
        value = handle(line, detector)
        line = None  # Do not retain the last frame's base64 while waiting for the next request.
        emit(destination, value)
        if value['type'] == 'fatal': return 1
        value = None


if __name__ == '__main__':
    raise SystemExit(serve(sys.stdin, sys.stdout))
