#!/usr/bin/env python3
"""Master Campaign Orchestrator for Varnish Bug-Finding."""

import json
import os
import sys
import time

from backend import start_backend
from phase_result import COMPLETED, PhaseResult, exception_diagnostic
from runtime_health import VarnishRuntime
import test_static_analysis
import test_properties
import test_stateful
import test_stress

REPORT_PATH = os.environ.get("CAMPAIGN_REPORT", "/campaign/report.json")

PHASES = [
    ("phase1_static_and_boundary", "Phase 1 (Static Analysis & Boundaries):  ",
     lambda runtime, backend: test_static_analysis.run_all()),
    ("phase2_cgpt_properties", "Phase 2 (Property-based & Metamorphic):  ",
     lambda runtime, backend: test_properties.run_all("127.0.0.1", 80, backend)),
    ("phase3_stateful_sequences", "Phase 3 (Stateful Sequence Minimizer):   ",
     lambda runtime, backend: test_stateful.run_all("127.0.0.1", 80, backend)),
    # Concurrency stress with 5000 requests across 20 workers.
    ("phase4_concurrency_stress", "Phase 4 (Concurrency Stress & Health):   ",
     lambda runtime, backend: test_stress.run_all(runtime, num_requests=5000, concurrency=20)),
]


class CampaignReport:
    """The campaign report on disk, rewritten after every step of this run.

    The first write replaces any earlier run's report, so the file only ever
    describes this run: every phase starts not-run and the campaign running.
    Each write goes to a temporary file renamed over the report, so a reader
    never sees a partial file.
    """

    def __init__(self, path):
        self.path = path
        self.data = {"campaign": {"status": "running"}, "startup": None}
        for key, _, _ in PHASES:
            self.data[key] = PhaseResult.not_run().to_dict()
        self.write()

    def record(self, key, value):
        self.data[key] = value
        self.write()

    def finish(self, status, diagnostics=()):
        self.data["campaign"] = {"status": status, "diagnostics": list(diagnostics)}
        self.write()

    def write(self):
        tmp = f"{self.path}.tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f, indent=2)
        os.replace(tmp, self.path)


def run_phases(report, runtime, backend):
    """Run each phase in order, persisting its result; stop at the first that is not completed."""
    for key, _, run in PHASES:
        result = run(runtime, backend)
        report.record(key, result.to_dict())
        if result.status != COMPLETED:
            print(f"\n{key} {result.status}; later phases are not run.")
            for diagnostic in result.diagnostics:
                print(diagnostic.get("traceback") or diagnostic.get("error"))
            return False
    return True


def print_summary(report):
    print("\n" + "="*70)
    print("                 CAMPAIGN EXECUTION SUMMARY")
    print("="*70)
    phases = [(label, report.data[key]) for key, label, _ in PHASES]
    total_findings = sum(len(phase["findings"]) for _, phase in phases)
    print(f"Total Unique Findings / Vulnerabilities Discovered: {total_findings}")
    for label, phase in phases:
        line = f"  - {label}{len(phase['findings'])} ({phase['status']}"
        if "requests" in phase:
            line += f", {phase['failed_connections']}/{phase['requests']} connection failures"
        print(line + ")")
        for reason in phase["reasons"]:
            print(f"    INCOMPLETE: {reason}")
    print("="*70)


def main():
    report = CampaignReport(REPORT_PATH)
    try:
        completed = run_campaign(report)
    except BaseException as exc:
        report.finish("failed", [exception_diagnostic(exc)])
        raise
    report.finish("completed" if completed else "failed")
    if not completed:
        print(f"Campaign did not complete; see {REPORT_PATH}.")
        sys.exit(1)


def run_campaign(report):
    print("******************************************************************")
    print("*    STARTING COMPREHENSIVE VARNISH BUG-FINDING CAMPAIGN         *")
    print("*    (RESOURCE-CAPPED CONTAINER EXECUTION)                       *")
    print("******************************************************************\n")

    # Step 1: Start python backend on 127.0.0.1:8080
    print("[1/2] Initializing Campaign Origin Backend on 127.0.0.1:8080...")
    backend = start_backend(8080)
    time.sleep(1)

    # Step 2: Start Varnish through the image's runtime start interface,
    # with a bounded thread pool to respect resource caps. Startup readiness and
    # the stress phase share this runtime's health snapshots.
    print("[2/2] Starting Varnish via /start.sh on 127.0.0.1:80...")
    runtime = VarnishRuntime.start("127.0.0.1", 80, {
        "VARNISH_STORAGE": "malloc,256m",
        "VARNISH_BACKEND_HOST": "127.0.0.1",
        "VARNISH_BACKEND_PORT": "8080",
        "VARNISH_BACKEND_PROBE_PATH": "/ready",
        "VARNISH_EXTRA_ARGS": (
            "-p thread_pools=1 -p thread_pool_min=10 -p thread_pool_max=50 "
            "-p default_grace=3600 -p vsl_mask=+Hash"
        ),
    })

    try:
        print("Waiting for Varnish HTTP readiness...")
        ready = runtime.wait_ready(timeout=20)
        startup = runtime.snapshot()
        report.record("startup", {"ready": ready, "snapshot": startup.to_dict()})
        if not ready or not startup.available:
            print("Varnish did not become ready!" if not ready else "Varnish runtime health is not measurable!")
            print(json.dumps(startup.diagnostics, indent=2))
            return False
        print("Varnish is UP and healthy!\n")

        completed = run_phases(report, runtime, backend)
        print_summary(report)
        return completed

    finally:
        print("\nTearing down test processes...")
        runtime.stop()

if __name__ == "__main__":
    main()
