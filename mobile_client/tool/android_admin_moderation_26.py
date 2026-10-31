"""SOURCE-ONLY bounded Admin APK reviews of exactly the three supplied QA records.

Root must restore a real Admin through normal password/email OTP, return to Workspace,
grant the existing emulator5554 slot and ensure no other UI/session-file driver runs.
Only server/.local/demo31-admin-pending.json is accepted. That file is never overwritten.
No new records, HTTP reviews, role grants, retry/replay, secret keys, mail or AI calls.
Admin API is read-only here; all three review decisions must be actual APK button actions.

From project root AFTER explicit execution approval:
  server/.tools/ai-venv/Scripts/python.exe -X utf8 -B mobile_client/tool/android_admin_moderation_26.py \
    --sessions server/.local/2.4-real-sessions.json \
    --output mobile_client/verification/2.6/admin-review-NEW --run

--only role|branch|article selects an explicitly remaining case after operator inspection.
Changed state/revision always stops that run before a decision, never silently retries.
"""
from __future__ import annotations

import argparse
import io
import json
from pathlib import Path
import re
import shlex
import time
import uuid

from android_demo_actions_26 import DemoActions, texts
from android_messaging_26 import CLIENT, SERVER, ProbeFailure, adb, bounds, tap, PACKAGE

PENDING = SERVER / '.local/demo31-admin-pending.json'
CASES = {
    'role': ('roleApplication', 'role-applications', 'organisationName', 'Submitted',
             'NeedsInformation', 'Duyệt nâng vai trò', 'Hồ sơ nâng vai trò', 'Yêu cầu bổ sung', 'Cần bổ sung'),
    'branch': ('branch', 'branches', 'name', 'Pending', 'Approved',
               'Duyệt cơ sở', 'Duyệt cơ sở', 'Chấp thuận', 'Đã chấp thuận'),
    'article': ('article', 'articles', 'title', 'AwaitingReview', 'Published',
                'Duyệt bài cộng đồng', 'Duyệt bài cộng đồng', 'Công bố', 'Đã công bố'),
}


class AdminModeration(DemoActions):
    def __init__(self, args, folder):
        args.role, args.phase = 'Admin', 'admin-moderation'
        super().__init__(args, folder)
        self.deadline = self.started + 300
        self.private_output = SERVER / '.local/admin-ui26' / (self.run_id + '.json')
        self.selected = tuple(CASES) if args.only == 'all' else (args.only,)
        self.targets = {}
        self.attempted = set()
        self.report.update({
            'scope': 'One real Admin APK: specified synthetic role application NeedsInformation, specified new branch Approved, specified Community article Published. API reads verify identity/state only; no HTTP review or role grant.',
            'selectedCases': list(self.selected), 'reviewObservations': [],
            'intendedCleanup': 'No cleanup/reversal of decisions. Keep supplied QA records and review audit. Original pending manifest is never changed.',
            'cleanupPolicy': 'Read-only API probes; no automatic review retries or foreign-record mutation.',
        })

    def read_detail(self, kind):
        _, collection, *_ = CASES[kind]
        identifier = self.targets[kind]['id']
        path = f'/api/v1/admin/{collection}/{identifier}' if kind == 'role' else f'/api/v1/{collection}/{identifier}'
        return self.request('Admin', path)

    def bind_targets(self):
        if not PENDING.is_file() or PENDING.stat().st_size > 65536:
            raise ProbeFailure('Existing bounded exact pending manifest is required')
        seed = json.loads(PENDING.read_text(encoding='utf-8-sig'))
        if seed.get('status') != 'READY_FOR_ADMIN_APK' or seed.get('adminReviewsPerformed') != 0 or not str(seed.get('label', '')).startswith('DEMO QA31 ADMIN APK '):
            raise ProbeFailure('Pending manifest is not the unreviewed technical QA seed')
        for role in ('Admin', 'Producer', 'Consumer'):
            if seed['actors'][role]['id'] != self.actors[role]['id']:
                raise ProbeFailure('Supplied sessions do not own the exact manifest actors')
        for kind in self.selected:
            key, collection, name, before, *_ = CASES[kind]
            record = seed['ownedOnly'][key]
            uuid.UUID(record['id'])
            if record.get('status') != before or type(record.get('revision')) is not int or record['revision'] < 1 or not record[name].startswith(seed['label']):
                raise ProbeFailure('Specified record is not the original named unreviewed QA record')
            self.targets[kind] = record
            actual = self.read_detail(kind)
            self.check('specified QA record state revision and exact name match ' + kind,
                actual['id'] == record['id'] and actual['revision'] == record['revision'] and
                actual['status'] == before and actual[name] == record[name])
            if kind == 'role':
                self.check('role application belongs to the preserved Consumer with supplied evidence',
                    actual['userId'] == self.actors['Consumer']['id'] and
                    actual['requestedRole'] == record['requestedRole'] and
                    [e['id'] for e in actual.get('evidence', [])] == [e['id'] for e in record.get('evidence', [])] and bool(actual.get('evidence')))
            elif kind == 'branch':
                self.check('specified new branch belongs to the supplied Producer', (actual.get('owner') or {}).get('id') == self.actors['Producer']['id'])
            else:
                self.check('specified article is the Consumer Community QA article', actual.get('audienceLane') == 'Community' and
                    (actual.get('author') or {}).get('id') == self.actors['Consumer']['id'])
            queue = self.request('Admin', f'/api/v1/admin/{collection}?limit=50&status={before}' + ('&lane=Community' if kind == 'article' else ''))['items']
            matching = [row for row in queue if row.get(name) == record[name]]
            self.check('queue exact name uniquely binds the specified ID ' + kind, len(matching) == 1 and matching[0]['id'] == record['id'])
        self.report['manifestPreflight'] = 'Only selected exact owned IDs/names/revisions verified; original manifest retained'

    def open_proof(self, record):
        evidence = record['evidence'][0]
        if evidence.get('contentType') not in ('image/jpeg', 'image/png'):
            raise ProbeFailure('This bounded proof-view phase requires the supplied synthetic image evidence')
        _, data, media_type = self.exchange('Admin', f'/api/v1/admin/role-applications/{record["id"]}/evidence/{evidence["id"]}', binary=True)
        self.check('exact authorized proof response matches supplied metadata', media_type == evidence['contentType'] and len(data) == evidence['sizeBytes'])
        from PIL import Image
        with Image.open(io.BytesIO(data)) as decoded:
            self.check('supplied proof is a bounded actual encoded image', decoded.width * decoded.height <= 24_000_000)
            decoded.verify()
        self.click('Xem chứng từ', scroll=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            nodes = self.snapshot()
            in_app_title = any(line.strip() == 'Ảnh minh chứng' for node in nodes for line in texts(node).splitlines())
            if in_app_title and not self.has(nodes, 'Không mở được ảnh này.'):
                focus = adb('shell', 'dumpsys', 'window').decode('utf-8', 'replace')
                current = next((line for line in focus.splitlines() if 'mCurrentFocus=' in line), '')
                if PACKAGE not in current:
                    raise ProbeFailure('Proof title is not in the foreground app')
                # Flutter Image can be painted without an ImageView AX node. The
                # authorized bytes were already size/MIME/PIL verified above;
                # retain PNG for Root to confirm pixels, never infer that from AX.
                self.shot('admin-authorized-synthetic-proof-in-app')
                self.report['photoProofNeedsRootVisualReview'] = True
                self.observe('Admin reached exact in-app proof route with verified bytes; PNG awaits Root visual review')
                self.back()
                self.wait_ui(lambda state: self.has(state, 'Hồ sơ nâng vai trò'))
                return
            if any(self.has(nodes, title) for title in ('Open with', 'Mở bằng')):
                option = next((text for text in ('Gallery', 'Thư viện', 'Photos', 'Ảnh') if self.has(nodes, text)), None)
                if option is None:
                    raise ProbeFailure('Operator must select an actual installed image viewer; no viewer is assumed')
                self.click(option)
                current = self.snapshot()
                for choice in ('Just once', 'Chỉ một lần'):
                    if self.has(current, choice):
                        self.click(choice)
                        break
                continue
            chooser = any(self.has(nodes, text) for text in ('Open with', 'Mở bằng', 'Just once', 'Chỉ một lần'))
            viewer = any(any(name in node.get('package', '').lower() for name in ('gallery', 'photos')) for node in nodes)
            image = any(node.get('class') == 'android.widget.ImageView' for node in nodes)
            if viewer and image and not chooser:
                self.shot('admin-authorized-synthetic-proof')
                self.observe('Admin opened the exact supplied private synthetic image proof in the actual OS viewer')
                self.back()
                self.wait_ui(lambda state: self.has(state, 'Hồ sơ nâng vai trò'))
                return
            if self.has(nodes, 'Thiết bị cần ứng dụng xem ảnh hoặc PDF'):
                raise ProbeFailure('No installed proof viewer; no successful display is claimed')
            time.sleep(.3)
        raise ProbeFailure('Authorized proof viewer was not visibly confirmed')

    def reason(self, kind, value):
        # These three bound read-only detail pages contain exactly one editable
        # ReviewActions reason. Empty Flutter hints may not appear in AX.
        expected_heading = CASES[kind][6]
        self.click('Quyết định xét duyệt', scroll=True)
        for _ in range(5):
            nodes = self.snapshot()
            if not self.has(nodes, expected_heading):
                raise ProbeFailure('Specified moderation detail changed before reason input')
            fields = [node for node in nodes if node.get('class') == 'android.widget.EditText' and
                bounds(node)[2] > bounds(node)[0] and bounds(node)[3] > bounds(node)[1]]
            viewport = bounds(nodes[0]) if nodes else [0, 0, 0, 0]
            if len(fields) == 1:
                box = bounds(fields[0])
                center_y = (box[1] + box[3]) / 2
                if viewport[1] <= center_y < viewport[3]:
                    if fields[0].get('text', '').strip() not in ('', 'Lý do xét duyệt'):
                        raise ProbeFailure('Existing reason must be inspected by operator; never append or replace blindly')
                    tap(fields[0])
                    self.ui_taps += 1
                    adb('shell', 'input', 'text', shlex.quote(value.replace(' ', '%s')))
                    ime = adb('shell', 'dumpsys', 'input_method').decode('utf-8', 'replace')
                    if re.search(r'(?:mInputShown|mIsInputViewShown|isInputViewShown)=true', ime):
                        adb('shell', 'input', 'keyevent', '4')
                    return
            width, height = viewport[2], viewport[3]
            adb('shell', 'input', 'swipe', str(width // 2), str(int(height * .76)), str(width // 2), str(int(height * .42)), '250')
            self.ui_swipes += 1
        raise ProbeFailure('The one source-known moderation reason field is not visible')

    def moderate(self, kind):
        record = self.targets[kind]
        _, _, name, before, after, queue_label, _, action, ui_after = CASES[kind]
        self.stage = 'open_exact_' + kind
        self.click('Xét duyệt', exact=True)
        self.click(queue_label, scroll=True, exact=True)
        self.click(record[name], scroll=True, exact=True)
        self.wait_ui(lambda nodes: self.has(nodes, record[name]))
        self.observe('Admin opened only the exact named ' + kind + ' detail')
        if kind == 'role':
            self.stage = 'view_specified_private_proof'
            self.open_proof(record)
        self.stage = 'review_exact_' + kind
        reason = 'DEMO QA31 ADMIN APK ' + kind + '. Technical fixture, no legal verification.'
        self.reason(kind, reason)
        fresh = self.read_detail(kind)
        self.check('specified target remains unchanged immediately before UI review ' + kind,
            fresh['status'] == before and fresh['revision'] == record['revision'])
        if kind in self.attempted:
            raise ProbeFailure('A second review attempt is forbidden')
        self.attempted.add(kind)  # Set before the only button tap; uncertain result is never replayed.
        self.click(action, scroll=True, exact=True)
        changed = None
        for _ in range(4):
            changed = self.read_detail(kind)
            if changed.get('status') == after:
                break
            time.sleep(.4)
        self.check('single APK review committed the exact expected transition ' + kind,
            changed is not None and changed['status'] == after and changed['revision'] == record['revision'] + 1 and changed.get('reviewReason') == reason)
        self.click(ui_after, scroll=True, direction='down')
        self.shot('admin-reviewed-' + kind)
        self.report['reviewObservations'].append({'kind': kind, 'from': before, 'to': after,
            'uiActionObserved': True, 'apiRevisionAdvancedOnce': True})
        self.observe('Admin APK ' + kind + ' decision confirmed in UI and read-only API')
        self.back()
        self.back()
        self.workspace()

    def run(self):
        self.prepare()
        self.bind_targets()  # Every selected target verified before the first review action.
        for kind in self.selected:
            self.moderate(kind)
        consumer = self.request('Consumer', '/api/v1/auth/me')
        self.check('main Consumer remains active Approved Consumer after NeedsInformation',
            consumer['id'] == self.actors['Consumer']['id'] and consumer['role'] == 'Consumer' and
            consumer['isActive'] and consumer['approvalStatus'] == 'Approved')
        self.report['status'] = ('REVIEW_ACTIONS_CONFIRMED_PROOF_VISUAL_REVIEW_REQUIRED'
            if self.report.get('photoProofNeedsRootVisualReview') else 'PASS_SPECIFIED_ADMIN_UI_REVIEWS')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True)
    parser.add_argument('--version-code', type=int, choices=(6012, 6013), default=6012)
    parser.add_argument('--only', choices=('all', 'role', 'branch', 'article'), default='all')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run', action='store_true', required=True)
    args = parser.parse_args(argv)
    folder = args.output.resolve()
    allowed = (CLIENT / 'verification/2.6').resolve()
    if not folder.is_relative_to(allowed) or folder == allowed or folder.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'choose_new_receipt_directory'}))
        return 2
    folder.mkdir(parents=True, exist_ok=False)
    probe = AdminModeration(args, folder)
    try:
        probe.run()
    except Exception as error:
        probe.report.update(status='FAIL', failedStage=probe.stage, errorType=type(error).__name__)
    finally:
        try:
            probe.finish()
        except Exception as error:
            probe.report.update(status='FAIL', receiptErrorType=type(error).__name__)
        print(json.dumps({'status': probe.report['status'], 'receipt': str(probe.output), 'scope': 'specified QA records only; no HTTP review decisions'}))
    return 0 if probe.report['status'] in ('PASS_SPECIFIED_ADMIN_UI_REVIEWS', 'REVIEW_ACTIONS_CONFIRMED_PROOF_VISUAL_REVIEW_REQUIRED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
