"""Bounded one-job CPU inference. Stdout is reserved for the NDJSON protocol."""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time
import warnings

# Set before importing any numerical runtime. ORT also has explicit thread limits.
os.environ['OMP_NUM_THREADS'] = '2'
os.environ['MKL_NUM_THREADS'] = '2'
os.environ['OPENBLAS_NUM_THREADS'] = '2'
os.environ['OPENCV_LOG_LEVEL'] = 'SILENT'
os.environ['OPENCV_FFMPEG_LOGLEVEL'] = '-8'

MODEL_SHA256 = '8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41'
MODEL_NAME = 'YOLOX-Tiny reviewed partial-visibility fruit geometry and source stages'
ASSETS = Path(__file__).resolve().parents[2] / 'app/android/app/src/main/assets'
STAGE_LABELS = ('Xanh / chưa chín', 'Chín')
UNKNOWN_LABEL = 'Chưa xác định'
FRUIT_LABEL = 'Xoài (dự đoán)'
EMPTY_RESULT_MESSAGE = 'Không phát hiện xoài đạt ngưỡng'
MAX_IMAGE_PIXELS = 24_000_000
MAX_FRAMES = 3600
MAX_SECONDS = 120
JOB_SECONDS = 165
LIMITATIONS = [
    'Chỉ dùng cho bản trình diễn phi thương mại; giấy phép nguồn dữ liệu/model còn hạn chế.',
    'Chỉ giữ đối tượng được mô hình dự đoán là xoài; bộ lọc có thể bỏ sót hoặc nhận nhầm loài khác.',
    'Hai nhãn giai đoạn từ dữ liệu nguồn không xác nhận độ chín ngoài thực tế; độ tin cậy thấp được ghi Chưa xác định.',
    'Không phát hiện xoài đạt ngưỡng không chứng minh ảnh hoặc video không có xoài.',
    'Màu vỏ bên ngoài không xác nhận giống xoài, chất lượng bên trong, hư hỏng hoặc an toàn thực phẩm.',
    'Video chưa đạt tiêu chí chất lượng khoa học; có thể bỏ sót, trùng khung hoặc sai giai đoạn.',
    'Theo dõi bằng hình học không tái nhận dạng vật thể: che khuất lâu, quay lại và camera chuyển động có thể làm sai số đếm.',
    'Số qua vạch y=0.5 đếm mỗi ID một lần theo cả hai hướng; không phải bảo đảm số quả vật lý duy nhất.',
]


class WorkerError(Exception):
    """Safe, user-facing validation/inference failure; never include file contents."""


@dataclass(frozen=True)
class Transform:
    width: int
    height: int
    left: int
    top: int

    def original(self, box):
        return tuple(max(0., min(1., (float(v) - offset) / length))
                     for v, offset, length in zip(box,
                         (self.left, self.top, self.left, self.top),
                         (self.width, self.height, self.width, self.height)))


@dataclass(frozen=True)
class Detection:
    box: tuple[float, float, float, float]
    score: float
    species: int
    stage: int
    stage_confidence: float

    def as_object(self, track=None):
        stage = (track.stage if track is not None else self.stage) if self.species == 1 else -1
        return {'trackId': track.id if track is not None else None,
                'box': list(self.box), 'score': round(self.score, 7),
                'fruitLabel': FRUIT_LABEL, 'stageCode': stage,
                'stageLabel': STAGE_LABELS[stage] if stage in (0, 1) else UNKNOWN_LABEL}


def iou(a, b):
    intersection = max(0., min(a[2], b[2]) - max(a[0], b[0])) * max(
        0., min(a[3], b[3]) - max(a[1], b[1]))
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - intersection
    return intersection / max(union, 1e-12)


def select_outputs(boxes, scores, species, stages, stage_scores, transform, limit=64):
    """Mango scope first, then stable confidence order and clipped-box NMS."""
    import numpy as np
    boxes = np.asarray(boxes).reshape(-1, 4)
    scores = np.asarray(scores).reshape(-1)
    species = np.asarray(species).reshape(-1)
    stages = np.asarray(stages).reshape(-1)
    stage_scores = np.asarray(stage_scores).reshape(-1, 2)
    n = len(scores)
    if (len(boxes) != n or len(species) != n or len(stages) != n or len(stage_scores) != n
            or not 1 <= limit <= 64 or not np.isfinite(boxes).all()
            or not np.isfinite(scores).all() or not np.isfinite(stage_scores).all()
            or not ((scores >= 0) & (scores <= 1)).all()
            or not ((stage_scores >= 0) & (stage_scores <= 1)).all()
            or not np.isin(species, [-1, 0, 1, 2]).all()
            or not np.isin(stages, [0, 1]).all()
            or ((species == -1) & (scores != 0)).any()):
        raise WorkerError('Đầu ra mô hình không hợp lệ.')
    selected = []
    for index in sorted(range(n), key=lambda k: -float(scores[k])):
        # Filter before NMS so a higher-scoring banana/generic box cannot remove a mango.
        # This changes serving scope only; graph classes and pinned thresholds stay intact.
        if scores[index] < .35 or species[index] != 1:
            continue
        stage = int(stages[index])
        distribution = stage_scores[index]
        if (abs(float(sum(distribution)) - 1.) >= .001
                or distribution[stage] < distribution[1 - stage]):
            raise WorkerError('Phân phối giai đoạn của mô hình không hợp lệ.')
        box = transform.original(boxes[index])
        if box[0] >= box[2] or box[1] >= box[3]:
            continue
        if any(iou(box, previous.box) > .5 for previous in selected):
            continue
        confidence = float(distribution[stage])
        selected.append(Detection(box, float(scores[index]), int(species[index]),
            stage if confidence >= .6 else -1, confidence))
        if len(selected) > limit:
            return selected[:limit], True
    return selected, False


def preprocess(image):
    """Pillow RGB BILINEAR matches legacy 22-bit two-pass rounded resampler."""
    import numpy as np
    from PIL import Image
    scale = min(480 / image.width, 480 / image.height)
    width, height = max(1, int(image.width * scale)), max(1, int(image.height * scale))
    left, top = (480 - width) // 2, (480 - height) // 2
    canvas = Image.new('RGB', (480, 480), (128, 128, 128))
    canvas.paste(image.convert('RGB').resize((width, height), Image.Resampling.BILINEAR), (left, top))
    rgb = np.asarray(canvas, dtype=np.float32) / np.float32(255.)
    return np.ascontiguousarray(rgb.transpose(2, 0, 1)[None]), Transform(width, height, left, top)


class Detector:
    def __init__(self):
        import onnxruntime as ort
        model = Path(os.environ.get('FRUITVISION_MODEL_PATH', ASSETS / 'mango_detector.onnx'))
        if not model.is_file() or hashlib.sha256(model.read_bytes()).hexdigest() != MODEL_SHA256:
            raise WorkerError('Model không đúng SHA-256 đã được phê duyệt.')
        metadata = json.loads((ASSETS / 'detector_metadata.json').read_text(encoding='utf-8'))
        required = {'model_sha256': MODEL_SHA256, 'input_shape': [1, 3, 480, 480],
            'outputs': ['boxes', 'scores', 'species_ids', 'stage_ids', 'stage_scores'],
            'confidence_threshold': .35, 'nms_iou': .5, 'max_classified_objects': 64,
            'letterbox_alignment': 'center', 'letterbox_rounding': 'floor',
            'padding_rgb': [128, 128, 128], 'nms_mode': 'class_agnostic',
            'species_names': ['banana', 'mango', 'fruit'], 'stage_labels': list(STAGE_LABELS)}
        if any(metadata.get(k) != v for k, v in required.items()):
            raise WorkerError('Metadata model khác hợp đồng suy luận đã ghim.')
        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        options.inter_op_num_threads = 1
        options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        options.log_severity_level = 3
        self.session = ort.InferenceSession(str(model), options, providers=['CPUExecutionProvider'])
        inputs = self.session.get_inputs()
        outputs = self.session.get_outputs()
        if (len(inputs) != 1 or inputs[0].shape != [1, 3, 480, 480]
                or inputs[0].type != 'tensor(float)'
                or [item.name for item in outputs] != required['outputs']
                or [item.shape for item in outputs] != [[1, 4725, 4], [1, 4725], [1, 4725], [1, 4725], [1, 4725, 2]]):
            raise WorkerError('Graph ONNX không đúng hợp đồng direct Tiny480.')
        self.input_name = inputs[0].name

    def detect(self, image):
        tensor, transform = preprocess(image)
        result = self.session.run(None, {self.input_name: tensor})
        return select_outputs(*result, transform)


def joint_assignment(scores, tracks):
    """Rectangular Hungarian, ported from app/lib/fruit_tracking.dart."""
    count = len(scores)
    result = [None] * count
    if count == 0 or tracks == 0:
        return result
    columns = [j for j in range(tracks) if any(row[j] >= .2 for row in scores)]
    if not columns:
        return result
    m = len(columns) + count
    u, v, p, way = [0.] * (count + 1), [0.] * (m + 1), [0] * (m + 1), [0] * (m + 1)
    for i in range(1, count + 1):
        p[0], j0 = i, 0
        minimum, used = [math.inf] * (m + 1), [False] * (m + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], math.inf, 0
            for j in range(1, m + 1):
                if used[j]:
                    continue
                score = scores[i0 - 1][columns[j - 1]] if j <= len(columns) else None
                cost = 0 if score is None else (-(count + 1 + score) if score >= .2 else 1e6)
                current = cost - u[i0] - v[j]
                if current < minimum[j]:
                    minimum[j], way[j] = current, j0
                if minimum[j] < delta:
                    delta, j1 = minimum[j], j
            for j in range(m + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minimum[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while j0:
            next_column = way[j0]
            p[j0], j0 = p[next_column], next_column
    for j in range(1, len(columns) + 1):
        if p[j] and scores[p[j] - 1][columns[j - 1]] >= .2:
            result[p[j] - 1] = columns[j - 1]
    return result


@dataclass
class Track:
    id: int
    box: tuple
    last_seen: float
    observations: int = 1
    vx: float = 0.
    vy: float = 0.
    votes: dict = field(default_factory=dict)
    side: int = 0
    crossed: bool = False

    @property
    def stage(self):
        return max(self.votes, key=self.votes.get) if self.votes else -1


class Tracker:
    def __init__(self, max_history=10000):
        self.tracks, self.active = {}, {}
        self.last_timestamp = None
        self.max_history = max_history
        self.line_crossing_count = 0

    @property
    def confirmed_count(self):
        return sum(t.observations >= 2 for t in self.tracks.values())

    def grade_counts(self):
        counts = {STAGE_LABELS[0]: 0, STAGE_LABELS[1]: 0, UNKNOWN_LABEL: 0}
        for track in self.tracks.values():
            if track.observations >= 2:
                counts[STAGE_LABELS[track.stage] if track.stage >= 0 else UNKNOWN_LABEL] += 1
        return counts

    def update(self, timestamp, detections):
        if not math.isfinite(timestamp) or timestamp < 0 or (
                self.last_timestamp is not None and timestamp <= self.last_timestamp):
            raise WorkerError('Mốc thời gian video phải tăng liên tục.')
        self.last_timestamp = timestamp
        self.active = {k: t for k, t in self.active.items() if timestamp - t.last_seen <= 2000}
        active = list(self.active.values())
        predicted = [tuple(value + (t.vx if index % 2 == 0 else t.vy) * (timestamp - t.last_seen)
                           for index, value in enumerate(t.box)) for t in active]
        scores = [[max(iou(d.box, predicted[j]), iou(d.box, t.box))
                   for j, t in enumerate(active)] for d in detections]
        matches = joint_assignment(scores, len(active))
        assigned = []
        for detection, match in zip(detections, matches):
            if match is None:
                if len(self.tracks) >= self.max_history or len(self.active) >= 1024:
                    raise WorkerError('Vượt giới hạn lịch sử theo dõi; hãy chia video nhỏ hơn.')
                track = Track(len(self.tracks) + 1, detection.box, timestamp)
                self.tracks[track.id] = self.active[track.id] = track
            else:
                track = active[match]
                elapsed = timestamp - track.last_seen
                track.vx = ((detection.box[0] + detection.box[2]) - (track.box[0] + track.box[2])) / (2 * elapsed)
                track.vy = ((detection.box[1] + detection.box[3]) - (track.box[1] + track.box[3])) / (2 * elapsed)
                track.box, track.last_seen = detection.box, timestamp
                track.observations += 1
            if detection.stage in (0, 1) and detection.species == 1 and detection.stage_confidence >= .6:
                track.votes[detection.stage] = track.votes.get(detection.stage, 0.) + detection.stage_confidence
            center = (detection.box[1] + detection.box[3]) / 2
            side = -1 if center <= .48 else (1 if center >= .52 else 0)
            if side:
                if track.side and side != track.side and track.observations >= 2 and not track.crossed:
                    track.crossed = True
                    self.line_crossing_count += 1
                track.side = side
            assigned.append(track)
        return assigned


def read_image(path):
    from PIL import Image, ImageOps, UnidentifiedImageError
    try:
        with warnings.catch_warnings():
            warnings.simplefilter('error', Image.DecompressionBombWarning)
            with Image.open(path) as image:
                if image.format not in ('JPEG', 'PNG'):
                    raise WorkerError('Chỉ nhận ảnh JPEG hoặc PNG thực sự.')
                if image.width < 1 or image.height < 1 or image.width * image.height > MAX_IMAGE_PIXELS:
                    raise WorkerError('Ảnh vượt giới hạn 24 megapixel.')
                image.verify()
            with Image.open(path) as image:
                image.load()
                return ImageOps.exif_transpose(image).convert('RGB')
    except WorkerError:
        raise
    except (OSError, ValueError, UnidentifiedImageError, Image.DecompressionBombError,
            Image.DecompressionBombWarning) as error:
        raise WorkerError('Không giải mã được ảnh JPEG/PNG hoàn chỉnh.') from error


def validate_video_properties(width, height, fps, frame_count):
    if (not all(math.isfinite(float(v)) for v in (width, height, fps, frame_count))
            or width < 1 or height < 1 or max(width, height) > 1920 or min(width, height) > 1080
            or width * height > 1920 * 1080 or not 0 < fps <= 240
            or not 1 <= frame_count <= MAX_FRAMES or int(frame_count) != frame_count):
        raise WorkerError('Video cần kích thước tối đa 1920×1080, FPS hợp lệ và tối đa 3600 khung.')
    duration = frame_count / fps
    if not 0 < duration <= MAX_SECONDS:
        raise WorkerError('Video phải ngắn hơn hoặc bằng 120 giây.')
    return duration


def emit(message):
    print(json.dumps(message, ensure_ascii=False, allow_nan=False, separators=(',', ':')), flush=True)


def emit_progress(progress, frames):
    emit({'type': 'progress', 'progress': max(0, min(99, int(progress))), 'framesProcessed': frames})


def check_deadline(started):
    if time.monotonic() - started > JOB_SECONDS:
        raise WorkerError('Vượt thời gian xử lý; hãy dùng video ngắn hơn. Chưa có kết quả hoàn chỉnh.')


def save_preview(image, objects, output, video=False):
    from PIL import ImageDraw, ImageFont
    preview = image.copy()
    preview.thumbnail((1280, 1280))
    draw = ImageDraw.Draw(preview)
    font_path = Path(os.environ.get('WINDIR', 'C:/Windows')) / 'Fonts/arial.ttf'
    font = ImageFont.truetype(str(font_path), 18) if font_path.is_file() else ImageFont.load_default()
    if video:
        draw.line((0, preview.height // 2, preview.width, preview.height // 2), fill=(60, 200, 255), width=2)
    if not objects:
        draw.text((4, 4), EMPTY_RESULT_MESSAGE, font=font, fill=(255, 255, 255),
                  stroke_width=2, stroke_fill=(18, 28, 36))
    for obj in objects:
        box = tuple(round(v * (preview.width if i % 2 == 0 else preview.height)) for i, v in enumerate(obj['box']))
        color = (40, 210, 120) if obj['stageCode'] == 0 else ((255, 180, 35) if obj['stageCode'] == 1 else (100, 190, 255))
        draw.rectangle(box, outline=color, width=3)
        text = (f"#{obj['trackId']} " if obj['trackId'] is not None else '') + obj['fruitLabel'] + ' · ' + obj['stageLabel']
        text_y = max(0, box[1] - 23)
        label_box = draw.textbbox((box[0], text_y), text, font=font)
        draw.rectangle(label_box, fill=(18, 28, 36))
        draw.text((box[0], text_y), text, font=font, fill=color)
    destination = output / 'preview.jpg'
    temporary = output / 'preview.tmp'
    preview.save(temporary, 'JPEG', quality=88)
    temporary.replace(destination)
    return str(destination)


def process_job(job, detector_factory=Detector):
    started = time.monotonic()
    if not isinstance(job, dict) or not isinstance(job.get('id'), str) or not 1 <= len(job['id']) <= 128:
        raise WorkerError('Mã tác vụ không hợp lệ.')
    media_type = job.get('mediaType')
    if media_type not in ('image', 'video'):
        raise WorkerError('Loại dữ liệu phải là image hoặc video.')
    if not isinstance(job.get('inputPath'), str) or not isinstance(job.get('outputDirectory'), str):
        raise WorkerError('Đường dẫn tác vụ không hợp lệ.')
    path, output = Path(job['inputPath']), Path(job['outputDirectory'])
    if not path.is_absolute() or not output.is_absolute() or not path.is_file():
        raise WorkerError('Tác vụ cần đường dẫn tuyệt đối đến tệp đã tải lên.')
    if path.stat().st_size > (12 if media_type == 'image' else 80) * 1024 * 1024:
        raise WorkerError('Tệp vượt giới hạn dung lượng cho phép.')
    output.mkdir(parents=True, exist_ok=True)
    frames, maximum, limited = 0, 0, False
    tracker = Tracker()
    emit_progress(0, 0)
    if media_type == 'image':
        preview = read_image(path)
        detector = detector_factory()
        detections, limited = detector.detect(preview)
        objects = [d.as_object() for d in detections]
        frames, maximum = 1, len(detections)
        counts = {STAGE_LABELS[0]: 0, STAGE_LABELS[1]: 0, UNKNOWN_LABEL: 0}
        for obj in objects:
            counts[obj['stageLabel']] += 1
        emit_progress(99, frames)
    else:
        import cv2
        from PIL import Image
        with path.open('rb') as stream:
            header = stream.read(32)
        if len(header) < 12 or header[4:8] != b'ftyp' or header[8:12] not in (
                b'isom', b'iso2', b'avc1', b'mp41', b'mp42', b'M4V ', b'dash', b'iso5', b'iso6'):
            raise WorkerError('Chỉ nhận video trong container MP4 thực sự.')
        cv2.setNumThreads(2)
        capture = cv2.VideoCapture(str(path), cv2.CAP_FFMPEG, [cv2.CAP_PROP_N_THREADS, 2])
        try:
            if not capture.isOpened():
                raise WorkerError('Không mở được video MP4.')
            width, height, fps, total = (capture.get(prop) for prop in
                (cv2.CAP_PROP_FRAME_WIDTH, cv2.CAP_PROP_FRAME_HEIGHT, cv2.CAP_PROP_FPS, cv2.CAP_PROP_FRAME_COUNT))
            validate_video_properties(width, height, fps, total)
            detector = detector_factory()
            preview, objects, best_detections = None, [], []
            best_track_ids = []
            last_progress, last_pts = -1, -1.
            while True:
                check_deadline(started)
                success, bgr = capture.read()
                if not success:
                    break
                frames += 1
                if frames > MAX_FRAMES or frames > total or bgr is None:
                    raise WorkerError('Video có số khung thực tế không hợp lệ hoặc vượt giới hạn.')
                actual_height, actual_width = bgr.shape[:2]
                validate_video_properties(actual_width, actual_height, fps, total)
                pts = capture.get(cv2.CAP_PROP_POS_MSEC)
                if not math.isfinite(pts) or pts < 0 or pts > MAX_SECONDS * 1000 or (frames > 1 and pts <= last_pts):
                    raise WorkerError('Không xác minh được thời lượng/mốc thời gian của toàn bộ video.')
                last_pts = pts
                image = Image.fromarray(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
                detections, frame_limited = detector.detect(image)
                limited = limited or frame_limited
                tracks = tracker.update(pts, detections)
                if preview is None or len(detections) > maximum:
                    maximum = len(detections)
                    preview = image.copy()
                    best_detections = detections
                    best_track_ids = [t.id for t in tracks]
                progress = min(99, int(frames / total * 99))
                if progress != last_progress:
                    emit_progress(progress, frames)
                    last_progress = progress
            if frames == 0 or frames != int(total) or preview is None:
                raise WorkerError('Video bị cắt/hỏng hoặc chưa giải mã đủ toàn bộ số khung đã khai báo.')
            objects = [d.as_object(tracker.tracks[track_id]) for d, track_id in zip(best_detections, best_track_ids)]
            counts = tracker.grade_counts()
        finally:
            capture.release()
    check_deadline(started)
    limitations = list(LIMITATIONS)
    if limited:
        limitations.append('Có khung vượt 64 đối tượng; giới hạn kết quả có thể làm thiếu số đếm.')
    if media_type == 'image':
        limitations.append('Ảnh đơn không theo dõi ID; xem số quả đang thấy (maxVisibleCount).')
    result = {'schema': 'fruitvision-ai-v1', 'modelName': MODEL_NAME, 'modelSha256': MODEL_SHA256,
              'scope': 'predicted-mango-only',
              'summary': EMPTY_RESULT_MESSAGE if maximum == 0 else 'Phát hiện xoài dự đoán đạt ngưỡng',
              'framesProcessed': frames, 'maxVisibleCount': maximum,
              'confirmedTrackCount': tracker.confirmed_count, 'lineCrossingCount': tracker.line_crossing_count,
              'gradeCounts': counts, 'objects': objects, 'limitations': limitations,
              'processingSeconds': round(time.monotonic() - started, 3)}
    preview_path = save_preview(preview, objects, output, media_type == 'video')
    result['processingSeconds'] = round(time.monotonic() - started, 3)
    return result, preview_path


def main(argv=None):
    try:
        # Argument errors also use the same stdout protocol, never argparse's help/error dump.
        parser = argparse.ArgumentParser(add_help=False, exit_on_error=False)
        parser.add_argument('--job')
        args, unknown = parser.parse_known_args(argv)
        if not args.job:
            raise WorkerError('Cần tham số --job với đường dẫn tuyệt đối.')
        path = Path(args.job)
        if unknown or not path.is_absolute() or not path.is_file() or path.stat().st_size > 16_384:
            raise WorkerError('Tệp cấu hình tác vụ không hợp lệ.')
        job = json.loads(path.read_text(encoding='utf-8-sig'))
        result, preview_path = process_job(job)
        emit({'type': 'completed', 'result': result, 'previewPath': preview_path})
        return 0
    except (WorkerError, json.JSONDecodeError, UnicodeError) as error:
        message = str(error) if isinstance(error, WorkerError) else 'Tệp cấu hình tác vụ không phải JSON hợp lệ.'
    except (SystemExit, argparse.ArgumentError):
        message = 'Cần tham số --job với đường dẫn tuyệt đối.'
    except Exception as error:
        # Bound stderr and omit exception messages, paths, uploaded bytes and tracebacks.
        print(f'AI worker failed ({type(error).__name__}).', file=sys.stderr, flush=True)
        message = 'Xử lý AI thất bại; không có kết quả hoàn chỉnh. Kiểm tra runtime hoặc định dạng tệp.'
    emit({'type': 'error', 'message': message})
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
