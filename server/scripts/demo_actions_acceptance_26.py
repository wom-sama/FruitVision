"""Explicit opt-in HTTPS demo-action acceptance, not native/four-phone/AI/E2EE proof.

Use --sessions PRIVATE_JSON --run --output NEW_JSON only after Root's live grant.
At most 120 sequential HTTP requests/240 seconds, normal real-session refresh only.
Mutates newly created labeled QA resources plus temporary own Consumer privacy/block state;
restores the latter and soft-deletes owned QA articles/branches. No human application is edited.
AI, device UI/local quiz state, crypto and positive live Admin appointment are excluded.
No import-time actions. Do not run old drivers or retry uncertain mutations automatically.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request

from feedback_acceptance_25 import FeedbackAcceptance, GUID, ROOT, ROLES
from verticals_e2e import NoRedirect, ProbeFailure

TAG = 'DEMO QA2.6 ACTIONS'
MAX_REQUESTS = 120
EDITABLE = ('displayName', 'bio', 'phone', 'gender', 'showGender', 'showPhone', 'showRegion')


class DemoActions(FeedbackAcceptance):
    def __init__(self, sessions, output):
        super().__init__(sessions, output)
        self.deadline = self.started + 240
        self.private_output = ROOT / '.local/demo-actions26' / (self.run_id + '.json')
        self.original_profile = None
        self.applied_profile = None
        self.profile_changed = False
        self.introduced_block = False
        self.restoring = False
        self.coverage = {}
        self.branches, self.articles = {}, {}
        self.report.update({'scope': 'Fresh owned HTTPS API actions mapped to the 2.6 demo checklist. No native, four-phone, WSS, AI, crypto or public Admin promotion acceptance.',
            'requestBudget': MAX_REQUESTS, 'deadlineSeconds': 240,
            'intendedCleanup': 'Reject owned synthetic role application/remove its proof; soft-delete owned QA articles/branches; close own QA group; restore own privacy fields and remove only the block introduced here. Audit, chat history, Directs and private media may remain labeled QA.',
            'formalRoleApplicationFlow': 'Owned synthetic Producer application only: Draft/Submitted/NeedsInformation/resubmit/Rejected. Main Consumer is never approved or appointed Admin.'})

    def exchange(self, role, path, data=None, method=None, expected=200, raw=None, content_type=None, binary=False):
        # Reviewed same-origin transport, copied here to make 120 the real cap rather than
        # silently inheriting the older drivers' 72/80 limits. No redirects or proxy forwarding.
        if not path.startswith('/') or path.startswith('//') or '://' in path or any(c in path for c in ('\\', '\r', '\n', '\0', '#')):
            raise ProbeFailure('Unsafe API route')
        if self.request_count >= MAX_REQUESTS:
            raise ProbeFailure('Authorized HTTP budget exhausted')
        self.request_count += 1
        headers = {'Accept': 'image/jpeg' if binary else 'application/json'}
        if role is not None:
            headers['Authorization'] = 'Bearer ' + self.tokens[role]
        body = raw if raw is not None else (json.dumps(data, ensure_ascii=False).encode('utf-8') if data is not None else None)
        if body is not None:
            headers['Content-Type'] = content_type or 'application/json'
        verb = method or ('POST' if body is not None else 'GET')
        request = urllib.request.Request(self.base + path, data=body, headers=headers, method=verb)
        status, started = None, time.monotonic()
        try:
            try:
                response = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=self.remaining(15))
            except urllib.error.HTTPError as error:
                response = error
            with response:
                status = response.status
                payload = response.read((5 * 1024 * 1024 if binary else 1048576) + 1)
                if len(payload) > (5 * 1024 * 1024 if binary else 1048576):
                    raise ProbeFailure('Bounded acceptance response exceeded cap')
                media_type = response.headers.get('Content-Type', '').split(';', 1)[0]
                value = payload if binary else (json.loads(payload) if payload and 'json' in media_type else None)
        finally:
            parsed = urllib.parse.urlsplit(path)
            self.report['requests'].append({'role': role or 'anonymous', 'method': verb, 'routeTemplate': GUID.sub('{id}', parsed.path),
                'queryNames': sorted(urllib.parse.parse_qs(parsed.query)), 'status': status, 'expectedStatus': expected,
                'latencyMs': round((time.monotonic() - started) * 1000, 1)})
        self.check(role + ' API expected status' if role else 'anonymous API expected status', status in (expected if isinstance(expected, tuple) else (expected,)))
        return status, value, media_type

    @contextmanager
    def case(self, key, rows):
        item = {'status': 'RUNNING', 'playbookRows': rows, 'firstRequest': self.request_count + 1}
        self.coverage[key] = item
        try:
            with self.phase(key):
                yield
            item['status'] = 'PASS_HTTP_ONLY'
        finally:
            if item['status'] == 'RUNNING': item['status'] = 'FAIL'
            item['lastRequest'] = self.request_count

    def save_ownership(self):
        if self.owned or self.original_profile is not None:
            self.write_private(self.private_output, {'runId': self.run_id, 'label': TAG, 'status': self.report['status'],
                'ownedOnly': self.owned, 'states': self.owned_states,
                'consumerId': self.actors.get('Consumer', {}).get('id'), 'producerId': self.actors.get('Producer', {}).get('id'),
                'restoreConsumerProfile': self.original_profile, 'lastAppliedConsumerProfile': self.applied_profile,
                'profileChanged': self.profile_changed, 'introducedConsumerProducerBlock': self.introduced_block,
                'warning': 'Private self-restore snapshot/owned QA IDs. Never alter other applications or pre-existing blocks. No passwords, OTPs or tokens are stored here.'})

    def review(self, lane, record, status):
        return self.request('Admin', f'/api/v1/admin/{lane}/{record["id"]}/review', {'status': status,
            'reason': TAG + ': synthetic technical evidence; no legal/business/food-quality certification.', 'expectedRevision': record['revision']})

    def restore_self(self):
        self.restoring = True
        try:
            if self.introduced_block:
                self.request('Consumer', '/api/v1/profiles/' + self.actors['Producer']['id'] + '/block', method='DELETE', expected=204)
                self.introduced_block = False
            if self.profile_changed:
                current = self.request('Consumer', '/api/v1/profile')
                self.check('self restore does not overwrite an unrelated concurrent profile edit', {k: current[k] for k in EDITABLE} == self.applied_profile)
                restored = self.request('Consumer', '/api/v1/profile', self.original_profile, method='PUT')
                self.check('own Consumer profile restored exactly', {k: restored[k] for k in EDITABLE} == self.original_profile)
                self.profile_changed = False
            self.save_ownership()
        finally:
            self.restoring = False

    def role_flow(self, jpeg):
        with self.case('role_application_review', ['M01', 'M02', 'M18']):
            app = self.request('Consumer', '/api/v1/role-applications', {'requestedRole': 'Producer'}, expected=201)
            identifier = self.own('roleApplications', app)
            route = '/api/v1/role-applications/' + identifier
            app = self.request('Consumer', route, {'organisationName': TAG + ' synthetic farm ' + self.run_id,
                'address': TAG + ' synthetic test address', 'countryCode': 'VN', 'provinceCode': '79', 'phone': '+84900000000',
                'products': ['mango'], 'cultivatedAreaHa': 1.25, 'expectedRevision': app['revision']}, method='PUT')
            _, app, _ = self.exchange('Consumer', route + f'/evidence?category=ProductionEvidence&expectedRevision={app["revision"]}', raw=jpeg, content_type='image/jpeg', expected=201)
            self.check('saving profile and proof remains Draft', app['status'] == 'Draft' and app['submittedAt'] is None)
            before = self.request('Admin', '/api/v1/admin/role-applications?status=Submitted&limit=50')['items']
            self.check('Draft is absent from Submitted queue', all(row['id'] != identifier for row in before))
            app = self.request('Consumer', route + '/submit', {'expectedRevision': app['revision']})
            self.owned_states[identifier] = app['status']; self.save_ownership()
            queue = self.request('Admin', '/api/v1/admin/role-applications?status=Submitted&limit=50')['items']
            found = next((x for x in queue if x['id'] == identifier), None)
            self.check('Submitted queue has own applicant timestamp and proof', found is not None and found['status'] == 'Submitted' and
                found['applicant']['id'] == self.actors['Consumer']['id'] and found['applicant']['role'] == 'Consumer' and bool(found['submittedAt']) and len(found['evidence']) == 1)
            detail = self.request('Admin', '/api/v1/admin/role-applications/' + identifier)
            evidence_id = detail['evidence'][0]['id']
            _, proof, _ = self.exchange('Admin', f'/api/v1/admin/role-applications/{identifier}/evidence/{evidence_id}', binary=True)
            self.check('Admin evidence download equals own synthetic JPEG', proof == jpeg)
            app = self.review('role-applications', app, 'NeedsInformation')
            self.owned_states[identifier] = app['status']; self.save_ownership()
            owner = self.request('Consumer', route)
            self.check('applicant sees NeedsInformation and technical reason', owner['status'] == 'NeedsInformation' and TAG in owner['reviewReason'])
            app = self.request('Consumer', route + '/submit', {'expectedRevision': owner['revision']})
            self.owned_states[identifier] = app['status']; self.save_ownership()
            app = self.review('role-applications', app, 'Rejected')
            self.owned_states[identifier] = app['status']; self.save_ownership()
            app = self.request('Consumer', f'{route}/evidence/{evidence_id}?expectedRevision={app["revision"]}', method='DELETE')
            self.check('owned QA ends Rejected and own evidence removed', app['status'] == 'Rejected' and not app['evidence'])
            self.owned_states[identifier] = 'Rejected'; self.save_ownership()

    def publishing(self, jpeg):
        with self.case('branches_and_articles', ['M03', 'M04', 'M06', 'M09', 'M11', 'M17']):
            for role in ('Producer', 'Trader'):
                branch = self.request(role, '/api/v1/branches', {'name': TAG + ' ' + role + ' ' + self.run_id, 'countryCode': 'VN',
                    'provinceCode': '79', 'street': TAG + ' synthetic premises', 'phone': '+84900000000'}, expected=201)
                self.own('branches', branch)
                branch = self.request(role, '/api/v1/branches/' + branch['id'], {'name': TAG + ' revised ' + role + ' ' + self.run_id,
                    'countryCode': 'VN', 'provinceCode': '79', 'street': TAG + ' revised synthetic premises', 'phone': '+84900000000', 'expectedRevision': branch['revision']}, method='PUT')
                branch = self.review('branches', branch, 'Approved'); self.branches[role] = branch
                self.check('owned edited branch is Approved', branch['status'] == 'Approved')
            for role in ('Producer', 'Trader', 'Consumer'):
                _, image, _ = self.exchange(role, '/api/v1/articles/images', raw=jpeg, content_type='image/jpeg', expected=201)
                self.own('articleImages', image)
                body = {'title': TAG + ' ' + role + ' ' + self.run_id, 'body': TAG + ': synthetic mango observation, not stock, price, legal or food-quality evidence.', 'imageId': image['id']}
                if role != 'Consumer': body['branchId'] = self.branches[role]['id']
                article = self.request(role, '/api/v1/articles', body, expected=201); self.own('articles', article)
                article = self.review('articles', article, 'Published'); self.articles[role] = article
                self.check('article lane matches actor role', article['audienceLane'] == ('Community' if role == 'Consumer' else 'Professional'))
                if role != 'Consumer': self.request('Consumer', '/api/v1/articles/' + article['id'])
                self.image(None, '/api/v1/articles/' + article['id'] + '/image', image)

    def engagement(self):
        import uuid
        with self.case('likes_comments', ['M20']):
            route = '/api/v1/articles/' + self.articles['Consumer']['id']; comments = {}
            for role in ('Producer', 'Trader', 'Consumer'):
                self.request(role, route + '/like', {'liked': True}, method='PUT')
                body = {'clientCommentId': str(uuid.uuid4()), 'body': TAG + ' ' + role + ' observation'}
                row = self.request(role, route + '/comments', body, expected=201); self.own('comments', row)
                self.check('comment identifies exact public author', row['author'] == {'id': self.actors[role]['id'], 'displayName': self.profiles[role]['displayName'], 'role': role})
                comments[role] = (row, body)
            repeated = self.request('Producer', route + '/comments', comments['Producer'][1])
            self.check('exact comment retry reuses record', repeated['id'] == comments['Producer'][0]['id'])
            self.request('Producer', route + '/comments', {**comments['Producer'][1], 'body': 'Changed duplicate must conflict'}, expected=409)
            self.request('Producer', route + '/like', {'liked': True}, method='PUT')
            counts = self.request('Consumer', route + '/likes'); self.check('three durable likes and comments', counts['likeCount'] == 3 and counts['commentCount'] == 3)
            rows = self.request('Admin', route + '/comments?limit=20'); self.check('Admin sees three moderatable comments', len(rows['items']) == 3 and all(x['canDelete'] for x in rows['items']))
            self.request('Consumer', route + '/comments/' + comments['Consumer'][0]['id'], method='DELETE', expected=204)
            self.request('Consumer', route + '/comments', comments['Consumer'][1], expected=409)
            counts = self.request('Consumer', route + '/comments?limit=20'); self.check('deleted comment stays deleted', counts['commentCount'] == 2 and len(counts['items']) == 2)

    def group(self):
        import uuid
        with self.case('admin_group_membership', ['M05', 'M21']):
            body = {'title': TAG + ' group ' + self.run_id, 'region': 'Đồng Tháp', 'productCode': 'mango'}
            group = self.request('Admin', '/api/v1/community/groups', body, expected=201); self.group_id = self.own('groups', group)
            for role in ('Producer', 'Trader', 'Consumer'):
                self.request(role, '/api/v1/community/groups', body, expected=403)
                self.request(role, f'/api/v1/community/groups/{self.group_id}/join', {}, expected=201)
            self.group_message_ids = []
            for role in ROLES:
                row = self.request(role, f'/api/v1/conversations/{self.group_id}/messages', {'clientMessageId': 'qa26_' + uuid.uuid4().hex, 'text': TAG + ' ' + role + ' group message'}, expected=201)
                self.assert_sender(row, role); self.group_message_ids.append(row['id'])
            persisted = self.request('Admin', f'/api/v1/conversations/{self.group_id}/messages?limit=20')['items']
            self.check('Admin retrieves all four persisted group messages', {x['id'] for x in persisted} == set(self.group_message_ids))

    def direct(self, jpeg):
        import uuid
        with self.case('direct_photo_inbox_acl', ['M10', 'M13', 'M15', 'X02']):
            path = '/api/v1/articles/' + self.articles['Producer']['id'] + '/conversations'
            direct = self.request('Trader', path, {}, expected=201); self.direct_id = self.own('directConversations', direct)
            self.check('article contact reuses exact Direct', self.request('Trader', path, {})['id'] == self.direct_id)
            for role in ('Trader', 'Producer'):
                self.request(role, f'/api/v1/conversations/{self.direct_id}/messages', {'clientMessageId': 'qa26_' + uuid.uuid4().hex, 'text': TAG + ' ' + role + ' direct text'}, expected=201)
            _, image, _ = self.exchange('Trader', f'/api/v1/conversations/{self.direct_id}/images?clientMessageId=qa26_{uuid.uuid4().hex}', raw=jpeg, content_type='image/jpeg', expected=201)
            self.own('imageMessages', image)
            self.image('Producer', f'/api/v1/conversations/{self.direct_id}/images/{image["image"]["id"]}', image['image'])
            self.request('Consumer', f'/api/v1/conversations/{self.direct_id}/messages', expected=404)
            self.request('Admin', f'/api/v1/conversations/{self.direct_id}/images/{image["image"]["id"]}', expected=404)
            displayed = self.request('Producer', f'/api/v1/conversations/{self.direct_id}/messages?limit=20')['items']
            self.check('recipient actually fetched displayed image message', any(x['id'] == image['id'] for x in displayed))
            inbox = self.request('Producer', '/api/v1/conversations?limit=20')
            first = inbox['items'][0]; self.check('new incoming image raises Direct to top with exact peer and unread', first['id'] == self.direct_id and first['peer']['id'] == self.actors['Trader']['id'] and first['peer']['role'] == 'Trader' and first['lastMessage']['kind'] == 'image' and first['unreadCount'] == 2)
            read = self.request('Producer', f'/api/v1/conversations/{self.direct_id}/read', {'lastMessageId': image['id']}); self.check('displayed cursor clears only owned thread', read['unreadCount'] == 0)
            self.request('Consumer', f'/api/v1/conversations/{self.direct_id}/read', {'lastMessageId': image['id']}, expected=404)
            term = urllib.parse.quote(self.profiles['Producer']['displayName'][:80], safe='')
            contacts = self.request('Consumer', '/api/v1/contacts?limit=50&search=' + term)['items']
            self.check('contact search contains intended Producer without email', any(x['id'] == self.actors['Producer']['id'] for x in contacts) and all('email' not in x for x in contacts))
            status, generic, _ = self.exchange('Consumer', '/api/v1/conversations/direct', data={'userId': self.actors['Producer']['id']}, expected=(200, 201))
            if status == 201: self.own('genericDirectsCreatedHere', generic)  # Never send to or claim ownership of an existing personal thread.
            own = self.request('Producer', '/api/v1/articles/' + self.articles['Consumer']['id'] + '/conversations', {}, expected=201)
            self.consumer_direct_id = self.own('directConversations', own)
            peers = self.request('Producer', '/api/v1/conversations?limit=20')['items']
            self.check('inbox distinguishes Consumer and Trader peers', next(x for x in peers if x['id'] == self.consumer_direct_id)['peer']['role'] == 'Consumer' and next(x for x in peers if x['id'] == self.direct_id)['peer']['role'] == 'Trader')

    def privacy_block(self):
        import uuid
        with self.case('profile_privacy_block_restore', ['X03', 'X04']):
            target = self.actors['Consumer']['id']; producer = self.actors['Producer']['id']
            hidden = {**self.original_profile, 'phone': '+84900000000', 'gender': 'Other', 'showGender': False, 'showPhone': False, 'showRegion': False}
            self.profile_changed = True; self.applied_profile = hidden; self.save_ownership()
            self.request('Consumer', '/api/v1/profile', hidden, method='PUT')
            view = self.request('Producer', '/api/v1/profiles/' + target)
            self.check('private fields and email are hidden', 'email' not in view and view['phone'] is None and view['gender'] is None and view['region'] is None)
            visible = {**hidden, 'showPhone': True, 'showGender': True, 'showRegion': True}
            self.applied_profile = visible; self.save_ownership(); self.request('Consumer', '/api/v1/profile', visible, method='PUT')
            view = self.request('Producer', '/api/v1/profiles/' + target)
            self.check('opted-in synthetic fields are visible without email', 'email' not in view and view['phone'] == visible['phone'] and view['gender'] == 'Other' and view['region'] == self.profiles['Consumer']['region'])
            self.introduced_block = True; self.save_ownership(); self.request('Consumer', '/api/v1/profiles/' + producer + '/block', {}, method='PUT')
            self.request('Producer', '/api/v1/profiles/' + target, expected=404)
            self.request('Producer', f'/api/v1/conversations/{self.consumer_direct_id}/messages', {'clientMessageId': 'qa26_' + uuid.uuid4().hex, 'text': TAG + ' must be blocked'}, expected=403)
            _, _, _ = self.exchange('Producer', f'/api/v1/conversations/{self.consumer_direct_id}/images?clientMessageId=qa26_{uuid.uuid4().hex}', raw=self.block_test_jpeg, content_type='image/jpeg', expected=403)
            self.request('Consumer', f'/api/v1/conversations/{self.group_id}/messages', {'clientMessageId': 'qa26_' + uuid.uuid4().hex, 'text': TAG + ' group remains allowed'}, expected=201)
            self.request('Consumer', f'/api/v1/conversations/{self.consumer_direct_id}/messages')
            self.request('Producer', '/api/v1/conversations/direct', {'userId': target}, expected=404)
            self.request('Consumer', '/api/v1/profiles/' + producer + '/block', method='DELETE', expected=204); self.introduced_block = False; self.save_ownership()
            self.request('Producer', '/api/v1/profiles/' + target)
            self.restore_self()

    def cleanup_owned(self):
        import uuid
        with self.case('owned_resource_deletion_group_close', ['M05', 'X05', 'X06']):
            branch = self.branches['Producer']
            self.request('Producer', f'/api/v1/branches/{branch["id"]}?expectedRevision={branch["revision"]}', method='DELETE', expected=409)
            for role, article in self.articles.items():
                self.request(role, f'/api/v1/articles/{article["id"]}?expectedRevision={article["revision"]}', method='DELETE', expected=204)
                self.owned_states[article['id']] = 'Deleted'
            self.request(None, '/api/v1/articles/' + self.articles['Consumer']['id'], expected=404)
            for role, branch in self.branches.items():
                self.request(role, f'/api/v1/branches/{branch["id"]}?expectedRevision={branch["revision"]}', method='DELETE', expected=204)
                self.owned_states[branch['id']] = 'Deleted'
            self.request('Admin', f'/api/v1/community/groups/{self.group_id}/close', {})
            self.owned_states[self.group_id] = 'Closed'; self.save_ownership()
            self.request('Trader', f'/api/v1/conversations/{self.group_id}/messages', {'clientMessageId': 'qa26_' + uuid.uuid4().hex, 'text': TAG + ' closed group must reject'}, expected=409)

    def run(self):
        with self.case('sessions_preconditions_learning', ['M16', 'M19']):
            self.load_and_verify_sessions()
            applications = self.request('Consumer', '/api/v1/role-applications?limit=50')
            self.check('no existing active/human application is mutated', not applications.get('next') and not any(x['status'] in ('Draft', 'Submitted', 'NeedsInformation') for x in applications['items']))
            profile = self.request('Consumer', '/api/v1/profile'); self.original_profile = {k: profile[k] for k in EDITABLE}; self.save_ownership()
            for role, other in (('Consumer', 'Producer'), ('Producer', 'Consumer')):
                blocked = self.request(role, '/api/v1/profile/blocked')['items']
                self.check('no pre-existing personal block may be removed', all(x['id'] != self.actors[other]['id'] for x in blocked))
            learning = self.request('Consumer', '/api/v1/learning/mango')
            self.check('Consumer has mango learning content without AI execution', learning['productCode'] == 'mango' and bool(learning['sections']))
        jpeg = self.fixture_jpeg('demo-actions26-' + self.run_id)
        self.block_test_jpeg = jpeg
        self.role_flow(jpeg); self.publishing(jpeg); self.engagement(); self.group(); self.direct(jpeg); self.privacy_block(); self.cleanup_owned()
        with self.case('original_four_roles_preserved', []):
            for role in ROLES:
                self.check('original role remains intact', self.request(role, '/api/v1/auth/me')['role'] == role)
        self.report['status'] = 'PASS_AUTHORIZED_HTTP_SCOPE_WITH_EXCLUSIONS'

    def finish(self):
        try:
            if self.profile_changed or self.introduced_block:
                self.restore_self()
        except Exception as error:
            self.report['status'] = 'FAIL'; self.report['criticalRestoreErrorType'] = type(error).__name__
        self.report['coverage'] = self.coverage
        self.report['exclusions'] = {'M07': 'NOT_RUN: no AI calls granted', 'M08': 'NOT_RUN: no AI/device lifecycle calls granted',
            'M12': 'NOT_RUN: no AI calls granted', 'M14': 'NOT_RUN: no E2EE keys/cipher/device tests granted',
            'M22': 'NOT_RUN: no AI/video/history calls granted', 'X01_positive_appointment': 'NOT_RUN_BY_THIS_DRIVER: isolated PostgreSQL tests and Root-controlled fifth genuine-OTP Consumer acceptance have separate receipts. Main Consumer never promoted here.',
            'local_learning_quiz': 'NOT_RUN: API content only; local read-progress/questions require actual app UI',
            'M16': 'PARTIAL_HTTP_CONTENT_ONLY: local read-progress/questions require actual app UI',
            'M19': 'PARTIAL: non-Admin group creation denied and four roles verified; no AI/secret calls or UI button visibility assertions.',
            'native_four_devices_WSS': 'NOT_RUN: HTTP clients do not prove rendering, zoom, foreground alerts or four-device realtime'}
        self.report['criticalSelfRestoreComplete'] = not self.profile_changed and not self.introduced_block
        super().finish()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True)
    parser.add_argument('--run', action='store_true', required=True)
    parser.add_argument('--output', type=Path, required=True, help='New sanitized receipt path; never overwrite previous evidence.')
    args = parser.parse_args(argv); output = args.output.resolve()
    if output.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'output_exists_choose_new_path'})); return 2
    probe = DemoActions(args.sessions, output)
    try:
        probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'; probe.report['errorType'] = type(error).__name__
        if isinstance(error, ProbeFailure): probe.report['failedStep'] = GUID.sub('{id}', str(error)[:240])
    finally:
        try: probe.finish()
        except Exception as error: probe.report['status'] = 'FAIL'; probe.report['receiptErrorType'] = type(error).__name__
        print(json.dumps({'status': probe.report['status'], 'checks': len(probe.report['checks']), 'httpRequests': probe.request_count,
            'criticalSelfRestoreComplete': not probe.profile_changed and not probe.introduced_block, 'receipt': str(output)}))
    return 0 if probe.report['status'] == 'PASS_AUTHORIZED_HTTP_SCOPE_WITH_EXCLUSIONS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
