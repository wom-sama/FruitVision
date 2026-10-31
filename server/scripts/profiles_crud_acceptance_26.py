"""Bounded public HTTPS acceptance, only supplied QA role sessions and owned fixtures.

Temporarily changes the demo Consumer's optional profile, restores it in finally,
and never removes a preexisting block. No role grant, OTP, keys, SQL or AI calls.
Public receipt contains contracts/statuses, not profile fields or message bodies.
"""
from __future__ import annotations
import argparse, json, uuid
from pathlib import Path
from messaging_acceptance_26 import MessagingAcceptance, ROOT, GUID
from verticals_e2e import ProbeFailure


class ProfilesCrudAcceptance(MessagingAcceptance):
    def __init__(self, sessions, output):
        super().__init__(sessions, output)
        self.private_output = ROOT / '.local/profiles26' / (self.run_id + '.json')
        self.original = None
        self.new_block = False
        self.report.update(scope='Actual public HTTPS profile privacy/block/CRUD with four existing real OTP sessions; no four-device, AI or cryptographic claim.',
                           intendedCleanup='Restore Consumer optional profile, remove only this run new block, soft-delete only newly owned article/branch. Preserve existing accounts, four roles, human applications, history and other blocks.')

    @staticmethod
    def editable(profile):
        return {key: profile[key] for key in ('displayName', 'bio', 'phone', 'gender', 'showGender', 'showPhone', 'showRegion')}

    def run(self):
        self.load_and_verify_sessions()
        profiles = {role: self.request(role, '/api/v1/profile') for role in ('Admin', 'Producer', 'Trader', 'Consumer')}
        consumer, trader = self.actors['Consumer']['id'], self.actors['Trader']['id']
        self.original = self.editable(profiles['Consumer'])
        # Recovery snapshot remains private, even if the network subsequently fails.
        self.write_private(self.private_output.with_name(self.run_id + '-restore.json'), {'consumerId': consumer, 'original': self.original, 'newBlockTarget': trader})
        self.check('all four own profiles preserve current roles and private email', all(profiles[role]['role'] == role and profiles[role].get('email') for role in profiles))
        candidates = self.request('Admin', '/api/v1/admin/admin-candidates?limit=50')['items']
        self.check('Admin candidate projection has only the four intended fields', all(set(item) == {'id', 'displayName', 'email', 'region'} for item in candidates))
        self.request('Consumer', '/api/v1/admin/admin-candidates', expected=403)
        public = self.request('Trader', '/api/v1/profiles/' + consumer)
        self.check('public profile never contains email or legal evidence', not any(key in public for key in ('email', 'roleApplication', 'evidence', 'taxCode', 'businessRegistrationNumber')))
        for role, target in (('Consumer', trader), ('Trader', consumer)):
            existing = self.request(role, '/api/v1/profile/blocked')['items']
            self.check('no preexisting QA pair block will be removed', not any(item['id'] == target for item in existing))

        try:
            changed = {**self.original, 'bio': 'DEMO QA2.6 optional-profile check ' + self.run_id, 'gender': 'Female', 'phone': '+84900000000',
                       'showGender': True, 'showPhone': False, 'showRegion': False}
            self.request('Consumer', '/api/v1/profile', changed, method='PUT')
            public = self.request('Trader', '/api/v1/profiles/' + consumer)
            self.check('individual visibility choices govern actual public projection', public.get('gender') == 'Female' and public.get('phone') is None and public.get('region') is None)
            thread = self.request('Consumer', '/api/v1/conversations/direct', {'userId': trader}, expected=(200, 201))
            conversation = thread['id']
            message = self.request('Consumer', f'/api/v1/conversations/{conversation}/messages',
                                   {'clientMessageId': uuid.uuid4().hex, 'text': 'DEMO QA2.6 before block ' + self.run_id}, expected=201)
            self.own('normalMessages', message)
            self.request('Consumer', f'/api/v1/profiles/{trader}/block', {}, method='PUT')
            self.new_block = True
            self.request('Trader', '/api/v1/profiles/' + consumer, expected=404)
            self.request('Consumer', '/api/v1/profiles/' + trader, expected=404)
            contacts = self.request('Trader', '/api/v1/contacts?limit=50')['items']
            self.check('blocked profile is absent from contacts', not any(item['id'] == consumer for item in contacts))
            self.request('Trader', '/api/v1/conversations/direct', {'userId': consumer}, expected=404)
            self.request('Trader', f'/api/v1/conversations/{conversation}/messages',
                         {'clientMessageId': uuid.uuid4().hex, 'text': 'DEMO QA2.6 blocked attempt ' + self.run_id}, expected=403)
            history = self.request('Trader', f'/api/v1/conversations/{conversation}/messages?limit=50')['items']
            self.check('existing conversation history is retained', any(item['id'] == message['id'] for item in history))
            self.request('Consumer', f'/api/v1/profiles/{trader}/block', method='DELETE', expected=204)
            self.new_block = False
            self.request('Trader', '/api/v1/profiles/' + consumer)

            article = self.request('Consumer', '/api/v1/articles', {'title': 'DEMO QA2.6 CRUD ' + self.run_id,
                'body': 'Synthetic technical mango observations for actual API CRUD verification, not a legal or quality claim.'}, expected=201)
            self.own('articles', article)
            article = self.request('Consumer', '/api/v1/articles/' + article['id'], {'title': 'DEMO QA2.6 revised ' + self.run_id,
                'body': 'Revised synthetic technical information must return to moderation before being public.', 'expectedRevision': article['revision']}, method='PUT')
            self.request('Consumer', f'/api/v1/articles/{article["id"]}?expectedRevision={article["revision"]}', method='DELETE', expected=204)
            self.owned_states[article['id']] = 'Deleted'
            self.request('Consumer', '/api/v1/articles/' + article['id'], expected=404)
            branch = self.request('Producer', '/api/v1/branches/mine?limit=50')['items'][0]
            created = self.request('Producer', '/api/v1/branches', {'name': 'DEMO QA2.6 site ' + self.run_id,
                'countryCode': branch['countryCode'], 'provinceCode': branch['provinceCode'], 'street': '123 technical QA site, not a real business', 'phone': '0900000000'}, expected=201)
            self.own('branches', created)
            self.request('Producer', f'/api/v1/branches/{created["id"]}?expectedRevision={created["revision"]}', method='DELETE', expected=204)
            self.owned_states[created['id']] = 'Deleted'
            self.request('Producer', '/api/v1/branches/' + created['id'], expected=404)
            self.check('existing Consumer role remains unchanged', self.request('Consumer', '/api/v1/auth/me')['role'] == 'Consumer')
            self.report['status'] = 'PASS'
        finally:
            if self.new_block:
                self.request('Consumer', f'/api/v1/profiles/{trader}/block', method='DELETE', expected=204)
                self.new_block = False
            if self.original is not None:
                restored = self.request('Consumer', '/api/v1/profile', self.original, method='PUT')
                self.check('original optional profile and all visibility flags are restored', self.editable(restored) == self.original)
            self.save_ownership()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sessions', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--run', action='store_true', required=True)
    args = parser.parse_args(); output = args.output.resolve()
    if not output.is_relative_to((ROOT / 'docs').resolve()) or output.exists() or output.suffix != '.json':
        raise SystemExit('Choose a new public JSON receipt under server/docs')
    probe = ProfilesCrudAcceptance(args.sessions, output)
    try:
        probe.run()
    except Exception as error:
        probe.report['status'] = 'FAIL'; probe.report['errorType'] = type(error).__name__
        if isinstance(error, ProbeFailure): probe.report['failedStep'] = GUID.sub('{id}', str(error))[:200]
    finally:
        probe.finish()
    print(json.dumps({'status': probe.report['status'], 'httpRequests': probe.request_count, 'checks': len(probe.report['checks']), 'receipt': str(output)}))
    return 0 if probe.report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
