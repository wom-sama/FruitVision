"""Opt-in 2.3 HTTPS/WSS acceptance using operator-provided real authenticated sessions.

No password login, mail, face, AI upload, SQL, identity proof fabrication or main-account role change.
All created domain data is explicitly DEMO QA2.3; Admin test approval is not legal verification.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import datetime as dt
import json
from pathlib import Path
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

# This module has no import-time actions; reuse transport helpers, never its login/workflow/receipt.
from verticals_e2e import NoRedirect, ProbeFailure, RoleSocket

ROOT = Path(__file__).resolve().parents[1]
ROLES = ('Admin', 'Producer', 'Trader', 'Consumer')
TAG = 'DEMO QA2.3'


class Acceptance:
    def __init__(self, sessions, output):
        self.sessions_file, self.output = sessions, output
        self.started = time.monotonic()
        self.deadline = self.started + 160
        self.lock = threading.Lock()
        self.base, self.tokens, self.actors, self.sockets = '', {}, {}, {}
        self.report = {'status': 'RUNNING', 'startedUtc': dt.datetime.now(dt.timezone.utc).isoformat(),
            'scope': 'Actual public HTTPS/WSS with four operator-supplied authenticated role sessions. Domain data is declared DEMO QA2.3, not legal proof, stock or transactions. Not four phones.',
            'sessionProvenance': 'Login/email OTP performed separately by operator; this driver confirms actual current API identities and never fabricates or refreshes tokens.',
            'tlsVerificationDisabled': False, 'requests': [], 'checks': [], 'phases': [], 'records': {},
            'formalRoleUpgradeLive': 'NOT_RUN: requires a separate verified Consumer and actual formal evidence; main Consumer is preserved.'}

    def remaining(self, ceiling=12):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise ProbeFailure('Overall 2.3 acceptance deadline exceeded')
        return max(.1, min(ceiling, left))

    def check(self, name, passed):
        with self.lock:
            self.report['checks'].append({'name': name, 'pass': bool(passed), 'atMs': round((time.monotonic() - self.started) * 1000)})
        if not passed:
            raise ProbeFailure(name)

    @contextmanager
    def phase(self, name):
        item = {'name': name, 'startMs': round((time.monotonic() - self.started) * 1000), 'status': 'RUNNING'}
        self.report['phases'].append(item)
        try:
            yield
            item['status'] = 'PASS'
        finally:
            if item['status'] == 'RUNNING':
                item['status'] = 'FAIL'
            item['endMs'] = round((time.monotonic() - self.started) * 1000)

    def request(self, role, path, data=None, method=None, expected=200):
        if not path.startswith('/') or '://' in path:
            raise ProbeFailure('Unsafe API route')
        self.remaining()
        headers = {'Accept': 'application/json'}
        if role is not None:
            headers['Authorization'] = 'Bearer ' + self.tokens[role]
        body = json.dumps(data, ensure_ascii=False).encode('utf-8') if data is not None else None
        if body is not None:
            headers['Content-Type'] = 'application/json'
        verb = method or ('POST' if body is not None else 'GET')
        status, start = None, time.monotonic()
        request = urllib.request.Request(self.base + path, data=body, headers=headers, method=verb)
        try:
            try:
                response = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=self.remaining())
            except urllib.error.HTTPError as error:
                response = error
            with response:
                status = response.status
                raw = response.read(1048577)
                if len(raw) > 1048576:
                    raise ProbeFailure('API response exceeded bounded acceptance size')
                value = json.loads(raw) if raw and 'json' in response.headers.get('Content-Type', '') else None
        finally:
            with self.lock:
                self.report['requests'].append({'role': role or 'anonymous', 'method': verb, 'route': path,
                    'status': status, 'expectedStatus': expected, 'startMs': round((start - self.started) * 1000),
                    'latencyMs': round((time.monotonic() - start) * 1000, 1)})
        if status != expected:
            self.check(f'{role or "anonymous"} {verb} {path}: expected {expected}, actual {status}', False)
        return value

    def load_sessions(self):
        path = self.sessions_file.resolve()
        if not path.is_relative_to((ROOT / '.local').resolve()) or not path.is_file() or path.stat().st_size > 65536:
            raise ProbeFailure('Sessions must be a bounded private JSON file under server/.local')
        document = json.loads(path.read_text(encoding='utf-8-sig'))
        self.base = document['baseURL'].rstrip('/')
        url = urllib.parse.urlsplit(self.base)
        if url.scheme != 'https' or not url.hostname or url.username or url.password or url.path or url.query or url.fragment or url.port not in (None, 443):
            raise ProbeFailure('Only a public HTTPS base URL without credentials/path/query is accepted')
        recorded = json.loads((ROOT / '.local/tunnel-state.json').read_text(encoding='utf-8-sig'))
        if self.base != recorded.get('publicUrl', '').rstrip('/'):
            raise ProbeFailure('Session base URL differs from the current privately recorded owned tunnel')
        self.report['baseURL'] = self.base
        sessions = document['sessions']
        for role in ROLES:
            row = sessions[role]
            token = row['accessToken']
            if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
                raise ProbeFailure('Provided session is not a valid opaque access-token shape')
            self.tokens[role] = token
            self.actors[role] = {'id': str(uuid.UUID(row['user']['id']))}
        self.check('four supplied role sessions identify four distinct users', len({actor['id'] for actor in self.actors.values()}) == 4)

    def review(self, lane, record, status):
        return self.request('Admin', f'/api/v1/admin/{lane}/{record["id"]}/review',
            {'status': status, 'reason': TAG + ': kiểm luồng kỹ thuật với dữ liệu demo; không chứng nhận cơ sở/pháp lý.', 'expectedRevision': record['revision']})

    def post_body(self, role, product, branch, suffix):
        return {'title': f'{TAG} {role} business forecast {suffix}',
            'body': TAG + ': bản ghi kiểm thử công bố dự kiến, chưa có thu hoạch, tồn kho, đặt hàng hoặc giao dịch.',
            'productCode': product, 'estimatedQuantityKg': 2 if role == 'Producer' else 1,
            'branchId': branch, 'purpose': 'Supply' if role == 'Producer' else 'Demand',
            'availableOn': (dt.datetime.now(dt.timezone.utc).date() + dt.timedelta(days=7)).isoformat()}

    def sender(self, value, role):
        sender = value.get('sender') or {}
        return sender.get('id') == self.actors[role]['id'] and sender.get('role') == role and isinstance(sender.get('displayName'), str) and bool(sender['displayName'].strip())

    def message(self, sender, conversation, recipients, text):
        result = self.request(sender, f'/api/v1/conversations/{conversation}/messages',
            {'clientMessageId': uuid.uuid4().hex, 'text': TAG + ': ' + text}, expected=201)
        message_id = str(uuid.UUID(result['id']))
        self.report['records'].setdefault('messages', []).append({'id': message_id, 'conversationId': conversation, 'senderRole': sender})
        self.check('HTTP message identifies actual named sender ' + message_id, self.sender(result, sender))
        for recipient in recipients:
            event = self.sockets[recipient].event('MessageCreated', message_id)
            payload = event['arguments'][0]
            self.check(recipient + ' actual WSS named message ' + message_id,
                payload.get('conversationId') == conversation and self.sender(payload, sender))
        return message_id

    def run(self):
        self.load_sessions()
        suffix = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]
        with self.phase('provided identities and Seller-only AI policy; no inference'):
            for role in ROLES:
                profile = self.request(role, '/api/v1/auth/me')
                self.check(role + ' actual current verified approved identity', profile['id'] == self.actors[role]['id'] and profile['role'] == role and
                    profile['emailConfirmed'] and profile['isActive'] and profile['approvalStatus'] == 'Approved')
            self.report['actors'] = self.actors
            for role in ROLES:
                for route in ('/api/v1/ai/stats', '/api/v1/ai/capabilities'):
                    self.request(role, route, expected=403 if role in ('Admin', 'Consumer') else 200)
        with self.phase('actual trusted location catalog'):
            countries = self.request(None, '/api/v1/locations/countries')
            self.check('country catalog contains VN with provenance', any(row['code'] == 'VN' for row in countries['items']) and bool(countries.get('source')) and bool(countries.get('asOf')))
            provinces = self.request(None, '/api/v1/locations/provinces?country=VN')
            selected = next((row for row in provinces['items'] if row['code'] == '79'), None)
            self.check('actual VN directory is34 provinces and contains selected79', len(provinces['items']) == 34 and selected is not None and provinces.get('countryCode') == 'VN')
            self.report['geography'] = {'countryCode': 'VN', 'provinceCode': '79', 'provinceCount': 34,
                'source': provinces.get('source'), 'asOf': provinces.get('asOf'), 'stale': provinces.get('stale')}
            foreign = self.request(None, '/api/v1/locations/provinces?country=US')
            foreign_code = next((row['code'] for row in foreign['items'] if row['code'] not in {item['code'] for item in provinces['items']}), None)
            self.check('actual foreign catalog offers a cross-country rejection control', foreign_code is not None)
            catalog = self.request(None, '/api/v1/catalog/products')
            product = next((row['code'] for row in catalog['items'] if row['code'] == 'mango'), None)
            self.check('mango is an actual catalog code', product is not None)
        with self.phase('Consumer article reviewed separately from business posts'):
            article = self.request('Consumer', '/api/v1/articles', {'title': TAG + ' consumer community article ' + suffix,
                'body': TAG + ': chia sẻ thử nghiệm quy trình bài viết cộng đồng; không phải đề nghị bán hàng hoặc thông tin thị trường thật.'}, expected=201)
            article['id'] = str(uuid.UUID(article['id']))
            self.report['records']['articleId'] = article['id']
            self.check('community article starts AwaitingReview', article['status'] == 'AwaitingReview')
            self.request('Trader', f'/api/v1/articles/{article["id"]}', expected=404)
            self.request('Producer', '/api/v1/articles', {'title': TAG + ' disallowed seller article', 'body': 'This request must not create a Consumer community article.'}, expected=403)
            published = self.review('articles', article, 'Published')
            for role in ('Producer', 'Trader', 'Consumer'):
                rows = self.request(role, '/api/v1/articles?limit=50')['items']
                item = next((row for row in rows if row['id'] == article['id']), None)
                self.check(role + ' public article lane contains no private reason', item is not None and 'reviewReason' not in item)
            for role in (None, 'Producer', 'Trader'):
                item = self.request(role, f'/api/v1/articles/{article["id"]}')
                self.check((role or 'anonymous') + ' public detail omits moderation reason', 'reviewReason' not in item and item['status'] == 'Published')
            own = self.request('Consumer', f'/api/v1/articles/{article["id"]}')
            self.check('author can read private review result', isinstance(own.get('reviewReason'), str))
            self.request('Consumer', f'/api/v1/articles/{article["id"]}', {'title': TAG + ' stale edit', 'body': 'A stale revision must never replace published content.', 'expectedRevision': article['revision']}, method='PUT', expected=409)
            self.check('stale article write left published revision unchanged', self.request('Producer', f'/api/v1/articles/{article["id"]}')['revision'] == published['revision'])
        with self.phase('Seller branches pending gate, trusted geography and Admin approval'):
            branches = {}
            for role in ('Producer', 'Trader'):
                body = {'name': f'{TAG} {role} branch {suffix}', 'countryCode': 'VN', 'provinceCode': '79',
                    'street': 'DEMO QA2.3 - địa chỉ kiểm thử, không chứng nhận cơ sở thật', 'phone': '+84900000000'}
                if role == 'Producer':
                    self.request(role, '/api/v1/branches', {**body, 'provinceCode': foreign_code}, expected=400)
                branch = self.request(role, '/api/v1/branches', body, expected=201)
                branch['id'] = str(uuid.UUID(branch['id'])); branches[role] = branch
                self.report['records'][role.lower() + 'BranchId'] = branch['id']
                self.check(role + ' branch is Pending from trusted selection', branch['status'] == 'Pending' and branch['countryCode'] == 'VN' and branch['provinceCode'] == '79')
                self.request(role, '/api/v1/posts', self.post_body(role, product, branch['id'], suffix), expected=409)
            self.request('Trader', f'/api/v1/branches/{branches["Producer"]["id"]}', expected=404)
            for role, branch in list(branches.items()):
                branches[role] = self.review('branches', branch, 'Approved')
                public = self.request(None, f'/api/v1/branches/{branch["id"]}')
                self.check(role + ' public approved branch is minimal', public['status'] == 'Approved' and 'reviewReason' not in public and 'phone' not in public and 'street' not in public)
            self.request('Trader', '/api/v1/posts', self.post_body('Trader', product, branches['Producer']['id'], suffix), expected=409)
            self.request('Consumer', '/api/v1/posts', self.post_body('Producer', product, branches['Producer']['id'], suffix), expected=403)
        with self.phase('real WSS clients, moderated business posts, contact and named private messages'):
            def open_socket(role):
                socket = RoleSocket(self, role, self.tokens[role])
                with self.lock:
                    self.sockets[role] = socket
                return socket.open()
            with ThreadPoolExecutor(max_workers=3) as pool:
                opened = list(pool.map(open_socket, ('Producer', 'Trader', 'Consumer')))
            self.check('three real WSS background receivers concurrently alive', all(socket.thread.is_alive() for socket in opened))
            posts = {}
            for role in ('Producer', 'Trader'):
                post = self.request(role, '/api/v1/posts', self.post_body(role, product, branches[role]['id'], suffix), expected=201)
                post['id'] = str(uuid.UUID(post['id'])); self.report['records'][role.lower() + 'PostId'] = post['id']
                self.check(role + ' business post is linked to own Approved branch and awaits review', post['status'] == 'AwaitingReview' and
                    post['branchId'] == branches[role]['id'] and post['region'] == branches[role]['region'] and post['actualStockKg'] is None and not post['canOrder'])
                posts[role] = self.review('posts', post, 'Published')
            direct = self.request('Trader', f'/api/v1/posts/{posts["Producer"]["id"]}/conversations', {}, expected=201)
            conversation = str(uuid.UUID(direct['id'])); self.report['records']['producerTraderConversationId'] = conversation
            for role in ('Producer', 'Trader'):
                self.sockets[role].event('ConversationCreated', conversation)
                self.sockets[role].join(conversation)
            self.request('Consumer', f'/api/v1/conversations/{conversation}/messages', expected=404)
            self.request('Admin', f'/api/v1/conversations/{conversation}/messages', expected=404)
            self.sockets['Consumer'].join(conversation, allowed=False)
            self.message('Trader', conversation, ('Producer', 'Trader'), 'Thương lái hỏi về tin dự kiến; chưa đặt hàng.')
            self.message('Producer', conversation, ('Producer', 'Trader'), 'Nhà sản xuất trả lời theo thông tin demo; chưa cam kết tồn kho.')
            contact = self.request('Consumer', f'/api/v1/posts/{posts["Producer"]["id"]}/conversations', {}, expected=201)
            consumer_direct = str(uuid.UUID(contact['id'])); self.report['records']['producerConsumerConversationId'] = consumer_direct
            self.check('Consumer contact is a distinct private thread', consumer_direct != conversation)
            for role in ('Producer', 'Consumer'):
                self.sockets[role].join(consumer_direct)
            self.request('Trader', f'/api/v1/conversations/{consumer_direct}/messages', expected=404)
            self.message('Consumer', consumer_direct, ('Producer', 'Consumer'), 'Người tiêu dùng hỏi thông tin, chưa hình thành giao dịch.')
            self.message('Producer', consumer_direct, ('Producer', 'Consumer'), 'Trả lời người tiêu dùng trong hội thoại riêng đúng thành viên.')
        with self.phase('fresh group recipient membership after leave'):
            group = self.request('Producer', '/api/v1/community/groups', {'title': TAG + ' membership control ' + suffix,
                'region': branches['Producer']['region'], 'productCode': product}, expected=201)
            group_id = str(uuid.UUID(group['id'])); self.report['records']['groupId'] = group_id
            for role in ('Trader', 'Consumer'):
                self.request(role, f'/api/v1/community/groups/{group_id}/join', {}, expected=201)
            for role in ('Producer', 'Trader', 'Consumer'):
                self.sockets[role].join(group_id)
            self.message('Producer', group_id, ('Producer', 'Trader', 'Consumer'), 'Nhóm kiểm tra ba thành viên trước khi một người rời.')
            self.request('Consumer', f'/api/v1/community/groups/{group_id}/leave', {})
            self.request('Consumer', f'/api/v1/conversations/{group_id}/messages', expected=404)
            message_id = self.message('Trader', group_id, ('Producer', 'Trader'), 'Tin mới chỉ gửi thành viên hiện tại sau khi Consumer rời.')
            self.check('departed Consumer receives no new group WSS event', self.sockets['Consumer'].event('MessageCreated', message_id, timeout=2, absent=True) is True)
        self.report['status'] = 'PASS'

    def finish(self):
        for socket in self.sockets.values():
            socket.close()
        self.report['wssClients'] = {role: {'bufferedFrames': len(socket.events), 'receiverFailureType': socket.failure,
            'backgroundReceiverStarted': socket.thread is not None} for role, socket in self.sockets.items()}
        self.tokens.clear()
        self.report['providedSessionsRetained'] = True
        self.report['finishedUtc'] = dt.datetime.now(dt.timezone.utc).isoformat()
        self.report['elapsedSeconds'] = round(time.monotonic() - self.started, 3)
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_text(json.dumps(self.report, ensure_ascii=False, indent=2), encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True, help='Private server/.local JSON: baseURL and sessions keyed Admin/Producer/Trader/Consumer.')
    parser.add_argument('--run', action='store_true', required=True, help='Authorize persistent declared DEMO QA2.3 API records on the owned recorded HTTPS tunnel.')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/auth-publishing-https-e2e-23.json')
    args = parser.parse_args(argv)
    probe = Acceptance(args.sessions, args.output.resolve())
    try:
        probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'
        probe.report['errorType'] = type(error).__name__
        if isinstance(error, ProbeFailure):
            probe.report['failedStep'] = str(error)[:240]
    finally:
        try:
            probe.finish()
        except Exception as error:
            probe.report['status'] = 'FAIL'
            probe.report['receiptErrorType'] = type(error).__name__
        print(json.dumps({'status': probe.report['status'], 'checks': len(probe.report['checks']),
            'receipt': str(probe.output), 'scope': 'provided real sessions; four roles, three WSS clients; no mail/face/AI upload'}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
