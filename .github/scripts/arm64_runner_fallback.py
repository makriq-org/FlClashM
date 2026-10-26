#!/usr/bin/env python3
"""Bound Blacksmith queue time; never hide a started build's failure."""
import json
import os
import re
import signal
import subprocess
import time
import uuid


class BuildFailure(RuntimeError):
    pass


def gh(path, method='GET', body=None):
    args = ['gh', 'api', path, '--method', method]
    if body is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=json.dumps(body) if body else None,
                            text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else None


def cancel(api, repo, run_id, sleep=time.sleep):
    """Confirm cancellation before permitting a duplicate local build."""
    api(f'{repo}/actions/runs/{run_id}/cancel', 'POST')
    for _ in range(18):
        if api(f'{repo}/actions/runs/{run_id}')['status'] == 'completed':
            return
        sleep(5)
    raise BuildFailure(f'Cannot confirm cancellation of worker {run_id}')


def execute(api=gh, sleep=time.sleep, clock=time.monotonic):
    if os.environ.get('CAN_DISPATCH') != 'true':
        print('GitHub runner selected by policy (fork PR or explicit override).')
        return None
    repo = 'repos/' + os.environ['GITHUB_REPOSITORY']
    workflow = repo + '/actions/workflows/android-base-verification.yaml'
    key = f"{os.environ['GITHUB_RUN_ID']}-{os.environ['GITHUB_RUN_ATTEMPT']}-{uuid.uuid4().hex[:12]}"
    deadline = clock() + 120
    started_at = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time()-5))
    body = {'ref': os.environ['WORKER_REF'], 'inputs': {
        'arm64_worker': 'true', 'worker_probe': os.environ.get('RUNNER_PROBE', 'false'), 'worker_key': key,
        'source_sha': os.environ['SOURCE_SHA'],
        'worker_deadline': str(int(time.time()) + 120),
        'backend_test': os.environ.get('BACKEND_TEST', 'false')}}
    run_id = None
    try:
        result = api(workflow + '/dispatches', 'POST', body)
        if result:
            run_id = result.get('workflow_run_id')
    except RuntimeError as error:
        # A network failure may have happened after GitHub accepted the request.
        # Find and cancel any accepted worker rather than dispatching twice.
        print(f'Worker dispatch unavailable: {error}')
        if re.search(r'HTTP (403|404|422)\b', str(error)):
            return None
    try:
        while clock() < deadline:
            if run_id is None:
                runs = api(workflow + '/runs?event=workflow_dispatch&per_page=100&created=%3E%3D' + started_at)['workflow_runs']
                matches = [r for r in runs if r['display_title'] == 'ARM64 worker / ' + key]
                if matches:
                    run_id = matches[0]['id']
                else:
                    sleep(5)
                    continue
            run = api(f'{repo}/actions/runs/{run_id}')
            if run['head_sha'] != os.environ['WORKER_WORKFLOW_SHA']:
                cancel(api, repo, run_id, sleep)
                print('Worker branch moved: build original source on GitHub.')
                return None
            jobs = api(f'{repo}/actions/runs/{run_id}/jobs?per_page=100')['jobs']
            worker = next((j for j in jobs if j['name'] == 'android-arm64-worker'), None)
            # The run itself can be in_progress while its Blacksmith job is queued.
            if worker and worker.get('runner_name'):
                break
            if run['status'] == 'completed':
                print('Blacksmith worker could not start; using GitHub.')
                return None
            sleep(5)
        else:
            if run_id is None:
                if os.environ.get('RUNNER_PROBE') == 'true':
                    return None
                raise BuildFailure('Cannot identify dispatched worker; refusing duplicate build')
            cancel(api, repo, run_id, sleep)
            print('Blacksmith did not start within 120s; using GitHub.')
            return None

        # A started compilation must pass. No fallback on code/test errors.
        for _ in range(280):
            run = api(f'{repo}/actions/runs/{run_id}')
            if run['status'] == 'completed':
                if run['conclusion'] != 'success':
                    if os.environ.get('RUNNER_PROBE') == 'true':
                        return None
                    raise BuildFailure(f"Blacksmith build failed: {run['html_url']}")
                print(f"Blacksmith build succeeded: {run['html_url']}")
                return run_id
            sleep(10)
        cancel(api, repo, run_id, sleep)
        raise BuildFailure('Blacksmith build exceeded execution deadline')
    except BaseException as failure:
        if run_id:
            try:
                run = api(f'{repo}/actions/runs/{run_id}')
                if run['status'] != 'completed':
                    cancel(api, repo, run_id, sleep)
            except Exception as error:
                print(f'Worker cleanup failed: {error}')
        if os.environ.get('RUNNER_PROBE') == 'true' and isinstance(failure, Exception) and not isinstance(failure, BuildFailure):
            print(f'Availability probe failed; using GitHub: {failure}')
            return None
        raise


def main():
    def stopped(signum, frame):
        raise BuildFailure(f'Parent cancelled (signal {signum})')
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    run_id = execute()
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'fallback={str(run_id is None).lower()}\n')
        output.write(f'remote_run_id={run_id or ""}\n')


if __name__ == '__main__':
    main()
