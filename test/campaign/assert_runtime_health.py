#!/usr/bin/env python3
"""Real-process checks for the campaign runtime-health interface.

Runs inside the campaign image. Every check starts the real /start.sh runtime,
real varnishstat and real sockets; nothing is substituted.
"""

import json
import os
import signal
import sys
import time

from backend import start_backend
from runtime_health import REQUIRED_COUNTERS, VarnishRuntime
import test_stress

HOST = "127.0.0.1"
PORT = 80


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print(f"OK: {message}")


def campaign_runtime(**overrides):
    env = {
        "VARNISH_LISTEN": f"{HOST}:{PORT}",
        "VARNISH_STORAGE": "malloc,64m",
        "VARNISH_BACKEND_HOST": "127.0.0.1",
        "VARNISH_BACKEND_PORT": "8080",
        "VARNISH_BACKEND_PROBE_PATH": "/ready",
    }
    env.update(overrides)
    return VarnishRuntime.start(HOST, PORT, env)


def assert_unavailable_runtime_is_incomplete():
    print("=== Unavailable runtime: stress must not look like a healthy run ===")
    runtime = campaign_runtime(VARNISH_LISTEN="not-a-listen-address")
    try:
        check(not runtime.wait_ready(timeout=10), "start.sh with an invalid listen address never becomes ready")
        result = test_stress.run_all(runtime, num_requests=3, concurrency=1)
    finally:
        runtime.stop()

    report = json.loads(json.dumps(result.to_dict()))
    check(report["status"] == "incomplete", "stress result is incomplete")
    check(report["failed_connections"] == 3, "all three connection failures are preserved")
    check(report["requests"] == 3, "request count is preserved")
    check(report["findings"] == [], "instrumentation failure is not reported as a Varnish finding")
    for name in ("initial_snapshot", "final_snapshot"):
        snapshot = report[name]
        check(snapshot["available"] is False, f"{name} is marked unavailable")
        check(snapshot["counters"] == {}, f"{name} carries no defaulted counters")
        collectors = {d["collector"] for d in snapshot["diagnostics"]}
        check("process" in collectors, f"{name} records that the runtime process is not alive")
        stat = [d for d in snapshot["diagnostics"] if d["collector"] == "varnishstat"]
        check(len(stat) == 1, f"{name} records a varnishstat diagnostic")
        check(
            stat[0].get("returncode") not in (None, 0) or "timeout" in stat[0].get("error", ""),
            f"{name} varnishstat diagnostic keeps the exit status or timeout",
        )
        check(stat[0].get("stderr", "") != "" or "timeout" in stat[0].get("error", ""),
              f"{name} varnishstat diagnostic keeps stderr or timeout")
    check(any("start.sh exited" in r for r in report["reasons"]), "reasons name the exited start.sh")
    check(any("all 3 requests failed" in r for r in report["reasons"]), "reasons name the failed workload")


def assert_healthy_runtime_completes():
    print("=== Healthy runtime: snapshots carry real counters and stress completes ===")
    runtime = campaign_runtime()
    try:
        check(runtime.wait_ready(timeout=20), "start.sh runtime becomes ready")
        snapshot = runtime.snapshot()
        check(snapshot.available, f"startup snapshot is available: {snapshot.diagnostics}")
        check(set(REQUIRED_COUNTERS) <= set(snapshot.counters), "snapshot has every required counter")
        check(all(isinstance(v, int) for v in snapshot.counters.values()), "every counter is an integer")
        check(snapshot.counters["MGT.child_start"] >= 1, "child_start counts the running child")
        check(snapshot.manager_pid == runtime.pid, "manager identity is the start.sh process")
        check(len(snapshot.children) == 1, "exactly one Varnish child belongs to this manager")
        check(snapshot.children[0]["rss_kb"] > 0, "child RSS is measured")

        result = test_stress.run_all(runtime, num_requests=60, concurrency=4)
    finally:
        runtime.stop()

    report = result.to_dict()
    check(report["status"] == "completed", f"stress completes: {report['reasons']}")
    check(report["failed_connections"] == 0, "no connection failures against a healthy runtime")
    check(report["findings"] == [], "healthy run has no findings")
    check(report["final_snapshot"]["counters"]["MAIN.sess_conn"]
          > report["initial_snapshot"]["counters"]["MAIN.sess_conn"],
          "workload reached Varnish according to its own counters")


def assert_runtime_stopped_between_snapshots_is_incomplete():
    print("=== Runtime stopped between snapshots: not a healthy zero-finding run ===")
    runtime = campaign_runtime()
    try:
        check(runtime.wait_ready(timeout=20), "start.sh runtime becomes ready")
        initial = runtime.snapshot()
        check(initial.available, "initial snapshot is available")
        workload = test_stress.run_workload(HOST, PORT, num_requests=10, concurrency=2)
        runtime.stop()
        final = runtime.snapshot()
    finally:
        runtime.stop()

    check(not final.available, "final snapshot after stop is unavailable")
    result = test_stress.evaluate(initial, final, workload)
    check(result.status == "incomplete", "result is incomplete")
    check(result.findings == [], "no fabricated findings")
    check(any("final snapshot unavailable" in r for r in result.reasons), "reason names the lost final snapshot")


def assert_killed_child_is_a_restart_finding():
    print("=== Child killed between snapshots: restart is a Varnish finding ===")
    runtime = campaign_runtime()
    try:
        check(runtime.wait_ready(timeout=20), "start.sh runtime becomes ready")
        initial = runtime.snapshot()
        check(initial.available, "initial snapshot is available")
        os.kill(initial.children[0]["pid"], signal.SIGKILL)
        deadline = time.time() + 20
        final = runtime.snapshot()
        while time.time() < deadline and not (
            final.available and final.children[0]["pid"] != initial.children[0]["pid"]
        ):
            time.sleep(0.5)
            final = runtime.snapshot()
        check(runtime.wait_ready(timeout=20), "manager restarts the child")
        workload = test_stress.run_workload(HOST, PORT, num_requests=10, concurrency=2)
        final = runtime.snapshot()
    finally:
        runtime.stop()

    check(final.available, f"final snapshot is available: {final.diagnostics}")
    check(final.children[0]["pid"] != initial.children[0]["pid"], "child identity changed")
    result = test_stress.evaluate(initial, final, workload)
    check(result.status == "completed", "measured run completes")
    categories = [f["category"] for f in result.findings]
    check("Crash / Child Restart" in categories, "child restart is reported as a finding")


def main():
    start_backend(8080)
    assert_unavailable_runtime_is_incomplete()
    assert_healthy_runtime_completes()
    assert_runtime_stopped_between_snapshots_is_incomplete()
    assert_killed_child_is_a_restart_finding()
    print("=== Campaign runtime-health checks PASSED ===")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
