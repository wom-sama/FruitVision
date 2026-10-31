"""One authorized QA Consumer registration. Secrets/challenge stay only in server/.local.

No login/OTP verification, main-session access, role assignment or automatic retries.
Root verifies the real email OTP separately before a formal Producer application.
"""
from pathlib import Path
import datetime as dt
import json
import os
import secrets
import urllib.error
import urllib.parse
import urllib.request

from feedback_acceptance_25 import FeedbackAcceptance, ROOT
from verticals_e2e import NoRedirect


def main():
    target = ROOT / '.local/demo31-qa-producer.json'
    if target.exists():
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'private_registration_record_already_exists'})); return 2
    origin = json.loads((ROOT / '.local/tunnel-state.json').read_text(encoding='utf-8-sig'))['publicUrl'].rstrip('/')
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment or parsed.port not in (None, 443):
        raise ValueError('Invalid owned HTTPS origin')
    record = {'schemaVersion': 1, 'purpose': 'Root-authorized disposable QA Consumer; formal Producer approval only after real OTP',
        'baseURL': origin, 'email': os.environ['FRUITVISION_QA_REGISTRATION_EMAIL'],
        'displayName': 'DEMO QA31 encrypted Producer', 'password': 'Fv9!' + secrets.token_urlsafe(36),
        'countryCode': 'VN', 'provinceCode': '79', 'createdUtc': dt.datetime.now(dt.timezone.utc).isoformat(),
        'status': 'registration_pending_single_attempt'}
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as private:
        json.dump(record, private, ensure_ascii=False, indent=2)
    status = None
    try:
        body = json.dumps({key: record[key] for key in ('displayName', 'email', 'password', 'countryCode', 'provinceCode')}, ensure_ascii=False).encode('utf-8')
        request = urllib.request.Request(origin + '/api/v1/auth/register', data=body,
            headers={'Content-Type': 'application/json', 'Accept': 'application/json'}, method='POST')
        try:
            response = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=25)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            status = response.status; raw = response.read(32769)
            if len(raw) > 32768: raise ValueError('Registration response exceeded cap')
            received = json.loads(raw)
        record['httpStatus'] = status
        record['registrationResponse'] = received
        if status == 201 and received.get('requiresTwoFactor') is True and received.get('method') == 'email' and received.get('user', {}).get('role') == 'Consumer':
            record.update({'status': 'awaiting_real_email_otp', 'challengeToken': received['challengeToken'], 'user': received['user'],
                'challengeExpiresUtc': (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=received.get('expiresIn', 600))).isoformat()})
        else:
            record['status'] = 'registration_not_completed_do_not_retry_blindly'
    except Exception as error:
        record['status'] = 'registration_uncertain_do_not_retry'; record['errorType'] = type(error).__name__
    FeedbackAcceptance.write_private(target, record)
    print(json.dumps({'status': record['status'], 'httpStatus': status, 'httpRequests': 1,
        'privateRecord': '.local/demo31-qa-producer.json', 'otpVerified': False, 'roleGranted': False, 'originalSessionsTouched': False}))
    return 0 if record['status'] == 'awaiting_real_email_otp' else 1


if __name__ == '__main__':
    raise SystemExit(main())
