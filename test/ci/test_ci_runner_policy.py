import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]


class RunnerPolicyTest(unittest.TestCase):
    def test_blacksmith_sizes_never_exceed_eight(self):
        found = []
        for path in (ROOT / '.github').rglob('*.yaml'):
            for size in re.findall(r'blacksmith-(\d+)vcpu-', path.read_text()):
                found.append(int(size))
                self.assertLessEqual(int(size), 8, str(path))
        self.assertTrue(found)

    def test_only_control_jobs_directly_use_github(self):
        for path in (ROOT / '.github/workflows').glob('*.yaml'):
            text = path.read_text()
            if path.name in ['select-ci-runner.yaml', 'android-base-verification.yaml']:
                continue
            self.assertNotIn('runs-on: ubuntu-latest', text, str(path))
            self.assertIn('uses: ./.github/workflows/select-ci-runner.yaml', text)

    def test_manual_e2e_defaults_to_shared_runner_policy(self):
        text = (ROOT / '.github/workflows/android-base-verification.yaml').read_text()
        options = text.split('      e2e_runner:', 1)[1].split('      e2e_only:', 1)[0]
        self.assertIn('default: auto', options)
        e2e = text.split('  android-emulator-e2e:', 1)[1]
        selection = next(line for line in e2e.splitlines() if 'runs-on:' in line)
        self.assertIn("inputs.e2e_only", selection)
        self.assertIn("inputs.e2e_runner != 'auto'", selection)
        self.assertIn("vars.BLACKSMITH_DISABLED != 'true'", selection)
        self.assertIn('needs.select-runner.outputs.large', selection)

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
