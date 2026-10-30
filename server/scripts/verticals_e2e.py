"""Opt-in real HTTPS/WSS acceptance probe; creates persistent, clearly labeled demo records.

Four independent role clients are not four physical phones. No SQL, mock prices or model work.
Only the currently recorded private tunnel receives credentials. No work runs on import.
"""
from __future__ import annotations

import argparse
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import json
from pathlib import Path
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
ROLES = ('admin', 'producer', 'trader', 'consumer')
REGION = 'Đồng Tháp'


class ProbeFailure(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


class RoleSocket:
    """One real connection, a bounded event buffer, background receiver and SignalR keepalive."""
    def __init__(self, probe, role, token):
        self.probe, self.role, self.token = probe, role, token
        self.events = deque(maxlen=256)
        self.condition = threading.Condition()
        self.send_lock = threading.Lock()
        self.stop = threading.Event()
        self.failure = None
        self.ws = None
        self.thread = None

    def open(self):
        from websockets.sync.client import connect
        self.ws = connect(self.probe.base.replace('https://', 'wss://') + '/hubs/fruitvision',
            additional_headers={'Authorization': 'Bearer ' + self.token}, proxy=None,
            open_timeout=self.probe.remaining(10), close_timeout=1, max_size=65536,
            ping_interval=10, ping_timeout=10)
        self.send({'protocol': 'json', 'version': 1})
        initial = self.ws.recv(timeout=self.probe.remaining(8))
        frames = [json.loads(part) for part in initial.split('\x1e') if part]
        self.probe.check(self.role + ' actual WSS handshake', bool(frames) and frames[0] == {})
        for frame in frames[1:]:
            self.record(frame)
        self.thread = threading.Thread(target=self.receive, name='vertical-wss-' + self.role, daemon=True)
        self.thread.start()
        return self

    def send(self, frame):
        with self.send_lock:
            self.ws.send(json.dumps(frame, ensure_ascii=False) + '\x1e')

    def record(self, frame):
        if frame.get('type') == 6:
            return
        with self.condition:
            if len(self.events) == 256:
                self.failure = 'EventBufferOverflow'
            else:
                self.events.append((time.monotonic(), frame))
            self.condition.notify_all()

    def receive(self):
        last_ping = time.monotonic()
        try:
            while not self.stop.is_set():
                if time.monotonic() - last_ping >= 10:
                    self.send({'type': 6})
                    last_ping = time.monotonic()
                try:
                    packet = self.ws.recv(timeout=.5)
                except TimeoutError:
                    continue
                for part in packet.split('\x1e'):
                    if part:
                        self.record(json.loads(part))
        except Exception as error:
            if not self.stop.is_set():
                with self.condition:
                    self.failure = type(error).__name__
                    self.condition.notify_all()

    def wait(self, predicate, timeout=8, absent=False):
        deadline = min(self.probe.deadline, time.monotonic() + timeout)
        with self.condition:
            while True:
                if self.failure:
                    raise ProbeFailure(self.role + ' WSS receiver failed: ' + self.failure)
                match = next((frame for _, frame in self.events if predicate(frame)), None)
                if match is not None:
                    return None if absent else match
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    if absent:
                        return True
                    raise ProbeFailure(self.role + ' WSS expected event timed out')
                self.condition.wait(min(.5, remaining))

    def event(self, target, object_id, timeout=8, absent=False):
        def matches(frame):
            args = frame.get('arguments') or []
            return frame.get('target') == target and args and str(args[0].get('id')) == object_id
        return self.wait(matches, timeout, absent)

    def join(self, conversation_id, allowed=True):
        invocation = uuid.uuid4().hex
        self.send({'type': 1, 'invocationId': invocation, 'target': 'JoinConversation', 'arguments': [conversation_id]})
        reply = self.wait(lambda frame: frame.get('type') == 3 and frame.get('invocationId') == invocation)
        self.probe.check(self.role + ' JoinConversation completion ' + conversation_id,
                         ('error' not in reply) == allowed)

    def close(self):
        self.stop.set()
        if self.ws is not None:
            try:
                self.ws.close()
            except Exception:
                pass
        if self.thread is not None:
            self.thread.join(timeout=1.5)
        self.token = ''


class Probe:
    def __init__(self, output):
        self.started = time.monotonic()
        self.deadline = self.started + 160  # Leave bounded time for socket close, restoration and logout.
        self.output = output
        self.lock = threading.Lock()
        self.tokens, self.sockets = {}, {}
        self.restore_supply = None
        self.report = {'startedUtc': dt.datetime.now(dt.timezone.utc).isoformat(), 'status': 'RUNNING',
            'scope': 'Four independent role clients on this PC, actual owned public HTTPS/WSS and API persistence; not four phones, stock, trades or market-price qualification.',
            'tlsVerificationDisabled': False, 'checks': [], 'requests': [], 'interleavings': [], 'records': {}, 'cleanup': []}
        self.base = ''

    def remaining(self, ceiling=12):
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise ProbeFailure('Overall acceptance deadline exceeded')
        return max(.1, min(ceiling, left))

    def check(self, name, passed):
        with self.lock:
            self.report['checks'].append({'name': name, 'pass': bool(passed),
                'atMs': round((time.monotonic() - self.started) * 1000)})
        if not passed:
            raise ProbeFailure(name)

    def request(self, role, path, data=None, method=None, expected=None, cleanup=False):
        if not path.startswith('/') or '://' in path:
            raise ProbeFailure('Unsafe request route')
        headers = {'Accept': 'application/json'}
        if role is not None:
            headers['Authorization'] = 'Bearer ' + self.tokens[role]
        payload = json.dumps(data, ensure_ascii=False).encode('utf-8') if data is not None else None
        if payload is not None:
            headers['Content-Type'] = 'application/json'
        started = time.monotonic()
        request = urllib.request.Request(self.base + path, data=payload, headers=headers, method=method)
        status = None
        try:
            try:
                response = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(
                    request, timeout=3 if cleanup else self.remaining(12))
            except urllib.error.HTTPError as error:
                response = error
            with response:
                status = response.status
                raw = response.read(1_048_577)
                if len(raw) > 1_048_576:
                    raise ProbeFailure('Response exceeded bounded probe limit')
                result = json.loads(raw) if raw and 'json' in response.headers.get('Content-Type', '') else None
        finally:
            with self.lock:
                self.report['requests'].append({'role': role or 'anonymous', 'method': method or ('POST' if data is not None else 'GET'),
                    'route': path, 'status': status, 'expectedStatus': expected, 'startMs': round((started - self.started) * 1000),
                    'latencyMs': round((time.monotonic() - started) * 1000, 1)})
        if expected is not None and status != expected:
            self.check(f'{role or "anonymous"} {method or ("POST" if data is not None else "GET")} {path} expected {expected}, actual {status}', False)
        return status, result

    def parallel(self, operations, label=None):
        started = time.monotonic()
        with ThreadPoolExecutor(max_workers=min(8, len(operations))) as pool:
            futures = [pool.submit(operation) for operation in operations]
            result = [future.result() for future in futures]
        if label:
            self.report['interleavings'].append({'name': label, 'operations': len(operations),
                'startMs': round((started - self.started) * 1000), 'endMs': round((time.monotonic() - self.started) * 1000)})
        return result

    def login(self, role, password):
        _, result = self.request(None, '/api/v1/auth/login',
            {'email': role + '@fruitvision.test', 'password': password}, expected=200)
        self.check(role + ' login contains in-memory access token', isinstance(result.get('accessToken'), str))
        with self.lock:
            self.tokens[role] = result['accessToken']
        _, profile = self.request(role, '/api/v1/auth/me', expected=200)
        self.check(role + ' own approved role', profile['role'].lower() == role and profile['approvalStatus'] == 'Approved' and profile['isActive'])
        return profile['id']

    def review(self, post_id, status, revision):
        return self.request('admin', f'/api/v1/admin/posts/{post_id}/review',
            {'status': status, 'reason': 'Demo nghiệm thu HTTPS/WSS 2.2: bài dự kiến, chưa có giao dịch.', 'expectedRevision': revision})

    def market(self, product):
        path = '/api/v1/market/summary?' + urllib.parse.urlencode({'region': REGION, 'productCode': product})
        _, result = self.request('consumer', path, expected=200)
        self.check('market source/time and non-AI asking reference', result['source'] == 'published-user-asking-prices' and
            result.get('isForecast') is False and bool(result.get('asOf')))
        rows = result['items']
        self.check('filtered market has at most one exact region/product bucket', len(rows) <= 1 and
            all(row['productCode'] == product and row['region'] == REGION for row in rows))
        return rows[0] if rows else {'supplyEstimatedKg': 0, 'demandEstimatedKg': 0, 'priceSampleCount': 0,
            'referencePriceVndPerKg': None, 'supplyPostCount': 0, 'demandPostCount': 0}

    def message(self, sender, conversation, text, recipients):
        key = uuid.uuid4().hex
        _, result = self.request(sender, f'/api/v1/conversations/{conversation}/messages',
            {'clientMessageId': key, 'text': text}, expected=201)
        message_id = str(uuid.UUID(result['id']))
        self.report['records'].setdefault('messages', []).append(
            {'id': message_id, 'conversationId': conversation, 'senderRole': sender})
        for recipient in recipients:
            event = self.sockets[recipient].event('MessageCreated', message_id)
            self.check(recipient + ' receives persisted WSS message ' + message_id,
                event['arguments'][0]['conversationId'] == conversation)
        return key, message_id

    def group(self, label, product):
        _, result = self.request('producer', '/api/v1/community/groups',
            {'title': label, 'region': REGION, 'productCode': product}, expected=201)
        group_id = str(uuid.UUID(result['id']))
        self.check('group creator is owner/member', result['isMember'] and result['currentRole'] == 'Owner')
        return group_id

    def run(self):
        state = json.loads((ROOT / '.local/tunnel-state.json').read_text(encoding='utf-8-sig'))
        self.base = str(state.get('publicUrl', '')).rstrip('/')
        parsed = urllib.parse.urlsplit(self.base)
        self.check('only current privately recorded HTTPS tunnel', parsed.scheme == 'https' and
            parsed.hostname is not None and parsed.hostname.endswith('.trycloudflare.com') and
            not parsed.username and not parsed.password and not parsed.query and not parsed.fragment and parsed.path == '' and
            parsed.port in (None, 443) and state.get('origin') == 'http://127.0.0.1:5098')
        self.report['baseUrl'] = self.base
        settings = json.loads((ROOT / '.local/runtime.json').read_text(encoding='utf-8-sig'))
        password = settings['Demo']['Password']
        self.request(None, '/health/ready', expected=200)
        self.request(None, '/.local/runtime.json', expected=404)
        self.request(None, '/api/v1/community/groups', expected=401)
        self.parallel([lambda role=role: self.login(role, password) for role in ROLES], 'four-role-login')
        del password, settings
        _, catalog = self.request('consumer', '/api/v1/catalog/products', expected=200)
        codes = [row['code'] for row in catalog['items']]
        self.check('actual product catalog available', bool(codes))
        product = 'mango' if 'mango' in codes else codes[0]
        baseline = self.market(product)
        self.check('price baseline permits an honest 25000 reference probe', baseline['referencePriceVndPerKg'] in (None, 25000))
        self.report['marketBaseline'] = baseline
        def open_socket(role):
            socket = RoleSocket(self, role, self.tokens[role])
            with self.lock:
                self.sockets[role] = socket
            return socket.open()
        opened = self.parallel([lambda role=role: open_socket(role) for role in ROLES], 'four-concurrent-WSS-connects')
        self.check('all four independent WSS clients concurrently live', all(socket.thread.is_alive() for socket in opened))
        suffix = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6]
        upcoming = (dt.datetime.now(dt.timezone.utc).date() + dt.timedelta(days=7)).isoformat()
        _, supply = self.request('producer', '/api/v1/posts', {'title': 'Demo 2.2 · dự kiến cung xoài ' + suffix,
            'body': 'Bài dự kiến do người demo nhập: 500 kg, chưa xác nhận thu hoạch, tồn kho, đặt hàng hoặc giao dịch.',
            'productCode': product, 'estimatedQuantityKg': 500, 'region': REGION, 'purpose': 'Supply',
            'availableOn': upcoming, 'priceMinVndPerKg': 20000, 'priceMaxVndPerKg': 30000}, expected=201)
        supply_id = str(uuid.UUID(supply['id']))
        self.report['records']['supplyPostId'] = supply_id
        self.check('producer submission awaits moderation', supply['status'] == 'AwaitingReview' and supply['actualStockKg'] is None and not supply['canOrder'])
        self.parallel([lambda role=role: self.request(role, f'/api/v1/posts/{supply_id}', expected=404)
                       for role in (None, 'trader', 'consumer')])
        review_body = {'status': 'Published', 'reason': 'Forbidden role control', 'expectedRevision': supply['revision']}
        self.request('trader', f'/api/v1/admin/posts/{supply_id}/review', review_body, expected=403)
        revisions = self.parallel([lambda: self.review(supply_id, 'Published', supply['revision']) for _ in range(2)], 'same-revision-admin-review')
        self.check('simultaneous same-revision review has one success/one conflict', sorted(row[0] for row in revisions) == [200, 409])
        published = next(row[1] for row in revisions if row[0] == 200)
        _, feed = self.request('consumer', '/api/v1/posts?limit=20', expected=200)
        self.check('new published supply is newest visible feed entry', feed['items'][0]['id'] == supply_id)
        self.request('producer', f'/api/v1/posts/{supply_id}/conversations', {}, expected=409)
        self.request('admin', f'/api/v1/posts/{supply_id}/conversations', {}, expected=403)
        contacts = self.parallel([lambda: self.request('trader', f'/api/v1/posts/{supply_id}/conversations', {}) for _ in range(8)], 'eight-concurrent-trader-contacts')
        self.check('eight simultaneous contacts create once and reuse seven times', sorted(row[0] for row in contacts) == [200] * 7 + [201])
        direct = str(uuid.UUID(contacts[0][1]['id']))
        self.check('all eight contact results identify one direct thread', all(row[1]['id'] == direct for row in contacts))
        self.report['records']['producerTraderConversationId'] = direct
        self.sockets['producer'].event('ConversationCreated', direct)
        _, own_threads = self.request('producer', '/api/v1/conversations?limit=50', expected=200)
        self.check('producer sees newly contacted thread', any(row['id'] == direct for row in own_threads['items']))
        self.request('consumer', f'/api/v1/conversations/{direct}/messages', expected=404)
        self.request('consumer', f'/api/v1/community/groups/{direct}/join', {}, expected=404)
        self.sockets['consumer'].join(direct, allowed=False)
        _, contacted = self.request('consumer', f'/api/v1/posts/{supply_id}/conversations', {}, expected=201)
        consumer_direct = str(uuid.UUID(contacted['id']))
        self.check('consumer direct thread is distinct', consumer_direct != direct)
        self.report['records']['producerConsumerConversationId'] = consumer_direct
        for role in ('producer', 'trader'):
            self.sockets[role].join(direct)
        for role in ('producer', 'consumer'):
            self.sockets[role].join(consumer_direct)
        key, message_id = self.message('trader', direct, 'Demo 2.2: hỏi lịch dự kiến, chưa chốt mua hoặc giữ hàng.', ('producer', 'trader'))
        _, repeated = self.request('trader', f'/api/v1/conversations/{direct}/messages',
            {'clientMessageId': key, 'text': 'Demo 2.2: hỏi lịch dự kiến, chưa chốt mua hoặc giữ hàng.'}, expected=200)
        self.check('message retry reuses persisted ID', repeated['id'] == message_id)
        self.request('trader', f'/api/v1/conversations/{direct}/messages', {'clientMessageId': key, 'text': 'Nội dung khác với cùng khóa.'}, expected=409)
        self.message('producer', direct, 'Demo 2.2: cơ sở sẽ xác nhận sau khảo sát; đây chưa phải tồn kho.', ('producer', 'trader'))
        self.message('consumer', consumer_direct, 'Demo 2.2: người tiêu dùng hỏi thông tin sản phẩm dự kiến.', ('producer', 'consumer'))
        self.message('producer', consumer_direct, 'Demo 2.2: đã nhận câu hỏi, chưa hình thành đơn mua bán.', ('producer', 'consumer'))

        group = self.group('Demo 2.2 · kiểm tra nhóm đóng ' + suffix, product)
        self.report['records']['closedAcceptanceGroupId'] = group
        for role in ('trader', 'consumer'):
            joined = self.parallel([lambda role=role: self.request(role, f'/api/v1/community/groups/{group}/join', {}) for _ in range(2)], role + '-duplicate-concurrent-group-join')
            self.check(role + ' duplicate concurrent group join adds once', sorted(row[0] for row in joined) == [200, 201])
        self.request('admin', f'/api/v1/conversations/{group}/messages', expected=404)
        self.request('admin', f'/api/v1/community/groups/{group}/join', {}, expected=201)
        self.request('consumer', f'/api/v1/community/groups/{group}/join', {'userId': str(uuid.uuid4())}, expected=400)
        for role in ROLES:
            self.sockets[role].join(group)
        self.message('producer', group, 'Demo 2.2: bốn vai trò cùng thảo luận; chưa có giao dịch.', ROLES)
        self.request('consumer', f'/api/v1/community/groups/{group}/leave', {}, expected=200)
        self.request('consumer', f'/api/v1/conversations/{group}/messages', expected=404)
        _, after_leave = self.message('trader', group, 'Demo 2.2: tin sau khi thành viên đã rời nhóm.', ('admin', 'producer', 'trader'))
        self.check('departed consumer receives no new group WSS message', self.sockets['consumer'].event('MessageCreated', after_leave, timeout=2, absent=True) is True)
        self.request('trader', f'/api/v1/community/groups/{group}/close', {}, expected=403)
        self.request('producer', f'/api/v1/community/groups/{group}/close', {}, expected=200)
        self.request('trader', f'/api/v1/conversations/{group}/messages', {'clientMessageId': uuid.uuid4().hex, 'text': 'Nhóm đóng không nhận tin mới.'}, expected=409)
        self.request('consumer', f'/api/v1/community/groups/{group}/join', {}, expected=409)

        before_demand = self.market(product)
        self.check('supply adds exactly500 estimated kg and one asking sample', abs(before_demand['supplyEstimatedKg'] - baseline['supplyEstimatedKg'] - 500) < .00001 and
            before_demand['priceSampleCount'] == baseline['priceSampleCount'] + 1 and before_demand['referencePriceVndPerKg'] == 25000)
        _, demand = self.request('trader', '/api/v1/posts', {'title': 'Demo 2.2 · nhu cầu thu mua ' + suffix,
            'body': 'Nhu cầu dự kiến 200 kg do người demo nhập; chưa đặt cọc, giữ hàng, đặt hàng hoặc giao dịch.',
            'productCode': product, 'estimatedQuantityKg': 200, 'region': REGION, 'purpose': 'Demand',
            'availableOn': upcoming, 'priceMinVndPerKg': 1000, 'priceMaxVndPerKg': 2000}, expected=201)
        demand_id = str(uuid.UUID(demand['id']))
        self.report['records']['demandPostId'] = demand_id
        status, _ = self.review(demand_id, 'Published', demand['revision'])
        self.check('admin publishes trader demand', status == 200)
        self.request('trader', f'/api/v1/posts/{demand_id}/conversations', {}, expected=409)
        after_demand = self.market(product)
        self.check('demand adds200 estimated kg without shifting supply asking reference',
            abs(after_demand['demandEstimatedKg'] - baseline['demandEstimatedKg'] - 200) < .00001 and
            after_demand['referencePriceVndPerKg'] == 25000 and after_demand['priceSampleCount'] == before_demand['priceSampleCount'])
        status, paused = self.review(supply_id, 'Paused', published['revision'])
        self.check('admin pauses supply with current revision', status == 200)
        self.restore_supply = (supply_id, paused['revision'])
        self.request('consumer', f'/api/v1/posts/{supply_id}', expected=404)
        paused_market = self.market(product)
        self.check('paused supply is excluded from quantities and price samples',
            abs(paused_market['supplyEstimatedKg'] - baseline['supplyEstimatedKg']) < .00001 and paused_market['priceSampleCount'] == baseline['priceSampleCount'])
        status, _ = self.review(supply_id, 'Published', paused['revision'])
        self.check('supply restored Published for human demo', status == 200)
        self.restore_supply = None
        human_group = self.group('Cộng đồng demo FruitVision · ' + suffix, product)
        self.report['records']['openHumanDemoGroupId'] = human_group
        for role in ('admin', 'trader', 'consumer'):
            self.request(role, f'/api/v1/community/groups/{human_group}/join', {}, expected=201)
        for role in ROLES:
            self.sockets[role].join(human_group)
        for role in ROLES:
            self.message(role, human_group, f'Demo 2.2 · {role}: chào cộng đồng, trao đổi minh bạch về dự kiến, chưa có đơn hàng hoặc thanh toán.', ROLES)
        _, detail = self.request('consumer', f'/api/v1/community/groups/{human_group}', expected=200)
        self.check('human-ready group remains open with all four roles', detail['isOpen'] and detail['memberCount'] == 4)
        self.report['marketAfter'] = self.market(product)
        self.report['records']['productCode'] = product
        self.report['records']['region'] = REGION
        self.report['status'] = 'PASS'

    def finish(self):
        if self.restore_supply is not None and 'admin' in self.tokens:
            post_id, revision = self.restore_supply
            try:
                status, _ = self.request('admin', f'/api/v1/admin/posts/{post_id}/review',
                    {'status': 'Published', 'reason': 'Restore this probe-owned demo supply after acceptance interruption.',
                     'expectedRevision': revision}, cleanup=True)
                self.report['cleanup'].append({'action': 'restore-probe-owned-supply', 'postId': post_id, 'status': status})
            except Exception as error:
                self.report['cleanup'].append({'action': 'restore-probe-owned-supply', 'postId': post_id, 'errorType': type(error).__name__})
        for socket in self.sockets.values():
            socket.close()
        self.report['wssClients'] = {role: {'bufferedFrames': len(socket.events),
            'receiverFailureType': socket.failure, 'backgroundReceiverStarted': socket.thread is not None}
            for role, socket in self.sockets.items()}
        def logout(role):
            try:
                status, _ = self.request(role, '/api/v1/auth/logout', method='POST', cleanup=True)
                result = {'role': role, 'logoutStatus': status}
            except Exception as error:
                result = {'role': role, 'errorType': type(error).__name__}
            with self.lock:
                self.report['cleanup'].append(result)
        if self.tokens:
            self.parallel([lambda role=role: logout(role) for role in list(self.tokens)])
        self.tokens.clear()
        self.report['finishedUtc'] = dt.datetime.now(dt.timezone.utc).isoformat()
        self.report['elapsedSeconds'] = round(time.monotonic() - self.started, 3)
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_text(json.dumps(self.report, ensure_ascii=False, indent=2), encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', required=True,
                        help='Authorize persistent demo posts/groups/messages on the currently recorded owned HTTPS tunnel.')
    parser.add_argument('--output', type=Path, default=ROOT / 'docs/verticals-https-e2e.json')
    args = parser.parse_args(argv)
    probe = Probe(args.output.resolve())
    try:
        probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'
        probe.report['errorType'] = type(error).__name__
        # Only our static check names are safe; network errors can contain headers/URLs.
        if isinstance(error, ProbeFailure):
            probe.report['failedStep'] = str(error)[:200]
    finally:
        try:
            probe.finish()
        except Exception as error:
            probe.report['status'] = 'FAIL'
            probe.report['receiptErrorType'] = type(error).__name__
        print(json.dumps({'status': probe.report['status'], 'checks': len(probe.report['checks']),
            'receipt': str(probe.output), 'scope': 'four role clients, not four phones'}, ensure_ascii=False))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
