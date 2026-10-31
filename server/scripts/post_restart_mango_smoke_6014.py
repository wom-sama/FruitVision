"""Dormant one-job restart smoke; run only after Root grants the inference window.

The operator explicitly supplies the new origin already bound to the same local API.
No redirects, password/OTP login, role/key changes, freshness reset or mutation retry.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import time
import uuid

from feedback_acceptance_25 import FeedbackAcceptance
from mango_image_smoke_24 import ASSETS, FIXTURES, ROOT, Smoke, SmokeFailure, require, validate_base, validate_result


class RestartSmoke(Smoke):
    def __init__(self, args):
        super().__init__(args)
        self.deadline = self.started + 60
        self.session_lock = None
        self.report['scope'] = 'Post-restart public HTTPS technical smoke: one existing mango JPEG, one Producer job, bounded polling and preview. No video/live rerun, native, FPS or quality/accuracy proof.'
        self.report['maximumSubmissions'] = 1

    def load(self):
        path = self.args.sessions.resolve()
        require(path.is_relative_to((ROOT / '.local').resolve()) and path.is_file() and path.stat().st_size <= 65536,
                'Use the existing bounded private canonical session JSON')
        lock = path.with_name(path.name + '.feedback25.lock')
        descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor); self.session_lock = lock
        original = path.read_bytes(); document = json.loads(original.decode('utf-8-sig'))
        tunnel = json.loads((ROOT / '.local/tunnel-state.json').read_text(encoding='utf-8-sig'))
        self.base = validate_base(self.args.authorized_base.rstrip('/'), tunnel['publicUrl'])
        origin_changed = document.get('baseURL', '').rstrip('/') != self.base
        supplied = document['sessions']['Producer']; self.token = supplied['accessToken']
        require(isinstance(self.token, str) and re.fullmatch(r'[A-Za-z0-9_-]{43}', self.token), 'Invalid supplied opaque access token')
        expected_user = str(uuid.UUID(supplied['user']['id']))
        # GET may report401 once; only that condition authorizes one normal refresh.
        previous_requests = len(self.report['requests']); rotated = False
        try:
            profile = self.request('/api/v1/auth/me')
        except SmokeFailure:
            require(len(self.report['requests']) == previous_requests + 1 and self.report['requests'][-1]['status'] == 401,
                    'Stop after non-authentication failure; no automatic retry')
            refresh = supplied.get('refreshToken')
            require(isinstance(refresh, str) and re.fullmatch(r'[A-Za-z0-9_-]{43}', refresh), 'A valid real refresh token is required')
            pair = self.request('/api/v1/auth/refresh', method='POST', anonymous=True,
                data=json.dumps({'refreshToken': refresh}).encode('utf-8'), headers={'Content-Type': 'application/json'})
            require(pair.get('user', {}).get('id') == expected_user and all(isinstance(pair.get(key), str) and
                re.fullmatch(r'[A-Za-z0-9_-]{43}', pair[key]) for key in ('accessToken', 'refreshToken')), 'Refresh identity/token shape changed')
            supplied.update({key: pair[key] for key in ('accessToken', 'refreshToken', 'expiresIn', 'user')})
            self.token = pair['accessToken']; rotated = True
            # Persist rotated credentials immediately with compare-and-swap, even if a later read fails.
            document['baseURL'] = self.base
            original = FeedbackAcceptance.write_private(path, document, expected_bytes=original)
            profile = self.request('/api/v1/auth/me')
        require(profile.get('id') == expected_user and profile.get('role') == 'Producer' and profile.get('isActive') is True
                and profile.get('emailConfirmed') is True and profile.get('approvalStatus') == 'Approved', 'Current Producer identity is not eligible')
        migrated = document.get('baseURL', '').rstrip('/') != self.base
        if migrated:
            document['baseURL'] = self.base
            FeedbackAcceptance.write_private(path, document, expected_bytes=original)
        self.report.update({'baseURL': self.base, 'userId': expected_user, 'normalRefreshPerformed': rotated,
            'canonicalOriginMigrated': origin_changed, 'freshStrongAuthenticationClaimed': False})

    def run(self):
        self.load()
        require(self.request('/api/v1/ai/capabilities').get('aiReady') is True, 'PC AI runtime is unavailable; stop without resubmission')
        require(not any(job.get('status') in ('Queued', 'Running') for job in self.request('/api/v1/ai/jobs').get('items', [])), 'Producer already has an active job')
        name, content_type, expected_hash = FIXTURES['single']; raw = (ASSETS / name).read_bytes()
        require(hashlib.sha256(raw).hexdigest() == expected_hash, 'Known mango fixture hash changed')
        self.report['fixture'] = {'path': 'app/android/app/src/main/assets/' + name, 'sha256': expected_hash, 'sizeBytes': len(raw),
            'limitation': 'Existing transformed demo photo; not independent field-quality ground truth.'}
        job = self.request('/api/v1/ai/jobs?mediaType=image', method='POST', data=raw, expected=202,
            headers={'Content-Type': content_type, 'X-Client-Request-Id': 'restart6014-' + uuid.uuid4().hex})
        self.job_id = str(uuid.UUID(job['id'])); self.job_status = job['status']; self.report['jobId'] = self.job_id
        for attempt in range(20):
            job = self.request('/api/v1/ai/jobs/' + self.job_id); self.job_status = job['status']
            if self.job_status not in ('Queued', 'Running'): break
            if attempt < 19: time.sleep(min(1, self.remaining()))
        self.check('One real post-restart image job succeeded', self.job_status == 'Succeeded')
        validate_result(job.get('result')); self.report['result'] = job['result']
        self.check('Pinned mango technical result and image-count semantics are valid', True)
        require(job.get('previewAvailable') is True, 'Successful job lacks preview')
        preview = self.request('/api/v1/ai/jobs/' + self.job_id + '/preview', binary=True)
        self.report['preview'] = {'sizeBytes': len(preview), 'sha256': hashlib.sha256(preview).hexdigest()}
        self.report['status'] = 'PASS'

    def finish(self):
        try:
            super().finish()
        finally:
            if self.session_lock is not None: self.session_lock.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True)
    parser.add_argument('--authorized-base', required=True, help='Exact new operator-owned origin, positively bound by Root to the existing API')
    parser.add_argument('--output', type=Path, required=True, help='NEW technical receipt under server/docs')
    parser.add_argument('--run', action='store_true', required=True)
    args = parser.parse_args(argv); args.role = 'Producer'
    if args.output.exists(): parser.error('Choose a new output; never overwrite a prior probe')
    probe = RestartSmoke(args)
    try: probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'; probe.report['errorType'] = type(error).__name__
    finally:
        try: probe.finish()
        except Exception as error: probe.report['status'] = 'FAIL'; probe.report['receiptErrorType'] = type(error).__name__
    print(json.dumps({'status': probe.report['status'], 'jobId': probe.job_id, 'requests': len(probe.report['requests']),
        'receipt': str(probe.output.relative_to(ROOT)), 'qualityEvaluation': 'NOT_PERFORMED'}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__': raise SystemExit(main())
