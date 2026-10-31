"""SOURCE-ONLY normal APK password/email-OTP helper, split into two operator stages.

Root alone executes on restored emulator5554/APK6012. No HTTP/login API, tokens,
session injection, mail access, installation, launch, role change or OTP invention.
Start request from Workspace (bottom navigation visible) or normal login page.
Operator reads the real email separately, then writes its code to a PRIVATE file.

Private credentials JSON: {"role":"Consumer","email":"...","password":"..."}
Also accepts {"accounts":{"Consumer":{"email":"...","password":"..."},...}}.
Code file: {"code":"six real digits"}; neither value is accepted as a CLI argument.

Project-root CLI, only after Root grants the VM/UI slot:
  server/.tools/ai-venv/Scripts/python.exe -X utf8 -B mobile_client/tool/android_login_otp_26.py \
    request --role Consumer --credentials server/.local/ui-login.json \
    --output mobile_client/verification/2.6/login-consumer-request-NEW --run
  server/.tools/ai-venv/Scripts/python.exe -X utf8 -B mobile_client/tool/android_login_otp_26.py \
    verify --role Consumer --otp-file server/.local/ui-otp.json \
    --request-receipt mobile_client/verification/2.6/login-consumer-request-NEW/receipt.json \
    --output mobile_client/verification/2.6/login-consumer-verify-NEW --run

Password/code are piped to adb shell stdin, not placed in host process arguments or logs.
No authentication-page screenshot or raw XML is saved. One login/verify tap, no resend/retry.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import threading

from android_ui import ADB, adb, tap
from android_messaging_26 import AndroidMessagingAcceptance, CLIENT, SERVER, ProbeFailure, bounds
from android_demo_actions_26 import DemoActions, ROLE_LABEL, texts

SNAPSHOT_LOCK = threading.Lock()


def private_json(path):
    path = path.resolve()
    if not path.is_relative_to((SERVER / '.local').resolve()) or not path.is_file() or path.stat().st_size > 65536:
        raise ProbeFailure('A bounded existing private JSON file under server/.local is required')
    return json.loads(path.read_text(encoding='utf-8-sig'))


class NormalLogin(AndroidMessagingAcceptance):
    click = DemoActions.click

    def __init__(self, args, folder):
        super().__init__(args.credentials or args.otp_file, folder, include_block=False, version_code=args.version_code)
        self.args, self.role = args, args.role
        self.deadline = self.started + 120
        self.ui_lock = SERVER / '.local/android-ui-emulator5554.lock'
        self.owns_ui_lock = False
        self.report.update({
            'scope': 'One actual APK normal password/email-OTP UI stage; real operator mail retrieval separate. No API/token/session injection or role changes.',
            'stage': args.action, 'targetRole': self.role,
            'sessionProvenance': 'Normal app authentication only; no private API session is loaded or injected.',
            'authSecretsLogged': False, 'authScreenshots': False,
        })
        self.stage = args.action

    def snapshot(self):
        with SNAPSHOT_LOCK:
            return super().snapshot()

    @staticmethod
    def has(nodes, text):
        return any(text in texts(node) for node in nodes)

    def fields(self, nodes, title, count):
        fields = [node for node in nodes if node.get('class') == 'android.widget.EditText'
            and bounds(node)[2] > bounds(node)[0] and bounds(node)[3] > bounds(node)[1]]
        return sorted(fields, key=lambda node: bounds(node)[1]) if self.has(nodes, title) and len(fields) == count else None

    def input_secret(self, title, count, index, value, limit):
        if not isinstance(value, str) or not value or len(value) > limit or any(ord(char) < 32 or ord(char) > 126 for char in value) or '%s' in value:
            raise ProbeFailure('Private UI input unsupported; use the normal keyboard manually, never alter the credential')
        fields = self.fields(self.snapshot(), title, count)
        if fields is None:
            raise ProbeFailure('Known authentication page and exact field count are required')
        field = fields[index]
        tap(field)
        self.ui_taps += 1
        # Source-known login fields are single-line; remove any autofilled value.
        previous = field.get('text', '')
        if previous:
            adb('shell', 'input', 'keyevent', '123', *(['67'] * (limit + 2)))
        script = 'input text ' + shlex.quote(value.replace(' ', '%s')) + '\n'
        subprocess.run([str(ADB), '-s', 'emulator-5554', 'shell'], input=script.encode('utf-8'),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=15)
        ime = adb('shell', 'dumpsys', 'input_method').decode('utf-8', 'replace')
        if re.search(r'(?:mInputShown|mIsInputViewShown|isInputViewShown)=true', ime):
            adb('shell', 'input', 'keyevent', '4')

    def request(self):
        document = private_json(self.args.credentials)
        if not isinstance(document, dict):
            raise ProbeFailure('Credentials must be one private object or an accounts-by-role object')
        record = document.get('accounts', document)
        if isinstance(record, dict) and self.role in record:
            record = record[self.role]
        if not isinstance(record, dict) or record.get('role', self.role) != self.role:
            raise ProbeFailure('Private credential role does not match the requested normal UI login')
        email, password = record.get('email', record.get('Email')), record.get('password', record.get('Password'))
        if not isinstance(email, str) or not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email):
            raise ProbeFailure('Private credential email is invalid')
        try:
            nodes = self.snapshot()
            if not self.has(nodes, 'Chào mừng trở lại'):
                if not self.has(nodes, 'Tài khoản') or not self.has(nodes, 'Tin nhắn'):
                    raise ProbeFailure('Return normally to Workspace before requesting logout/login')
                self.click('Tài khoản', exact=True)
                self.click('Đăng xuất', scroll=True, exact=True)
            self.wait_ui(lambda nodes: self.fields(nodes, 'Chào mừng trở lại', 2) is not None)
            self.input_secret('Chào mừng trở lại', 2, 0, email, 254)
            self.input_secret('Chào mừng trở lại', 2, 1, password, 128)
            self.click('Đăng nhập', scroll=True, exact=True)
            self.wait_ui(lambda nodes: self.fields(nodes, 'Xác thực email', 1) is not None, seconds=25)
            self.check('normal password UI requested a real email challenge with one OTP field', True)
            self.report.update(status='OTP_REQUESTED_UI', requestUtc=dt.datetime.now(dt.timezone.utc).isoformat(),
                nextStep='Operator obtains the actual email code and supplies it through a private JSON file; no resend or verify was attempted here.')
        finally:
            password = email = None
            record = document = None

    def verify(self):
        receipt_path = self.args.request_receipt.resolve()
        if not receipt_path.is_relative_to((CLIENT / 'verification/2.6').resolve()) or not receipt_path.is_file():
            raise ProbeFailure('Existing public request-stage receipt is required')
        request = json.loads(receipt_path.read_text(encoding='utf-8'))
        timestamp = dt.datetime.fromisoformat(request['requestUtc'])
        age = (dt.datetime.now(dt.timezone.utc) - timestamp).total_seconds()
        if request.get('status') != 'OTP_REQUESTED_UI' or request.get('targetRole') != self.role or not 0 <= age < 600:
            raise ProbeFailure('Request receipt role/status/ten-minute window mismatch')
        document = private_json(self.args.otp_file)
        code = document.get('code') if isinstance(document, dict) else None
        if not isinstance(code, str) or not re.fullmatch(r'\d{6}', code):
            raise ProbeFailure('Private code file must contain exactly six real digits')
        try:
            self.wait_ui(lambda nodes: self.fields(nodes, 'Xác thực email', 1) is not None)
            self.input_secret('Xác thực email', 1, 0, code, 6)
            self.click('Xác thực và đăng nhập', scroll=True, exact=True)
            self.wait_ui(lambda nodes: self.has(nodes, 'Tin nhắn') and self.has(nodes, 'Tài khoản'), seconds=25)
            self.click('Tài khoản', exact=True)
            self.wait_ui(lambda nodes: self.has(nodes, ROLE_LABEL[self.role]))
            self.check('normal password and real email code reached the expected server-derived role UI', True)
            self.click('Xét duyệt' if self.role == 'Admin' else 'Học về xoài' if self.role == 'Consumer' else 'AI xoài', exact=True)
            self.report['status'] = 'PASS_UI_PASSWORD_EMAIL_OTP'
        finally:
            code = document = None

    def run(self):
        self.ui_lock.parent.mkdir(parents=True, exist_ok=True)
        try:
            fd = os.open(self.ui_lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            raise ProbeFailure('Shared UI owner lock exists; never remove it automatically') from None
        os.close(fd)
        self.owns_ui_lock = True
        self.preflight()
        self.request() if self.args.action == 'request' else self.verify()

    def finish(self):
        try:
            super().finish()
        finally:
            if self.owns_ui_lock:
                self.ui_lock.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('request', 'verify'))
    parser.add_argument('--role', choices=tuple(ROLE_LABEL), required=True)
    parser.add_argument('--version-code', type=int, choices=(6012, 6013), default=6012)
    parser.add_argument('--credentials', type=Path)
    parser.add_argument('--otp-file', type=Path)
    parser.add_argument('--request-receipt', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run', action='store_true', required=True)
    args = parser.parse_args(argv)
    if (args.action == 'request' and args.credentials is None) or (args.action == 'verify' and (args.otp_file is None or args.request_receipt is None)):
        parser.error('request needs --credentials; verify needs --otp-file and --request-receipt')
    folder = args.output.resolve()
    allowed = (CLIENT / 'verification/2.6').resolve()
    if not folder.is_relative_to(allowed) or folder == allowed or folder.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'choose_new_receipt_directory'}))
        return 2
    folder.mkdir(parents=True, exist_ok=False)
    probe = NormalLogin(args, folder)
    try:
        probe.run()
    except Exception as error:
        probe.report.update(status='FAIL', failedStage=probe.stage, errorType=type(error).__name__)
    finally:
        try:
            probe.finish()
        except Exception as error:
            probe.report.update(status='FAIL', receiptErrorType=type(error).__name__)
        print(json.dumps({'status': probe.report['status'], 'role': args.role, 'stage': args.action, 'receipt': str(probe.output)}))
    return 0 if probe.report['status'] in ('OTP_REQUESTED_UI', 'PASS_UI_PASSWORD_EMAIL_OTP') else 1


if __name__ == '__main__':
    raise SystemExit(main())
