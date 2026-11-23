#!/usr/bin/env python3
"""Exercise hostile runner locks with real processes and isolated ownership."""
import os
from pathlib import Path
import signal
import subprocess
import time

runner = Path(__file__).resolve().with_name('run-hostile-scenario.sh')
port = str(30000 + os.getpid() % 20000)
cases = [('static-cookie', Path('/tmp/varnish-hostile-8081.lock')),
         ('surrogate-esi-nostore', Path(f'/tmp/varnish-surrogate-esi-nostore-test-{port}.lock'))]
env = dict(os.environ, HOSTILE_SURROGATE_ESI_PORT=port, HOSTILE_LOCK_TIMEOUT='1')

for scenario, lock in cases:
    # Atomic acquisition ensures we never remove or interfere with another run's lock.
    try:
        lock.mkdir()
    except FileExistsError:
        raise SystemExit(f'Cannot safely test {scenario}: lock already exists: {lock}')
    try:
        try:
            result = subprocess.run([runner, scenario], env=env, capture_output=True,
                                    text=True, timeout=5)
        except subprocess.TimeoutExpired as exc:
            raise AssertionError(f'{scenario}: abandoned lock caused an indefinite wait') from exc
        assert result.returncode != 0, result
        assert scenario in result.stderr and str(lock) in result.stderr, result.stderr
        assert lock.is_dir(), 'waiter removed an unowned lock'

        waiter = subprocess.Popen([runner, scenario], env=dict(env, HOSTILE_LOCK_TIMEOUT='30'),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(0.2)
        assert waiter.poll() is None, 'waiter entered while lock was held'
        waiter.send_signal(signal.SIGTERM)
        waiter.communicate(timeout=5)
        assert waiter.returncode != 0 and lock.is_dir(), 'terminated waiter removed owner lock'
    finally:
        lock.rmdir()
    print(f'OK: {scenario} abandoned lock and terminated waiter')

# The owner is the runner itself, not a simulated lock holder. Its complete
# scenario also verifies normal teardown and exercises the real Docker fixture.
for scenario, lock in cases:
    owner = subprocess.Popen([runner, scenario], env=dict(env, HOSTILE_LOCK_TIMEOUT='30'),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.monotonic() + 20
        while not lock.exists() and owner.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        assert lock.is_dir() and owner.poll() is None, f'{scenario}: owner did not acquire lock'
        contender = subprocess.run([runner, scenario], env=env, capture_output=True, text=True, timeout=5)
        assert contender.returncode != 0 and str(lock) in contender.stderr, contender.stderr
        assert lock.is_dir() and owner.poll() is None, 'contender disrupted live owner'
        output, _ = owner.communicate(timeout=180)
        assert owner.returncode == 0, output
        assert not lock.exists(), f'{scenario}: completed owner retained lock'
    finally:
        if owner.poll() is None:
            owner.terminate()
            owner.communicate(timeout=180)
    print(f'OK: {scenario} live owner serialized and released lock')

    owner = subprocess.Popen([runner, scenario], env=dict(env, HOSTILE_LOCK_TIMEOUT='30'),
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        deadline = time.monotonic() + 20
        while not lock.exists() and owner.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        assert lock.is_dir() and owner.poll() is None, f'{scenario}: owner did not acquire lock'
        owner.terminate()
        output, _ = owner.communicate(timeout=180)
        assert owner.returncode != 0, output
        assert not lock.exists(), f'{scenario}: terminated owner retained lock'
    finally:
        if owner.poll() is None:
            owner.terminate()
            owner.communicate(timeout=180)
    print(f'OK: {scenario} terminated owner released lock')
