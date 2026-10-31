"""Root-granted formal role workflow for the single separately OTP-verified QA account.

No registration, OTP generation, SQL, direct role assignment, main-user promotion or key reset.
All credentials/proof references remain private. Run only after Root verifies the real OTP.
"""
import json

from feedback_acceptance_25 import FeedbackAcceptance, ROOT
from verticals_e2e import ProbeFailure


def main():
    path = ROOT / '.local/demo31-qa-producer.json'
    original = path.read_bytes(); record = json.loads(original.decode('utf-8-sig'))
    if record.get('status') != 'otp_verified' or record.get('roleApplication') or record.get('workflowErrorType'):
        print(json.dumps({'status': 'NOT_RUN', 'reason': 'requires_verified_owned_consumer_without_prior_application'})); return 2
    probe = FeedbackAcceptance(ROOT / '.local/2.4-real-sessions.json', ROOT / '.local/unused-qa31.json')
    def save():
        nonlocal original
        original = FeedbackAcceptance.write_private(path, record, expected_bytes=original)
    try:
        probe.load_and_verify_sessions()
        if record['baseURL'] != probe.base or record['user']['id'] in {x['id'] for x in probe.actors.values()}:
            raise ProbeFailure('Owned QA must use current origin and differ from all four main users')
        probe.tokens['OwnedQA'] = record['accessToken']
        qa = probe.request('OwnedQA', '/api/v1/auth/me')
        probe.check('new owned Consumer is active approved and genuinely email verified', qa['id'] == record['user']['id'] and qa['role'] == 'Consumer' and qa['emailConfirmed'] and qa['isActive'] and qa['approvalStatus'] == 'Approved')
        existing = probe.request('OwnedQA', '/api/v1/role-applications?limit=20')
        probe.check('fresh owned QA has no prior application', not existing['items'] and not existing.get('next'))
        app = probe.request('OwnedQA', '/api/v1/role-applications', {'requestedRole': 'Producer'}, expected=201)
        record['roleApplication'] = app; record['status'] = 'owned_producer_application_draft'; save()
        route = '/api/v1/role-applications/' + app['id']
        app = probe.request('OwnedQA', route, {'organisationName': 'DEMO QA31 synthetic encrypted Producer',
            'address': 'DEMO QA31 synthetic technical test premises, not verified business evidence', 'countryCode': 'VN', 'provinceCode': '79',
            'phone': '+84900000000', 'products': ['mango'], 'cultivatedAreaHa': 1.25, 'expectedRevision': app['revision']}, method='PUT')
        jpeg = probe.fixture_jpeg('qa31-owned-producer-' + probe.run_id)
        _, app, _ = probe.exchange('OwnedQA', route + f'/evidence?category=ProductionEvidence&expectedRevision={app["revision"]}', raw=jpeg, content_type='image/jpeg', expected=201)
        app = probe.request('OwnedQA', route + '/submit', {'expectedRevision': app['revision']})
        record['roleApplication'] = app; record['status'] = 'owned_producer_application_submitted'; save()
        detail = probe.request('Admin', '/api/v1/admin/role-applications/' + app['id'])
        probe.check('Admin approves only owned new QA submitted Producer application', detail['userId'] == qa['id'] and detail['requestedRole'] == 'Producer' and detail['status'] == 'Submitted' and len(detail['evidence']) == 1 and detail['organisationName'].startswith('DEMO QA31'))
        app = probe.request('Admin', '/api/v1/admin/role-applications/' + app['id'] + '/review', {'status': 'Approved',
            'reason': 'DEMO QA31 owned synthetic account approved through formal workflow for native encrypted-message QA; not legal or business certification.', 'expectedRevision': detail['revision']})
        record['roleApplication'] = app; record['status'] = 'owned_producer_application_approved'; save()
        status, current, _ = probe.exchange('OwnedQA', '/api/v1/auth/me', expected=(200, 401))
        if status == 401:
            # Use only the real password login protocol. A new mail challenge stays private
            # for Root; never manufacture a fresh strong session or verify OTP here.
            login = probe.request(None, '/api/v1/auth/login', {'email': record['email'], 'password': record['password']})
            record['normalLoginResponse'] = login
            if login.get('accessToken'):
                record.update({k: login[k] for k in ('accessToken', 'refreshToken', 'user')})
            record['status'] = 'approved_needs_root_normal_login_verification'; save()
            print(json.dumps({'status': record['status'], 'httpRequests': probe.request_count, 'mainUsersUntouched': True, 'secretDevicesInspected': False})); return 1
        probe.check('owned QA is now Producer through real approval', current['id'] == qa['id'] and current['role'] == 'Producer')
        devices = probe.request('OwnedQA', '/api/v1/secret/devices')['items']
        probe.check('new owned QA has zero prior active secret devices', not any(x.get('revokedAt') is None for x in devices))
        record['user'] = current; record['status'] = 'producer_approved_ready_for_native_key_enrollment'; record['activeSecretDevicesBeforeNativeEnrollment'] = 0; save()
        print(json.dumps({'status': record['status'], 'httpRequests': probe.request_count, 'role': 'Producer', 'activeSecretDevices': 0,
            'mainUsersUntouched': True, 'keysRegisteredOrReset': False, 'privateRecord': '.local/demo31-qa-producer.json'})); return 0
    except Exception as error:
        record['workflowErrorType'] = type(error).__name__
        save_error = None
        try: save()
        except Exception as persistence: save_error = type(persistence).__name__
        print(json.dumps({'status': 'PARTIAL_STOP_NO_RETRY', 'errorType': type(error).__name__, 'privateSaveErrorType': save_error, 'httpRequests': probe.request_count, 'mainUsersUntouched': True})); return 1
    finally:
        probe.tokens.clear(); probe.profiles.clear(); probe.session_document.clear(); probe.session_bytes = None
        if probe.session_lock is not None: probe.session_lock.unlink(missing_ok=True)


if __name__ == '__main__':
    raise SystemExit(main())
