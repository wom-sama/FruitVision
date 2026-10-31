"""Offline validation only; no session reads, network, decoder or inference."""
import ast
import copy
from pathlib import Path
import unittest
from unittest.mock import patch

from ai_acceptance_26 import AiAcceptance, LABELS, MODEL_SHA256, ProbeFailure, VIDEO_FRAMES, validate_video
from mango_image_smoke_24 import SmokeFailure


class AiAcceptanceContractTests(unittest.TestCase):
    def result(self):
        return {'schema': 'fruitvision-ai-v1', 'scope': 'predicted-mango-only', 'modelSha256': MODEL_SHA256,
            'framesProcessed': VIDEO_FRAMES, 'maxVisibleCount': 1, 'confirmedTrackCount': 1, 'lineCrossingCount': 0,
            'gradeCounts': {LABELS[-1]: 0, LABELS[0]: 1, LABELS[1]: 0},
            'objects': [{'trackId': 1, 'box': [.1, .2, .5, .7], 'score': .8, 'fruitLabel': 'Xoài (dự đoán)', 'stageCode': 0, 'stageLabel': LABELS[0]}],
            'processingSeconds': .1, 'limitations': ['one', 'two', 'three']}

    def test_video_frame_and_confirmed_track_semantics_are_separate(self):
        result = self.result(); validate_video(result)
        wrong = copy.deepcopy(result); wrong['gradeCounts'][LABELS[0]] = VIDEO_FRAMES
        with self.assertRaises(SmokeFailure): validate_video(wrong)
        wrong = copy.deepcopy(result); wrong['framesProcessed'] -= 1
        with self.assertRaises(SmokeFailure): validate_video(wrong)
        wrong = copy.deepcopy(result); wrong['objects'][0]['box'][0] = float('nan')
        with self.assertRaises(SmokeFailure): validate_video(wrong)

    def test_all_workflow_route_expressions_have_explicit_api_version(self):
        source = ast.parse(Path(__file__).with_name('ai_acceptance_26.py').read_text(encoding='utf-8'))
        routes = []
        for node in ast.walk(source):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ('request', 'exchange') and len(node.args) > 1:
                value = node.args[1]
                while isinstance(value, ast.BinOp): value = value.left
                if isinstance(value, ast.JoinedStr): value = value.values[0]
                if isinstance(value, ast.Constant) and isinstance(value.value, str): routes.append(value.value)
        self.assertGreaterEqual(len(routes), 20)
        self.assertTrue(all(route.startswith('/api/v1/') for route in routes), routes)

    def test_bad_route_never_reaches_http_transport(self):
        probe = object.__new__(AiAcceptance)
        with patch('urllib.request.build_opener') as network:
            with self.assertRaises(ProbeFailure): probe.exchange('Producer', '/ai/jobs')
            network.assert_not_called()


if __name__ == '__main__': unittest.main()
