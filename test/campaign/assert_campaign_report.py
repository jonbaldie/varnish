#!/usr/bin/env python3
"""Real-process checks for the campaign's phase execution and report boundary.

Runs inside the campaign image as root. Each check runs the real orchestrator
or real phase entry points against the real /start.sh runtime, real sockets
and real cache policies; nothing is substituted.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

CAMPAIGN_DIR = os.path.dirname(os.path.abspath(__file__))
POLICY_PATH = "/etc/varnish/cache-policy.vcl"
MUTANT_POLICY = os.environ.get(
    "SURROGATE_ESI_MUTANT_POLICY", "/fixtures/cache-policy-surrogate-esi-cached.vcl"
)
PHASES = (
    "phase1_static_and_boundary",
    "phase2_cgpt_properties",
    "phase3_stateful_sequences",
    "phase4_concurrency_stress",
)
STALE_MARKER = "stale-report-from-an-earlier-run"


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print(f"OK: {message}")


def stale_report_path():
    """A report path already holding an earlier run's completed report."""
    path = os.path.join(tempfile.mkdtemp(), "report.json")
    stale = {"campaign": {"status": "completed", "marker": STALE_MARKER}}
    stale.update({p: {"status": "completed", "findings": []} for p in PHASES})
    with open(path, "w") as fh:
        json.dump(stale, fh)
    return path


def read_report(path):
    with open(path) as fh:
        return json.load(fh)


def start_orchestrator(report_path):
    return subprocess.Popen(
        [sys.executable, "orchestrator.py"],
        cwd=CAMPAIGN_DIR,
        env={**os.environ, "CAMPAIGN_REPORT": report_path},
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )


def run_orchestrator(report_path, timeout=300):
    proc = start_orchestrator(report_path)
    out, _ = proc.communicate(timeout=timeout)
    return proc.returncode, out


class MutantPolicy:
    """Swap the image's shared cache policy for a mutant, restoring it afterwards."""

    def __enter__(self):
        self.backup = tempfile.mktemp()
        shutil.copy(POLICY_PATH, self.backup)
        shutil.copy(MUTANT_POLICY, POLICY_PATH)
        return self

    def __exit__(self, *exc):
        shutil.copy(self.backup, POLICY_PATH)
        os.unlink(self.backup)


def assert_failed_startup_supersedes_stale_report():
    print("=== Startup failure: an earlier run's report is not left as the result ===")
    blocker = socket.socket()
    blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    blocker.bind(("127.0.0.1", 80))
    blocker.listen()
    report_path = stale_report_path()
    try:
        code, out = run_orchestrator(report_path, timeout=120)
    finally:
        blocker.close()

    check(code != 0, "orchestrator exits non-zero when Varnish cannot start")
    report = read_report(report_path)
    check(STALE_MARKER not in json.dumps(report), "stale report content is gone")
    check(report["campaign"]["status"] == "failed", "campaign status is failed")
    check(report["startup"]["ready"] is False, "startup records that Varnish never became ready")
    for phase in PHASES:
        check(report[phase]["status"] == "not-run", f"{phase} is marked not-run")


def assert_mutant_campaign_serializes_surrogate_finding():
    print("=== Mutant cache policy: campaign persists the Surrogate-Control finding ===")
    report_path = stale_report_path()
    with MutantPolicy():
        code, out = run_orchestrator(report_path)
    print(out[-3000:])

    check("NameError" not in out, "no NameError while formatting findings")
    check(code == 0, f"campaign exits zero when every phase completes (exit {code})")
    report = read_report(report_path)
    check(STALE_MARKER not in json.dumps(report), "stale report content is gone")
    check(report["campaign"]["status"] == "completed", "campaign status is completed")
    for phase in PHASES:
        check(report[phase]["status"] == "completed", f"{phase} completed")
        check(report[phase]["diagnostics"] == [], f"{phase} has no execution diagnostics")
        check(isinstance(report[phase]["findings"], list), f"{phase} findings are a list")

    phase2 = report["phase2_cgpt_properties"]["findings"]
    surrogate = [f for f in phase2 if "Surrogate-Control" in f.get("name", "")]
    check(surrogate, "phase 2 reports a Surrogate-Control finding")
    esi = [f for f in surrogate if 'content="ESI/1.0"' in f["name"]]
    check(esi, "the ESI advertisement variant is reported")
    evidence = esi[0]["evidence"]
    check("HIT" in evidence["second"]["x_cache"], "evidence keeps the observed X-Cache: HIT")
    check("private" in evidence["second"]["headers"].get("Cache-Control", "")
          or "no-" in evidence["second"]["headers"].get("Cache-Control", ""),
          "evidence keeps the observed Cache-Control header")
    check(all("narrative_error" not in f for f in phase2), "every finding narrative was formatted")

    stress = report["phase4_concurrency_stress"]
    for key in ("status", "reasons", "requests", "failed_connections",
                "initial_snapshot", "final_snapshot"):
        check(key in stress, f"stress report keeps {key}")
    check(stress["reasons"] == [], "healthy stress has no incomplete reasons")
    check("connection failures" in out, "summary reports stress connection failures")


def assert_transport_failure_mid_campaign_is_persisted():
    print("=== Varnish lost after phase 1: phase 2 error is persisted, later phases not-run ===")
    report_path = stale_report_path()
    proc = start_orchestrator(report_path)
    try:
        deadline = time.time() + 180
        while True:
            if proc.poll() is not None:
                raise AssertionError("orchestrator exited before phase 1 was persisted")
            if time.time() >= deadline:
                raise AssertionError("phase 1 result was not persisted while the campaign ran")
            try:
                # The stale report also says phase 1 completed; only this
                # run's report says the campaign is still running.
                report = read_report(report_path)
                if (report["campaign"]["status"] == "running"
                        and report["phase1_static_and_boundary"]["status"] == "completed"):
                    break
            except (ValueError, KeyError):
                pass
            time.sleep(0.05)
        print("OK: phase 1 result is persisted while the campaign runs")
        # The campaign runtime's varnishd manager and child, killed outright:
        # phase 2's next request meets a refused connection.
        subprocess.run(["pkill", "-KILL", "-x", "varnishd"], check=True)
        out, _ = proc.communicate(timeout=120)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    print(out[-3000:])

    check(proc.returncode != 0, f"orchestrator exits non-zero (exit {proc.returncode})")
    check("Tearing down test processes" in out, "runtime teardown still runs")
    report = read_report(report_path)
    check(STALE_MARKER not in json.dumps(report), "stale report content is gone")
    check(report["campaign"]["status"] == "failed", "campaign status is failed")
    check(report["phase1_static_and_boundary"]["status"] == "completed", "phase 1 result is kept")
    phase2 = report["phase2_cgpt_properties"]
    check(phase2["status"] == "error", "phase 2 is marked error")
    tb = "\n".join(d.get("traceback", "") for d in phase2["diagnostics"])
    check("ConnectionRefusedError" in tb or "ConnectionResetError" in tb
          or "RemoteDisconnected" in tb, "phase 2 diagnostics keep the transport error traceback")
    check(phase2["findings"] is not None, "phase 2 keeps findings collected before the error")
    for phase in PHASES[2:]:
        check(report[phase]["status"] == "not-run", f"{phase} is marked not-run")


def assert_repeated_phases_do_not_share_findings():
    print("=== Same phase twice in one process: findings are run-local ===")
    sys.path.insert(0, CAMPAIGN_DIR)
    from backend import start_backend
    from runtime_health import VarnishRuntime
    import test_properties
    import test_static_analysis

    first_static = test_static_analysis.run_all()
    second_static = test_static_analysis.run_all()
    check(first_static.status == second_static.status == "completed", "static phase completes twice")
    check(len(second_static.findings) == len(first_static.findings),
          "second static run does not carry over the first run's findings")

    backend = start_backend(8080)
    with MutantPolicy():
        runtime = VarnishRuntime.start("127.0.0.1", 80, {
            "VARNISH_STORAGE": "malloc,64m",
            "VARNISH_BACKEND_HOST": "127.0.0.1",
            "VARNISH_BACKEND_PORT": "8080",
            "VARNISH_BACKEND_PROBE_PATH": "/ready",
        })
        try:
            check(runtime.wait_ready(timeout=20), "mutant runtime becomes ready")
            first = test_properties.run_all("127.0.0.1", 80, backend)
            second = test_properties.run_all("127.0.0.1", 80, backend)
        finally:
            runtime.stop()
    check(first.status == second.status == "completed", "property phase completes twice")
    check(len(first.findings) > 0, "mutant policy produces property findings")
    check(len(second.findings) == len(first.findings),
          f"second property run has its own findings ({len(second.findings)} vs {len(first.findings)})")


def main():
    assert_failed_startup_supersedes_stale_report()
    assert_mutant_campaign_serializes_surrogate_finding()
    assert_transport_failure_mid_campaign_is_persisted()
    assert_repeated_phases_do_not_share_findings()
    print("=== Campaign phase report checks PASSED ===")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
