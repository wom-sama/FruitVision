"""Offline route-contract checks; never read sessions or open HTTP/WSS."""
import ast
from pathlib import Path
import unittest
from unittest.mock import patch

from messaging_acceptance_26 import MessagingAcceptance, FeedbackAcceptance, ProbeFailure


class MessagingRouteTests(unittest.TestCase):
    def test_all_workflow_routes_explicitly_include_api_version(self):
        source = ast.parse(Path(__file__).with_name('messaging_acceptance_26.py').read_text(encoding='utf-8'))
        routes = []
        for node in ast.walk(source):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ('request', 'exchange') and len(node.args) >= 2:
                value = node.args[1]
                if isinstance(value, ast.JoinedStr): value = value.values[0]
                if isinstance(value, ast.Constant) and isinstance(value.value, str): routes.append(value.value)
        self.assertGreaterEqual(len(routes), 15)
        self.assertTrue(all(route.startswith('/api/v1/') for route in routes), routes)

    def test_real_helper_methods_pass_exact_routes_to_fake_transport(self):
        probe = object.__new__(MessagingAcceptance)
        probe.request_count = 0; probe.run_id = 'offline'; probe.actors = {'Consumer': {'id': 'consumer'}}
        probe.own = lambda *args: None
        probe.check = lambda name, value: self.assertTrue(value, name)
        recorded = []

        def fake_exchange(_self, role, path, *args, **kwargs):
            recorded.append((role, path))
            if '/messages' in path:
                result = {'id': 'message', 'conversationId': 'thread', 'senderId': 'consumer', 'text': kwargs['data']['text']}
            elif '/read' in path: result = {'id': 'thread', 'unreadCount': 0}
            else: result = {'items': [], 'summary': {'unreadTotal': 0, 'unreadConversations': 0}}
            return 200, result, 'application/json'

        with patch.object(FeedbackAcceptance, 'exchange', new=fake_exchange):
            probe.inbox('Producer'); probe.message('thread', 'A1'); probe.ack('thread', 'message', 0)
        self.assertEqual(recorded, [('Producer', '/api/v1/conversations?limit=50'),
            ('Consumer', '/api/v1/conversations/thread/messages'), ('Producer', '/api/v1/conversations/thread/read')])

    def test_unversioned_route_fails_before_transport(self):
        probe = object.__new__(MessagingAcceptance); probe.request_count = 0
        with patch.object(FeedbackAcceptance, 'exchange') as transport:
            with self.assertRaises(ProbeFailure): probe.exchange('Producer', '/conversations')
            transport.assert_not_called()


if __name__ == '__main__': unittest.main()
