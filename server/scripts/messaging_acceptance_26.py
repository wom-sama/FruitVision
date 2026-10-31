"""Opt-in2.6 inbox/read acceptance with four real OTP sessions and one receiver WSS.

The Producer socket NEVER invokes JoinConversation. Only newly created, labeled QA
article/Direct/group records are mutated. No password/email/SQL/AI/key/crypto calls.
Run only after Root deploys2.6 and grants execution; imports perform no workflow.
"""
from __future__ import annotations

import argparse
import importlib.metadata
import importlib.util
import json
from pathlib import Path
import re
import uuid

from feedback_acceptance_25 import FeedbackAcceptance, GUID, ROOT
from verticals_e2e import ProbeFailure, RoleSocket

TAG = 'DEMO QA2.6'
MAX_REQUESTS = 50


class UserGroupSocket(RoleSocket):
    """Only SignalR handshake/keepalive: this receiver represents another app tab."""
    join_invocations = 0

    def send(self, frame):
        if frame.get('target') == 'JoinConversation':
            self.join_invocations += 1
            raise ProbeFailure('Inbox socket must never join a conversation')
        return super().send(frame)

    def join(self, *args, **kwargs):
        raise ProbeFailure('Inbox acceptance forbids conversation joins')


class MessagingAcceptance(FeedbackAcceptance):
    def __init__(self, sessions, output):
        super().__init__(sessions, output)
        self.deadline = self.started + 90
        self.private_output = ROOT / '.local/messaging26' / (self.run_id + '.json')
        self.article = None; self.group_id = None; self.receiver = None
        self.report.pop('formalRoleApplicationFlow', None)
        self.report.update({
            'scope': 'Four real supplied role sessions over owned public HTTPS; one Producer WSS receives Consumer normal messages on its automatic user group without JoinConversation. REST inbox/read representation, not four phones or Flutter/native UI proof.',
            'requestBudget': MAX_REQUESTS,
            'secretCryptoAcceptance': 'NOT_RUN: no secret endpoint, ciphertext, key, device or secret read cursor is mutated. API unit tests cover separate metadata/ACL behavior; this driver supplies no cryptographic proof.',
            'ordinaryPhotoAcceptance': 'NOT_RUN: focus is text delivery, inbox ordering and exact read cursors; ordinary image ACL has a separate acceptance helper.',
            'intendedCleanup': 'On PASS only the owned QA article is Paused and owned control group Closed. New Direct/messages/history remain labeled seed; Trader unread is deliberately not acknowledged. Legacy human records/read cursors are never mutated.'})

    def exchange(self, role, path, *args, **kwargs):
        if not isinstance(path, str) or not path.startswith('/api/v1/'):
            raise ProbeFailure('Messaging route must include the explicit API version prefix')
        if self.request_count >= MAX_REQUESTS:
            raise ProbeFailure('Messaging acceptance HTTP budget reached')
        return super().exchange(role, path, *args, **kwargs)

    def save_ownership(self):
        if self.owned:
            self.write_private(self.private_output, {'runId': self.run_id, 'label': TAG, 'status': self.report['status'],
                'ownedOnly': self.owned, 'states': self.owned_states,
                'warning': 'Only new labeled QA IDs; no bodies, names, emails, session tokens or legacy human read cursors. Inspect after failure; do not replay mutations automatically.'})

    def inbox(self, role):
        data = self.request(role, '/api/v1/conversations?limit=50')
        if not isinstance(data.get('items'), list) or not isinstance(data.get('summary'), dict):
            raise ProbeFailure('Deployed API lacks2.6 inbox items/summary contract')
        for key in ('unreadTotal', 'unreadConversations'):
            self.check('inbox summary has nonnegative ' + key, type(data['summary'].get(key)) is int and data['summary'][key] >= 0)
        return data

    @staticmethod
    def item(data, identifier):
        row = next((row for row in data['items'] if row.get('id') == identifier), None)
        if row is None:
            raise ProbeFailure('New owned conversation is missing from bounded receiver inbox')
        return row

    def normal_preview(self, row, body, unread):
        peer = row.get('peer') or {}; message = row.get('lastMessage') or {}
        self.check('receiver inbox identifies the exact Consumer peer', set(peer) == {'id', 'displayName', 'role'} and
            peer['id'] == self.actors['Consumer']['id'] and peer['role'] == 'Consumer' and peer['displayName'] == self.profiles['Consumer']['displayName'])
        self.check('normal inbox preview matches real latest message and sender', message.get('kind') == 'text' and message.get('text') == body
            and message.get('senderName') == self.profiles['Consumer']['displayName'] and bool(message.get('createdAt')))
        self.check('normal inbox has current activity and correct unread count', bool(row.get('lastActivityAt')) and row.get('unreadCount') == unread)
        self.check('Consumer Direct is normal with no secret preview or linked secret room', row.get('lastMessageEncrypted') is False and row.get('secretConversationId') is None)

    def message(self, conversation_id, suffix):
        body = TAG + ' ' + self.run_id + ' Consumer message ' + suffix
        result = self.request('Consumer', f'/api/v1/conversations/{conversation_id}/messages',
            {'text': body, 'clientMessageId': uuid.uuid4().hex}, expected=201)
        self.own('normalMessages', result)
        self.check('actual persisted message has Consumer sender and requested body', result.get('conversationId') == conversation_id and
            result.get('senderId') == self.actors['Consumer']['id'] and result.get('text') == body)
        return result, body

    def event(self, message):
        frame = self.receiver.event('MessageCreated', message['id'], timeout=8)
        delivered = frame['arguments'][0]
        self.check('Producer receives the exact normal message without joining conversation', self.receiver.join_invocations == 0 and
            delivered.get('id') == message['id'] and delivered.get('conversationId') == message['conversationId'] and
            delivered.get('senderId') == self.actors['Consumer']['id'] and delivered.get('text') == message['text'])

    def ack(self, conversation_id, message_id, expected_unread):
        result = self.request('Producer', f'/api/v1/conversations/{conversation_id}/read', {'lastMessageId': message_id})
        self.check('exact displayed read cursor returns the expected remaining unread', result.get('id') == conversation_id and result.get('unreadCount') == expected_unread)

    def run(self):
        # Dependency preflight precedes any session refresh or domain writes.
        if importlib.util.find_spec('websockets.sync.client') is None:
            raise ProbeFailure('websockets.sync is unavailable; use the operator Python environment with websockets16')
        self.report['wssLibraryVersion'] = importlib.metadata.version('websockets')
        self.load_and_verify_sessions()  # Existing exclusive-lock + atomic one-time refresh helper.

        self.article = self.request('Consumer', '/api/v1/articles', {
            'title': TAG + ' inbox delivery ' + self.run_id,
            'body': TAG + ': synthetic technical mango knowledge article for inbox delivery/read validation; no trade, quantity, identity proof or role change.'}, expected=201)
        self.own('articles', self.article)
        self.check('new Consumer article is in Community and AwaitingReview', self.article.get('audienceLane') == 'Community' and self.article.get('status') == 'AwaitingReview')
        self.article = self.request('Admin', f'/api/v1/admin/articles/{self.article["id"]}/review',
            {'status': 'Published', 'reason': TAG + ' technical QA fixture only.', 'expectedRevision': self.article['revision']})
        self.owned_states[self.article['id']] = self.article['status']; self.save_ownership()
        producer = self.request('Producer', f'/api/v1/articles/{self.article["id"]}/conversations', {}, expected=201)
        trader = self.request('Trader', f'/api/v1/articles/{self.article["id"]}/conversations', {}, expected=201)
        producer_id = self.own('producerDirect', producer); trader_id = self.own('traderDirect', trader)

        # A later-created, owned control conversation proves an older Direct actually moves up.
        group = self.request('Admin', '/api/v1/community/groups', {'title': TAG + ' newer inbox control ' + self.run_id,
            'region': 'Đồng Tháp', 'productCode': 'mango'}, expected=201)
        self.group_id = self.own('controlGroups', group)
        self.request('Producer', f'/api/v1/community/groups/{self.group_id}/join', {}, expected=201)
        baseline = self.inbox('Producer'); old = self.item(baseline, producer_id)
        indices = {row['id']: index for index, row in enumerate(baseline['items'])}
        self.check('newer control conversation initially sorts above the older Direct', indices[self.group_id] < indices[producer_id] and old.get('unreadCount') == 0)
        before_total = baseline['summary']['unreadTotal']
        self.check('new Trader Direct initially has no unread messages', self.item(self.inbox('Trader'), trader_id).get('unreadCount') == 0)

        self.receiver = UserGroupSocket(self, 'Producer', self.tokens['Producer']); self.sockets['Producer'] = self.receiver; self.receiver.open()
        self.report['conversationJoinInvocations'] = 0
        trader_message, trader_body = self.message(trader_id, 'Trader-B1')
        first, first_body = self.message(producer_id, 'Producer-A1'); self.event(first)
        incoming = self.inbox('Producer'); row = self.item(incoming, producer_id)
        self.check('new incoming message moves the older Direct to receiver inbox top', incoming['items'][0]['id'] == producer_id)
        self.normal_preview(row, first_body, 1)
        self.check('receiver summary badge increments by one incoming message', incoming['summary']['unreadTotal'] == before_total + 1)

        displayed = self.request('Producer', f'/api/v1/conversations/{producer_id}/messages?limit=20')['items']
        first_displayed = next((item for item in displayed if item.get('id') == first['id']), None)
        self.check('receiver fetches the exact first displayed message', first_displayed is not None and first_displayed.get('text') == first_body)
        second, second_body = self.message(producer_id, 'Producer-A2-after-display'); self.event(second)

        self.exchange('Admin', f'/api/v1/conversations/{producer_id}/read', data={'lastMessageId': first['id']}, expected=404)
        self.exchange('Producer', f'/api/v1/conversations/{producer_id}/read', data={'lastMessageId': trader_message['id']}, expected=(400, 404))
        self.check('outsider read and wrong-conversation cursor are rejected', True)
        self.ack(producer_id, first_displayed['id'], 1)
        partial = self.inbox('Producer'); self.normal_preview(self.item(partial, producer_id), second_body, 1)
        self.check('acknowledging displayed first message does not clear later message', partial['summary']['unreadTotal'] == before_total + 1)
        self.normal_preview(self.item(self.inbox('Trader'), trader_id), trader_body, 1)
        self.check('Producer read cursor does not clear another receiver unread', True)

        displayed_again = self.request('Producer', f'/api/v1/conversations/{producer_id}/messages?limit=20')['items']
        latest_displayed = next((item for item in displayed_again if item.get('id') == second['id']), None)
        self.check('receiver fetches the exact second displayed message', latest_displayed is not None and latest_displayed.get('text') == second_body)
        self.ack(producer_id, latest_displayed['id'], 0)
        self.ack(producer_id, first_displayed['id'], 0)  # Deliberate monotonic cursor check, not an automatic retry.
        finished = self.inbox('Producer'); self.normal_preview(self.item(finished, producer_id), second_body, 0)
        self.check('final receiver badge returns to its original baseline', finished['summary']['unreadTotal'] == before_total)
        summary = self.request('Producer', '/api/v1/conversations/summary')
        self.check('standalone unread summary agrees with inbox summary', summary == finished['summary'])
        self.check('Trader unread remains pending after all Producer acknowledgements', self.item(self.inbox('Trader'), trader_id).get('unreadCount') == 1)
        self.report['observedReadState'] = {'producerNewDirectUnread': [0, 1, 1, 0], 'traderNewDirectUnreadAfterProducerRead': 1,
            'producerGlobalUnreadBaseline': before_total, 'producerGlobalUnreadAfter': finished['summary']['unreadTotal']}
        self.report['messageCreatedEventsObservedWithoutJoin'] = 2
        self.report['conversationJoinInvocations'] = self.receiver.join_invocations

        self.article = self.request('Admin', f'/api/v1/admin/articles/{self.article["id"]}/review',
            {'status': 'Paused', 'reason': TAG + ' owned fixture cleanup.', 'expectedRevision': self.article['revision']})
        self.owned_states[self.article['id']] = self.article['status']
        self.request('Admin', f'/api/v1/community/groups/{self.group_id}/close', {})
        self.owned_states[self.group_id] = 'Closed'; self.save_ownership()
        self.report['status'] = 'PASS'

    def finish(self):
        try:
            for socket in self.sockets.values(): socket.close()
            self.save_ownership()
            self.report.update({'httpRequests': self.request_count, 'sessionRotations': self.rotations,
                'ownedFixtureCounts': {key: len(value) for key, value in self.owned.items()},
                'wssClients': {role: {'bufferedFrames': len(socket.events), 'receiverFailureType': socket.failure,
                    'backgroundReceiverStarted': socket.thread is not None, 'joinConversationInvocations': socket.join_invocations} for role, socket in self.sockets.items()},
                'providedSessionsRetained': True})
            import datetime as dt, time
            self.report['finishedUtc'] = dt.datetime.now(dt.timezone.utc).isoformat(); self.report['elapsedSeconds'] = round(time.monotonic() - self.started, 3)
            for field in ('records', 'actors', 'baseURL'): self.report.pop(field, None)
            self.output.parent.mkdir(parents=True, exist_ok=True)
            with self.output.open('x', encoding='utf-8') as output:
                json.dump(self.report, output, ensure_ascii=False, indent=2, allow_nan=False); output.write('\n')
        finally:
            self.profiles.clear(); self.session_document.clear(); self.session_bytes = None; self.tokens.clear()
            if self.session_lock is not None: self.session_lock.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True, help='Current private four-role OTP sessions; no concurrent refresh writers')
    parser.add_argument('--output', type=Path, required=True, help='NEW sanitized public JSON under server/docs; never overwritten')
    parser.add_argument('--run', action='store_true', required=True, help='Authorize owned synthetic records AFTER2.6 deployment; one real WSS without conversation join')
    args = parser.parse_args(argv); output = args.output.resolve()
    if not output.is_relative_to((ROOT / 'docs').resolve()) or output.suffix != '.json' or output.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'choose_new_json_output_under_server_docs'})); return 2
    probe = MessagingAcceptance(args.sessions, output)
    try: probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'; probe.report['errorType'] = type(error).__name__
        if isinstance(error, ProbeFailure): probe.report['failedStep'] = GUID.sub('{id}', re.sub(r'\?\S+', '', str(error)))[:240]
    finally:
        try: probe.finish()
        except Exception as error: probe.report['status'] = 'FAIL'; probe.report['receiptErrorType'] = type(error).__name__
        print(json.dumps({'status': probe.report['status'], 'httpRequests': probe.request_count, 'wssClients': len(probe.sockets),
            'receipt': str(output), 'scope': 'Inbox REST plus one automatic-user-group WSS; no native or E2EE cryptographic proof'}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
