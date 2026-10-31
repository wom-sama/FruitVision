"""Opt-in real APK2.6 inbox/profile acceptance on the existing shared AVD only.

SOURCE ONLY until Root finishes API acceptance and grants the restored Producer VM.
No login/OTP, install, launch, force-stop, settings change, new AVD, AI or secret-key call.
One labeled ordinary message remains in the existing/new generic Consumer/Producer Direct.
Optional block coverage removes ONLY the block this run created, even after failure.

From the project root, using the existing operator Python environment:
  server/.tools/ai-venv/Scripts/python.exe -X utf8 -B mobile_client/tool/android_messaging_26.py \
    --sessions server/.local/2.4-real-sessions.json \
    --output mobile_client/verification/2.6/android-messaging-NEW --run [--include-block]

The output directory must be new. Session refresh reuses the other acceptance drivers'
exclusive lock and atomic private-file rotation. Never run them concurrently.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import re
import sys
import time
import uuid

CLIENT = Path(__file__).resolve().parents[1]
SERVER = CLIENT.parent / 'server'
sys.path.insert(0, str(SERVER / 'scripts'))

# These imports define helpers only; their main/login workflows are never invoked.
from feedback_acceptance_25 import FeedbackAcceptance
from verticals_e2e import ProbeFailure
from android_ui import adb, state, label, tap, PACKAGE

SERIAL = 'emulator-5554'  # android_ui.adb is fixed to this same shared serial.
VERSION_CODE = 6012
MAX_HTTP = 48
MAX_SNAPSHOTS = 80
EMAIL = re.compile(r'[^\s@]+@[^\s@]+\.[^\s@]+')


def bounds(node):
    values = [int(value) for value in re.findall(r'-?\d+', node.get('bounds', ''))]
    return values if len(values) == 4 else [0, 0, 0, 0]


class AndroidMessagingAcceptance(FeedbackAcceptance):
    def __init__(self, sessions, folder, include_block, *, version_code=VERSION_CODE):
        super().__init__(sessions, folder / 'receipt.json')
        if type(version_code) is not int or version_code not in (6012, 6013):
            raise ProbeFailure('An explicitly supported demo release is required')
        self.version_code = version_code
        self.folder, self.include_block = folder, include_block
        self.deadline = self.started + 240
        self.private_output = SERVER / '.local/android-messaging26' / (self.run_id + '.json')
        self.stage = 'preflight'
        self.snapshots = self.ui_taps = self.ui_swipes = 0
        self.added_block = False
        self._cleaning = False
        self.report.pop('formalRoleApplicationFlow', None)
        self.report.update({
            'scope': 'One actual shared Android AVD, restored Producer, independent Consumer HTTPS sender: foreground inbox notification, normal chat display/read and public peer profile. Not four phones, background Android push, OTP login, AI FPS or E2EE cryptography proof.',
            'serial': SERIAL, 'requiredVersionCode': self.version_code,
            'requestBudget': MAX_HTTP, 'snapshotBudget': MAX_SNAPSHOTS,
            'screenshots': [], 'ordinaryMessagesPersistedByThisRun': 0,
            'blockUiCoverage': 'NOT_RUN' if not include_block else 'PENDING',
            'intendedCleanup': 'Keep labeled ordinary Direct/message QA history. If requested, remove only this run newly added Producer block. No foreign blocks, profiles, roles, keys or existing history are changed.',
        })

    def exchange(self, *args, **kwargs):
        if self.request_count >= (MAX_HTTP if self._cleaning else MAX_HTTP - 1):
            raise ProbeFailure('Android acceptance HTTP budget reached')
        return super().exchange(*args, **kwargs)

    def snapshot(self):
        self.remaining()
        if self.snapshots >= MAX_SNAPSHOTS:
            raise ProbeFailure('Android acceptance snapshot budget reached')
        self.snapshots += 1
        return state()

    def wait_ui(self, predicate, seconds=15):
        until = time.monotonic() + min(seconds, self.remaining(seconds))
        while time.monotonic() < until:
            nodes = self.snapshot()
            if predicate(nodes):
                return nodes
            time.sleep(.4)
        raise ProbeFailure('Current Android UI did not reach the required state')

    @staticmethod
    def has(nodes, text):
        return any(text in label(node) for node in nodes)

    def click(self, text, *, scroll=False, exclude_profile=False):
        def target(nodes):
            matches = [node for node in nodes if text in label(node)
                       and (not exclude_profile or not label(node).startswith('Xem hồ sơ'))
                       and bounds(node)[2] > bounds(node)[0]
                       and bounds(node)[3] > bounds(node)[1]]
            return min(matches, key=lambda node: (label(node) != text, len(label(node)))) if matches else None

        for attempt in range(8 if scroll else 3):
            nodes = self.snapshot()
            node = target(nodes)
            viewport = bounds(nodes[0]) if nodes else [0, 0, 0, 0]
            width, height = viewport[2], viewport[3]
            usable = node is not None and (not scroll or
                (bounds(node)[1] >= height * .12 and bounds(node)[3] <= height * .88))
            if usable:
                # Swipe completion can precede Flutter's final scroll position. Do
                # not tap clipped text or coordinates captured while it is moving.
                time.sleep(.2)
                current = target(self.snapshot())
                if current is not None and max(abs(a - b) for a, b in zip(bounds(node), bounds(current))) <= 4:
                    tap(current)
                    self.ui_taps += 1
                    return
                continue
            if scroll and attempt < 7:
                if width <= 0 or height <= 0:
                    raise ProbeFailure('No current viewport for bounded scrolling')
                # Small correction once the label appears near the bottom; large
                # scans otherwise. Both stay away from Android navigation bars.
                end = .58 if node is not None else .30
                adb('shell', 'input', 'swipe', str(width // 2), str(int(height * .80)),
                    str(width // 2), str(int(height * end)), '250')
                self.ui_swipes += 1
        raise ProbeFailure('Required current Android action is not visible')

    def back(self):
        adb('shell', 'input', 'keyevent', '4')
        self.ui_taps += 1

    def shot(self, name):
        # Own-account pages contain email, so they are intentionally never captured.
        nodes = self.snapshot()
        if any(EMAIL.search(label(node)) for node in nodes):
            raise ProbeFailure('Screenshot blocked because a visible email is present')
        target = self.folder / (name + '.png')
        with target.open('xb') as stream:
            stream.write(adb('exec-out', 'screencap', '-p'))
        self.report['screenshots'].append(target.name)

    def preflight(self):
        self.check('only the existing shared emulator is targeted', adb('get-state').strip() == b'device')
        package = adb('shell', 'dumpsys', 'package', PACKAGE).decode('utf-8', 'replace')
        found = re.search(r'\bversionCode=(\d+)\b', package)
        self.check('actual installed APK is exactly the expected release', found is not None and int(found.group(1)) == self.version_code)
        focus = adb('shell', 'dumpsys', 'window').decode('utf-8', 'replace')
        current = next((line for line in focus.splitlines() if 'mCurrentFocus=' in line), '')
        self.check('the already running FruitVision APK is foreground', PACKAGE in current)
        self.report['installedVersionCode'] = self.version_code

    def row(self, identifier):
        response = self.request('Producer', '/api/v1/conversations?limit=50')
        row = next((row for row in response.get('items', []) if row.get('id') == identifier), None)
        self.check('actual server inbox contains the exact generic Direct', row is not None)
        return response, row

    @staticmethod
    def badge(nodes, count):
        if count <= 0:
            return False
        height = max((bounds(node)[3] for node in nodes), default=0)
        for node in nodes:
            text = label(node)
            # Do not mistake a tab index such as "Tab3of4" for an unread badge.
            numeric_line = str(count) in [line.strip() for line in text.splitlines()]
            near_navigation = bounds(node)[1] >= height * .80
            if numeric_line and (near_navigation or 'Tin nhắn chưa đọc' in text or 'Tin nhắn' in text):
                return True
        return False

    def run(self):
        self.preflight()  # No refresh or domain writes before the APK/foreground guard.
        self.stage = 'verify_existing_sessions_and_app_identity'
        self.load_and_verify_sessions()
        self.producer = self.actors['Producer']['id']
        self.consumer = self.actors['Consumer']['id']
        for role, other in (('Producer', self.consumer), ('Consumer', self.producer)):
            blocked = self.request(role, '/api/v1/profile/blocked')['items']
            self.check('preexisting pair block is never removed or bypassed', not any(row['id'] == other for row in blocked))

        # Read current UI identity, without login or screenshots of the private email.
        self.click('Tài khoản')
        self.wait_ui(lambda nodes: self.has(nodes, self.profiles['Producer']['displayName']) and self.has(nodes, 'Nhà sản xuất'))
        self.check('restored APK shows the exact supplied Producer identity and role', True)
        self.click('AI xoài')
        self.wait_ui(lambda nodes: self.has(nodes, 'Phân tích xoài'))
        self.check('receiver is on AI workspace rather than an open conversation', not self.has(self.snapshot(), 'Gửi tin nhắn'))
        time.sleep(.8)  # Let the foreground InboxController initial snapshot settle.

        self.stage = 'create_or_reuse_generic_direct'
        status, direct, _ = self.exchange('Consumer', '/api/v1/conversations/direct',
            data={'userId': self.producer}, expected=(200, 201))
        identifier = str(uuid.UUID(direct['id']))
        self.check('server-derived generic normal Direct has no article/post context', direct.get('kind') == 'Direct' and direct.get('postId') is None and direct.get('articleId') is None)
        baseline, _ = self.row(identifier)
        marker = 'DEMO QA2.6 ANDROID ' + self.run_id
        client_id = uuid.uuid4().hex
        # Preserve uncertain-send ownership BEFORE the only POST. Never auto-post again.
        self.write_private(self.private_output, {'runId': self.run_id, 'directId': identifier,
            'createdDirectThisRun': status == 201, 'clientMessageId': client_id, 'messageId': None,
            'warning': 'Ordinary labeled QA history persists. No credentials or body. Never blindly rerun an uncertain send.'})
        self.stage = 'send_one_marker_while_ai_visible'
        sent = self.request('Consumer', f'/api/v1/conversations/{identifier}/messages',
            {'clientMessageId': client_id, 'text': marker}, expected=201)
        self.check('one real Consumer message was persisted', sent.get('senderId') == self.consumer and sent.get('text') == marker)
        self.report['ordinaryMessagesPersistedByThisRun'] = 1
        self.write_private(self.private_output, {'runId': self.run_id, 'directId': identifier,
            'createdDirectThisRun': status == 201, 'clientMessageId': client_id, 'messageId': sent['id']})
        incoming, row = self.row(identifier)
        expected_total = incoming['summary']['unreadTotal']
        self.check('server summary increases from its actual baseline', expected_total == baseline['summary']['unreadTotal'] + 1)
        self.check('receiver inbox normal preview identifies the exact Consumer', (row.get('peer') or {}).get('id') == self.consumer and
            (row.get('lastMessage') or {}).get('text') == marker and row.get('lastMessageEncrypted') is False)

        self.stage = 'automatic_foreground_inbox_notification'
        visible = self.wait_ui(lambda nodes: self.has(nodes, 'Bạn có tin nhắn mới') or self.badge(nodes, expected_total), seconds=15)
        self.report['automaticNotificationObserved'] = self.has(visible, 'Bạn có tin nhắn mới')
        self.report['actualUnreadBadgeObserved'] = self.badge(visible, expected_total)
        self.check('incoming message is signaled without manually refreshing or opening chat', True)
        self.shot('incoming-while-ai')

        self.stage = 'open_inbox_and_display_marker'
        self.click('Tin nhắn')
        self.wait_ui(lambda nodes: self.has(nodes, self.profiles['Consumer']['displayName']) and self.has(nodes, marker))
        self.shot('inbox')
        # A user can have several post/article/generic Directs with the same peer.
        # The unique received preview selects the correct server-created generic one.
        self.click(marker, exclude_profile=True)
        self.wait_ui(lambda nodes: self.has(nodes, marker) and self.has(nodes, 'Xem hồ sơ người trao đổi'))
        self.check('actual newest marker is visible in the opened ordinary chat', True)
        self.shot('normal-chat-marker')
        for attempt in range(5):
            _, read = self.row(identifier)
            if read.get('unreadCount') == 0:
                break
            time.sleep(.6)
        self.check('APK visible-history receipt clears actual Direct unread', read.get('unreadCount') == 0)
        self.report['directUnreadAfterDisplay'] = read.get('unreadCount')

        self.stage = 'public_peer_profile'
        self.click('Xem hồ sơ người trao đổi')
        nodes = self.wait_ui(lambda nodes: self.has(nodes, 'Hồ sơ người dùng') and self.has(nodes, self.profiles['Consumer']['displayName']))
        self.check('public peer profile displays the real Consumer and no email', self.has(nodes, 'Người tiêu dùng') and not any(EMAIL.search(label(node)) for node in nodes))
        self.shot('consumer-public-profile')
        if self.include_block:
            self.block_and_unblock(identifier)
        self.report['status'] = 'PASS'

    def block_and_unblock(self, identifier):
        self.stage = 'explicit_block_ui'
        self.click('Chặn người dùng', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Xác nhận chặn'))
        self.click('Xác nhận chặn')
        # From this point cleanup may remove our block even if the UI/navigation fails.
        self.added_block = True
        self.wait_ui(lambda nodes: self.has(nodes, 'Bạn đã chặn người này.'))
        blocked = self.request('Producer', '/api/v1/profile/blocked')['items']
        self.check('UI block exists in the actual Producer block list', any(row['id'] == self.consumer for row in blocked))
        self.request('Consumer', f'/api/v1/conversations/{identifier}/messages',
            {'clientMessageId': uuid.uuid4().hex, 'text': 'DEMO QA2.6 blocked attempt ' + self.run_id}, expected=403)
        self.shot('blocked-direct')
        self.back()
        self.wait_ui(lambda nodes: self.has(nodes, 'AI xoài') and self.has(nodes, 'Tài khoản'))
        self.click('Tài khoản')
        self.stage = 'open_own_profile_for_unblock'
        self.click('Hồ sơ & quyền riêng tư', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Thông tin cá nhân'))
        self.stage = 'open_blocked_list'
        self.click('Danh sách đã chặn', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Danh sách đã chặn') and self.has(nodes, self.profiles['Consumer']['displayName']))
        self.stage = 'confirm_ui_unblock'
        self.click('Bỏ chặn')
        self.wait_ui(lambda nodes: self.has(nodes, 'Hủy') and self.has(nodes, 'Bỏ chặn'))
        self.click('Bỏ chặn')
        for attempt in range(5):
            blocked = self.request('Producer', '/api/v1/profile/blocked')['items']
            if not any(row['id'] == self.consumer for row in blocked):
                break
            time.sleep(.5)
        self.check('explicit UI unblock removes only this run new block', not any(row['id'] == self.consumer for row in blocked))
        self.added_block = False
        self.report['blockUiCoverage'] = 'PASS: real UI block, sender403, and real UI unblock'
        self.shot('unblocked-list')

    def finish(self):
        try:
            if self.added_block:
                self._cleaning = True
                self.deadline = max(self.deadline, time.monotonic() + 15)
                self.request('Producer', f'/api/v1/profiles/{self.consumer}/block', method='DELETE', expected=204)
                self.report['failureCleanup'] = 'Removed only this run newly added block through API; this is NOT UI-unblock proof.'
                self.added_block = False
        except Exception as error:
            self.report['status'] = 'FAIL'
            self.report['cleanupErrorType'] = type(error).__name__
        finally:
            self.report.update({'httpRequests': self.request_count, 'sessionRotations': self.rotations,
                'uiSnapshots': self.snapshots, 'uiTaps': self.ui_taps, 'uiSwipes': self.ui_swipes,
                'finishedUtc': dt.datetime.now(dt.timezone.utc).isoformat(),
                'elapsedSeconds': round(time.monotonic() - self.started, 3)})
            for key in ('baseURL', 'actors', 'records'):
                self.report.pop(key, None)
            try:
                with self.output.open('x', encoding='utf-8') as stream:
                    json.dump(self.report, stream, ensure_ascii=False, indent=2, allow_nan=False)
                    stream.write('\n')
            finally:
                self.tokens.clear()
                self.profiles.clear()
                self.session_document.clear()
                self.session_bytes = None
                if self.session_lock is not None:
                    self.session_lock.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True, help='Existing private four-role file; no CLI tokens/passwords')
    parser.add_argument('--output', type=Path, required=True, help='NEW directory beneath mobile_client/verification/2.6')
    parser.add_argument('--include-block', action='store_true', help='Also perform explicit UI block/unblock of only the supplied QA pair')
    parser.add_argument('--run', action='store_true', required=True, help='Root confirms API acceptance finished and existing restored VM execution is granted')
    args = parser.parse_args(argv)
    folder = args.output.resolve()
    allowed = (CLIENT / 'verification/2.6').resolve()
    if not folder.is_relative_to(allowed) or folder == allowed or folder.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'choose_new_directory_beneath_verification_2_6'}))
        return 2
    folder.mkdir(parents=True, exist_ok=False)
    probe = AndroidMessagingAcceptance(args.sessions, folder, args.include_block)
    try:
        probe.run()
    except Exception as error:
        probe.report.update(status='FAIL', failedStage=probe.stage, errorType=type(error).__name__)
    finally:
        try:
            probe.finish()
        except Exception as error:
            probe.report.update(status='FAIL', receiptErrorType=type(error).__name__)
        # Never expose API payloads, UI labels, tokens, email or private file contents.
        print(json.dumps({'status': probe.report['status'], 'stage': probe.stage,
            'receipt': str(probe.output), 'scope': 'one shared AVD; foreground normal inbox/profile only'}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
