import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('fallback', Path(__file__).parents[2] / '.github/scripts/arm64_runner_fallback.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class Clock:
    now = 0

    def read(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class API:
    def __init__(self, mode='success'):
        self.mode = mode
        self.cancelled = False
        self.requests = []
        self.observed = False

    def __call__(self, path, method='GET', body=None):
        self.requests.append((path, method, body))
        if path.endswith('/dispatches'):
            if self.mode == 'denied':
                raise RuntimeError('HTTP 403')
            return {'workflow_run_id': 42}
        if '/runs?event=' in path:
            return {'workflow_runs': []}
        if path.endswith('/cancel'):
            self.cancelled = True
            return None
        if path.endswith('/jobs?per_page=100'):
            return {'jobs': [{'name': 'android-arm64-worker', 'runner_name': '' if self.mode == 'queued' else 'blacksmith'}]}
        if path.endswith('/runs/42'):
            completed = self.cancelled or self.observed
            self.observed = self.mode in ('success', 'compile-error')
            return {'status': 'completed' if completed else 'in_progress',
                    'head_sha': 'moved' if self.mode == 'moved' else 'abc',
                    'conclusion': 'failure' if self.mode == 'compile-error' else 'success',
                    'html_url': 'https://example.test/run/42'}
        raise AssertionError(path)


class FallbackTest(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {
            'CAN_DISPATCH': 'true', 'GITHUB_REPOSITORY': 'owner/repo',
            'GITHUB_RUN_ID': '1', 'GITHUB_RUN_ATTEMPT': '2',
            'WORKER_REF': 'build/test', 'SOURCE_SHA': 'merge-sha',
            'WORKER_WORKFLOW_SHA': 'abc', 'BACKEND_TEST': 'false'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.clock = Clock()

    def run_worker(self, api):
        return m.execute(api, self.clock.sleep, self.clock.read)

    def test_success_returns_artifact_run(self):
        api = API()
        self.assertEqual(self.run_worker(api), 42)
        self.assertFalse(api.cancelled)
        self.assertEqual(api.requests[0][2]['inputs']['source_sha'], 'merge-sha')

    def test_queue_timeout_cancels_before_fallback(self):
        api = API('queued')
        self.assertIsNone(self.run_worker(api))
        self.assertTrue(api.cancelled)
        self.assertGreaterEqual(self.clock.now, 120)

    def test_fork_does_not_dispatch(self):
        os.environ['CAN_DISPATCH'] = 'false'
        api = API()
        self.assertIsNone(self.run_worker(api))
        self.assertEqual(api.requests, [])

    def test_dispatch_denied_uses_github(self):
        self.assertIsNone(self.run_worker(API('denied')))

    def test_compile_failure_is_not_hidden(self):
        with self.assertRaises(m.BuildFailure):
            self.run_worker(API('compile-error'))

    def test_branch_move_cancels_worker(self):
        api = API('moved')
        self.assertIsNone(self.run_worker(api))
        self.assertTrue(api.cancelled)

    def test_ambiguous_dispatch_does_not_start_duplicate_build(self):
        def unknown(path, method='GET', body=None):
            if method == 'POST':
                raise RuntimeError('connection lost after request')
            return {'workflow_runs': []}
        with self.assertRaises(m.BuildFailure):
            self.run_worker(unknown)

    def test_cancellation_must_be_confirmed(self):
        def stuck(path, method='GET', body=None):
            return {'status': 'in_progress'} if method == 'GET' else None
        with self.assertRaises(m.BuildFailure):
            m.cancel(stuck, 'repos/a/b', 42, self.clock.sleep)

    def test_api_error_after_dispatch_does_not_start_duplicate_build(self):
        api = API('queued')
        def broken(path, method='GET', body=None):
            if path.endswith('/jobs?per_page=100'):
                raise RuntimeError('network error')
            return api(path, method, body)
        with self.assertRaises(RuntimeError):
            self.run_worker(broken)
        self.assertTrue(api.cancelled)


if __name__ == '__main__':
    unittest.main()
