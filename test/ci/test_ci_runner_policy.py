import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]


class RunnerPolicyTest(unittest.TestCase):
    def test_workflows_use_github_hosted_runners(self):
        """Require explicit GitHub-hosted runners in every workflow."""
        workflows = ROOT / '.github/workflows'
        for path in [*workflows.glob('*.yaml'), *workflows.glob('*.yml')]:
            content = path.read_text()
            runners = re.findall(r'^    runs-on:[ \t]*([^\n]*)$', content, re.MULTILINE)
            self.assertTrue(runners, str(path))
            self.assertTrue(all(value.strip() == 'ubuntu-latest' for value in runners), str(path))
            self.assertNotIn('blacksmith', content.lower(), str(path))

    def test_sdkmanager_success_is_not_overridden_by_yes_sigpipe(self):
        # Composite actions explicitly enable pipefail. A consumer that exits
        # after one accepted answer must retain its successful exit code.
        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c',
                                 'sdkmanager() { read -r answer; test "$answer" = y; }; sdkmanager < <(yes)'],
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        action = (ROOT / '.github/actions/build-arm64-smoke/action.yaml').read_text()
        self.assertIn('< <(yes)', action)
        self.assertNotIn('yes | sdkmanager', action)


if __name__ == '__main__':
    unittest.main()
