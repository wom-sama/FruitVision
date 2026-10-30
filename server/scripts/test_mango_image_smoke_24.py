"""Offline protocol tests only; these dictionaries are not inference evidence."""
import copy
import unittest

import mango_image_smoke_24 as smoke


def result():
    return {'schema': 'fruitvision-ai-v1', 'scope': 'predicted-mango-only', 'modelSha256': smoke.MODEL_SHA256,
        'framesProcessed': 1, 'maxVisibleCount': 1, 'confirmedTrackCount': 0, 'lineCrossingCount': 0,
        'processingSeconds': .1, 'summary': 'Phát hiện xoài dự đoán đạt ngưỡng',
        'gradeCounts': {'Xanh / chưa chín': 1, 'Chín': 0, 'Chưa xác định': 0},
        'objects': [{'trackId': None, 'fruitLabel': 'Xoài (dự đoán)', 'stageCode': 0,
                     'stageLabel': 'Xanh / chưa chín', 'score': .8, 'box': [.1, .2, .4, .5]}],
        'limitations': ['Offline synthetic protocol fixture', 'Not model accuracy evidence', 'Not an actual API response']}


class SmokeProtocolTests(unittest.TestCase):
    def test_only_current_owned_https_base_without_redirect_target_is_allowed(self):
        owned = 'https://owned-demo.example.com'
        self.assertEqual(smoke.validate_base(owned, owned), owned)
        for base in ('http://owned-demo.example.com', 'https://user:secret@owned-demo.example.com',
                     owned + '/api', owned + '?token=x', owned + ':444', 'https://127.0.0.1',
                     'https://another-demo.example.com'):
            with self.assertRaises(smoke.SmokeFailure): smoke.validate_base(base, owned)

    def test_mango_result_rejects_legacy_scope_wrong_hash_unmapped_labels_and_invalid_numbers(self):
        smoke.validate_result(result())
        values = []
        for field, value in (('scope', None), ('modelSha256', '0' * 64), ('maxVisibleCount', 2)):
            changed = result(); changed[field] = value; values.append(changed)
        for field, value in (('stageCode', 4), ('fruitLabel', 'Quả'), ('score', float('nan')), ('box', [0, 0, 2, 1])):
            changed = result(); changed['objects'][0][field] = value; values.append(changed)
        changed = result(); changed['gradeCounts']['Chín'] = 1; values.append(changed)
        for changed in values:
            with self.assertRaises(smoke.SmokeFailure): smoke.validate_result(changed)

    def test_empty_result_requires_decline_message_instead_of_absence_claim(self):
        empty = result(); empty['objects'] = []; empty['maxVisibleCount'] = 0
        empty['gradeCounts']['Xanh / chưa chín'] = 0; empty['summary'] = 'Không phát hiện xoài đạt ngưỡng'
        smoke.validate_result(empty)
        wrong = copy.deepcopy(empty); wrong['summary'] = 'Không có xoài'
        with self.assertRaises(smoke.SmokeFailure): smoke.validate_result(wrong)


if __name__ == '__main__':
    unittest.main()
