"""Opt-in HTTPS 2.5 acceptance; run only after the operator deploys the matching API.

Uses four private real-OTP sessions. Creates labeled synthetic records, never modifies an
existing application, grants a role, sends mail, executes AI or changes E2EE keys/ciphertext.
No import-time actions. Public output contains no identities, bodies, evidence or tokens.
Existing Consumer active applications stop the run before any domain writes.

From server after deployment:
  & ./.tools/ai-venv/Scripts/python.exe -X utf8 -B scripts/feedback_acceptance_25.py --sessions .local/2.4-real-sessions.json --run --output docs/feedback-https-acceptance-25.json
Approximately 60 requests with fresh access; at most 68 when all four need refresh; hard cap 72.
Private owned IDs are retained under .local/feedback25. Rejected applications/audits cannot
be deleted through this API; Paused article, Closed group and labeled history remain seed.
After failure inspect those private references; do not rerun mutations automatically.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import urllib.parse
import uuid

from media_acceptance_24 import MediaAcceptance, ROOT, ROLES
from verticals_e2e import ProbeFailure

TAG = 'DEMO QA2.5'
MAX_REQUESTS = 72
GUID = re.compile(r'\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b')
OPAQUE = re.compile(r'[A-Za-z0-9_-]{43}')


class FeedbackAcceptance(MediaAcceptance):
    def __init__(self, sessions, output):
        super().__init__(sessions, output)
        self.run_id = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]
        self.owned, self.owned_states = {}, {}
        self.private_output = ROOT / '.local/feedback25' / (self.run_id + '.json')
        self.session_document, self.session_bytes = {}, None
        self.session_lock = None
        self.rotations = 0
        self.report.pop('formalRoleUpgradeLive', None)
        self.report.update({
            'sessionProvenance': 'Existing separately verified Email OTP sessions; access is checked against auth/me and an expired access token may rotate through the normal refresh endpoint with exclusive atomic private-file persistence. No token or authentication freshness is fabricated.',
            'scope': 'HTTPS 2.5 REST with four real supplied OTP sessions: synthetic role-application submission/review, article image/likes/comments, normal Direct and Admin-owned group. Not native/WSS/E2EE cryptography acceptance.',
            'requestBudget': MAX_REQUESTS,
            'formalRoleApplicationFlow': 'Synthetic technical evidence only; PASS requires both requested roles end Rejected and Consumer stays Consumer. No legal verification or role grant.',
            'secretCryptoAcceptance': 'NOT_RUN/UNCHANGED: no secret endpoint, key, device, ciphertext or encrypted image is mutated. Separate real-Sodium/native evidence remains required.',
            'intendedCleanup': 'On PASS: owned technical applications Rejected, article Paused, group Closed. Likes/comments, ordinary image, Direct/history and audits remain labeled operator seed. On FAIL: inspect private owned references; do not retry mutations or delete foreign records.'})

    def check(self, name, passed):
        # Base helpers include routes in checks. Never publish concrete IDs or query values.
        super().check(GUID.sub('{id}', re.sub(r'\?\S+', '', name)), passed)

    def exchange(self, role, path, *args, **kwargs):
        if self.request_count >= MAX_REQUESTS:
            raise ProbeFailure('Bounded feedback acceptance HTTP budget reached')
        before = len(self.report['requests'])
        try:
            return super().exchange(role, path, *args, **kwargs)
        finally:
            for row in self.report['requests'][before:]:
                route = urllib.parse.urlsplit(row.pop('route', ''))
                row['routeTemplate'] = GUID.sub('{id}', route.path)
                if route.query:
                    row['queryNames'] = sorted(urllib.parse.parse_qs(route.query))

    @staticmethod
    def write_private(path, value, expected_bytes=None):
        path = path.resolve()
        if not path.is_relative_to((ROOT / '.local').resolve()):
            raise ProbeFailure('Private receipt/session file must remain under server/.local')
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
        encoded = json.dumps(value, ensure_ascii=False, indent=2).encode('utf-8')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        # A new rotated pair is already retained in the private .tmp if an unrelated writer
        # changed the source. Stop; never retry an already-used refresh token or overwrite it.
        if expected_bytes is not None and path.read_bytes() != expected_bytes:
            raise ProbeFailure('Private sessions changed concurrently; stop and recover the private pending file')
        os.replace(temporary, path)
        return encoded

    def own(self, kind, record):
        identifier = str(uuid.UUID(record['id']))
        self.owned.setdefault(kind, []).append(identifier)
        if 'status' in record:
            self.owned_states[identifier] = record['status']
        self.save_ownership()
        return identifier

    def save_ownership(self):
        if self.owned:
            self.write_private(self.private_output, {'runId': self.run_id, 'label': TAG,
                'status': self.report['status'], 'ownedOnly': self.owned, 'states': self.owned_states,
                'consumerId': self.actors.get('Consumer', {}).get('id'),
                'warning': 'Only these newly created synthetic IDs may be cleaned up. Never modify an existing human draft. No passwords, OTPs or session tokens are stored here.'})

    def load_and_verify_sessions(self):
        path = self.sessions_file.resolve()
        if not path.is_relative_to((ROOT / '.local').resolve()) or not path.is_file():
            raise ProbeFailure('Sessions must be an existing private file under server/.local')
        lock_path = path.with_name(path.name + '.feedback25.lock')
        try:
            fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            raise ProbeFailure('Session file is in use; operator must verify no concurrent driver before removing a stale lock') from None
        os.close(fd)
        self.session_lock = lock_path
        self.load_sessions()  # Reuses bounded file, opaque-token and owned current HTTPS tunnel checks.
        self.session_bytes = path.read_bytes()
        self.session_document = json.loads(self.session_bytes.decode('utf-8-sig'))
        for role in ROLES:
            status, profile, _ = self.exchange(role, '/api/v1/auth/me', expected=(200, 401))
            if status == 401:
                if path.read_bytes() != self.session_bytes:
                    raise ProbeFailure('Private sessions changed before refresh; no refresh attempted')
                old = self.session_document['sessions'][role]
                refresh = old.get('refreshToken')
                if not isinstance(refresh, str) or not OPAQUE.fullmatch(refresh):
                    raise ProbeFailure('Expired session requires a real operator login; no valid stored refresh token')
                _, rotated, _ = self.exchange(None, '/api/v1/auth/refresh', data={'refreshToken': refresh})
                self.check('rotated pair has opaque token shapes and same real user',
                    all(isinstance(rotated.get(key), str) and OPAQUE.fullmatch(rotated[key]) for key in ('accessToken', 'refreshToken')) and
                    rotated.get('user', {}).get('id') == self.actors[role]['id'])
                old.update({key: rotated[key] for key in ('accessToken', 'refreshToken', 'expiresIn', 'user') if key in rotated})
                self.session_bytes = self.write_private(path, self.session_document, expected_bytes=self.session_bytes)
                self.tokens[role] = rotated['accessToken']
                self.rotations += 1
                profile = self.request(role, '/api/v1/auth/me')
            self.check(role + ' is the current active verified approved supplied role', profile['id'] == self.actors[role]['id'] and
                profile['role'] == role and profile['isActive'] and profile['emailConfirmed'] and profile['approvalStatus'] == 'Approved')
            self.profiles[role] = profile

    def review(self, lane, record, status):
        return self.request('Admin', f'/api/v1/admin/{lane}/{record["id"]}/review',
            {'status': status, 'reason': TAG + ': synthetic technical fixture only; not legal or commercial evidence.', 'expectedRevision': record['revision']})

    def role_application(self, requested, jpeg):
        app = self.request('Consumer', '/api/v1/role-applications', {'requestedRole': requested}, expected=201)
        identifier = self.own('roleApplications', app)
        self.check('new owned role application begins Draft', app['status'] == 'Draft' and app['userId'] == self.actors['Consumer']['id'] and app['requestedRole'] == requested)
        profile = {'organisationName': TAG + ' SYNTHETIC ' + requested + ' ' + self.run_id,
            'address': TAG + ' synthetic technical test address, not a verified business',
            'countryCode': 'VN', 'provinceCode': '79', 'phone': '+84900000000',
            'products': ['mango'], 'expectedRevision': app['revision']}
        if requested == 'Producer':
            profile['cultivatedAreaHa'] = 1.25
            invalid = {**profile, 'businessRegistrationNumber': 'DEMO-NOT-LEGAL'}
            category = 'ProductionEvidence'
        else:
            profile['businessRegistrationNumber'] = 'DEMO-NOT-LEGAL-' + self.run_id
            invalid = {**profile, 'cultivatedAreaHa': 1.25}
            category = 'BusinessEvidence'
        route = '/api/v1/role-applications/' + identifier
        self.request('Consumer', route, invalid, method='PUT', expected=400)
        app = self.request('Consumer', route, profile, method='PUT')
        _, app, _ = self.exchange('Consumer', route + f'/evidence?category={category}&expectedRevision={app["revision"]}', raw=jpeg, content_type='image/jpeg', expected=201)
        self.check('real private JPEG proof is retained with correct role category', len(app['evidence']) == 1 and
            app['evidence'][0]['category'] == category and app['evidence'][0]['contentType'] == 'image/jpeg' and app['evidence'][0]['sizeBytes'] == len(jpeg))
        app = self.request('Consumer', route + '/submit', {'expectedRevision': app['revision']})
        self.owned_states[identifier] = app['status']; self.save_ownership()
        self.check('explicit Submit commits Submitted with timestamp', app['status'] == 'Submitted' and bool(app['submittedAt']))
        queue = self.request('Admin', '/api/v1/admin/role-applications?status=Submitted&limit=50')['items']
        found = next((row for row in queue if row['id'] == identifier), None)
        self.check('correct Admin Submitted queue contains owned application with public applicant identity and proof', found is not None and
            found['applicant'] == {'id': self.actors['Consumer']['id'], 'displayName': self.profiles['Consumer']['displayName'], 'role': 'Consumer'} and len(found['evidence']) == 1)
        detail = self.request('Admin', '/api/v1/admin/role-applications/' + identifier)
        self.check('Admin can inspect own synthetic submitted profile with distinct role fields', detail['status'] == 'Submitted' and detail['requestedRole'] == requested and
            ((requested == 'Producer' and detail['cultivatedAreaHa'] == 1.25 and detail['taxCode'] is None and detail['businessRegistrationNumber'] is None) or
             (requested == 'Trader' and detail['cultivatedAreaHa'] is None and bool(detail['businessRegistrationNumber']))))
        app = self.review('role-applications', app, 'Rejected')
        self.check('technical rejection releases active application without granting role', app['status'] == 'Rejected')
        self.owned_states[identifier] = 'Rejected'; self.save_ownership()

    def run(self):
        with self.phase('real supplied sessions; refresh only expired access once with private atomic persistence'):
            self.load_and_verify_sessions()
        with self.phase('protect human drafts before domain writes; trusted API location; real JPEG'):
            existing = self.request('Consumer', '/api/v1/role-applications?limit=50')
            self.check('no existing active Consumer application may be touched', not any(row['status'] in ('Draft', 'Submitted', 'NeedsInformation') for row in existing['items']))
            self.check('bounded application history is complete before creating a QA application', not existing.get('next'))
            directory = self.request(None, '/api/v1/locations/provinces?country=VN')
            self.check('trusted location API contains selected VN province', directory.get('countryCode') == 'VN' and any(item['code'] == '79' for item in directory['items']))
            jpeg = self.fixture_jpeg('feedback25-' + self.run_id)
        with self.phase('two real owned applications: distinct Producer/Trader fields; submit visible to Admin; technical rejection'):
            self.role_application('Producer', jpeg)
            self.role_application('Trader', jpeg)
            self.check('main Consumer role remains unchanged', self.request('Consumer', '/api/v1/auth/me')['role'] == 'Consumer')
        with self.phase('new Consumer article and real canonical thumbnail after Admin publication'):
            _, image, _ = self.exchange('Consumer', '/api/v1/articles/images', raw=jpeg, content_type='image/jpeg', expected=201)
            self.own('articleImages', image)
            article = self.request('Consumer', '/api/v1/articles', {'title': TAG + ' synthetic observation ' + self.run_id,
                'body': TAG + ': technical mango observation fixture, not verified food quality, stock, price or a transaction.', 'imageId': image['id']}, expected=201)
            article_id = self.own('articles', article)
            image_path = f'/api/v1/articles/{article_id}/image'
            self.request(None, image_path, expected=404)
            article = self.review('articles', article, 'Published')
            self.owned_states[article_id] = 'Published'; self.save_ownership()
            thumbnail = self.image(None, image_path, image)
            self.report['canonicalThumbnail'] = {key: thumbnail[key] for key in ('width', 'height', 'sizeBytes', 'exifRemoved')}
        comments = {}
        with self.phase('Producer Trader Consumer explicit likes and comments; retry and deletion cannot duplicate or resurrect'):
            route = f'/api/v1/articles/{article_id}'
            for role in ('Producer', 'Trader', 'Consumer'):
                liked = self.request(role, route + '/like', {'liked': True}, method='PUT')
                self.check('explicit like is true', liked['liked'])
                body = {'body': TAG + ' synthetic ' + role + ' observation', 'clientCommentId': str(uuid.uuid4())}
                comment = self.request(role, route + '/comments', body, expected=201)
                self.own('comments', comment)
                self.check('comment author exposes exact authorized public identity', comment['author'] ==
                    {'id': self.actors[role]['id'], 'displayName': self.profiles[role]['displayName'], 'role': role})
                comments[role] = (comment, body)
            repeated = self.request('Producer', route + '/comments', comments['Producer'][1])
            self.check('exact comment retry uses original record', repeated['id'] == comments['Producer'][0]['id'])
            self.request('Producer', route + '/like', {'liked': True}, method='PUT')
            self.request('Producer', route + '/comments', {**comments['Producer'][1], 'body': 'Changed retry must conflict'}, expected=409)
            totals = self.request('Consumer', route + '/likes')
            self.check('durable engagement counts are three likes and three comments', totals['likeCount'] == 3 and totals['commentCount'] == 3)
            page = self.request('Admin', route + '/comments?limit=20')
            self.check('Admin sees all three public comments with moderation permission', len(page['items']) == 3 and all(item['canDelete'] for item in page['items']))
            self.request('Consumer', route + '/comments/' + comments['Consumer'][0]['id'], method='DELETE', expected=204)
            self.request('Consumer', route + '/comments', comments['Consumer'][1], expected=409)
            page = self.request('Consumer', route + '/comments?limit=20')
            self.check('deleted comment is excluded from durable counts and list', page['commentCount'] == 2 and len(page['items']) == 2)
        with self.phase('ordinary article Direct remains private and reused; E2EE endpoints untouched'):
            contact = self.request('Producer', f'/api/v1/articles/{article_id}/conversations', {}, expected=201)
            direct_id = self.own('directConversations', contact)
            reused = self.request('Producer', f'/api/v1/articles/{article_id}/conversations', {})
            self.check('normal article contact reuses one exact Direct', reused['id'] == direct_id and contact['kind'] == 'Direct')
            self.request('Consumer', f'/api/v1/conversations/{direct_id}/messages')
            self.request('Trader', f'/api/v1/conversations/{direct_id}/messages', expected=404)
        with self.phase('only Admin creates groups; all three Approved business/community users can join and chat'):
            group_body = {'title': TAG + ' discussion ' + self.run_id, 'region': 'Đồng Tháp', 'productCode': 'mango'}
            group = self.request('Admin', '/api/v1/community/groups', group_body, expected=201)
            group_id = self.own('groups', group)
            self.owned_states[group_id] = 'Open'; self.save_ownership()
            self.check('new group is owned by Admin with creator membership', group['ownerId'] == self.actors['Admin']['id'] and group['isMember'] and group['kind'] == 'Group')
            sent = set()
            for role in ('Producer', 'Trader', 'Consumer'):
                self.request(role, '/api/v1/community/groups', group_body, expected=403)
                self.request(role, f'/api/v1/community/groups/{group_id}/join', {}, expected=201)
                message = self.request(role, f'/api/v1/conversations/{group_id}/messages', {'clientMessageId': 'qa25_' + uuid.uuid4().hex, 'text': TAG + ' synthetic ' + role + ' group message'}, expected=201)
                self.assert_sender(message, role)
                sent.add(message['id'])
            rows = self.request('Admin', f'/api/v1/conversations/{group_id}/messages?limit=20')['items']
            self.check('Admin reads three persisted member messages', {item['id'] for item in rows} == sent)
            self.request('Consumer', f'/api/v1/community/groups/{group_id}/close', {}, expected=403)
            self.request('Admin', f'/api/v1/community/groups/{group_id}/close', {})
            self.owned_states[group_id] = 'Closed'; self.save_ownership()
        with self.phase('leave only labeled owned operator seed; hide QA article and preserve main roles'):
            article = self.request('Consumer', f'/api/v1/articles/{article_id}/withdraw', {'expectedRevision': article['revision']})
            self.check('owned demo article is Paused after cleanup', article['status'] == 'Paused')
            self.owned_states[article_id] = 'Paused'; self.save_ownership()
        self.report['status'] = 'PASS'

    def finish(self):
        try:
            try:
                self.save_ownership()
            except Exception as error:
                self.report['status'] = 'FAIL'
                self.report['privateReceiptErrorType'] = type(error).__name__
            self.report['ownedFixtureCounts'] = {key: len(value) for key, value in self.owned.items()}
            self.report['lastAcknowledgedStateCounts'] = {state: list(self.owned_states.values()).count(state) for state in sorted(set(self.owned_states.values()))}
            self.report['sessionRotations'] = self.rotations
            self.report['httpRequests'] = self.request_count
            self.report.pop('records', None)
            self.report.pop('actors', None)
            self.report.pop('baseURL', None)
            self.profiles.clear()
            self.session_document.clear()
            self.session_bytes = None
            super().finish()
        finally:
            self.tokens.clear()
            if self.session_lock is not None:
                self.session_lock.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True, help='Private existing .local/2.4-real-sessions.json; no concurrent session-file writers.')
    parser.add_argument('--run', action='store_true', required=True, help='Authorize declared synthetic persistent QA fixtures AFTER matching backend deployment.')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/feedback-https-acceptance-25.json', help='New sanitized public receipt; existing files are never overwritten.')
    args = parser.parse_args(argv)
    output = args.output.resolve()
    if output.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'receipt_already_exists_choose_new_output'})); return 2
    probe = FeedbackAcceptance(args.sessions, output)
    try:
        probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'; probe.report['errorType'] = type(error).__name__
        if isinstance(error, ProbeFailure): probe.report['failedStep'] = GUID.sub('{id}', str(error)[:240])
    finally:
        try:
            probe.finish()
        except Exception as error:
            probe.report['status'] = 'FAIL'; probe.report['receiptErrorType'] = type(error).__name__
        print(json.dumps({'status': probe.report['status'], 'checks': len(probe.report['checks']), 'httpRequests': probe.request_count,
            'receipt': str(output), 'scope': 'HTTPS REST profile submission/admin queue, article engagement, normal Direct and Admin groups; no native or crypto acceptance'}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
