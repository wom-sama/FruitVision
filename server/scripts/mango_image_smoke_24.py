"""Opt-in one-image HTTPS execution smoke, using an operator's real Seller session.

No password login, email, face, SQL, model change, video, or accuracy evaluation.
Importing this module performs no I/O. --run creates one persistent AI job.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import ipaddress
import json
import math
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

MODEL_SHA256 = '8a69c66a9444c18c98a7e3e58a44f4dddda9eb4583dd4448f430ff9e8db27c41'
ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT.parent / 'app/android/app/src/main/assets'
LABELS = {-1: 'Chưa xác định', 0: 'Xanh / chưa chín', 1: 'Chín'}
FIXTURES = {
    'single': ('demo_mango.jpg', 'image/jpeg', '0104a1e5e313f5c4082607b4cac73b2497f9a916d130e500c96616e05684b9f5'),
    'multiple': ('demo_multi_mango.png', 'image/png', 'efd9b77733593c6ecbebc3304a0b64394e8019df394f82d13bb386f108b33dd2')}


class SmokeFailure(Exception):
    pass


def validate_base(base, recorded):
    require(isinstance(base, str) and base == recorded.rstrip('/'), 'Base URL differs from the current owned tunnel')
    value = urllib.parse.urlsplit(base)
    require(value.scheme == 'https' and bool(value.hostname) and not value.username and not value.password
            and not value.path and not value.query and not value.fragment and value.port in (None, 443), 'Unsafe HTTPS base URL')
    host = value.hostname.lower()
    require('.' in host and host != 'localhost' and not host.endswith(('.local', '.internal')), 'Public HTTPS host required')
    try: address = ipaddress.ip_address(host)
    except ValueError: address = None
    require(address is None or address.is_global, 'Public HTTPS host required')
    return base


def validate_result(result):
    require(isinstance(result, dict), 'Result must be an object')
    require(result.get('schema') == 'fruitvision-ai-v1' and result.get('scope') == 'predicted-mango-only'
            and result.get('modelSha256') == MODEL_SHA256, 'Wrong model, result schema or serving scope')
    finite(result)
    for name, expected in (('framesProcessed', 1), ('confirmedTrackCount', 0), ('lineCrossingCount', 0)):
        require(type(result.get(name)) is int and result[name] == expected, 'Unexpected image count semantics')
    objects, counts = result.get('objects'), result.get('gradeCounts')
    require(isinstance(objects, list) and len(objects) <= 64 and type(result.get('maxVisibleCount')) is int
            and result['maxVisibleCount'] == len(objects), 'Visible count differs from image objects')
    require(isinstance(counts, dict) and set(counts) == set(LABELS.values())
            and all(type(n) is int and n >= 0 for n in counts.values()), 'Invalid source-stage counts')
    observed = dict.fromkeys(LABELS.values(), 0)
    for obj in objects:
        require(isinstance(obj, dict) and obj.get('trackId') is None and obj.get('fruitLabel') == 'Xoài (dự đoán)', 'Unexpected object label or image track ID')
        code = obj.get('stageCode')
        require(type(code) is int and code in LABELS and obj.get('stageLabel') == LABELS[code], 'Unmapped source stage')
        score, box = obj.get('score'), obj.get('box')
        require(type(score) in (int, float) and 0 <= score <= 1, 'Invalid detection score')
        require(isinstance(box, list) and len(box) == 4 and all(type(v) in (int, float) and 0 <= v <= 1 for v in box)
                and box[0] < box[2] and box[1] < box[3], 'Invalid normalized box')
        observed[LABELS[code]] += 1
    require(counts == observed, 'Source-stage counts differ from image objects')
    require(type(result.get('processingSeconds')) in (int, float) and result['processingSeconds'] >= 0, 'Invalid processing duration')
    require(isinstance(result.get('limitations'), list) and len(result['limitations']) >= 3, 'Missing execution limitations')
    require(isinstance(result.get('summary'), str) and bool(result['summary']), 'Missing result summary')
    if not objects:
        require(result['summary'] == 'Không phát hiện xoài đạt ngưỡng', 'Empty result must not claim mango absence')


def require(passed, message):
    if not passed: raise SmokeFailure(message)


def finite(value):
    if isinstance(value, float): require(math.isfinite(value), 'Non-finite result number')
    elif isinstance(value, dict):
        for child in value.values(): finite(child)
    elif isinstance(value, list):
        for child in value: finite(child)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, stream, code, message, headers, target):
        return None


class Smoke:
    def __init__(self, arguments):
        self.args = arguments; self.started = time.monotonic(); self.deadline = self.started + 75
        self.token = ''; self.base = ''; self.job_id = None; self.job_status = None
        self.output = arguments.output.resolve()
        require(self.output.is_relative_to((ROOT / 'docs').resolve()) and self.output.suffix == '.json', 'Receipt must be a JSON file under server/docs')
        self.report = {'status': 'RUNNING', 'startedUtc': dt.datetime.now(dt.timezone.utc).isoformat(),
            'scope': 'One real HTTPS image job and preview using an operator-provided authenticated Seller session; no accuracy, field ripeness, phone or throughput proof.',
            'tlsVerificationDisabled': False, 'role': arguments.role, 'checks': [], 'requests': [],
            'qualityEvaluation': 'NOT_PERFORMED: bundled demo fixture, no independent annotations; zero detections is a valid execution outcome.'}

    def check(self, label, passed):
        self.report['checks'].append({'name': label, 'pass': bool(passed)})
        require(passed, label)

    def remaining(self, ceiling=12):
        left = self.deadline - time.monotonic(); require(left > 0, 'Image smoke deadline exceeded')
        return max(.1, min(left, ceiling))

    def request(self, route, *, method='GET', data=None, headers=None, expected=200, anonymous=False, binary=False, cleanup=False):
        require(route.startswith('/api/v1/') and '://' not in route, 'Unsafe API route')
        sent = {'Accept': 'image/jpeg' if binary else 'application/json'}
        if not anonymous: sent['Authorization'] = 'Bearer ' + self.token
        sent.update(headers or {}); status = None; start = time.monotonic()
        try:
            request = urllib.request.Request(self.base + route, data=data, method=method, headers=sent)
            try:
                response = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=5 if cleanup else self.remaining())
            except urllib.error.HTTPError as error: response = error
            with response:
                status = response.status; maximum = 10 * 1024 * 1024 if binary else 1024 * 1024
                body = response.read(maximum + 1); require(len(body) <= maximum, 'Bounded response size exceeded')
                content_type = response.headers.get('Content-Type', '').split(';')[0]
            require(status == expected, f'{method} {route}: unexpected HTTP status {status}')
            if binary:
                require(content_type == 'image/jpeg' and body.startswith(b'\xff\xd8\xff') and len(body) >= 4, 'Preview is not a bounded JPEG')
                return body
            if not body: return None
            require('json' in content_type, 'JSON response required')
            return json.loads(body, parse_constant=lambda value: (_ for _ in ()).throw(SmokeFailure('Non-finite JSON number')))
        finally:
            self.report['requests'].append({'method': method, 'route': route, 'status': status,
                'actor': 'anonymous' if anonymous else self.args.role, 'latencyMs': round((time.monotonic() - start) * 1000, 1)})

    def load(self):
        path = self.args.sessions.resolve()
        require(path.is_relative_to((ROOT / '.local').resolve()) and path.is_file() and path.stat().st_size <= 65536, 'Sessions must be a bounded private JSON file under server/.local')
        session = json.loads(path.read_text(encoding='utf-8-sig'))
        recorded_path = ROOT / '.local/tunnel-state.json'
        require(recorded_path.stat().st_size <= 65536, 'Owned tunnel record exceeds bound')
        recorded = json.loads(recorded_path.read_text(encoding='utf-8-sig'))
        self.base = validate_base(session['baseURL'].rstrip('/'), recorded.get('publicUrl', ''))
        row = session['sessions'][self.args.role]; self.token = row['accessToken']
        require(isinstance(self.token, str) and re.fullmatch(r'[A-Za-z0-9_-]{43}', self.token) is not None, 'Invalid opaque session shape')
        expected_id = str(uuid.UUID(row['user']['id']))
        profile = self.request('/api/v1/auth/me')
        self.check('Current real Seller identity is active, verified and approved', profile['id'] == expected_id and profile['role'] == self.args.role
                   and profile['emailConfirmed'] and profile['isActive'] and profile['approvalStatus'] == 'Approved')
        self.report.update({'baseURL': self.base, 'userId': expected_id})

    def run(self):
        self.load()
        capability = self.request('/api/v1/ai/capabilities')
        self.check('Server AI runtime reports ready', capability.get('aiReady') is True)
        guide = self.request('/api/v1/ai/guide')
        self.check('Deployed API advertises mango-only serving', guide.get('productCode') == 'mango' and guide.get('scope') == 'predicted-mango-only')
        jobs = self.request('/api/v1/ai/jobs')
        self.check('Seller has no existing active job', not any(j.get('status') in ('Queued', 'Running') for j in jobs.get('items', [])))
        name, content_type, expected_hash = FIXTURES[self.args.fixture]
        fixture = ASSETS / name; require(fixture.is_file() and fixture.stat().st_size <= 12 * 1024 * 1024, 'Bundled fixture is unavailable or oversized')
        body = fixture.read_bytes(); require(hashlib.sha256(body).hexdigest() == expected_hash, 'Bundled fixture SHA changed')
        self.report['fixture'] = {'path': str(fixture.relative_to(ROOT.parent)).replace('\\', '/'), 'sha256': expected_hash,
            'sizeBytes': len(body), 'kind': 'Existing bundled native demo image; may be transformed, no claim of independent source or ground truth. No image generated by this script.'}
        key = 'mango-smoke-' + uuid.uuid4().hex
        headers = {'Content-Type': content_type, 'X-Client-Request-Id': key}
        job = self.request('/api/v1/ai/jobs?mediaType=image', method='POST', data=body, headers=headers, expected=202)
        self.job_id = str(uuid.UUID(job['id'])); self.job_status = job['status']; self.report['jobId'] = self.job_id
        for _ in range(55):
            job = self.request('/api/v1/ai/jobs/' + self.job_id); self.job_status = job['status']
            if self.job_status not in ('Queued', 'Running'): break
            time.sleep(min(1, self.remaining()))
        self.check('Real server image job succeeded', self.job_status == 'Succeeded')
        validate_result(job.get('result')); self.check('Mango result schema, hash, labels and count semantics are valid', True)
        self.report['result'] = job['result']
        self.check('Successful job advertises preview', job.get('previewAvailable') is True)
        preview = self.request('/api/v1/ai/jobs/' + self.job_id + '/preview', binary=True)
        self.report['preview'] = {'sizeBytes': len(preview), 'sha256': hashlib.sha256(preview).hexdigest()}
        replay = self.request('/api/v1/ai/jobs?mediaType=image', method='POST', data=body, headers=headers)
        self.check('Deliberate identical-key replay reuses the same job', replay['id'] == self.job_id)
        self.request('/api/v1/ai/jobs/' + self.job_id, expected=401, anonymous=True)
        self.request('/api/v1/ai/jobs/' + self.job_id + '/preview', expected=401, anonymous=True)
        self.check('Anonymous job and preview reads are denied', True)
        self.report['status'] = 'PASS'

    def finish(self):
        if self.job_id and self.job_status in ('Queued', 'Running'):
            try:
                self.request('/api/v1/ai/jobs/' + self.job_id + '/cancel', method='POST', cleanup=True)
                self.report['cleanup'] = 'Own unfinished job cancellation requested; no operator session revoked.'
            except Exception as error: self.report['cleanup'] = 'Own job cancellation unconfirmed: ' + type(error).__name__
        self.token = ''
        self.report.update({'elapsedSeconds': round(time.monotonic() - self.started, 3), 'requestCount': len(self.report['requests'])})
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_text(json.dumps(self.report, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True, help='Private real-session JSON under server/.local; tokens are never printed')
    parser.add_argument('--role', choices=('Producer', 'Trader'), default='Producer')
    parser.add_argument('--fixture', choices=tuple(FIXTURES), default='single')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/mango-image-https-smoke-24.json')
    parser.add_argument('--run', action='store_true', help='Explicitly create one persistent real AI image job')
    arguments = parser.parse_args(argv)
    if not arguments.run: parser.error('--run is required; this creates one persistent real AI job')
    probe = Smoke(arguments)
    try:
        probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'
        probe.report['failure'] = str(error) if isinstance(error, SmokeFailure) else type(error).__name__
    finally:
        probe.finish()
    print(json.dumps({'status': probe.report['status'], 'receipt': str(probe.output.relative_to(ROOT)), 'jobId': probe.job_id,
                      'requestCount': probe.report['requestCount'], 'qualityEvaluation': 'NOT_PERFORMED'}, ensure_ascii=False))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
