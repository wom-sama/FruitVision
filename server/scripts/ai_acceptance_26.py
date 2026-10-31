"""Opt-in2.6 real HTTPS PC mango inference: two photos, one short video, three live frames.

Creates exactly three persistent owned AI jobs. No training, model changes, local
inference, camera/phone/FPS/field-accuracy proof. Root must grant resources before --run.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
from pathlib import Path
import time
import urllib.error
import urllib.request
import uuid

from feedback_acceptance_25 import FeedbackAcceptance, GUID
from live_ai_smoke_25 import LiveSmoke, validate_frame, job_snapshot
from mango_image_smoke_24 import ASSETS, ROOT, FIXTURES, LABELS, MODEL_SHA256, NoRedirect, require, finite, validate_result
from verticals_e2e import ProbeFailure

VIDEO_SHA = 'c4f13e6db96e43a583b8e569fdd547ce21f271cd38fe83e4a95381839536109c'
VIDEO_FRAMES = 231
MAX_REQUESTS = 80


def validate_video(result):
    require(isinstance(result, dict) and result.get('schema') == 'fruitvision-ai-v1' and
        result.get('scope') == 'predicted-mango-only' and result.get('modelSha256') == MODEL_SHA256, 'Wrong video scope/model')
    finite(result)
    require(result.get('framesProcessed') == VIDEO_FRAMES, 'Short clip must decode all231 encoded video frames')
    for key in ('maxVisibleCount', 'confirmedTrackCount', 'lineCrossingCount'):
        require(type(result.get(key)) is int and result[key] >= 0, 'Invalid video count')
    require(result['maxVisibleCount'] <= 64 and result['lineCrossingCount'] <= result['confirmedTrackCount'], 'Invalid count relationships')
    counts, objects = result.get('gradeCounts'), result.get('objects')
    require(isinstance(counts, dict) and set(counts) == set(LABELS.values()) and all(type(n) is int and n >= 0 for n in counts.values())
        and sum(counts.values()) == result['confirmedTrackCount'], 'Video grades must count confirmed tracks, not frames')
    require(isinstance(objects, list) and len(objects) == result['maxVisibleCount'], 'Video objects must represent the maximum-visible preview frame')
    ids = []
    for obj in objects:
        track, box, code, score = obj.get('trackId'), obj.get('box'), obj.get('stageCode'), obj.get('score')
        require(type(track) is int and track > 0 and track not in ids, 'Invalid/repeated preview track ID'); ids.append(track)
        require(obj.get('fruitLabel') == 'Xoài (dự đoán)' and type(code) is int and code in LABELS and obj.get('stageLabel') == LABELS[code], 'Invalid source stage')
        require(type(score) in (int, float) and 0 <= score <= 1, 'Invalid confidence')
        require(isinstance(box, list) and len(box) == 4 and all(type(v) in (int, float) and 0 <= v <= 1 for v in box)
            and box[0] < box[2] and box[1] < box[3], 'Invalid video box')
    require(type(result.get('processingSeconds')) in (int, float) and result['processingSeconds'] >= 0 and len(result.get('limitations', [])) >= 3, 'Missing video timing/limitations')
    if not objects: require(result.get('summary') == 'Không phát hiện xoài đạt ngưỡng', 'Empty video is not absence proof')


class AiAcceptance(FeedbackAcceptance):
    def __init__(self, sessions, output):
        super().__init__(sessions, output)
        self.deadline = self.started + 150
        self.private_output = ROOT / '.local/ai26' / (self.run_id + '.json')
        self.jobs = []; self.live_id = None; self.live_created = False; self.live_role = 'Producer'
        self.report = {'status': 'RUNNING', 'startedUtc': dt.datetime.now(dt.timezone.utc).isoformat(),
            'scope': 'Real2.6 public HTTPS to unchanged PC mango model: Producer/Trader photos, one bundled short video, three repeated live JPEGs with stop/restart. Not four phones, physical camera, field quality, unique physical fruit or FPS proof.',
            'requestBudget': MAX_REQUESTS, 'deadlineSeconds': 150, 'requests': [], 'checks': [], 'jobs': [], 'liveFrames': [],
            'qualityEvaluation': 'NOT_PERFORMED: bundled demo inputs lack independent physical-fruit/stage annotations; clip prediction count has no ground-truth assertion.',
            'modelSha256': MODEL_SHA256, 'tlsVerificationDisabled': False,
            'historicalCounts': 'Old stored result JSON is read unchanged; missing mango-only scope is archival and may include other species. Usage statistics count jobs/decoded frames, never unique fruit.',
            'resources': 'Three file jobs sequentially then one cached live worker; no local ORT or parallel file/live inference. Existing CPU2 policy unchanged.'}

    def exchange(self, role, path, data=None, method=None, expected=200, raw=None, content_type=None, binary=False, headers=None, cleanup=False):
        if not isinstance(path, str) or not path.startswith('/api/v1/') or '://' in path or any(c in path for c in ('\\', '\r', '\n', '\0', '#')):
            raise ProbeFailure('Unsafe/versionless API route')
        if self.request_count >= MAX_REQUESTS: raise ProbeFailure('AI acceptance HTTP budget reached')
        left = self.deadline - time.monotonic()
        if not cleanup and left <= 0: raise ProbeFailure('AI acceptance deadline reached')
        self.request_count += 1
        sent = {'Accept': 'image/jpeg' if binary else 'application/json'}
        if role: sent['Authorization'] = 'Bearer ' + self.tokens[role]
        sent.update(headers or {})
        body = raw if raw is not None else (json.dumps(data).encode('utf-8') if data is not None else None)
        if body is not None: sent['Content-Type'] = content_type or 'application/json'
        verb = method or ('POST' if body is not None else 'GET'); status = None; started = time.monotonic()
        try:
            request = urllib.request.Request(self.base + path, data=body, headers=sent, method=verb)
            try: response = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=5 if cleanup else max(.1, min(18, left)))
            except urllib.error.HTTPError as error: response = error
            with response:
                status = response.status; maximum = 5 * 1024 * 1024 if binary else 1024 * 1024
                payload = response.read(maximum + 1); require(len(payload) <= maximum, 'Response exceeded bound')
                media = response.headers.get('Content-Type', '').split(';')[0]
            allowed = expected if isinstance(expected, tuple) else (expected,)
            if status not in allowed: raise ProbeFailure('Unexpected HTTP status ' + str(status) + '; stop without automatic retry')
            if binary:
                require(media == 'image/jpeg' and payload.startswith(b'\xff\xd8\xff'), 'Expected annotated JPEG preview'); result = payload
            else:
                require(not payload or 'json' in media, 'Expected JSON response')
                result = json.loads(payload, parse_constant=lambda _: (_ for _ in ()).throw(ProbeFailure('Nonfinite JSON'))) if payload else None
            return status, result, media
        finally:
            self.report['requests'].append({'role': role or 'anonymous', 'method': verb, 'routeTemplate': GUID.sub('{id}', path.split('?')[0]),
                'status': status, 'expectedStatus': expected, 'latencyMs': round((time.monotonic() - started) * 1000, 3)})

    def save_ownership(self):
        self.write_private(self.private_output, {'runId': self.run_id, 'ownedAiJobs': self.jobs, 'ownLiveSessionId': self.live_id,
            'status': self.report['status'], 'warning': 'New QA AI records only. No images/tokens/identities retained here. Do not replay failed mutations automatically.'})

    def fixture(self, name, digest):
        path = ASSETS / name; raw = path.read_bytes(); require(hashlib.sha256(raw).hexdigest() == digest, 'Fixture hash changed')
        return raw

    def file_job(self, role, media_type, raw, content_type):
        job = self.request(role, '/api/v1/ai/jobs?mediaType=' + media_type, raw=raw, content_type=content_type,
            headers={'X-Client-Request-Id': 'qa26-' + uuid.uuid4().hex}, expected=202)
        identifier = str(uuid.UUID(job['id'])); self.jobs.append({'id': identifier, 'role': role, 'status': job['status']}); self.save_ownership()
        progress, frames = -1, -1
        while True:
            job = self.request(role, '/api/v1/ai/jobs/' + identifier)
            self.check('Job progress and decoded-frame cursor remain monotonic', type(job.get('progress')) is int and progress <= job['progress'] <= 100
                and type(job.get('framesProcessed')) is int and job['framesProcessed'] >= frames)
            progress, frames = job['progress'], job['framesProcessed']; self.jobs[-1]['status'] = job['status']
            if job['status'] not in ('Queued', 'Running'): break
            if self.deadline - time.monotonic() < 3: raise ProbeFailure('AI polling deadline; own unfinished job will be cancelled')
            time.sleep(2)  # Status reads only; mutations never retried.
        self.check(role + ' actual ' + media_type + ' job succeeded', job['status'] == 'Succeeded')
        validate_result(job['result']) if media_type == 'image' else validate_video(job['result'])
        self.check('Durable job frame count equals validated result frame count', job['framesProcessed'] == job['result']['framesProcessed'])
        self.check('Successful job has preview', job.get('previewAvailable') is True)
        preview = self.exchange(role, '/api/v1/ai/jobs/' + identifier + '/preview', binary=True)[1]
        other = 'Trader' if role == 'Producer' else 'Producer'
        self.exchange(other, '/api/v1/ai/jobs/' + identifier, expected=404)
        self.exchange(other, '/api/v1/ai/jobs/' + identifier + '/preview', expected=404)
        self.report['jobs'].append({'id': identifier, 'role': role, 'mediaType': media_type, 'result': job['result'],
            'preview': {'bytes': len(preview), 'sha256': hashlib.sha256(preview).hexdigest()}})
        self.save_ownership(); return job['result']

    # Unlike MediaAcceptance.request, this supports raw bytes/sequence headers too.
    def request(self, role, path, data=None, method=None, expected=200, **kwargs):
        return self.exchange(role, path, data=data, method=method, expected=expected, **kwargs)[1]

    def live_start(self, expected):
        started = self.request(self.live_role, '/api/v1/ai/live/sessions', {}, expected=expected)
        self.check('Live start advertises exact model/scope and frame bounds', started.get('scope') == 'predicted-mango-only' and
            started.get('modelSha256') == MODEL_SHA256 and started.get('maxFrameBytes') == 1048576 and started.get('maxEdge') == 960 and started.get('minFrameIntervalMs') == 150)
        if expected == 201: self.live_id = str(uuid.UUID(started['id'])); self.live_created = True; self.save_ownership()
        return started

    def frame(self, raw, dimensions, sequence):
        value = self.request(self.live_role, f'/api/v1/ai/live/sessions/{self.live_id}/frames', raw=raw, content_type='image/jpeg', headers={'X-Frame-Sequence': str(sequence)})
        validate_frame(value, self.live_id, sequence, dimensions)
        self.report['liveFrames'].append({**value, 'rttMs': self.report['requests'][-1]['latencyMs']}); return value

    def stop_live(self):
        self.exchange(self.live_role, '/api/v1/ai/live/sessions/' + self.live_id, method='DELETE', expected=204, cleanup=True)
        self.live_created = False

    def run(self):
        self.load_and_verify_sessions()  # Shared lock/atomic refresh only if needed; no new password/mail login.
        image = self.fixture('demo_mango.jpg', FIXTURES['single'][2]); video = self.fixture('camera_replay_demo.mp4', VIDEO_SHA)
        self.report['fixtures'] = [{'path': 'app/android/app/src/main/assets/demo_mango.jpg', 'bytes': len(image), 'sha256': FIXTURES['single'][2]},
            {'path': 'app/android/app/src/main/assets/camera_replay_demo.mp4', 'bytes': len(video), 'sha256': VIDEO_SHA, 'encodedFrames': VIDEO_FRAMES,
             'dimensions': [640, 360], 'durationSeconds': 7.7051367578385594, 'groundTruth': 'Unavailable; encoded-frame count is container metadata, not fruit count.'}]
        stats_before = {}
        for role in ('Producer', 'Trader'):
            self.check(role + ' own runtime is ready', self.request(role, '/api/v1/ai/capabilities').get('aiReady') is True)
            self.check('Guide advertises mango-only server inference', self.request(role, '/api/v1/ai/guide').get('scope') == 'predicted-mango-only')
            job_snapshot(self.request(role, '/api/v1/ai/jobs'))
            stats_before[role] = self.request(role, '/api/v1/ai/stats?days=7')
        for role in ('Admin', 'Consumer'):
            self.exchange(role, '/api/v1/ai/capabilities', expected=403)
            self.exchange(role, '/api/v1/ai/jobs?mediaType=image', raw=image, content_type='image/jpeg', headers={'X-Client-Request-Id': 'denied-' + uuid.uuid4().hex}, expected=403)
            self.exchange(role, '/api/v1/ai/live/sessions', data={}, expected=403)
        producer = self.file_job('Producer', 'image', image, 'image/jpeg')
        trader = self.file_job('Trader', 'image', image, 'image/jpeg')
        self.check('Identical original photo has equal predictions for both Seller roles', producer['objects'] == trader['objects'] and producer['gradeCounts'] == trader['gradeCounts'])
        self.file_job('Trader', 'video', video, 'video/mp4')
        for role, count, decoded in (('Producer', 1, 1), ('Trader', 2, VIDEO_FRAMES + 1)):
            jobs = self.request(role, '/api/v1/ai/jobs')['items']; owned = [j for j in self.jobs if j['role'] == role]
            self.check(role + ' own history list contains all new succeeded results', all(any(row['id'] == j['id'] and row['status'] == 'Succeeded' for row in jobs) for j in owned))
            history = self.request(role, '/api/v1/history?limit=50')['items']
            self.check('Completed jobs appear in persisted interaction history', all(any(row.get('kind') == 'AiJobSucceeded' and j['id'] in row.get('body', '') for row in history) for j in owned))
            after = self.request(role, '/api/v1/ai/stats?days=7'); before = stats_before[role]
            self.check('Own usage counts jobs/decoded frames without summing detections as fruit', after['scope'] == 'own-jobs' and
                after['counts']['total'] - before['counts']['total'] == count and after['media']['framesProcessed'] - before['media']['framesProcessed'] == decoded)
        before_live = job_snapshot(self.request('Producer', '/api/v1/ai/jobs'))
        adapter = object.__new__(LiveSmoke); adapter.report = {}; raw, dimensions = LiveSmoke.image(adapter)
        self.report['liveFixture'] = adapter.report['fixture']
        started = self.live_start(201); seq = started['nextSequence']
        first = self.frame(raw, dimensions, seq); time.sleep(.25); second = self.frame(raw, dimensions, seq + 1)
        same = self.live_start(200)
        self.check('Resume while active keeps same session and next sequence', same['id'] == self.live_id and same['nextSequence'] == seq + 2)
        self.exchange('Producer', f'/api/v1/ai/live/sessions/{self.live_id}/frames', raw=raw, content_type='image/jpeg', headers={'X-Frame-Sequence': str(seq + 1)}, expected=409)
        stopped_id = self.live_id; self.stop_live()
        self.exchange('Producer', f'/api/v1/ai/live/sessions/{stopped_id}/frames', raw=raw, content_type='image/jpeg', headers={'X-Frame-Sequence': str(seq + 2)}, expected=404)
        restarted = self.live_start(201)
        self.check('Restart after stop creates new session starting at sequence1', self.live_id != stopped_id and restarted['nextSequence'] == 1)
        third = self.frame(raw, dimensions, 1); self.stop_live()
        self.check('All three same-JPEG live predictions match across stop/restart', first['objects'] == second['objects'] == third['objects'])
        self.check('Live creates no observable own durable job/frame updates', before_live == job_snapshot(self.request('Producer', '/api/v1/ai/jobs')))
        self.report['status'] = 'PASS'

    def finish(self):
        try:
            if self.live_created:
                try: self.stop_live()
                except Exception as error: self.report['liveCleanupErrorType'] = type(error).__name__; self.report['status'] = 'FAIL'
            for job in self.jobs:
                if job['status'] in ('Queued', 'Running'):
                    try: self.exchange(job['role'], '/api/v1/ai/jobs/' + job['id'] + '/cancel', data={}, cleanup=True)
                    except Exception as error: self.report['cancelErrorType'] = type(error).__name__
            self.save_ownership()
            self.report.update({'elapsedSeconds': round(time.monotonic() - self.started, 3), 'httpRequests': self.request_count, 'sessionRotations': self.rotations,
                'liveSessionStopped': not self.live_created, 'persistentJobsCreated': len(self.jobs)})
            self.output.parent.mkdir(parents=True, exist_ok=True)
            with self.output.open('x', encoding='utf-8') as stream: json.dump(self.report, stream, ensure_ascii=False, indent=2, allow_nan=False)
        finally:
            self.tokens.clear(); self.session_document.clear(); self.session_bytes = None
            if self.session_lock is not None: self.session_lock.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='NEW JSON under server/docs')
    parser.add_argument('--run', action='store_true', required=True)
    args = parser.parse_args(argv); output = args.output.resolve()
    if not output.is_relative_to((ROOT / 'docs').resolve()) or output.suffix != '.json' or output.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'choose_new_receipt_under_server_docs'})); return 2
    probe = AiAcceptance(args.sessions, output)
    try: probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'; probe.report['errorType'] = type(error).__name__
        # Never publish raw HTTP bodies, tokens, private paths or exception messages.
    finally:
        try: probe.finish()
        except Exception as error: probe.report['status'] = 'FAIL'; probe.report['receiptErrorType'] = type(error).__name__
    print(json.dumps({'status': probe.report['status'], 'requests': probe.request_count, 'jobs': len(probe.jobs), 'liveFrames': len(probe.report['liveFrames']), 'receipt': str(output.relative_to(ROOT))}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__': raise SystemExit(main())
