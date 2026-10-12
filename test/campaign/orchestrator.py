#!/usr/bin/env python3
"""Master Campaign Orchestrator for Varnish Bug-Finding."""

import json
import os
import sys
import time

from backend import start_backend
from runtime_health import VarnishRuntime
import test_static_analysis
import test_properties
import test_stateful
import test_stress

REPORT_PATH = os.environ.get("CAMPAIGN_REPORT", "/campaign/report.json")


def write_report(report):
    with open(REPORT_PATH, "w") as f:
        json.dump(report, f, indent=2)


def main():
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
        startup_report = {"ready": ready, "snapshot": startup.to_dict()}
        if not ready or not startup.available:
            print("Varnish did not become ready!" if not ready else "Varnish runtime health is not measurable!")
            print(json.dumps(startup.diagnostics, indent=2))
            write_report({"startup": startup_report})
            sys.exit(1)
        print("Varnish is UP and healthy!\n")

        all_reports = {
            "startup": startup_report,
            "phase1_static_and_boundary": [],
            "phase2_cgpt_properties": [],
            "phase3_stateful_sequences": [],
            "phase4_concurrency_stress": [],
        }

        # Run Phase 1
        all_reports["phase1_static_and_boundary"] = test_static_analysis.run_all()

        # Run Phase 2
        all_reports["phase2_cgpt_properties"] = test_properties.run_all("127.0.0.1", 80, backend)

        # Run Phase 3
        all_reports["phase3_stateful_sequences"] = test_stateful.run_all("127.0.0.1", 80, backend)

        # Run Phase 4 (concurrency stress with 5000 requests across 20 workers)
        stress = test_stress.run_all(runtime, num_requests=5000, concurrency=20)
        all_reports["phase4_concurrency_stress"] = stress.to_dict()

        write_report(all_reports)

        print("\n" + "="*70)
        print("                 CAMPAIGN EXECUTION SUMMARY")
        print("="*70)
        total_findings = (
            len(all_reports["phase1_static_and_boundary"]) +
            len(all_reports["phase2_cgpt_properties"]) +
            len(all_reports["phase3_stateful_sequences"]) +
            len(stress.findings)
        )
        print(f"Total Unique Findings / Vulnerabilities Discovered: {total_findings}")
        print(f"  - Phase 1 (Static Analysis & Boundaries):  {len(all_reports['phase1_static_and_boundary'])}")
        print(f"  - Phase 2 (Property-based & Metamorphic):  {len(all_reports['phase2_cgpt_properties'])}")
        print(f"  - Phase 3 (Stateful Sequence Minimizer):   {len(all_reports['phase3_stateful_sequences'])}")
        print(f"  - Phase 4 (Concurrency Stress & Health):   {len(stress.findings)}"
              f" ({stress.status}, {stress.failed_connections}/{stress.requests} connection failures)")
        for reason in stress.reasons:
            print(f"    INCOMPLETE: {reason}")
        print("="*70)

        if stress.status != "completed":
            print(f"Phase 4 could not measure Varnish health; see {REPORT_PATH}.")
            sys.exit(1)

    finally:
        print("\nTearing down test processes...")
        runtime.stop()

if __name__ == "__main__":
    main()
