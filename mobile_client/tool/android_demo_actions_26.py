"""SOURCE-ONLY phased APK2.6 demo actions. Imports never drive Android or HTTP.

Root alone restores each account through normal app authentication, grants the existing
emulator5554 lease, and runs ONE phase at a time after all other UI/API drivers finish.
No login/OTP, role/session injection, install, launch, force-stop, AI, secret keys or model call.
Default role is the already restored Producer. Consumer learning requires a real Consumer UI.

Example from project root, after explicit Root execution approval:
  server/.tools/ai-venv/Scripts/python.exe -X utf8 -B mobile_client/tool/android_demo_actions_26.py \
    --sessions server/.local/2.4-real-sessions.json --role Producer --phase publishing \
    --image-document FruitVision-demo.jpg \
    --output mobile_client/verification/2.6/demo-publishing-NEW --run

Phases: publishing, learning, normal-photos, groups, profile-crud.
Optional --delete-owned-article deletes ONLY the article this publishing run creates.
An image must already exist in DocumentsUI; this driver never pushes device files.
Phase PASS describes only recorded substeps, never all28 rows/four devices/crypto/AI accuracy.
"""
from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path
import re
import shlex
import threading
import time
import urllib.parse
import uuid

from android_messaging_26 import (
    AndroidMessagingAcceptance, CLIENT, SERVER, EMAIL, ProbeFailure,
    adb, bounds, label, tap,
)

ROLE_LABEL = {'Admin': 'Quản trị', 'Producer': 'Nhà sản xuất',
              'Trader': 'Thương lái', 'Consumer': 'Người tiêu dùng'}
EDITABLE = ('displayName', 'bio', 'phone', 'gender', 'showGender', 'showPhone', 'showRegion')
SNAPSHOT_LOCK = threading.Lock()


def texts(node):
    # A filled EditText can have its value in text and its field label in content-desc.
    return '\n'.join(value for value in (node.get('text', ''), node.get('content-desc', '')) if value)


class DemoActions(AndroidMessagingAcceptance):
    def __init__(self, args, folder):
        super().__init__(args.sessions, folder, include_block=False, version_code=getattr(args, 'version_code', 6012))
        self.args, self.role = args, args.role
        self.deadline = self.started + 300
        self.stage = 'preflight'
        self.ui_lock_path = SERVER / '.local/android-ui-emulator5554.lock'
        self.ui_lock_owned = False
        self.original_profile = None
        self.created_article = self.created_group = None
        self.article_deleted = False
        self.private_output = SERVER / '.local/demo-actions26' / (self.run_id + '.json')
        self.marker = 'DEMO QA26 ' + self.run_id
        for key in ('blockUiCoverage', 'ordinaryMessagesPersistedByThisRun'):
            self.report.pop(key, None)
        self.report.update({
            'scope': 'One restored Android role, one bounded UI phase plus separately labeled HTTPS counterparty/assertion steps. Not all28 demo rows, four phones, fresh OTP, E2EE or AI acceptance.',
            'phase': args.phase, 'restoredUiRole': self.role,
            'uiObservations': [], 'httpCounterpartyObservations': [],
            'requestBudget': 48, 'snapshotBudget': 80,
            'cleanupPolicy': 'Restore only optional own-profile fields changed by this run; close only this run new group. New labeled messages/images persist. Published article is retained unless delete-owned-article explicitly requests its UI deletion.',
        })

    def snapshot(self):
        # Never run parallel uiautomator dumps, even within one process.
        with SNAPSHOT_LOCK:
            return super().snapshot()

    @staticmethod
    def has(nodes, text):
        return any(text in texts(node) for node in nodes)

    def observe(self, name):
        self.report['uiObservations'].append(name)
        self.check('actual APK: ' + name, True)

    def remote(self, name):
        self.report['httpCounterpartyObservations'].append(name)
        self.check('separate HTTPS: ' + name, True)

    def persist(self):
        self.write_private(self.private_output, {
            'runId': self.run_id, 'role': self.role, 'phase': self.args.phase,
            'createdArticle': self.created_article, 'createdGroup': self.created_group,
            'originalOptionalProfile': self.original_profile,
            'warning': 'Private recovery references only. Never mutate a foreign article/group or replay an uncertain UI submit. No tokens/passwords/OTP.'})

    @staticmethod
    def article_editor_fields(nodes):
        # Android's Flutter semantics may omit empty InputDecoration hints. This
        # fallback is restricted to the two source-defined article form fields;
        # it must never guess field order on login, profile, branch or OTP pages.
        titles = {'Viết bài chuyên môn', 'Viết bài cộng đồng'}
        known_page = any(line.strip() in titles for node in nodes
            if node.get('class') != 'android.widget.EditText'
            for line in texts(node).splitlines())
        fields = [node for node in nodes if node.get('class') == 'android.widget.EditText'
            and bounds(node)[2] > bounds(node)[0] and bounds(node)[3] > bounds(node)[1]]
        if not known_page or len(fields) != 2:
            return None
        return sorted(fields, key=lambda node: (bounds(node)[1], bounds(node)[0]))

    def click(self, text, *, scroll=False, exact=False, last=False, field=False, exclude_profile=False, direction='up'):
        def find(nodes):
            def matches(node):
                if not exact:
                    return text in texts(node)
                # Flutter tab semantics can append a second "Tab n of m" line;
                # match the exact label line, not an unrelated substring.
                return any(text == line.strip() for value in
                    (node.get('text', ''), node.get('content-desc', '')) for line in value.splitlines())
            candidates = [node for node in nodes
                if matches(node)
                and (not field or node.get('class') == 'android.widget.EditText')
                and (not exclude_profile or not texts(node).startswith('Xem hồ sơ'))
                and bounds(node)[2] > bounds(node)[0] and bounds(node)[3] > bounds(node)[1]]
            return (max(candidates, key=lambda node: bounds(node)[1]) if last else
                min(candidates, key=lambda node: (text not in (node.get('text'), node.get('content-desc')), len(texts(node))))) if candidates else None

        for attempt in range(18 if scroll else 4):
            nodes = self.snapshot()
            node = find(nodes)
            viewport = bounds(nodes[0]) if nodes else [0, 0, 0, 0]
            left, top, right, bottom = viewport
            if node is not None:
                box = bounds(node)
                center = ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
                # Fully visible lower controls are valid. No arbitrary88% rejection.
                visible_center = left <= center[0] < right and top <= center[1] < bottom
                if visible_center:
                    time.sleep(.2)
                    fresh = find(self.snapshot())
                    if fresh is not None and max(abs(a - b) for a, b in zip(box, bounds(fresh))) <= 4:
                        tap(fresh)
                        self.ui_taps += 1
                        return
                    continue
            if scroll and attempt < 17:
                if right <= left or bottom <= top:
                    raise ProbeFailure('Current UI viewport is unavailable')
                height = bottom - top
                upward = (direction == 'up') if node is None else bounds(node)[1] >= bottom
                start, end = ((.77, .36) if upward else (.35, .68))
                adb('shell', 'input', 'swipe', str((left + right) // 2), str(int(top + height * start)),
                    str((left + right) // 2), str(int(top + height * end)), '250')
                self.ui_swipes += 1
                time.sleep(.2)
        raise ProbeFailure('Required current action could not be hit within the UI budget')

    def set_field(self, name, value, *, old='', fallback=False):
        if not isinstance(value, str) or len(value) > 1000:
            raise ProbeFailure('Bounded field value required')
        # Synthetic marker input is ASCII. Original Unicode profile is restored by
        # authenticated JSON cleanup, never lossy adb input text conversion.
        if value and not re.fullmatch(r'[A-Za-z0-9 .,;:_/+-]+', value):
            raise ProbeFailure('UI input must be a declared safe nonempty ASCII marker')
        nodes = self.snapshot()
        ordered = self.article_editor_fields(nodes)
        editor_index = {'Tiêu đề bài viết': 0, 'Nội dung bài viết': 1}.get(name)
        labeled = any(name in texts(node) for node in nodes
            if node.get('class') == 'android.widget.EditText')
        if not labeled and editor_index is not None and ordered is not None:
            # Re-resolve immediately before tapping; no stale bounds from a prior
            # field or snapshot. Exactly two fields and exact editor title remain
            # required for both title and body.
            current = self.article_editor_fields(self.snapshot())
            if current is None:
                raise ProbeFailure('Known article editor changed before field focus')
            tap(current[editor_index])
            self.ui_taps += 1
        else:
            try:
                self.click(name, scroll=True, field=True)
            except ProbeFailure:
                if not fallback or not old:
                    raise
                self.click(old, scroll=True, field=True)
        if old:
            # Move to the final line, then delete bounded existing text. Never run
            # invalid `adb input text ''`, and never use clipboard/secret injection.
            downs = ['20'] * min(502, old.count('\n') + 2)
            deletes = ['67'] * min(1008, len(old) * 2 + 4)
            adb('shell', 'input', 'keyevent', *downs, '123', *deletes, timeout=25)
        if value:
            adb('shell', 'input', 'text', shlex.quote(value.replace(' ', '%s')))
        # A hardware keyboard can leave no soft IME open. Back in that state
        # would pop the form, so check the actual input-method state first.
        ime = adb('shell', 'dumpsys', 'input_method').decode('utf-8', 'replace')
        if re.search(r'(?:mInputShown|mIsInputViewShown|isInputViewShown)=true', ime):
            adb('shell', 'input', 'keyevent', '4')

    def workspace(self):
        self.wait_ui(lambda nodes: self.has(nodes, 'Tài khoản') and self.has(nodes, 'Tin nhắn'))

    def prepare(self):
        if self.args.phase == 'learning' and self.role != 'Consumer':
            raise ProbeFailure('Restore an actual Consumer before the Consumer learning phase')
        if self.args.phase == 'publishing' and self.role == 'Admin':
            raise ProbeFailure('Admin does not publish owner articles')
        self.ui_lock_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            fd = os.open(self.ui_lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            raise ProbeFailure('Another UI owner holds the shared serial lock; do not delete it automatically') from None
        os.close(fd)
        self.ui_lock_owned = True
        self.preflight()
        self.load_and_verify_sessions()  # Same exclusive/atomic normal refresh policy.
        self.workspace()
        self.click('Tài khoản', exact=True)
        self.wait_ui(lambda nodes: self.has(nodes, self.profiles[self.role]['displayName']) and self.has(nodes, ROLE_LABEL[self.role]))
        self.observe('existing UI account identity and role match the supplied real session')
        self.persist()

    def choose_document(self, trigger):
        name = self.args.image_document
        if not name or len(name) > 120 or Path(name).name != name or not name.lower().endswith(('.jpg', '.jpeg', '.png')):
            raise ProbeFailure('A pre-staged image document basename is required; driver never pushes files')
        self.click(trigger, scroll=True)
        nodes = self.wait_ui(lambda nodes: any('documentsui' in node.get('package', '') for node in nodes))
        if not self.has(nodes, name):
            for root_label in ('Show roots', 'Show navigation drawer', 'Hiển thị gốc'):
                if self.has(nodes, root_label):
                    self.click(root_label)
                    break
            nodes = self.snapshot()
            if self.has(nodes, 'Downloads'):
                self.click('Downloads', exact=True)
            elif self.has(nodes, 'Tải xuống'):
                self.click('Tải xuống', exact=True)
        self.click(name, scroll=True)
        self.wait_ui(lambda nodes: not any('documentsui' in node.get('package', '') for node in nodes))
        self.observe('real DocumentsUI selected the declared pre-staged image')

    def open_article_reader(self, lane):
        self.click('Cộng đồng' if self.role == 'Consumer' and lane == 'Community' else
                   ('Học về xoài' if self.role == 'Consumer' else 'Kiến thức'), exact=True)
        if not (self.role == 'Consumer' and lane == 'Community'):
            self.click('Đọc bài chuyên môn về xoài' if lane == 'Professional' else 'Đọc chia sẻ cộng đồng', scroll=True)

    def publishing(self):
        self.stage = 'publishing_form'
        lane = 'Community' if self.role == 'Consumer' else 'Professional'
        branch = None
        if lane == 'Professional':
            branches = self.request(self.role, '/api/v1/branches/mine?limit=50')['items']
            branch = next((row for row in branches if row['status'] == 'Approved'), None)
            if branch is None:
                raise ProbeFailure('An existing owned Approved branch is required; no branch/approval is invented')
        title = self.marker + ' mango article'
        body = self.marker + ' synthetic mango observation for UI verification. Not food safety or a trade offer.'
        self.click('Viết bài cộng đồng' if lane == 'Community' else 'Viết bài chuyên môn')
        self.wait_ui(lambda nodes: self.article_editor_fields(nodes) is not None)
        if branch is not None:
            self.click('Cơ sở đã duyệt', scroll=True)
            self.click(branch['name'], scroll=True)
        self.set_field('Tiêu đề bài viết', title)
        self.set_field('Nội dung bài viết', body)
        self.choose_document('Chọn ảnh bài viết')
        self.wait_ui(lambda nodes: self.has(nodes, 'Bỏ ảnh bài viết'))
        self.click('Gửi xét duyệt', scroll=True)
        self.workspace()
        mine = self.request(self.role, '/api/v1/articles/mine?limit=50&lane=' + lane)['items']
        article = next((row for row in mine if row.get('title') == title), None)
        self.check('own APK submission persisted exact title/body/lane/image and AwaitingReview', article is not None and
            article.get('body') == body and article.get('audienceLane') == lane and bool(article.get('image')) and article.get('status') == 'AwaitingReview')
        self.created_article = article
        self.persist()
        self.observe('article with a real chosen image submitted through APK and confirmed AwaitingReview')
        self.stage = 'counterparty_admin_publish'
        article = self.request('Admin', f'/api/v1/admin/articles/{article["id"]}/review', {
            'status': 'Published', 'reason': 'DEMO QA26 synthetic UI fixture only.', 'expectedRevision': article['revision']})
        self.created_article = article
        self.persist()
        self.remote('real Admin HTTP published only this run article; not Admin APK proof')
        self.stage = 'read_published_article'
        self.open_article_reader(lane)
        self.click(title, scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, body))
        self.click('Phóng to ảnh', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Ảnh bài viết') and not self.has(nodes, 'Không mở được ảnh'))
        self.shot('published-article-image-zoom')
        self.back()
        self.wait_ui(lambda nodes: self.has(nodes, title))
        self.observe('owner APK reads published body/image and opens image zoom')
        if self.args.delete_owned_article:
            self.stage = 'delete_only_this_run_article'
            self.click('Xóa bài viết', scroll=True)
            self.click('Xác nhận xóa')
            self.wait_ui(lambda nodes: not self.has(nodes, 'Xác nhận xóa'))
            self.request(self.role, '/api/v1/articles/' + article['id'], expected=404)
            self.article_deleted = True
            self.observe('owner confirmed UI deletion of only this run article; API detail404')

    def learning(self):
        self.stage = 'consumer_learning'
        content = self.request(self.role, '/api/v1/learning/mango')
        sections = content.get('sections', [])
        if not sections:
            raise ProbeFailure('Actual server learning sections are required')
        self.click('Học về xoài', exact=True)
        counter = 'mục đã đọc trong lần mở này'
        self.click(counter, scroll=True)
        def read_count(nodes):
            for node in nodes:
                found = re.search(r'(\d+)/(\d+) mục đã đọc trong lần mở này', texts(node))
                if found:
                    return int(found.group(1)), int(found.group(2))
            raise ProbeFailure('Actual read-progress counter is not visible')
        before_count, total = read_count(self.snapshot())
        first = '1. ' + sections[0]['title']
        self.click(first, scroll=True)
        nodes = self.snapshot()
        if not self.has(nodes, 'Tôi đã đọc và hiểu mục này'):
            self.click(first, scroll=True)
        nodes = self.snapshot()
        checked = next((node.get('checked') for node in nodes if
            'Tôi đã đọc và hiểu mục này' in texts(node) and node.get('checked') in ('true', 'false')), None)
        if checked is None:
            raise ProbeFailure('Actual lesson checkbox state is unavailable')
        self.click('Tôi đã đọc và hiểu mục này', scroll=True)
        self.wait_ui(lambda nodes: any('Tôi đã đọc và hiểu mục này' in texts(node) and
            node.get('checked') == ('false' if checked == 'true' else 'true') for node in nodes))
        self.click(counter, scroll=True, direction='down')
        after_count, after_total = read_count(self.snapshot())
        self.check('actual lesson read counter changes with the checkbox', total == after_total == len(sections) and
            after_count == before_count + (-1 if checked == 'true' else 1))
        self.observe('Consumer toggled a real lesson checkbox and its visible read counter changed')
        self.click('Tự kiểm tra cách hiểu', scroll=True)
        self.click('Quả chắc chắn đã hư.', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Hãy đọc lại học liệu.'))
        self.click('Chưa đủ tin cậy để gán giai đoạn.', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Đúng về cách hiểu.'))
        self.observe('Consumer quiz changed from incorrect feedback to correct source-bound feedback')
        self.shot('consumer-learning-quiz')

    def normal_photos(self):
        self.stage = 'normal_direct_photo'
        peer_role = self.args.peer_role or ('Trader' if self.role == 'Producer' else 'Producer')
        if peer_role == self.role:
            raise ProbeFailure('Photo counterparty must be a different real supplied role')
        peer = self.profiles[peer_role]
        self.click('Tin nhắn', exact=True)
        self.click('Tin nhắn mới')
        self.click(peer['displayName'], scroll=True, exclude_profile=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Gửi tin nhắn'))
        direct = self.request(self.role, '/api/v1/conversations/direct', {'userId': peer['id']}, expected=(200, 201))
        identifier = direct['id']
        before = self.request(self.role, f'/api/v1/conversations/{identifier}/messages?limit=50')['items']
        before_ids = {row['id'] for row in before}
        self.choose_document('Chọn ảnh gửi trong chat thường')
        self.click('Gửi ảnh', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Mở và phóng to Ảnh hội thoại'))
        messages = self.request(self.role, f'/api/v1/conversations/{identifier}/messages?limit=50')['items']
        sent = next((row for row in messages if row['id'] not in before_ids and row.get('senderId') == self.actors[self.role]['id'] and row.get('image')), None)
        self.check('real native picker UI created one new own normal image message', sent is not None)
        image = sent['image']
        _, data, kind = self.exchange(peer_role, f'/api/v1/conversations/{identifier}/images/{image["id"]}', binary=True)
        self.check('real receiver HTTP can read the exact canonical JPEG image bytes', kind == 'image/jpeg' and len(data) == image['sizeBytes'])
        from PIL import Image
        with Image.open(io.BytesIO(data)) as decoded:
            decoded.verify()
        self.remote('counterparty image HTTP read/valid JPEG only; not receiver APK display')
        self.shot('normal-photo-thumbnail')
        self.click('Mở và phóng to Ảnh hội thoại', last=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Ảnh hội thoại') and not self.has(nodes, 'Không mở được ảnh'))
        self.shot('normal-photo-zoom')
        self.back()
        self.wait_ui(lambda nodes: self.has(nodes, 'Mở và phóng to Ảnh hội thoại'))
        self.observe('normal photo sent in APK, inline thumbnail, zoom and return remain visible')

    def groups(self):
        self.stage = 'new_admin_http_group_fixture'
        if self.role == 'Admin':
            raise ProbeFailure('This bounded phase proves member APK actions; Admin creation/close APK remains a separate manual row')
        group = self.request('Admin', '/api/v1/community/groups', {
            'title': self.marker + ' group', 'region': self.profiles[self.role]['region'], 'productCode': 'mango'}, expected=201)
        self.created_group = group
        self.persist()
        self.remote('Admin HTTP created only this run technical group; not Admin APK proof')
        self.click('Tin nhắn', exact=True)
        self.click('Nhóm cộng đồng')
        self.click(group['title'], scroll=True)
        self.click('Tham gia và trò chuyện', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Gửi tin nhắn'))
        detail = self.request(self.role, f'/api/v1/community/groups/{group["id"]}')
        self.check('actual group membership follows UI Join', detail.get('isMember') is True)
        message = self.marker + ' group sender'
        self.set_field('Tin nhắn', message)
        self.click('Gửi tin nhắn')
        self.wait_ui(lambda nodes: self.has(nodes, message))
        history = self.request(self.role, f'/api/v1/conversations/{group["id"]}/messages?limit=50')['items']
        self.check('UI group message persisted with exact real sender', any(row.get('text') == message and row.get('senderId') == self.actors[self.role]['id'] for row in history))
        other = 'Consumer' if self.role != 'Consumer' else 'Producer'
        self.request(other, f'/api/v1/community/groups/{group["id"]}/join', {}, expected=201)
        incoming = self.marker + ' group other sender'
        self.request(other, f'/api/v1/conversations/{group["id"]}/messages', {'text': incoming, 'clientMessageId': uuid.uuid4().hex}, expected=201)
        self.wait_ui(lambda nodes: self.has(nodes, incoming), seconds=15)
        self.observe('member APK joined, sent and automatically received a real counterparty group message')
        self.shot('group-message-received')
        self.request('Admin', f'/api/v1/community/groups/{group["id"]}/close', {})
        self.wait_ui(lambda nodes: self.has(nodes, 'Nhóm đã đóng; chỉ xem lịch sử'), seconds=15)
        self.check('closed group still displays this run message history', self.has(self.snapshot(), incoming))
        self.observe('member APK became read-only after separate Admin HTTP close; history retained')
        self.shot('group-closed-history')
        self.back()
        self.click('Rời nhóm', scroll=True)
        self.request(self.role, f'/api/v1/conversations/{group["id"]}/messages?limit=20', expected=404)
        self.observe('member APK left this run closed group; server messages now404')

    def profile_crud(self):
        self.stage = 'own_optional_profile_edit'
        original = self.request(self.role, '/api/v1/profile')
        self.original_profile = {key: original[key] for key in EDITABLE}
        self.persist()  # Retained before any UI mutation for recovery after process loss.
        self.click('Hồ sơ & quyền riêng tư', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Thông tin cá nhân'))
        self.set_field('Giới thiệu (công khai, tùy chọn)', self.marker, old=original.get('bio') or '', fallback=True)
        self.click('Công khai khu vực', scroll=True)
        self.click('Lưu hồ sơ', scroll=True)
        self.wait_ui(lambda nodes: self.has(nodes, 'Đã lưu hồ sơ và quyền riêng tư.'))
        changed = self.request(self.role, '/api/v1/profile')
        self.check('APK saved exact optional bio and toggled visibility without role/region mutation', changed['bio'] == self.marker and
            changed['showRegion'] is (not original['showRegion']) and changed['role'] == original['role'] and changed['region'] == original['region'])
        other = 'Consumer' if self.role != 'Consumer' else 'Producer'
        public = self.request(other, '/api/v1/profiles/' + self.actors[self.role]['id'])
        self.check('actual other-account public projection follows saved region visibility and never email', 'email' not in public and
            public.get('bio') == self.marker and public.get('region') == (original['region'] if changed['showRegion'] else None))
        self.remote('other-account public privacy projection verified via HTTPS; not other APK profile view')
        self.observe('own APK saved bio and region visibility; reviewed role/region stayed read-only')
        # No own-profile screenshot: private email may still be in the semantics tree.

    def run(self):
        self.prepare()
        {'publishing': self.publishing, 'learning': self.learning,
         'normal-photos': self.normal_photos, 'groups': self.groups,
         'profile-crud': self.profile_crud}[self.args.phase]()
        self.report['status'] = 'PASS'

    def finish(self):
        try:
            # Deliberate bounded cleanup; never relabel HTTP restoration as UI proof.
            self._cleaning = True
            self.deadline = max(self.deadline, time.monotonic() + 30)
            if self.original_profile is not None:
                restored = self.request(self.role, '/api/v1/profile', self.original_profile, method='PUT')
                self.check('all original optional profile fields restored by normal HTTP cleanup', all(restored[key] == value for key, value in self.original_profile.items()))
                self.report['profileCleanup'] = 'HTTP restored original optional fields; no UI-restoration claim'
            if self.created_group is not None:
                group = self.request('Admin', '/api/v1/community/groups/' + self.created_group['id'])
                if group['isOpen']:
                    self.request('Admin', f'/api/v1/community/groups/{group["id"]}/close', {})
                self.report['groupCleanup'] = 'Only this run new group is Closed; labeled history remains'
            self.persist()
        except Exception as error:
            self.report['status'] = 'FAIL'
            self.report['cleanupErrorType'] = type(error).__name__
        finally:
            try:
                super().finish()
            finally:
                if self.ui_lock_owned:
                    self.ui_lock_path.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True)
    parser.add_argument('--role', choices=tuple(ROLE_LABEL), default='Producer', help='Already restored real app identity; never performs login or role switching')
    parser.add_argument('--version-code', type=int, choices=(6012, 6013), default=6012)
    parser.add_argument('--phase', choices=('publishing', 'learning', 'normal-photos', 'groups', 'profile-crud'), required=True)
    parser.add_argument('--peer-role', choices=tuple(ROLE_LABEL))
    parser.add_argument('--image-document', help='Existing public technical fixture basename in DocumentsUI, not a local/remote path')
    parser.add_argument('--delete-owned-article', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run', action='store_true', required=True, help='Root confirms shared VM lease, restored identity and exclusive UI/session-file ownership')
    args = parser.parse_args(argv)
    folder = args.output.resolve()
    allowed = (CLIENT / 'verification/2.6').resolve()
    if not folder.is_relative_to(allowed) or folder == allowed or folder.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'choose_new_output_directory_under_verification_2_6'}))
        return 2
    folder.mkdir(parents=True, exist_ok=False)
    probe = DemoActions(args, folder)
    try:
        probe.run()
    except Exception as error:
        probe.report.update(status='FAIL', failedStage=probe.stage, errorType=type(error).__name__)
    finally:
        try:
            probe.finish()
        except Exception as error:
            probe.report.update(status='FAIL', receiptErrorType=type(error).__name__)
        print(json.dumps({'status': probe.report['status'], 'phase': args.phase, 'role': args.role,
            'receipt': str(probe.output), 'scope': 'selected phase only; not all28 demo cases'}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
