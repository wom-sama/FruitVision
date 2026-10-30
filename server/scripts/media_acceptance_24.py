"""Opt-in public HTTPS2.4 REST acceptance with real operator-provided OTP sessions.

Creates labeled ordinary demo articles/images/Direct messages; no passwords, OTP delivery,
SQL, role changes, inference, secret-device enrollment or invented cryptographic proof.
No import-time I/O. Execute only after the operator deploys and authorizes this release.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import hashlib
import io
import json
from pathlib import Path
import time
import urllib.error
import urllib.request
import uuid

from auth_publishing_e2e_23 import Acceptance as BaseAcceptance, ROOT, ROLES
from verticals_e2e import NoRedirect, ProbeFailure

TAG = 'DEMO QA2.4'
MAX_IMAGE = 5 * 1024 * 1024


class MediaAcceptance(BaseAcceptance):
    def __init__(self, sessions, output):
        super().__init__(sessions, output)
        self.deadline = self.started + 180
        self.request_count = 0
        self.profiles = {}
        self.report.update({
            'scope': 'Actual owned public HTTPS REST, four existing real-OTP sessions, ordinary canonical JPEG/article/Direct-image ACL and replay checks. Not four phones or WSS acceptance.',
            'ordinaryImagesAreEndToEndEncrypted': False,
            'secretCryptoAcceptance': 'NOT_RUN: no keys are generated/enrolled, no sealed packets are posted, and no client/native cryptography is tested. Separate real-Sodium acceptance is required.',
            'aiInference': 'NOT_RUN: this driver calls no AI endpoints for any role.',
            'requestBudget': 80,
            'formalRoleUpgradeLive': 'NOT_RUN: main roles are preserved; no formal identity evidence is fabricated.'})

    def exchange(self, role, path, data=None, method=None, expected=200, raw=None,
                 content_type=None, binary=False):
        if not isinstance(path, str) or not path.startswith('/') or path.startswith('//') or '://' in path or any(c in path for c in ('\\', '\r', '\n', '\0', '#')):
            raise ProbeFailure('Unsafe acceptance API route')
        with self.lock:
            if self.request_count >= 80:
                raise ProbeFailure('Bounded acceptance HTTP budget reached')
            self.request_count += 1
        headers = {'Accept': 'image/jpeg' if binary else 'application/json'}
        if role is not None:
            headers['Authorization'] = 'Bearer ' + self.tokens[role]
        body = raw if raw is not None else (json.dumps(data, ensure_ascii=False).encode('utf-8') if data is not None else None)
        if body is not None:
            headers['Content-Type'] = content_type or 'application/json'
        verb = method or ('POST' if body is not None else 'GET')
        status, start = None, time.monotonic()
        request = urllib.request.Request(self.base + path, data=body, headers=headers, method=verb)
        limit = MAX_IMAGE if binary else 1024 * 1024
        try:
            try:
                response = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=self.remaining(15))
            except urllib.error.HTTPError as error:
                response = error
            with response:
                status = response.status
                payload = response.read(limit + 1)
                if len(payload) > limit:
                    raise ProbeFailure('Acceptance response exceeded bounded size')
                media_type = response.headers.get('Content-Type', '').split(';', 1)[0]
                result = payload if binary else (json.loads(payload) if payload and 'json' in media_type else None)
        finally:
            with self.lock:
                self.report['requests'].append({'role': role or 'anonymous', 'method': verb, 'route': path, 'status': status,
                    'expectedStatus': expected, 'latencyMs': round((time.monotonic() - start) * 1000, 1)})
        allowed = expected if isinstance(expected, tuple) else (expected,)
        self.check(f'{role or "anonymous"} {verb} {path} returns expected status', status in allowed)
        return status, result, media_type

    def request(self, role, path, data=None, method=None, expected=200):
        return self.exchange(role, path, data=data, method=method, expected=expected)[1]

    def review(self, lane, record, status):
        return self.request('Admin', f'/api/v1/admin/{lane}/{record["id"]}/review',
            {'status': status, 'reason': TAG + ': technical demo only, not legal or business verification.', 'expectedRevision': record['revision']})

    def fixture_jpeg(self, suffix, variant=0):
        # A real encoded input, deliberately larger than2048 and carrying harmless test EXIF.
        # Canonical outputs are downloaded from the actual server, never fabricated locally.
        from PIL import Image, ImageDraw
        folder = ROOT / '.local/acceptance-media24'
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / (suffix + '-' + str(variant) + '.jpg')
        with Image.new('RGB', (2400, 1600), (220, 235 - variant, 195)) as image:
            draw = ImageDraw.Draw(image)
            for i in range(8):
                draw.rectangle((100 + i * 270, 200, 280 + i * 270, 1400), fill=(40 + i * 15, 125, 70 + variant))
            draw.text((100, 70), 'DEMO QA2.4 - synthetic JPEG - no personal data', fill=(0, 0, 0))
            exif = Image.Exif(); exif[315] = 'DEMO_QA24_REMOVE'; exif[274] = 1
            image.save(target, format='JPEG', quality=90, exif=exif)
        value = target.read_bytes()
        self.check('real Pillow JPEG fixture is within upload cap', value.startswith(b'\xff\xd8\xff') and len(value) <= MAX_IMAGE)
        return value

    def image(self, role, path, expected_shape):
        from PIL import Image
        _, value, content_type = self.exchange(role, path, binary=True)
        self.check('actual image response is JPEG', content_type == 'image/jpeg')
        with Image.open(io.BytesIO(value)) as image:
            image.load()
            self.check('actual canonical JPEG dimensions match server metadata', image.format == 'JPEG' and
                tuple(image.size) == (expected_shape['width'], expected_shape['height']) and max(image.size) <= 2048)
            self.check('actual server canonicalization removed EXIF and resized input', not image.getexif() and max(image.size) < 2400)
        self.check('actual image byte length matches stored metadata', len(value) == expected_shape['sizeBytes'])
        return {'sizeBytes': len(value), 'sha256': hashlib.sha256(value).hexdigest(), 'width': expected_shape['width'], 'height': expected_shape['height'], 'exifRemoved': True}

    def upload_image(self, role, path, image):
        value = self.exchange(role, path, raw=image, content_type='image/jpeg', expected=201)[1]
        # Retain safe IDs immediately: a later assertion must not hide already-created records.
        if path == '/api/v1/articles/images':
            self.report['records'].setdefault('articleImageUploadIds', []).append(value['id'])
        else:
            self.report['records']['ordinaryImageMessageId'] = value['id']
            if isinstance(value.get('image'), dict):
                self.report['records']['ordinaryChatImageId'] = value['image']['id']
        return value

    def branch(self, role, suffix):
        rows = self.request(role, '/api/v1/branches/mine?limit=50')['items']
        branch = next((row for row in rows if row['status'] == 'Approved' and row['owner']['id'] == self.actors[role]['id']), None)
        if branch is None:
            branch = self.request(role, '/api/v1/branches', {'name': TAG + ' technical branch ' + suffix,
                'countryCode': 'VN', 'provinceCode': '79', 'street': TAG + ' synthetic technical-test address', 'phone': '+84900000000'}, expected=201)
            self.report['records'][role.lower() + 'BranchId'] = branch['id']
            branch = self.review('branches', branch, 'Approved')
        self.report['records'][role.lower() + 'BranchId'] = branch['id']
        return branch

    def assert_sender(self, message, role):
        sender = message.get('sender') or {}
        self.check('normal image message sender is exact authorized public identity', set(sender) == {'id', 'displayName', 'role'} and
            sender['id'] == self.actors[role]['id'] and sender['role'] == role and sender['displayName'] == self.profiles[role]['displayName'])

    def run(self):
        self.load_sessions()
        suffix = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]
        with self.phase('four real supplied sessions; no authentication manufacture'):
            for role in ROLES:
                profile = self.request(role, '/api/v1/auth/me')
                self.check(role + ' current verified approved role matches supplied real identity', profile['id'] == self.actors[role]['id'] and
                    profile['role'] == role and profile['emailConfirmed'] and profile['isActive'] and profile['approvalStatus'] == 'Approved')
                self.profiles[role] = profile
            self.report['actors'] = self.actors
        with self.phase('trusted API geography and actual Pillow input'):
            directory = self.request(None, '/api/v1/locations/provinces?country=VN')
            self.check('current API34-province VN directory with79 and provenance', directory.get('countryCode') == 'VN' and len(directory['items']) == 34 and
                any(row['code'] == '79' for row in directory['items']) and bool(directory.get('source')))
            original = self.fixture_jpeg(suffix)
            different = self.fixture_jpeg(suffix, variant=1)
            self.report['inputFixture'] = {'synthetic': True, 'realJpegEncoding': True, 'width': 2400, 'height': 1600,
                'sizeBytes': len(original), 'sha256': hashlib.sha256(original).hexdigest(), 'hasHarmlessExifForRemovalTest': True}
        with self.phase('Consumer community article with real canonical image and moderation ACL'):
            image = self.upload_image('Consumer', '/api/v1/articles/images', original)
            self.check('unattached image upload exposes no public URL', not image.get('downloadPath') and image['contentType'] == 'image/jpeg')
            article = self.request('Consumer', '/api/v1/articles', {'title': TAG + ' community observation ' + suffix,
                'body': TAG + ': synthetic community observation for image/moderation acceptance, not an actual price or transaction.', 'imageId': image['id']}, expected=201)
            self.check('Consumer article is Community lane and AwaitingReview', article['audienceLane'] == 'Community' and article['status'] == 'AwaitingReview')
            self.report['records']['communityArticleId'] = article['id']
            path = f'/api/v1/articles/{article["id"]}/image'
            self.request(None, path, expected=404); self.request('Trader', path, expected=404)
            canonical = self.image('Consumer', path, image)
            published = self.review('articles', article, 'Published')
            public = self.request(None, f'/api/v1/articles/{article["id"]}')
            self.check('published Community detail omits private review reason', public['audienceLane'] == 'Community' and 'reviewReason' not in public)
            self.check('published image matches actual private canonical bytes', self.image(None, path, image)['sha256'] == canonical['sha256'])
            paused = self.request('Consumer', f'/api/v1/articles/{article["id"]}/withdraw', {'expectedRevision': published['revision']})
            self.request(None, path, expected=404)
            self.review('articles', paused, 'Published')
            self.report['communityCanonicalImage'] = canonical
        with self.phase('Seller Professional article uses owned Approved branch; no legacy403 expectation'):
            producer_branch = self.branch('Producer', suffix)
            trader_branch = self.branch('Trader', suffix)
            image = self.upload_image('Producer', '/api/v1/articles/images', original)
            body = {'title': TAG + ' professional mango information ' + suffix,
                'body': TAG + ': synthetic professional information, not verified stock, legal evidence or a commercial offer.', 'imageId': image['id']}
            self.request('Producer', '/api/v1/articles', body, expected=400)
            self.request('Producer', '/api/v1/articles', {**body, 'branchId': trader_branch['id']}, expected=409)
            article = self.request('Producer', '/api/v1/articles', {**body, 'branchId': producer_branch['id']}, expected=201)
            self.check('Seller article is Professional lane with own branch snapshot', article['audienceLane'] == 'Professional' and article['branchId'] == producer_branch['id'])
            self.report['records']['professionalArticleId'] = article['id']
            published = self.review('articles', article, 'Published')
            rows = self.request('Consumer', '/api/v1/articles?lane=Professional&limit=20')['items']
            self.check('Professional public lane includes new controlled article', any(row['id'] == article['id'] and row['audienceLane'] == 'Professional' for row in rows))
            self.report['professionalCanonicalImage'] = self.image(None, f'/api/v1/articles/{article["id"]}/image', image)
        with self.phase('article DM exactly reused; ordinary chat image private/idempotent and REST recoverable'):
            route = f'/api/v1/articles/{published["id"]}/conversations'
            with ThreadPoolExecutor(max_workers=2) as pool:
                replies = list(pool.map(lambda _: self.exchange('Trader', route, data={}, expected=(200, 201)), range(2)))
            self.report['records']['articleConversationIds'] = sorted({reply[1]['id'] for reply in replies})
            self.check('simultaneous article contact creates once and reuses once', sorted(reply[0] for reply in replies) == [200, 201])
            conversation = replies[0][1]['id']
            self.check('article contact returns one bound Direct thread', replies[1][1]['id'] == conversation and replies[0][1]['articleId'] == published['id'] and replies[0][1]['kind'] == 'Direct')
            self.report['records']['articleConversationId'] = conversation
            self.request('Admin', route, {}, expected=403); self.request('Producer', route, {}, expected=409)
            self.request('Consumer', f'/api/v1/conversations/{conversation}/messages', expected=404)
            key = 'qa24_' + uuid.uuid4().hex
            upload = f'/api/v1/conversations/{conversation}/images?clientMessageId={key}'
            message = self.upload_image('Trader', upload, original)
            self.assert_sender(message, 'Trader')
            self.check('ordinary image message has image metadata', isinstance(message.get('image'), dict) and message['image']['contentType'] == 'image/jpeg')
            repeated = self.exchange('Trader', upload, raw=original, content_type='image/jpeg', expected=200)[1]
            self.check('same raw JPEG/idempotency key reuses message and image', repeated['id'] == message['id'] and repeated['image']['id'] == message['image']['id'])
            self.exchange('Trader', upload, raw=different, content_type='image/jpeg', expected=409)
            path = f'/api/v1/conversations/{conversation}/images/{message["image"]["id"]}'
            canonical = self.image('Producer', path, message['image'])
            self.request('Consumer', path, expected=404); self.request('Admin', path, expected=404); self.request(None, path, expected=401)
            rows = self.request('Producer', f'/api/v1/conversations/{conversation}/messages?limit=20')['items']
            recovered = [row for row in rows if row['id'] == message['id']]
            self.check('REST catchup contains exactly one image message with correct metadata', len(recovered) == 1 and recovered[0].get('image', {}).get('id') == message['image']['id'])
            self.assert_sender(recovered[0], 'Trader')
            self.report['ordinaryChatCanonicalImage'] = canonical
        with self.phase('opaque secret metadata authorization surface; no key/cipher mutation or crypto claim'):
            counts = {}
            for role in ('Admin', 'Consumer'):
                self.request(role, '/api/v1/secret/devices', expected=403)
                self.request(role, '/api/v1/secret/conversations', expected=403)
            allowed = {'deviceId', 'userId', 'version', 'label', 'encryptionPublicKey', 'signingPublicKey', 'createdAt', 'revokedAt'}
            for role in ('Producer', 'Trader'):
                devices = self.request(role, '/api/v1/secret/devices')['items']
                self.check(role + ' secret bundle endpoint exposes public metadata only for own account',
                    all(set(row).issubset(allowed) and row.get('userId') == self.actors[role]['id'] for row in devices))
                counts[role] = sum(row.get('revokedAt') is None for row in devices)
                self.request(role, '/api/v1/secret/conversations?limit=5')
                self.request(role, '/api/v1/secret/conversations/' + str(uuid.uuid4()), expected=404)
            self.request(None, '/api/v1/secret/devices', expected=401)
            self.report['secretMetadataBoundary'] = {'authorization': 'PASS', 'activeDeviceCounts': counts,
                'registeredOrRotatedDevices': False, 'postedSecretMessagesOrBlobs': False, 'serverCannotDecryptProvenByThisDriver': False,
                'nextRequiredEvidence': 'Separate real-Sodium signed/sealed text+image interop, OOB fingerprint verification, wrong-key/tamper and native keybag/third-party tests.'}
        self.report['preservedDemoData'] = 'Published controlled synthetic articles/ordinary images and Direct thread remain for operator inspection; no history is automatically deleted.'
        self.report['status'] = 'PASS'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True, help='Existing private server/.local JSON: baseURL and four real role sessions. Never paste tokens into CLI.')
    parser.add_argument('--run', action='store_true', required=True, help='Authorize labeled persistent QA2.4 records AFTER actual2.4 deployment.')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/media-https-e2e-24.json')
    args = parser.parse_args(argv)
    output = args.output.resolve()
    if output.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'receipt_already_exists_choose_new_output'})); return 2
    probe = MediaAcceptance(args.sessions, output)
    try:
        probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'; probe.report['errorType'] = type(error).__name__
        if isinstance(error, ProbeFailure): probe.report['failedStep'] = str(error)[:240]
    finally:
        probe.report['httpRequests'] = probe.request_count
        probe.profiles.clear()
        try: probe.finish()
        except Exception as error: probe.report['status'] = 'FAIL'; probe.report['receiptErrorType'] = type(error).__name__
        print(json.dumps({'status': probe.report['status'], 'checks': len(probe.report['checks']), 'httpRequests': probe.request_count,
            'receipt': str(output), 'scope': 'HTTPS REST ordinary images; read-only secret metadata boundary; no native/E2EE/AI proof'}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
