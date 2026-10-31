"""Opt-in HTTPS-to-PC live inference smoke; three repeats of one bundled photo.

No password/OTP/refresh calls, browser, SQL, fake tokens, video, native-camera or FPS proof.
Importing this module performs no session/network/file mutation. --run is required.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.request
import uuid

# These are inert stdlib transport/validation helpers; no earlier workflow or receipt is reused.
from mango_image_smoke_24 import ROOT, ASSETS, MODEL_SHA256, NoRedirect, SmokeFailure, validate_base, require, finite, LABELS

ROLES = ('Admin', 'Producer', 'Trader', 'Consumer')
SOURCE_SHA256 = '0104a1e5e313f5c4082607b4cac73b2497f9a916d130e500c96616e05684b9f5'


def validate_frame(value, session_id, sequence, dimensions):
    require(isinstance(value, dict), 'Live frame must be a JSON object')
    finite(value)
    require(value.get('schema') == 'fruitvision-live-v1' and value.get('scope') == 'predicted-mango-only'
            and value.get('modelSha256') == MODEL_SHA256, 'Live result schema/scope/model differs from the pinned contract')
    require(value.get('sessionId') == session_id and type(value.get('sequence')) is int and value['sequence'] == sequence,
            'Live result session/sequence differs from the submitted frame')
    require((value.get('imageWidth'), value.get('imageHeight')) == dimensions, 'Live result dimensions differ from the upright JPEG')
    objects, counts = value.get('objects'), value.get('stageCounts')
    require(isinstance(objects, list) and len(objects) <= 64 and type(value.get('visibleCount')) is int
            and value['visibleCount'] == len(objects), 'Live visible count differs from frame objects')
    require(isinstance(counts, dict) and set(counts) == set(LABELS.values())
            and all(type(n) is int and n >= 0 for n in counts.values()), 'Invalid live source-stage counts')
    actual = dict.fromkeys(LABELS.values(), 0)
    for obj in objects:
        require(isinstance(obj, dict) and obj.get('fruitLabel') == 'Xoài (dự đoán)', 'Unexpected live fruit label')
        code, score, box = obj.get('stageCode'), obj.get('score'), obj.get('box')
        require(type(code) is int and code in LABELS and obj.get('stageLabel') == LABELS[code], 'Unexpected live stage mapping')
        require(type(score) in (int, float) and 0 <= score <= 1, 'Invalid live confidence')
        require(isinstance(box, list) and len(box) == 4 and all(type(n) in (int, float) and 0 <= n <= 1 for n in box)
                and box[0] < box[2] and box[1] < box[3], 'Invalid normalized live box')
        actual[LABELS[code]] += 1
    require(counts == actual, 'Live stage counts differ from object labels')
    for field in ('processingMs', 'serverLatencyMs'):
        require(type(value.get(field)) in (int, float) and value[field] >= 0, 'Invalid live timing')
    require(isinstance(value.get('limitations'), list) and len(value['limitations']) >= 3, 'Missing live limitations')
    if not objects: require(value.get('summary') == 'Không phát hiện xoài đạt ngưỡng', 'Empty frame must not claim mango absence')


def job_snapshot(value):
    require(isinstance(value, dict) and isinstance(value.get('items'), list) and len(value['items']) <= 20, 'Invalid bounded own-job list')
    rows = value['items']
    require(not any(row.get('status') in ('Queued', 'Running') for row in rows), 'Seller already has an active file job')
    return {str(uuid.UUID(row['id'])): row['framesProcessed'] for row in rows}


class LiveSmoke:
    def __init__(self, args):
        self.args = args; self.output = args.output.resolve()
        require(self.output.is_relative_to((ROOT / 'docs').resolve()) and self.output.suffix == '.json', 'Choose a new JSON receipt under server/docs')
        require(not self.output.exists(), 'Receipt already exists; choose a new output')
        self.started = time.monotonic(); self.deadline = self.started + 75
        self.base = ''; self.tokens = {}; self.actors = {}; self.session_id = None; self.created = False; self.stopped = False
        suffix = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
        self.private_path = ROOT / '.local/test-results' / ('live-ai-smoke-25-' + suffix + '.errors.json')
        self.errors = []
        self.report = {'status': 'RUNNING', 'startedUtc': dt.datetime.now(dt.timezone.utc).isoformat(),
            'scope': 'Actual public HTTPS live-session PC inference, three identical frames from one existing bundled mango demo photo. Not continuous camera capture, mobile/native acceptance, field accuracy or FPS proof.',
            'qualityEvaluation': 'NOT_PERFORMED: no independent annotations or physical capture; zero detections is allowed.',
            'tlsVerificationDisabled': False, 'requestBudget': 20, 'requests': [], 'checks': [], 'frames': [],
            'cacheEvidence': 'Three frames in one API session. Process/session reuse follows the cached backend implementation; no remote process telemetry or cold-start claim.',
            'storageInspection': 'NOT_PERFORMED: no SQL or filesystem inspection. Own bounded AiJob metadata is compared before/after.'}

    def check(self, label, passed):
        self.report['checks'].append({'name': label, 'pass': bool(passed)}); require(passed, label)

    def safe_text(self, value, maximum=240):
        text = str(value)
        for token in self.tokens.values(): text = text.replace(token, '[redacted]')
        text = re.sub(r'Bearer\s+[^\s]+', 'Bearer [redacted]', text, flags=re.IGNORECASE)
        return text[:maximum]

    def exchange(self, role, route, *, method='GET', data=None, raw=None, sequence=None, expected=200, cleanup=False):
        require(route.startswith('/api/v1/') and not any(c in route for c in ('\\', '\r', '\n', '\0', '#')) and '://' not in route, 'Unsafe API route')
        require(len(self.report['requests']) < 20, 'Live smoke request budget reached')
        left = self.deadline - time.monotonic()
        require(cleanup or left > 0, 'Live smoke deadline exceeded')
        headers = {'Accept': 'application/json', 'Authorization': 'Bearer ' + self.tokens[role]}
        body = raw if raw is not None else (json.dumps(data).encode('utf-8') if data is not None else None)
        if body is not None: headers['Content-Type'] = 'image/jpeg' if raw is not None else 'application/json'
        if sequence is not None: headers['X-Frame-Sequence'] = str(sequence)
        status = None; start = time.monotonic()
        try:
            request = urllib.request.Request(self.base + route, data=body, headers=headers, method=method)
            try:
                response = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=5 if cleanup else max(.1, min(18 if route.endswith('/sessions') else 12, left)))
            except urllib.error.HTTPError as error: response = error
            with response:
                status = response.status; payload = response.read(65537)
                require(len(payload) <= 65536, 'Live smoke response exceeded bounded size')
                media_type = response.headers.get('Content-Type', '').split(';', 1)[0]
            value = None
            if payload:
                require('json' in media_type, 'Live smoke expected JSON')
                value = json.loads(payload, parse_constant=lambda constant: (_ for _ in ()).throw(SmokeFailure('Non-finite JSON number')))
            if status != expected:
                private = {'route': route, 'status': status, 'expectedStatus': expected}
                if isinstance(value, dict):
                    for field in ('code', 'title', 'correlationId'):
                        if field in value: private[field] = self.safe_text(value[field])
                self.errors.append(private)
                raise SmokeFailure(f'{role} {method} {route}: unexpected HTTP status {status}')
            return value
        finally:
            self.report['requests'].append({'role': role, 'method': method, 'route': route, 'status': status,
                'expectedStatus': expected, 'rttMs': round((time.monotonic() - start) * 1000, 3)})

    def load(self):
        path = self.args.sessions.resolve()
        require(path.is_relative_to((ROOT / '.local').resolve()) and path.is_file() and path.stat().st_size <= 65536, 'Sessions must be a bounded private JSON file under server/.local')
        document = json.loads(path.read_text(encoding='utf-8-sig'))
        tunnel_path = ROOT / '.local/tunnel-state.json'; require(tunnel_path.stat().st_size <= 65536, 'Tunnel record exceeds bound')
        tunnel = json.loads(tunnel_path.read_text(encoding='utf-8-sig'))
        self.base = validate_base(document['baseURL'].rstrip('/'), tunnel.get('publicUrl', ''))
        for role in ROLES:
            row = document['sessions'][role]; token = row['accessToken']
            require(isinstance(token, str) and re.fullmatch(r'[A-Za-z0-9_-]{43}', token) is not None, 'Invalid provided opaque session shape')
            self.tokens[role] = token; self.actors[role] = str(uuid.UUID(row['user']['id']))
        require(len(set(self.actors.values())) == 4, 'Four distinct real role identities are required')
        self.report.update({'baseURL': self.base, 'actors': self.actors.copy(), 'sellerRole': self.args.role})
        for role in ROLES:
            profile = self.exchange(role, '/api/v1/auth/me')
            self.check(role + ' current verified approved identity', profile['id'] == self.actors[role] and profile['role'] == role
                and profile['emailConfirmed'] and profile['isActive'] and profile['approvalStatus'] == 'Approved')

    def image(self):
        from PIL import Image, ImageOps
        source = ASSETS / 'demo_mango.jpg'; require(source.is_file() and source.stat().st_size <= 12 * 1024 * 1024, 'Bundled mango fixture unavailable')
        original = source.read_bytes(); require(hashlib.sha256(original).hexdigest() == SOURCE_SHA256, 'Bundled mango fixture SHA changed')
        with Image.open(io.BytesIO(original)) as decoded:
            upright = ImageOps.exif_transpose(decoded).convert('RGB'); original_size = upright.size
            upright.thumbnail((960, 960), Image.Resampling.BILINEAR); upright.info.clear()
            output = io.BytesIO(); upright.save(output, 'JPEG', quality=80, exif=b''); content = output.getvalue(); dimensions = upright.size
        require(len(content) <= 1048576 and max(dimensions) <= 960 and content.startswith(b'\xff\xd8\xff'), 'Canonical frame exceeds live input limits')
        self.report['fixture'] = {'path': 'app/android/app/src/main/assets/demo_mango.jpg', 'sourceSha256': SOURCE_SHA256,
            'originalUprightDimensions': list(original_size), 'frameDimensions': list(dimensions), 'frameSizeBytes': len(content),
            'frameSha256': hashlib.sha256(content).hexdigest(), 'transform': 'In-memory EXIF transpose/RGB, BILINEAR thumbnail<=960, JPEG quality80, metadata stripped; same bytes sent three times.',
            'provenanceLimit': 'Existing native demo sample may include padding/transformations; not independent ground truth. No synthetic scene generated by this driver.'}
        return content, dimensions

    def run(self):
        self.load(); content, dimensions = self.image(); role = self.args.role
        before = job_snapshot(self.exchange(role, '/api/v1/ai/jobs'))
        for forbidden in ('Consumer', 'Admin'):
            self.exchange(forbidden, '/api/v1/ai/live/sessions', method='POST', data={}, expected=403)
        self.check('Consumer and Admin cannot start live inference', True)
        started = self.exchange(role, '/api/v1/ai/live/sessions', method='POST', data={}, expected=201)
        self.session_id = str(uuid.UUID(started['id'])); self.created = True
        self.check('Live start returns pinned mango scope and input bounds', started.get('scope') == 'predicted-mango-only'
            and started.get('modelSha256') == MODEL_SHA256 and started.get('maxFrameBytes') == 1048576 and started.get('maxEdge') == 960
            and started.get('minFrameIntervalMs') == 150 and started.get('idleTimeoutSeconds') == 30)
        sequence = started['nextSequence']; require(type(sequence) is int and sequence > 0, 'Invalid initial sequence')
        self.report['sessionId'] = self.session_id; self.report['startRttMs'] = self.report['requests'][-1]['rttMs']
        first_objects = None
        for index in range(3):
            if index: time.sleep(.25)  # Fresh sequential requests; well below8 requests/sec, no throughput assertion.
            value = self.exchange(role, f'/api/v1/ai/live/sessions/{self.session_id}/frames', method='POST', raw=content, sequence=sequence + index)
            validate_frame(value, self.session_id, sequence + index, dimensions)
            if first_objects is None: first_objects = value['objects']
            else: self.check('Identical JPEG repeat ' + str(index + 1) + ' has identical detections', value['objects'] == first_objects)
            self.report['frames'].append({'sequence': value['sequence'], 'imageWidth': value['imageWidth'], 'imageHeight': value['imageHeight'],
                'visibleCount': value['visibleCount'], 'stageCounts': value['stageCounts'], 'objects': value['objects'],
                'processingMs': value['processingMs'], 'serverLatencyMs': value['serverLatencyMs'], 'rttMs': self.report['requests'][-1]['rttMs']})
        self.check('Three real live frame results satisfy the pinned contract', len(self.report['frames']) == 3)
        self.exchange(role, f'/api/v1/ai/live/sessions/{self.session_id}/frames', method='POST', raw=content, sequence=sequence + 2, expected=409)
        self.check('Repeated sequence is rejected as stale', True)
        self.exchange(role, f'/api/v1/ai/live/sessions/{self.session_id}', method='DELETE', expected=204); self.stopped = True
        self.exchange(role, f'/api/v1/ai/live/sessions/{self.session_id}/frames', method='POST', raw=content, sequence=sequence + 3, expected=404)
        self.check('Stop completes and late frames are rejected', True)
        after = job_snapshot(self.exchange(role, '/api/v1/ai/jobs'))
        self.check('Live frames create no observable durable AiJob or job-frame updates', before == after)
        self.report['durability'] = {'scope': 'own bounded last20 AiJob metadata', 'jobCountBefore': len(before), 'jobCountAfter': len(after),
            'observedNewJobIds': sorted(set(after) - set(before)), 'framesProcessedBefore': sum(before.values()), 'framesProcessedAfter': sum(after.values()),
            'observedDurableJobFrameDelta': sum(after.values()) - sum(before.values())}
        self.report['status'] = 'PASS'

    def finish(self):
        if self.created and not self.stopped and self.session_id:
            try:
                self.exchange(self.args.role, f'/api/v1/ai/live/sessions/{self.session_id}', method='DELETE', expected=204, cleanup=True)
                self.stopped = True
            except Exception as error: self.errors.append({'cleanup': 'Own session stop unconfirmed', 'errorType': type(error).__name__})
        self.report.update({'elapsedSeconds': round(time.monotonic() - self.started, 3), 'httpRequests': len(self.report['requests']),
            'privateErrors': str(self.private_path.relative_to(ROOT)).replace('\\', '/'), 'sessionStopped': self.stopped})
        self.private_path.parent.mkdir(parents=True, exist_ok=True)
        with self.private_path.open('x', encoding='utf-8') as output:
            json.dump({'errors': self.errors}, output, ensure_ascii=False, indent=2, allow_nan=False)
        self.tokens.clear()
        self.output.parent.mkdir(parents=True, exist_ok=True)
        with self.output.open('x', encoding='utf-8') as output:
            json.dump(self.report, output, ensure_ascii=False, indent=2, allow_nan=False); output.write('\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True, help='Private current four-role real-session JSON under server/.local')
    parser.add_argument('--role', choices=('Producer', 'Trader'), default='Producer')
    parser.add_argument('--output', type=Path, required=True, help='A NEW public-safe JSON receipt under server/docs; never overwritten')
    parser.add_argument('--run', action='store_true', required=True, help='Authorize a real PC live session AFTER deployment; no refresh/login writers')
    args = parser.parse_args(argv)
    try: probe = LiveSmoke(args)
    except SmokeFailure as error:
        print(json.dumps({'status': 'NOT_RUN', 'reason': str(error)})); return 2
    try:
        probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'; probe.report['errorType'] = type(error).__name__
        probe.errors.append({'errorType': type(error).__name__, 'safeMessage': probe.safe_text(error) if isinstance(error, SmokeFailure) else 'Details withheld from public receipt'})
    finally:
        try: probe.finish()
        except Exception as error:
            probe.report['status'] = 'FAIL'; probe.report['receiptErrorType'] = type(error).__name__; probe.tokens.clear()
        print(json.dumps({'status': probe.report['status'], 'httpRequests': len(probe.report['requests']),
            'completedFrames': len(probe.report['frames']), 'receipt': str(probe.output.relative_to(ROOT)),
            'qualityEvaluation': 'NOT_PERFORMED', 'nativeCameraAcceptance': 'NOT_PERFORMED'}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
